# Conversation UI — Module Architecture

The Conversation UI is the primary AI interaction surface. It displays agent-proposed cards organized in a grid layout, handles agent streaming visualization, and provides card-level actions (accept, reject, start workout, swap exercise).

## File Inventory

### Core Layout

| File | Purpose |
|------|---------|
| `Models.swift` | Canvas card models: `CanvasCardModel`, `CardType`, `CardLane`, `CardStatus`, `CanvasCardData` |
| `ConversationGridView.swift` | Masonry grid layout for cards |
| `CardContainer.swift` | Universal card wrapper with header, actions, and status badge |
| `CardHeader.swift` | Card title, subtitle, status indicator |
| `CardActionEnvironment.swift` | Environment object for propagating card action handlers |
| `UpNextRailView.swift` | Horizontal rail showing up-next card queue |
| `PinnedRailView.swift` | Pinned cards rail |
| `WorkoutRailView.swift` | Horizontal exercise rail for workout cards |
| `WorkspaceTimelineView.swift` | Timeline of workspace events |
| `ThinkingBubble.swift` | Gemini-style collapsible thinking bubble with live progress and elapsed timer |

### Cards (`Cards/`)

| File | Card Type | Purpose |
|------|-----------|---------|
| `SessionPlanCard.swift` | `session_plan` | Workout plan with exercises and sets grid |
| `RoutineSummaryCard.swift` | `routine_summary` | Multi-day routine overview (anchor card) |
| `RoutineOverviewCard.swift` | `routine_overview` | Routine summary display |
| `VisualizationCard.swift` | `visualization` | Charts (line, bar, table) |
| `AnalysisSummaryCard.swift` | `analysis_summary` | Progress analysis results |
| `ClarifyQuestionsCard.swift` | `clarify_questions` | Agent clarification questions |
| `AgentStreamCard.swift` | `agent_stream` | Live streaming agent output |
| `AgentMessageCard.swift` | — | Agent message display |
| `ChatCard.swift` | `chat` | Chat message card |
| `SuggestionCard.swift` | `suggestion` | Quick action suggestions |
| `SmallContentCard.swift` | `text` | Simple text content |
| `ListCardWithExpandableOptions.swift` | `list_card` | Generic expandable list |
| `VisualCard.swift` | — | Visual content card |
| `ProposalGroupHeader.swift` | — | Accept-all / Reject-all group actions |
| `SetGridView.swift` | — | Exercise set editing grid (used within cards) |
| `ExerciseDetailSheet.swift` | — | Exercise detail modal |

### Shared Card Components (`Cards/Shared/`)

| File | Purpose |
|------|---------|
| `ExerciseRowView.swift` | Single exercise row in a workout card |
| `ExerciseSwapSheet.swift` | Exercise swap modal |
| `ExerciseActionsRow.swift` | Per-exercise action buttons |
| `IterationActionsRow.swift` | Iteration-level action buttons |

### Charts (`Charts/`)

| File | Purpose |
|------|---------|
| `LineChartView.swift` | Line chart for trends |
| `BarChartView.swift` | Bar chart for comparisons |
| `RankedTableView.swift` | Ranked data table |
| `VisualizationModels.swift` | Chart data models |

## Card Type → View Mapping

The `CardContainer` dispatches to the correct card view based on `CanvasCardModel.type`:

```
session_plan      → SessionPlanCard
routine_summary   → RoutineSummaryCard
routine_overview  → RoutineOverviewCard
visualization     → VisualizationCard
analysis_summary  → AnalysisSummaryCard
clarify_questions → ClarifyQuestionsCard
agent_stream      → AgentStreamCard
suggestion        → SuggestionCard
text              → SmallContentCard
list_card         → ListCardWithExpandableOptions
```

## Key Model Details

### PlanSet Decoding

`PlanSet` (in `Models.swift`) supports two set formats:
1. **Flat**: `{ reps, rir, weight }` at top level (template/legacy format)
2. **Target-wrapped**: `{ target: { reps, rir, weight } }` (agent artifact format)

The custom decoder tries the flat path first, then falls back to unwrapping the `target` object. This ensures both agent-emitted artifacts and template-sourced data decode correctly.

### RoutineWorkoutSummary

Has an optional `blocks: [PlanExercise]?` field for inline exercises from SSE artifacts. When present, `RoutineSummaryCard.getExercisesFromLinkedCard()` prefers inline blocks over linked card lookup (the canvas-era pattern).

### CardMeta Artifact Provenance

`CardMeta` includes `artifactId` and `conversationId` fields populated when cards originate from SSE artifact events. These enable `CanvasScreen` to route actions (save_routine, accept, dismiss) through `AgentsApi.artifactAction()` instead of the legacy `applyAction` canvas reducer.

## Cross-References

- Card type schemas: `firebase_functions/functions/canvas/schemas/card_types/`
- Conversation ViewModel: `Povver/Povver/ViewModels/ConversationViewModel.swift`
- Conversation Screen: `Povver/Povver/Views/ConversationScreen.swift`
- Design tokens: `Povver/Povver/UI/DesignSystem/Tokens.swift`
- Artifact action endpoint: `firebase_functions/functions/artifacts/artifact-action.js`
