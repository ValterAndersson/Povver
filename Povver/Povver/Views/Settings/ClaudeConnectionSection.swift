import SwiftUI

/// Claude Desktop connection status card for ConnectedAppsView.
/// Uses ClaudeConnectionViewModel (Task 11) for state management.
struct ClaudeConnectionSection: View {
    @StateObject private var viewModel = ClaudeConnectionViewModel()
    @State private var showDisconnectAlert = false
    @State private var showingPaywall = false

    private let mcpUrl = "https://mcp.povver.ai"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // Header
            HStack(spacing: Space.sm) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 20))
                    .foregroundColor(Color.accent)
                    .frame(width: 32, height: 32)
                    .background(Color.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusIcon))

                Text("Claude Desktop")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color.textPrimary)

                Spacer()

                statusBadge
            }

            switch viewModel.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)

            case .notConnected:
                notConnectedContent

            case .connected(let lastUsedAt):
                connectedContent(lastUsedAt: lastUsedAt)

            case .disabled:
                disabledContent
            }
        }
        .padding(Space.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
        .padding(.horizontal, Space.lg)
        .task { await viewModel.checkStatus() }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
        }
        .alert("Disconnect Claude?", isPresented: $showDisconnectAlert) {
            Button("Disconnect", role: .destructive) {
                Task { await viewModel.disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Claude Desktop will lose access to your training data. You can reconnect anytime.")
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private var statusBadge: some View {
        switch viewModel.state {
        case .connected:
            HStack(spacing: 4) {
                Circle().fill(Color.accent).frame(width: 8, height: 8)
                Text("Connected")
                    .font(.system(size: 12))
                    .foregroundColor(Color.accent)
            }
        case .disabled:
            HStack(spacing: 4) {
                Circle().fill(Color.warning).frame(width: 8, height: 8)
                Text("Disabled")
                    .font(.system(size: 12))
                    .foregroundColor(Color.warning)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Not Connected

    private var notConnectedContent: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                instructionRow("1.", "Open Claude Desktop → Settings → Connectors → Add custom connector")
                instructionRow("2.", "Name: Povver, URL: \(mcpUrl)")
                instructionRow("3.", "Click Add, then sign in with your Povver account")
            }

            Button {
                UIPasteboard.general.string = mcpUrl
            } label: {
                HStack {
                    Image(systemName: "doc.on.doc")
                    Text("Copy URL")
                }
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.sm)
                .background(Color.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            }
            .foregroundColor(Color.accent)
        }
    }

    // MARK: - Connected

    private func connectedContent(lastUsedAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if let lastUsed = lastUsedAt {
                Text("Last used \(lastUsed, style: .relative)")
                    .font(.system(size: 12))
                    .foregroundColor(Color.textSecondary)
            }

            Button {
                showDisconnectAlert = true
            } label: {
                HStack {
                    if viewModel.isDisconnecting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.destructive)
                    }
                    Text("Disconnect")
                        .font(.system(size: 14, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.sm)
                .background(Color.destructive.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            }
            .foregroundColor(Color.destructive)
            .disabled(viewModel.isDisconnecting)
        }
    }

    // MARK: - Disabled (Premium Required)

    private var disabledContent: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Premium subscription required to use Claude Desktop with Povver.")
                .font(.system(size: 13))
                .foregroundColor(Color.textSecondary)

            Button {
                showingPaywall = true
            } label: {
                Text("Upgrade")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.sm)
                    .background(Color.accent)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.radiusControl))
            }
        }
    }

    // MARK: - Helpers

    private func instructionRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Text(number)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(Color.accent)
                .frame(width: 20, alignment: .leading)
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(Color.textSecondary)
        }
    }
}
