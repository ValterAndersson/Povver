import SwiftUI

/// Connected Apps — manage MCP API keys for external AI clients (Claude Desktop, ChatGPT, etc.).
/// Premium-gated. Accessed via NavigationLink from MoreView.
struct ConnectedAppsView: View {
    @ObservedObject private var subscriptionService = SubscriptionService.shared

    @State private var apiKeys: [McpApiKeyInfo] = []
    @State private var isLoading = true
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var newKeyName = ""
    @State private var generatedKey: String?
    @State private var showingGenerateSheet = false
    @State private var revokingKeyId: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                if !subscriptionService.isPremium {
                    premiumGate
                } else {
                    instructionsSection
                    keysSection
                }

                if let errorMessage {
                    Text(errorMessage)
                        .textStyle(.caption)
                        .foregroundColor(.destructive)
                        .padding(.horizontal, Space.lg)
                }

                Spacer(minLength: Space.xxl)
            }
        }
        .background(Color.bg)
        .navigationTitle("Connected Apps")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard subscriptionService.isPremium else {
                isLoading = false
                return
            }
            await loadKeys()
        }
        .sheet(isPresented: $showingGenerateSheet) {
            generateKeySheet
        }
    }

    // MARK: - Premium Gate

    private var premiumGate: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundColor(Color.textTertiary)

            Text("Premium Feature")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(Color.textPrimary)

            Text("Upgrade to Premium to connect external AI assistants like Claude Desktop or ChatGPT to your training data.")
                .font(.system(size: 14))
                .foregroundColor(Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xl)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.xxl)
    }

    // MARK: - Instructions

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            sectionHeader("How it works")

            VStack(alignment: .leading, spacing: Space.sm) {
                instructionRow("1.", "Generate an API key below")
                instructionRow("2.", "Copy the key (shown only once)")
                instructionRow("3.", "Add it to your Claude Desktop or ChatGPT MCP config")
            }
            .padding(Space.md)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.medium))
            .padding(.horizontal, Space.lg)
        }
    }

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

    // MARK: - Keys Section

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            sectionHeader("API Keys")

            VStack(spacing: 0) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(Space.xl)
                } else if apiKeys.isEmpty {
                    VStack(spacing: Space.sm) {
                        Text("No API keys yet")
                            .font(.system(size: 14))
                            .foregroundColor(Color.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(Space.xl)
                } else {
                    ForEach(apiKeys) { key in
                        keyRow(key)
                        if key.id != apiKeys.last?.id {
                            Divider().padding(.leading, Space.lg)
                        }
                    }
                }

                Divider()

                Button {
                    newKeyName = ""
                    generatedKey = nil
                    showingGenerateSheet = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(Color.accent)
                        Text("Generate New Key")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Color.accent)
                        Spacer()
                    }
                    .padding(Space.md)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(apiKeys.count >= 5)
            }
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.medium))
            .padding(.horizontal, Space.lg)
        }
    }

    private func keyRow(_ key: McpApiKeyInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(key.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color.textPrimary)

                HStack(spacing: Space.sm) {
                    Text(key.keyId)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color.textTertiary)

                    if let created = key.createdAt {
                        Text("Created \(created, style: .date)")
                            .font(.system(size: 12))
                            .foregroundColor(Color.textTertiary)
                    }
                }
            }

            Spacer()

            Button {
                Task { await revokeKey(key.keyId) }
            } label: {
                if revokingKeyId == key.keyId {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(Color.destructive)
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(revokingKeyId != nil)
        }
        .padding(Space.md)
    }

    // MARK: - Generate Key Sheet

    private var generateKeySheet: some View {
        NavigationView {
            VStack(spacing: Space.lg) {
                if let generatedKey {
                    // Key was generated — show it
                    VStack(alignment: .leading, spacing: Space.md) {
                        Text("Your API Key")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Color.textPrimary)

                        Text("Copy this key now. It will not be shown again.")
                            .font(.system(size: 14))
                            .foregroundColor(Color.destructive)

                        HStack {
                            Text(generatedKey)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Color.textPrimary)
                                .lineLimit(2)
                                .textSelection(.enabled)

                            Spacer()

                            Button {
                                UIPasteboard.general.string = generatedKey
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .foregroundColor(Color.accent)
                            }
                        }
                        .padding(Space.md)
                        .background(Color.bg)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.small))
                    }
                    .padding(.horizontal, Space.lg)
                } else {
                    // Name input
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Key Name")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color.textSecondary)

                        TextField("e.g. Claude Desktop", text: $newKeyName)
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal, Space.lg)
                    }
                    .padding(.horizontal, Space.lg)

                    Button {
                        Task { await generateKey() }
                    } label: {
                        HStack {
                            if isGenerating {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text("Generate")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(Space.md)
                        .background(Color.accent)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadiusToken.medium))
                    }
                    .disabled(isGenerating)
                    .padding(.horizontal, Space.lg)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundColor(.destructive)
                        .padding(.horizontal, Space.lg)
                }

                Spacer()
            }
            .padding(.top, Space.lg)
            .navigationTitle(generatedKey != nil ? "Key Created" : "New API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        showingGenerateSheet = false
                        if generatedKey != nil {
                            // Reload keys after generation
                            Task { await loadKeys() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color.textSecondary)
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.md)
    }

    // MARK: - API Calls

    private func loadKeys() async {
        isLoading = true
        errorMessage = nil

        do {
            let response: McpListKeysResponse = try await ApiClient.shared.postJSON(
                "listMcpApiKeys",
                body: EmptyBody()
            )
            apiKeys = response.data?.keys ?? []
        } catch {
            errorMessage = "Failed to load API keys."
            print("[ConnectedAppsView] loadKeys failed: \(error)")
        }

        isLoading = false
    }

    private func generateKey() async {
        isGenerating = true
        errorMessage = nil

        let keyName = newKeyName.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let response: McpGenerateKeyResponse = try await ApiClient.shared.postJSON(
                "generateMcpApiKey",
                body: McpGenerateKeyRequest(name: keyName.isEmpty ? "Default" : keyName)
            )
            generatedKey = response.data?.key
        } catch {
            errorMessage = "Failed to generate API key."
            print("[ConnectedAppsView] generateKey failed: \(error)")
        }

        isGenerating = false
    }

    private func revokeKey(_ keyId: String) async {
        revokingKeyId = keyId
        errorMessage = nil

        do {
            let _: McpRevokeKeyResponse = try await ApiClient.shared.postJSON(
                "revokeMcpApiKey",
                body: McpRevokeKeyRequest(key_id: keyId)
            )
            apiKeys.removeAll { $0.keyId == keyId }
        } catch {
            errorMessage = "Failed to revoke API key."
            print("[ConnectedAppsView] revokeKey failed: \(error)")
        }

        revokingKeyId = nil
    }
}

// MARK: - API Types

private struct EmptyBody: Encodable {}

private struct McpGenerateKeyRequest: Encodable {
    let name: String
}

private struct McpRevokeKeyRequest: Encodable {
    let key_id: String
}

// Envelope responses matching ok(res, data) shape: { success, data, meta }
private struct McpListKeysResponse: Decodable {
    let success: Bool
    let data: McpListKeysData?

    struct McpListKeysData: Decodable {
        let keys: [McpApiKeyInfo]
    }
}

private struct McpGenerateKeyResponse: Decodable {
    let success: Bool
    let data: McpGenerateKeyData?

    struct McpGenerateKeyData: Decodable {
        let key: String
        let name: String
        let key_id: String
    }
}

private struct McpRevokeKeyResponse: Decodable {
    let success: Bool
}

/// API key metadata returned by listMcpApiKeys.
struct McpApiKeyInfo: Decodable, Identifiable {
    let keyId: String
    let name: String
    let createdAt: Date?
    let lastUsedAt: Date?

    var id: String { keyId }

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case name
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyId = try container.decode(String.self, forKey: .keyId)
        name = try container.decode(String.self, forKey: .name)
        // Firestore timestamps come as { _seconds, _nanoseconds } or ISO strings
        createdAt = try? container.decodeIfPresent(Date.self, forKey: .createdAt)
        lastUsedAt = try? container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}
