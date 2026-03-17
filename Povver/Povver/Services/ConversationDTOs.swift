import Foundation
import FirebaseFirestore

// MARK: - DTOs matching platformvision.md

public enum CanvasPhase: String, Codable { case planning, active, analysis }

public struct CanvasStateDTO: Codable {
    public let phase: CanvasPhase?
    public let version: Int?
    public let purpose: String?
    public let lanes: [String]?
}

public struct UpNextEntryDTO: Codable {
    public let card_id: String
    public let priority: Int
    public let inserted_at: Date?
}

public struct CanvasActionDTO: Codable {
    public let type: String
    public let card_id: String?
    public let payload: [String: AnyCodable]?
    public let by: String?
    public let idempotency_key: String
}

public struct ApplyActionRequestDTO: Codable {
    public let canvasId: String
    public let expected_version: Int?
    public let action: CanvasActionDTO
}

public struct ChangedCardDTO: Codable { public let card_id: String; public let status: String }

public struct ApplyActionResponseDTO: Codable {
    public struct DataDTO: Codable {
        public let state: CanvasStateDTO?
        public let changed_cards: [ChangedCardDTO]?
        public let up_next_delta: [AnyCodable]?
        public let version: Int?
    }
    public let success: Bool
    public let data: DataDTO?
    public let error: ActionErrorDTO?
}

public struct ActionErrorDTO: Codable { public let code: String; public let message: String; public let details: [String: AnyCodable]? }

// MARK: - Aggregated Snapshot for UI

public struct ConversationSnapshot {
    public let version: Int
    public let state: CanvasStateDTO
    public let cards: [CanvasCardModel]
    public let upNext: [String]
}

// MARK: - Firestore Mappers

public enum ConversationMapper {
    public static func mapCard(from doc: DocumentSnapshot) -> CanvasCardModel? {
        let data = doc.data() ?? [:]
        guard let statusStr = data["status"] as? String else { return nil }
        let rawType = (data["type"] as? String) ?? "summary"
        let laneStr = (data["lane"] as? String) ?? "analysis"
        let title = data["title"] as? String
        let subtitle = data["subtitle"] as? String
        let status = CardStatus(rawValue: statusStr) ?? .active
        let lane = CardLane(rawValue: laneStr) ?? .analysis

        // Shared fields
        var width: CardWidth = .oneHalf
        if let w = (data["layout"] as? [String: Any])?["width"] as? String { width = CardWidth(rawValue: w) ?? width }
        else if let w = data["width"] as? String { width = CardWidth(rawValue: w) ?? width }

        let actions = parseActions(array: data["actions"]) ?? []
        let menuItems = parseActions(array: data["menuItems"]) ?? []
        let meta: CardMeta? = {
            guard let m = data["meta"] as? [String: Any] else { return nil }
            let context = m["context"] as? String
            let groupId = m["groupId"] as? String ?? m["group_id"] as? String
            let pinned = m["pinned"] as? Bool
            let dismissible = m["dismissible"] as? Bool
            return CardMeta(context: context, groupId: groupId, pinned: pinned, dismissible: dismissible)
        }()

        // Content mapping (tolerant to evolving backend types)
        let content = data["content"] as? [String: Any]
        let modelData: CanvasCardData = {
            switch rawType {
            case "visualization":
                // Try to parse full visualization spec
                if let content = content,
                   let chartTypeStr = content["chart_type"] as? String,
                   let chartType = ChartType(rawValue: chartTypeStr) {
                    
                    let title = (content["title"] as? String) ?? "Chart"
                    let subtitle = content["subtitle"] as? String
                    
                    // Parse data
                    let dataDict = content["data"] as? [String: Any]
                    let chartData = parseChartData(from: dataDict)
                    
                    // Parse annotations
                    let annotationsArr = content["annotations"] as? [[String: Any]]
                    let annotations = parseAnnotations(from: annotationsArr)
                    
                    let metricKey = content["metric_key"] as? String
                    let emptyState = content["empty_state"] as? String
                    
                    let spec = VisualizationSpec(
                        chartType: chartType,
                        title: title,
                        subtitle: subtitle,
                        data: chartData,
                        annotations: annotations,
                        metricKey: metricKey,
                        emptyState: emptyState
                    )
                    return .visualization(spec: spec)
                } else {
                    // Fallback to legacy format
                    let t = (content?["chart_type"] as? String) ?? "chart"
                    return .visualizationLegacy(title: t.capitalized, subtitle: nil)
                }
            case "session_plan":
                let blocks = (content?["blocks"] as? [[String: Any]]) ?? []
                let exercises: [PlanExercise] = blocks.compactMap { blk in
                    let exName = (blk["name"] as? String) ?? (blk["exercise_name"] as? String)
                    let exId = blk["exercise_id"] as? String
                    
                    // Build sets array
                    var planSets: [PlanSet] = []
                    
                    if let setsArr = blk["sets"] as? [[String: Any]] {
                        // New format: explicit per-set array
                        planSets = setsArr.map { setDict in
                            // Handle both direct format and target-wrapped format
                            let target = (setDict["target"] as? [String: Any]) ?? setDict
                            
                            let typeStr = (target["type"] as? String) ?? (setDict["type"] as? String)
                            let setType: SetType? = typeStr.flatMap { SetType(rawValue: $0) }
                            let reps = (target["reps"] as? Int) ?? 8
                            let rir = target["rir"] as? Int
                            let weight = (target["weight"] as? Double) 
                                ?? (target["weight_kg"] as? Double)
                                ?? (target["weight"] as? Int).map { Double($0) }
                            let setId = (setDict["id"] as? String) ?? UUID().uuidString
                            
                            return PlanSet(
                                id: setId,
                                type: setType ?? .working,
                                reps: reps,
                                weight: weight,
                                rir: rir
                            )
                        }
                    } else {
                        // Legacy format: sets as Int with separate reps/rir/weight
                        var setCount = 3
                        if let setsInt = blk["sets"] as? Int {
                            setCount = setsInt
                        } else if let setCountValue = blk["set_count"] as? Int {
                            setCount = setCountValue
                        }
                        
                        let reps = (blk["reps"] as? Int) ?? 8
                        let rir = blk["rir"] as? Int
                        let weight: Double? = (blk["weight"] as? Double) ?? (blk["weight"] as? Int).map { Double($0) }
                        
                        // Expand to identical working sets
                        planSets = (0..<max(setCount, 1)).map { _ in
                            PlanSet(type: .working, reps: reps, weight: weight, rir: rir)
                        }
                    }
                    
                    // Extract primary muscles and equipment
                    let primaryMuscles = (blk["primary_muscles"] as? [String]) ?? (blk["primaryMuscles"] as? [String])
                    let equipment = blk["equipment"] as? String
                    let coachNote = blk["notes"] as? String ?? blk["coach_note"] as? String
                    
                    let label = exName ?? exId
                    guard let name = label else { return nil }
                    
                    return PlanExercise(
                        id: (blk["id"] as? String) ?? UUID().uuidString,
                        exerciseId: exId,
                        name: name,
                        sets: planSets,
                        primaryMuscles: primaryMuscles,
                        equipment: equipment,
                        coachNote: coachNote
                    )
                }
                return .sessionPlan(exercises: exercises)
            case "proposal-group":
                return .groupHeader(title: title ?? (content?["title"] as? String ?? ""))
            case "inline-info":
                let text = (content?["text"] as? String) ?? (content?["summary"] as? String) ?? "Info"
                return .inlineInfo(text)
            case "clarify-questions":
                let qsArray = (content?["questions"] as? [[String: Any]]) ?? []
                let qs: [ClarifyQuestion] = qsArray.compactMap { q in
                    // Support both 'text' and 'label' fields for backwards compatibility
                    guard let text = (q["text"] as? String) ?? (q["label"] as? String) else { return nil }
                    let typeStr = (q["type"] as? String) ?? "text"
                    let qType = ClarifyQuestionType(rawValue: typeStr) ?? .text
                    let opts = q["options"] as? [String]
                    let qId = (q["id"] as? String) ?? UUID().uuidString
                    return ClarifyQuestion(id: qId, text: text, options: opts, type: qType)
                }
                return .clarifyQuestions(qs)
            case "routine-overview":
                let split = (content?["split"] as? String) ?? ""
                let days = (content?["days"] as? Int) ?? 0
                let notes = content?["notes"] as? String
                return .routineOverview(split: split, days: days, notes: notes)
            case "agent-message":
                let type = content?["type"] as? String
                let status = content?["status"] as? String
                let message = content?["message"] as? String
                let thoughts = content?["thoughts"] as? [String]
                
                var toolCalls: [ToolCall]? = nil
                if let tools = content?["toolCalls"] as? [[String: Any]] {
                    toolCalls = tools.map { tool in
                        ToolCall(
                            id: (tool["id"] as? String) ?? UUID().uuidString,
                            name: (tool["name"] as? String) ?? "",
                            displayName: (tool["displayName"] as? String) ?? (tool["name"] as? String) ?? "",
                            duration: tool["duration"] as? String
                        )
                    }
                }
                
                return .agentMessage(AgentMessage(
                    type: type,
                    status: status,
                    message: message,
                    toolCalls: toolCalls,
                    thoughts: thoughts
                ))
            case "list":
                let items = (content?["items"] as? [[String: Any]]) ?? []
                let options: [ListOption] = items.map { item in
                    ListOption(title: (item["title"] as? String) ?? "Item",
                               subtitle: item["subtitle"] as? String,
                               iconSystemName: item["iconSystemName"] as? String)
                }
                return .list(options: options)
            case "routine_summary":
                // Parse routine summary for multi-day routine drafts
                let name = (content?["name"] as? String) ?? "Routine"
                let description = content?["description"] as? String
                let frequency = (content?["frequency"] as? Int) ?? 3
                let draftId = content?["draft_id"] as? String
                let revision = content?["revision"] as? Int
                
                // Parse workouts array
                let workoutsArr = (content?["workouts"] as? [[String: Any]]) ?? []
                let workouts: [RoutineWorkoutSummary] = workoutsArr.enumerated().map { (idx, workout) in
                    let day = (workout["day"] as? Int) ?? (idx + 1)
                    let cardId = workout["card_id"] as? String
                    // Derive stable ID from draftId+day when card_id is absent to prevent edit loss on re-parse
                    let stableId = cardId ?? (draftId.map { "\($0)-day\(day)" } ?? "workout-day\(day)")
                    
                    return RoutineWorkoutSummary(
                        id: stableId,
                        day: day,
                        title: (workout["title"] as? String) ?? "Day \(day)",
                        cardId: cardId,
                        estimatedDuration: (workout["estimated_duration"] as? Int) ?? (workout["estimatedDuration"] as? Int),
                        exerciseCount: (workout["exercise_count"] as? Int) ?? (workout["exerciseCount"] as? Int),
                        muscleGroups: workout["muscle_groups"] as? [String]
                    )
                }
                
                let summaryData = RoutineSummaryData(
                    name: name,
                    description: description,
                    frequency: frequency,
                    workouts: workouts,
                    draftId: draftId,
                    revision: revision
                )
                return .routineSummary(summaryData)
            case "analysis_summary":
                // Parse analysis summary for progress insights from Analysis Agent
                let headline = (content?["headline"] as? String) ?? "Progress Analysis"
                
                // Parse period
                let period: AnalysisPeriod? = {
                    guard let periodDict = content?["period"] as? [String: Any] else { return nil }
                    let weeks = (periodDict["weeks"] as? Int) ?? 8
                    let end = periodDict["end"] as? String
                    return AnalysisPeriod(weeks: weeks, end: end)
                }()
                
                // Parse insights
                let insightsArr = (content?["insights"] as? [[String: Any]]) ?? []
                let insights: [AnalysisInsight] = insightsArr.enumerated().map { (idx, i) in
                    AnalysisInsight(
                        id: (i["id"] as? String) ?? "insight-\(idx)",
                        category: (i["category"] as? String) ?? "general",
                        signal: (i["signal"] as? String) ?? "",
                        trend: (i["trend"] as? String) ?? "stable",
                        metricKey: i["metric_key"] as? String,
                        value: i["value"] as? Double,
                        confidence: i["confidence"] as? String
                    )
                }
                
                // Parse recommendations
                let recsArr = (content?["recommendations"] as? [[String: Any]]) ?? []
                let recommendations: [AnalysisRecommendation] = recsArr.enumerated().map { (idx, r) in
                    AnalysisRecommendation(
                        id: (r["id"] as? String) ?? "rec-\(idx)",
                        priority: (r["priority"] as? Int) ?? 3,
                        action: (r["action"] as? String) ?? "",
                        rationale: (r["rationale"] as? String) ?? "",
                        category: r["category"] as? String
                    )
                }
                
                // Parse data quality
                let dataQuality: AnalysisDataQuality? = {
                    guard let dq = content?["data_quality"] as? [String: Any] else { return nil }
                    return AnalysisDataQuality(
                        weeksWithData: (dq["weeks_with_data"] as? Int) ?? 0,
                        workoutsAnalyzed: (dq["workouts_analyzed"] as? Int) ?? 0,
                        confidence: (dq["confidence"] as? String) ?? "low",
                        caveats: dq["caveats"] as? [String]
                    )
                }()
                
                let summaryData = AnalysisSummaryData(
                    headline: headline,
                    period: period,
                    insights: insights,
                    recommendations: recommendations,
                    dataQuality: dataQuality
                )
                return .analysisSummary(summaryData)
            case "analysis_task":
                if let steps = (content?["steps"] as? [[String: Any]]) {
                    let parsed: [AgentStreamStep] = steps.map { s in
                        let kindStr = (s["kind"] as? String) ?? (s["type"] as? String) ?? "info"
                        let kind = AgentStreamStep.Kind(rawValue: kindStr) ?? .info
                        return AgentStreamStep(kind: kind, text: s["text"] as? String, durationMs: s["durationMs"] as? Int)
                    }
                    return .agentStream(steps: parsed)
                }
                fallthrough
            default:
                let text = (content?["text"] as? String) ?? (content?["summary"] as? String) ?? rawType.capitalized
                return .text(text)
            }
        }()

        let cardType = CardType(rawValue: rawType) ?? {
            // Map certain UI-only types to closest generic CardType for tagging
            switch rawType {
            case "proposal-group", "inline-info", "list", "clarify-questions", "routine-overview": return .summary
            default: return .summary
            }
        }()

        let publishedAt = (data["created_at"] as? Timestamp)?.dateValue()
            ?? (data["updated_at"] as? Timestamp)?.dateValue()
        
        return CanvasCardModel(
            id: doc.documentID,
            type: cardType,
            status: status,
            lane: lane,
            title: title,
            subtitle: subtitle,
            data: modelData,
            width: width,
            actions: actions,
            menuItems: menuItems,
            meta: meta,
            publishedAt: publishedAt
        )
    }

    // MARK: - Chart Data Parsing
    
    private static func parseChartData(from dict: [String: Any]?) -> ChartData? {
        guard let dict = dict else { return nil }
        
        // Parse axes
        let xAxis: ChartAxis? = {
            guard let axisDict = dict["x_axis"] as? [String: Any] else { return nil }
            return ChartAxis(
                key: axisDict["key"] as? String,
                label: axisDict["label"] as? String,
                type: axisDict["type"] as? String,
                unit: axisDict["unit"] as? String,
                min: axisDict["min"] as? Double,
                max: axisDict["max"] as? Double
            )
        }()
        
        let yAxis: ChartAxis? = {
            guard let axisDict = dict["y_axis"] as? [String: Any] else { return nil }
            return ChartAxis(
                key: axisDict["key"] as? String,
                label: axisDict["label"] as? String,
                type: axisDict["type"] as? String,
                unit: axisDict["unit"] as? String,
                min: axisDict["min"] as? Double,
                max: axisDict["max"] as? Double
            )
        }()
        
        // Parse series (for line/bar charts)
        let series: [ChartSeries]? = {
            guard let arr = dict["series"] as? [[String: Any]] else { return nil }
            return arr.map { s in
                let name = (s["name"] as? String) ?? "Series"
                let colorStr = s["color"] as? String
                let color = colorStr.flatMap { ChartColorToken(rawValue: $0) } ?? .primary
                
                let pointsArr = (s["points"] as? [[String: Any]]) ?? []
                let points: [ChartDataPoint] = pointsArr.map { p in
                    let x: Double = (p["x"] as? Double) ?? (p["x"] as? Int).map { Double($0) } ?? 0
                    let y: Double = (p["y"] as? Double) ?? (p["y"] as? Int).map { Double($0) } ?? 0
                    let label = p["label"] as? String
                    return ChartDataPoint(x: x, y: y, label: label, date: nil)
                }
                
                return ChartSeries(name: name, color: color, points: points)
            }
        }()
        
        // Parse rows (for tables)
        let rows: [ChartTableRow]? = {
            guard let arr = dict["rows"] as? [[String: Any]] else { return nil }
            return arr.map { r in
                let rank = (r["rank"] as? Int) ?? 0
                let label = (r["label"] as? String) ?? ""
                
                // Handle flexible value type
                let value: String
                let numericValue: Double?
                if let num = r["value"] as? Double {
                    value = String(format: "%.1f", num)
                    numericValue = num
                } else if let intVal = r["value"] as? Int {
                    value = String(intVal)
                    numericValue = Double(intVal)
                } else {
                    value = (r["value"] as? String) ?? ""
                    numericValue = Double(value)
                }
                
                let delta = r["delta"] as? Double
                let trendStr = r["trend"] as? String
                let trend = trendStr.flatMap { TrendDirection(rawValue: $0) }
                let sublabel = r["sublabel"] as? String
                
                return ChartTableRow(
                    rank: rank,
                    label: label,
                    value: value,
                    numericValue: numericValue,
                    delta: delta,
                    trend: trend,
                    sublabel: sublabel
                )
            }
        }()
        
        // Parse columns (for tables)
        let columns: [ChartTableColumn]? = {
            guard let arr = dict["columns"] as? [[String: Any]] else { return nil }
            return arr.map { c in
                ChartTableColumn(
                    key: (c["key"] as? String) ?? "",
                    label: (c["label"] as? String) ?? "",
                    width: c["width"] as? String,
                    align: c["align"] as? String
                )
            }
        }()
        
        return ChartData(
            xAxis: xAxis,
            yAxis: yAxis,
            series: series,
            rows: rows,
            columns: columns
        )
    }
    
    private static func parseAnnotations(from arr: [[String: Any]]?) -> [ChartAnnotation]? {
        guard let arr = arr, !arr.isEmpty else { return nil }
        
        // We can't directly create ChartAnnotation since init(from:) requires a decoder
        // For now, return nil and we'll handle this later
        // TODO: Add a direct initializer to ChartAnnotation
        return nil
    }
    
    private static func parseActions(array: Any?) -> [CardAction]? {
        guard let arr = array as? [[String: Any]] else { return nil }
        return arr.compactMap { a in
            guard let kind = a["kind"] as? String ?? a["type"] as? String,
                  let label = a["label"] as? String ?? a["title"] as? String else { return nil }
            let styleStr = a["style"] as? String
            let style = styleStr.flatMap { CardActionStyle(rawValue: $0) }
            let icon = a["iconSystemName"] as? String ?? a["icon"] as? String
            return CardAction(kind: kind, label: label, style: style, iconSystemName: icon)
        }
    }
}
