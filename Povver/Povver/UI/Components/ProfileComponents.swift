import SwiftUI

/// Reusable row components for profile and settings views.
/// Extracted from ProfileView for use across LinkedAccountsView, DeleteAccountView, etc.

// MARK: - Profile Row

struct ProfileRow: View {
    let icon: String
    let title: String
    let value: String
    var isEditable: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(Color.textSecondary)
                    .frame(width: 24)

                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(Color.textPrimary)

                Spacer()

                Text(value)
                    .font(.system(size: 15))
                    .foregroundColor(isEditable ? Color.textSecondary : Color.textTertiary)
                    .lineLimit(1)

                if isEditable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.textTertiary)
                }
            }
            .padding(Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(action == nil)
    }
}

// MARK: - Profile Row Toggle

struct ProfileRowToggle: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(Color.textSecondary)
                .frame(width: 24)

            Text(title)
                .font(.system(size: 15))
                .foregroundColor(Color.textPrimary)

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .padding(Space.md)
        .onChange(of: isOn) { _, _ in
            HapticManager.selectionChanged()
        }
    }
}

// MARK: - Badge View

struct BadgeView: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 9 ? "9+" : "\(count)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(minWidth: 18, minHeight: 18)
                .background(Color.accent)
                .clipShape(Circle())
        }
    }
}

// MARK: - Profile Row Link Content

struct ProfileRowLinkContent: View {
    let icon: String
    let title: String
    let subtitle: String
    var badgeCount: Int = 0

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(Color.textSecondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(Color.textPrimary)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(Color.textSecondary)
            }

            Spacer()

            BadgeView(count: badgeCount)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.textTertiary)
        }
        .padding(Space.md)
        .contentShape(Rectangle())
    }
}
