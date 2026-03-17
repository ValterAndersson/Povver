/**
 =============================================================================
 ConversationRepository.swift - Firestore Conversation Subscription
 =============================================================================
 
 PURPOSE:
 Provides real-time Firestore listeners for conversation state, cards, and up_next.
 Returns an AsyncThrowingStream that emits ConversationSnapshot on any change.
 
 ARCHITECTURE CONTEXT:
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │ FIRESTORE LISTENER SETUP                                                    │
 │                                                                             │
 │ ConversationViewModel.start()                                                     │
 │   │                                                                         │
 │   ▼ repo.subscribe(userId, canvasId)                                       │
 │   │                                                                         │
 │   ▼ ConversationRepository (THIS FILE)                                           │
 │   │                                                                         │
 │   ├──▶ stateListener: users/{uid}/canvases/{canvasId} (doc)                │
 │   │      → state.phase, state.version, state.purpose                       │
 │   │                                                                         │
 │   ├──▶ cardsListener: users/{uid}/canvases/{canvasId}/cards (collection)   │
 │   │      → All card documents, mapped via ConversationMapper                     │
 │   │                                                                         │
 │   └──▶ upNextListener: users/{uid}/canvases/{canvasId}/up_next (collection)│
 │          → Priority-ordered list of card_ids for "suggested next"          │
 │                                                                             │
 │ Any listener change → emit(ConversationSnapshot) → ConversationViewModel receives      │
 └─────────────────────────────────────────────────────────────────────────────┘
 
 SNAPSHOT STRUCTURE:
 ConversationSnapshot {
   version: Int              // Incremented on every apply-action
   state: CanvasStateDTO     // Phase, purpose, lanes
   cards: [CanvasCardModel]  // All active cards
   upNext: [String]          // Card IDs suggested for next action
 }
 
 CACHE HANDLING:
 - First snapshot may be from local cache (offline persistence)
 - Skip cache-only card snapshots until server data arrives
 - This prevents showing stale cards on fresh open
 
 RELATED FILES:
 - ConversationViewModel.swift: Consumes this stream
 - ConversationMapper.swift: Maps Firestore docs to CanvasCardModel
 - ConversationService.swift: HTTP calls (apply-action, open-canvas)
 - Models.swift: CanvasCardModel, ConversationSnapshot definitions
 
 UNUSED CODE CHECK: ✅ No unused code in this file
 
 =============================================================================
 */

import Foundation
import FirebaseFirestore
import FirebaseAuth

protocol ConversationRepositoryProtocol {
    func subscribe(userId: String, canvasId: String) -> AsyncThrowingStream<ConversationSnapshot, Error>
}

final class ConversationRepository: ConversationRepositoryProtocol {
    static let shared = ConversationRepository()
    @MainActor var currentCanvasId: String?
    private let db = Firestore.firestore()

    func subscribe(userId: String, canvasId: String) -> AsyncThrowingStream<ConversationSnapshot, Error> {
        let stateRef = db.collection("users").document(userId).collection("conversations").document(canvasId)
        let cardsRef = stateRef.collection("cards")
        let upNextRef = stateRef.collection("up_next")

        return AsyncThrowingStream { continuation in
            var state: CanvasStateDTO = CanvasStateDTO(phase: nil, version: 0, purpose: nil, lanes: nil)
            var cards: [String: CanvasCardModel] = [:]
            var upNext: [String] = []

            func emit() {
                let version = state.version ?? 0
                let snapshot = ConversationSnapshot(version: version, state: state, cards: Array(cards.values), upNext: upNext)
                continuation.yield(snapshot)
            }

            let stateListener = stateRef.addSnapshotListener { snap, err in
                if let err {
                    AppLogger.shared.error(.store, "canvas state listener error", err)
                    continuation.finish(throwing: err)
                    return
                }
                guard let data = snap?.data() else { return }

                let source = snap?.metadata.isFromCache == true ? "cache" : "server"
                AppLogger.shared.snapshot("canvases/\(canvasId)", docs: 1, source: source)

                if let st = data["state"] as? [String: Any] {
                    let phase = (st["phase"] as? String).flatMap { CanvasPhase(rawValue: $0) }
                    let version = st["version"] as? Int
                    let purpose = st["purpose"] as? String
                    let lanes = st["lanes"] as? [String]
                    state = CanvasStateDTO(phase: phase, version: version, purpose: purpose, lanes: lanes)
                    emit()
                }
            }

            var hasReceivedServerCards = false
            let cardsListener = cardsRef.addSnapshotListener { snap, err in
                if let err {
                    AppLogger.shared.error(.store, "canvas cards listener error", err)
                    continuation.finish(throwing: err)
                    return
                }
                guard let snap else { return }

                let source = snap.metadata.isFromCache ? "cache" : "server"

                // Only skip cache on FIRST load (before server data arrives)
                if snap.metadata.isFromCache && !hasReceivedServerCards {
                    AppLogger.shared.info(.store, "skipping cache-only cards snapshot count=\(snap.documents.count)")
                    return
                }
                hasReceivedServerCards = true

                AppLogger.shared.snapshot("canvases/\(canvasId)/cards", docs: snap.documents.count, source: source)

                let docs = snap.documents
                var nextCards: [String: CanvasCardModel] = [:]
                for doc in docs {
                    if let model = ConversationMapper.mapCard(from: doc) {
                        nextCards[model.id] = model
                    }
                }
                cards = nextCards
                emit()
            }

            let upNextListener = upNextRef.order(by: "priority", descending: true).addSnapshotListener { snap, err in
                if let err {
                    AppLogger.shared.error(.store, "canvas up_next listener error", err)
                    continuation.finish(throwing: err)
                    return
                }
                guard let docs = snap?.documents else { return }

                let source = snap?.metadata.isFromCache == true ? "cache" : "server"
                AppLogger.shared.snapshot("canvases/\(canvasId)/up_next", docs: docs.count, source: source)

                upNext = docs.compactMap { $0.data()["card_id"] as? String }
                emit()
            }

            continuation.onTermination = { _ in
                stateListener.remove()
                cardsListener.remove()
                upNextListener.remove()
            }
        }
    }
}
