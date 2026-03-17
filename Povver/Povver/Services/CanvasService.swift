import Foundation

// =============================================================================
// MARK: - CanvasService.swift
// =============================================================================
//
// PURPOSE:
// Client for Canvas-related Firebase Functions. This is the primary interface
// between the iOS app and the Canvas backend for all state mutations.
//
// ARCHITECTURE CONTEXT:
// ┌─────────────────┐       ┌─────────────────────────────────┐
// │ iOS App         │       │ Firebase Functions              │
// │                 │       │                                 │
// │ CanvasService ──┼──────►│ applyAction (apply-action.js)   │
// │                 │       │ openCanvas (open-canvas.js)     │
// │                 │       │ bootstrapCanvas (bootstrap-canvas.js)
// │                 │       │ initializeSession (initialize-session.js)
// │                 │       │ purgeCanvas (bootstrap-canvas.js)│
// └─────────────────┘       └─────────────────────────────────┘
//
// KEY FIREBASE FUNCTION ENDPOINTS CALLED:
// - applyAction → firebase_functions/functions/canvas/apply-action.js
//   The single-writer reducer for all canvas mutations
// - openCanvas → firebase_functions/functions/canvas/open-canvas.js
//   Combined bootstrap + session initialization (saves round trips)
// - bootstrapCanvas → firebase_functions/functions/canvas/bootstrap-canvas.js
//   Creates or returns existing canvas for (userId, purpose)
// - initializeSession → firebase_functions/functions/canvas/initialize-session.js
//   Initializes Vertex AI Agent Engine session
// - purgeCanvas → firebase_functions/functions/canvas/bootstrap-canvas.js
//   Clears canvas workspace entries
//
// RELATED IOS FILES:
// - CanvasViewModel.swift: Uses this service for all canvas operations
// - CanvasDTOs.swift: Request/response DTOs used by this service
// - ApiClient.swift: Underlying HTTP client with auth
// - CanvasRepository.swift: Firestore subscriptions (reads cards written by applyAction)
//
// DATA FLOW:
// 1. User action in UI → CanvasViewModel.applyAction()
// 2. CanvasViewModel calls CanvasService.applyAction()
// 3. CanvasService → HTTP POST to Firebase Function (applyAction)
// 4. Firebase runs reducer in Firestore transaction
// 5. Cards written to Firestore users/{uid}/canvases/{canvasId}/cards
// 6. CanvasRepository's Firestore listener receives changes
// 7. CanvasViewModel updates UI state
//
// =============================================================================

// MARK: - Response DTOs

struct InitializeSessionResponse: Codable {
    let success: Bool
    let sessionId: String?
    let isReused: Bool?
    let latencyMs: Int?
    let error: String?
}

/// Combined response from openCanvas - returns both canvasId and sessionId in one call
/// Corresponds to firebase_functions/functions/canvas/open-canvas.js response
struct OpenCanvasResponse: Codable {
    let success: Bool
    let canvasId: String?
    let sessionId: String?
    let isNewSession: Bool?
    let resumeState: ResumeState?
    let timing: TimingInfo?
    let error: String?
    
    struct ResumeState: Codable {
        let cards: [AnyCodable]?
        let lastEntryCursor: String?
        let cardCount: Int?
    }
    
    struct TimingInfo: Codable {
        let totalMs: Int?
    }
}

/// Response from preWarmSession - warms the session before canvas is opened
struct PreWarmResponse: Codable {
    let success: Bool
    let sessionId: String?
    let isNew: Bool?
    let error: String?
}

// MARK: - Protocol

protocol CanvasServiceProtocol {
    /// Apply a canvas action via the single-writer reducer
    /// Calls: firebase_functions/functions/canvas/apply-action.js
    func applyAction(_ req: ApplyActionRequestDTO) async throws -> ApplyActionResponseDTO
    
    /// Create or return existing canvas for (userId, purpose)
    /// Calls: firebase_functions/functions/canvas/bootstrap-canvas.js
    func bootstrapCanvas(for userId: String, purpose: String) async throws -> String
    
    /// Clear canvas workspace entries
    /// Calls: firebase_functions/functions/canvas/bootstrap-canvas.js (purgeCanvas export)
    func purgeCanvas(userId: String, canvasId: String, dropEvents: Bool, dropState: Bool, dropWorkspace: Bool) async throws
    
    /// Initialize Vertex AI Agent Engine session for a canvas
    /// Calls: firebase_functions/functions/canvas/initialize-session.js
    func initializeSession(canvasId: String, purpose: String, forceNew: Bool) async throws -> String
    
    /// Combined endpoint - creates canvas and session in a single call (saves 1-2 round trips)
    /// Calls: firebase_functions/functions/canvas/open-canvas.js
    func openCanvas(userId: String, purpose: String) async throws -> (canvasId: String, sessionId: String)
    
    /// Pre-warm the session before the canvas is opened (call on app launch or Home screen)
    func preWarmSession(userId: String, purpose: String) async throws -> String
}

extension CanvasServiceProtocol {
    func initializeSession(canvasId: String, purpose: String) async throws -> String {
        try await initializeSession(canvasId: canvasId, purpose: purpose, forceNew: false)
    }
}

extension CanvasServiceProtocol {
    func purgeCanvas(userId: String, canvasId: String) async throws {
        try await purgeCanvas(userId: userId, canvasId: canvasId, dropEvents: false, dropState: false, dropWorkspace: true)
    }
}

// MARK: - Implementation

final class CanvasService: CanvasServiceProtocol {
    
    // =========================================================================
    // MARK: applyAction
    // =========================================================================
    // The single-writer mutation endpoint. ALL canvas state changes flow through here.
    //
    // Backend: firebase_functions/functions/canvas/apply-action.js
    //
    // The backend runs a reducer in a Firestore transaction:
    // 1. Validates idempotency key (prevents duplicate actions)
    // 2. Checks expected_version for optimistic concurrency
    // 3. Validates card schemas with Ajv
    // 4. Applies business logic based on action.type
    // 5. Writes updated cards to users/{uid}/canvases/{canvasId}/cards
    // 6. Increments state.version
    // 7. Appends event to users/{uid}/canvases/{canvasId}/events
    //
    // Action types: ACCEPT_PROPOSAL, REJECT_PROPOSAL, ADD_INSTRUCTION, LOG_SET,
    //               SWAP, ADJUST_LOAD, REORDER_SETS, COMPLETE, etc.
    //
    // Related DTOs: ApplyActionRequestDTO, ApplyActionResponseDTO (CanvasDTOs.swift)
    // =========================================================================
    func applyAction(_ req: ApplyActionRequestDTO) async throws -> ApplyActionResponseDTO {
        // Log canvas action
        let actionDesc = "action:\(req.action.type) card=\(req.action.card_id ?? "nil") v=\(req.expected_version ?? -1)"
        AppLogger.shared.info(.app, actionDesc)

        // POST to Firebase Function via ApiClient (uses Firebase Auth token)
        // Note: ApiClient already logs the full HTTP request/response
        let res: ApplyActionResponseDTO = try await ApiClient.shared.postJSON("applyAction", body: req)

        // Log the result
        if res.success == true, let data = res.data {
            AppLogger.shared.info(.app, "applyAction succeeded v=\(data.version ?? -1) cards=\(data.changed_cards?.count ?? 0)")
        } else if let err = res.error {
            AppLogger.shared.error(.app, "applyAction failed: \(err.code)")
        }
        
        return res
    }

    // =========================================================================
    // MARK: bootstrapCanvas
    // =========================================================================
    // Creates a new canvas or returns existing one for (userId, purpose).
    //
    // Backend: firebase_functions/functions/canvas/bootstrap-canvas.js
    //
    // The backend:
    // 1. Looks up existing canvas at users/{uid}/canvases/{purpose}
    // 2. If found, returns existing canvasId
    // 3. If not found, creates new canvas with initial state
    //
    // NOTE: Prefer openCanvas() which combines this with session initialization.
    // =========================================================================
    func bootstrapCanvas(for userId: String, purpose: String) async throws -> String {
        struct Req: Codable { let userId: String; let purpose: String }
        struct DataDTO: Codable { let canvasId: String }
        struct Envelope: Codable { let success: Bool; let data: DataDTO?; let error: ActionErrorDTO? }
        
        AppLogger.shared.info(.app, "bootstrapCanvas user=\(userId.prefix(8)) purpose=\(purpose)")
        let env: Envelope = try await ApiClient.shared.postJSON("bootstrapCanvas", body: Req(userId: userId, purpose: purpose))

        if env.success, let id = env.data?.canvasId {
            AppLogger.shared.info(.app, "bootstrapCanvas success id=\(id.prefix(8))")
        }
        if env.success, let id = env.data?.canvasId { return id }
        let message = env.error?.message ?? "Failed to bootstrap canvas"
        throw NSError(domain: "CanvasService", code: 500, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // =========================================================================
    // MARK: purgeCanvas
    // =========================================================================
    // Clears workspace entries from a canvas. Used to reset canvas state.
    //
    // Backend: firebase_functions/functions/canvas/bootstrap-canvas.js (purgeCanvas export)
    //
    // Options:
    // - dropEvents: Clear events subcollection
    // - dropState: Reset canvas state document
    // - dropWorkspace: Clear up_next queue (most common use)
    // =========================================================================
    func purgeCanvas(userId: String, canvasId: String, dropEvents: Bool = false, dropState: Bool = false, dropWorkspace: Bool = true) async throws {
        struct Req: Codable {
            let userId: String
            let canvasId: String
            let dropEvents: Bool
            let dropState: Bool
            let dropWorkspace: Bool
        }
        struct Envelope: Codable { let success: Bool; let error: ActionErrorDTO? }

        let req = Req(userId: userId, canvasId: canvasId, dropEvents: dropEvents, dropState: dropState, dropWorkspace: dropWorkspace)
        AppLogger.shared.info(.app, "purgeCanvas canvas=\(canvasId.prefix(8)) dropWorkspace=\(dropWorkspace)")
        let env: Envelope = try await ApiClient.shared.postJSON("purgeCanvas", body: req)

        if env.success {
            AppLogger.shared.info(.app, "purgeCanvas success")
        } else if let err = env.error {
            AppLogger.shared.error(.app, "purgeCanvas error: \(err.code)")
        }
        guard env.success else {
            let message = env.error?.message ?? "Failed to purge canvas"
            throw NSError(domain: "CanvasService", code: 500, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
    
    // =========================================================================
    // MARK: initializeSession
    // =========================================================================
    // Initializes a Vertex AI Agent Engine session for a canvas.
    //
    // Backend: firebase_functions/functions/canvas/initialize-session.js
    //
    // The backend:
    // 1. Checks for existing session in canvases/{canvasId}/state.sessionId
    // 2. If forceNew=false and session exists, validates it's still alive
    // 3. If no session or forceNew=true, creates new Agent Engine session
    // 4. Stores sessionId in canvas state
    //
    // The sessionId is then used by DirectStreamingService to stream to the agent.
    //
    // Related files:
    // - DirectStreamingService.swift: Uses sessionId for SSE streaming
    // - firebase_functions/functions/strengthos/stream-agent-normalized.js: SSE endpoint
    // =========================================================================
    func initializeSession(canvasId: String, purpose: String, forceNew: Bool = false) async throws -> String {
        struct Req: Codable { let canvasId: String; let purpose: String; let forceNew: Bool }
        
        AppLogger.shared.info(.app, "initializeSession canvas=\(canvasId.prefix(8)) forceNew=\(forceNew)")
        let response: InitializeSessionResponse = try await ApiClient.shared.postJSON("initializeSession", body: Req(canvasId: canvasId, purpose: purpose, forceNew: forceNew))

        if response.success, let sessionId = response.sessionId {
            AppLogger.shared.info(.app, "initializeSession success session=\(sessionId.prefix(8)) reused=\(response.isReused ?? false)")
        }
        
        if response.success, let sessionId = response.sessionId {
            return sessionId
        }
        
        let message = response.error ?? "Failed to initialize session"
        throw NSError(domain: "CanvasService", code: 500, userInfo: [NSLocalizedDescriptionKey: message])
    }
    
    // MARK: - Optimized Endpoints
    
    // =========================================================================
    // MARK: openCanvas
    // =========================================================================
    // Combined endpoint that creates canvas + session in ONE HTTP call.
    // Saves 1-2 network round trips compared to calling bootstrapCanvas + initializeSession.
    //
    // Backend: firebase_functions/functions/canvas/open-canvas.js
    //
    // The backend:
    // 1. Creates or retrieves canvas (like bootstrapCanvas)
    // 2. Initializes or reuses Agent Engine session (like initializeSession)
    // 3. Optionally returns resumeState with existing cards for hydration
    //
    // This is the RECOMMENDED entry point for opening a canvas.
    //
    // Called by: CanvasViewModel.bootstrap()
    // Note: Sessions eliminated (Phase 3c) — backend returns no-op stub with sessionId=nil.
    // =========================================================================
    func openCanvas(userId: String, purpose: String) async throws -> (canvasId: String, sessionId: String) {
        struct Req: Codable { let userId: String; let purpose: String }
        
        let startTime = Date()
        
        AppLogger.shared.info(.app, "openCanvas START user=\(userId.prefix(8)) purpose=\(purpose)")

        let response: OpenCanvasResponse = try await ApiClient.shared.postJSON("openCanvas", body: Req(userId: userId, purpose: purpose))

        let elapsed = Date().timeIntervalSince(startTime)
        let elapsedMs = Int(elapsed * 1000)

        if response.success, let canvasId = response.canvasId, let sessionId = response.sessionId {
            let category = elapsedMs < 500 ? "FAST" : (elapsedMs < 2000 ? "NORMAL" : "SLOW")
            AppLogger.shared.info(.app, "openCanvas COMPLETE \(elapsedMs)ms \(category) canvas=\(canvasId.prefix(8)) session=\(sessionId.prefix(8))")

            return (canvasId, sessionId)
        }

        let message = response.error ?? "Failed to open canvas"
        AppLogger.shared.error(.app, "openCanvas FAILED \(elapsedMs)ms: \(message)")
        throw NSError(domain: "CanvasService", code: 500, userInfo: [NSLocalizedDescriptionKey: message])
    }
    
    // =========================================================================
    // MARK: preWarmSession
    // =========================================================================
    // Pre-warm the session before the canvas is opened.
    // Call on app launch or when user navigates to Home screen.
    // This reduces latency when the user actually opens the canvas.
    //
    // The Agent Engine session takes ~2-3s to initialize on first call.
    // Pre-warming hides this latency from the user.
    // =========================================================================
    func preWarmSession(userId: String, purpose: String) async throws -> String {
        struct Req: Codable { let userId: String; let purpose: String }
        
        AppLogger.shared.info(.app, "preWarmSession user=\(userId.prefix(8)) purpose=\(purpose)")
        let startTime = Date()

        let response: PreWarmResponse = try await ApiClient.shared.postJSON("preWarmSession", body: Req(userId: userId, purpose: purpose))

        let elapsed = Date().timeIntervalSince(startTime)
        if response.success, let sessionId = response.sessionId {
            AppLogger.shared.info(.app, "preWarmSession \(Int(elapsed * 1000))ms session=\(sessionId.prefix(8)) isNew=\(response.isNew ?? true)")
        }
        
        if response.success, let sessionId = response.sessionId {
            return sessionId
        }
        
        let message = response.error ?? "Failed to pre-warm session"
        throw NSError(domain: "CanvasService", code: 500, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
