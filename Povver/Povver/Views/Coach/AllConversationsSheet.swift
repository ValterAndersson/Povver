import SwiftUI
import FirebaseFirestore

/// Full conversation history sheet with date-grouped sections and pagination.
/// Presented from CoachTabView "See all" button.
struct AllConversationsSheet: View {
    let onSelectCanvas: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [ConversationItem] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMorePages = true
    @State private var lastDocument: DocumentSnapshot?

    private let pageSize = 20

    var body: some View {
        SheetScaffold(
            title: "Conversations",
            doneTitle: nil,
            onCancel: { dismiss() }
        ) {
            Group {
                if isLoading {
                    loadingView
                } else if conversations.isEmpty {
                    emptyView
                } else {
                    conversationsList
                }
            }
        }
        .task {
            await loadConversations()
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: Space.md) {
            ProgressView()
                .progressViewStyle(.circular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundColor(Color.textTertiary)
            Text("No conversations yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Color.textPrimary)
            Text("Start a chat with your coach")
                .font(.system(size: 14))
                .foregroundColor(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var conversationsList: some View {
        ScrollView {
            LazyVStack(spacing: Space.md, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedConversations, id: \.label) { group in
                    Section {
                        ForEach(group.items) { item in
                            Button {
                                onSelectCanvas(item.id)
                            } label: {
                                SurfaceCard(padding: InsetsToken.all(Space.md)) {
                                    HStack(spacing: Space.md) {
                                        VStack(alignment: .leading, spacing: Space.xs) {
                                            Text(item.displayTitle)
                                                .textStyle(.secondary)
                                                .lineLimit(1)
                                            Text(item.date.relativeShort)
                                                .textStyle(.micro)
                                                .foregroundStyle(Color.textSecondary)
                                        }
                                        Spacer()
                                        Icon("chevron.right", size: .md, color: Color.textSecondary)
                                    }
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    } header: {
                        sectionHeader(group.label)
                    }
                }

                if hasMorePages {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoadingMore {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.8)
                            } else {
                                Text("Load More")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(Color.accent)
                            }
                            Spacer()
                        }
                        .padding(.vertical, Space.md)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isLoadingMore)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.md)
            .padding(.bottom, Space.xxl)
        }
    }

    private func sectionHeader(_ label: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color.textSecondary)
            Spacer()
        }
        .padding(.vertical, Space.sm)
        .background(Color.surfaceElevated)
    }

    // MARK: - Date Grouping

    private var groupedConversations: [ConversationGroup] {
        let calendar = Calendar.current
        var groups: [String: [ConversationItem]] = [:]
        var order: [String] = []

        for item in conversations {
            let label = dateGroupLabel(for: item.date, calendar: calendar)
            if groups[label] == nil {
                order.append(label)
            }
            groups[label, default: []].append(item)
        }

        return order.map { label in
            ConversationGroup(label: label, items: groups[label] ?? [])
        }
    }

    private func dateGroupLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            return "This Week"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }

    // MARK: - Data Loading

    private func loadConversations() async {
        guard let uid = AuthService.shared.currentUser?.uid else {
            isLoading = false
            return
        }

        let db = Firestore.firestore()
        do {
            let snapshot = try await db.collection("users").document(uid).collection("conversations")
                .whereField("status", isEqualTo: "active")
                .order(by: "updatedAt", descending: true)
                .limit(to: pageSize)
                .getDocuments()

            let items = snapshot.documents.compactMap { doc -> ConversationItem? in
                parseConversationDoc(doc)
            }

            await MainActor.run {
                conversations = items
                lastDocument = snapshot.documents.last
                hasMorePages = snapshot.documents.count == pageSize
                isLoading = false
            }
        } catch {
            AppLogger.shared.error(.store, "loadConversations failed", error)
            await MainActor.run { isLoading = false }
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, let last = lastDocument,
              let uid = AuthService.shared.currentUser?.uid else { return }

        await MainActor.run { isLoadingMore = true }

        let db = Firestore.firestore()
        do {
            let snapshot = try await db.collection("users").document(uid).collection("conversations")
                .whereField("status", isEqualTo: "active")
                .order(by: "updatedAt", descending: true)
                .start(afterDocument: last)
                .limit(to: pageSize)
                .getDocuments()

            let items = snapshot.documents.compactMap { doc -> ConversationItem? in
                parseConversationDoc(doc)
            }

            await MainActor.run {
                conversations.append(contentsOf: items)
                lastDocument = snapshot.documents.last
                hasMorePages = snapshot.documents.count == pageSize
                isLoadingMore = false
            }
        } catch {
            AppLogger.shared.error(.store, "loadMore failed", error)
            await MainActor.run { isLoadingMore = false }
        }
    }

    private func parseConversationDoc(_ doc: QueryDocumentSnapshot) -> ConversationItem? {
        let data = doc.data()
        let title = data["title"] as? String
        let lastMessage = data["lastMessage"] as? String
        let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue()
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
        guard lastMessage != nil || updatedAt != nil else { return nil }
        return ConversationItem(
            id: doc.documentID,
            title: title,
            lastMessage: lastMessage,
            date: updatedAt ?? createdAt ?? Date()
        )
    }
}

// MARK: - Models

private struct ConversationItem: Identifiable {
    let id: String
    let title: String?
    let lastMessage: String?
    let date: Date

    var displayTitle: String {
        title ?? lastMessage ?? "General chat"
    }
}

private struct ConversationGroup {
    let label: String
    let items: [ConversationItem]
}

// MARK: - Relative Date (short form for sheet rows)

private extension Date {
    var relativeShort: String {
        let interval = Date().timeIntervalSince(self)
        if interval < 60 { return "Just now" }
        if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        }
        if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        }
        let days = Int(interval / 86400)
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days)d ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: self)
    }
}
