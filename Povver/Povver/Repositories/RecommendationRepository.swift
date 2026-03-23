import Foundation
import FirebaseFirestore
import Combine

class RecommendationRepository: ObservableObject {
    static let shared = RecommendationRepository()
    @Published var recommendations: [AgentRecommendation] = []
    private var listener: ListenerRegistration?
    private let db = Firestore.firestore()

    func startListening(userId: String) {
        stopListening()

        listener = db.collection("users/\(userId)/agent_recommendations")
            .order(by: "created_at", descending: true)
            .limit(to: 20)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self = self, let snapshot = snapshot else {
                    if let error = error {
                        AppLogger.shared.error(.store, "Recommendation listener error", error)
                    }
                    return
                }

                // Skip metadata-only changes (cache)
                if snapshot.metadata.isFromCache && self.recommendations.isEmpty == false {
                    return
                }

                let recs = snapshot.documents.compactMap { doc -> AgentRecommendation? in
                    try? doc.data(as: AgentRecommendation.self)
                }

                DispatchQueue.main.async {
                    self.recommendations = recs
                }
            }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
    }
}
