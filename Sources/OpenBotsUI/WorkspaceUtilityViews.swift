import SwiftUI

/// The catalog route is available before a catalog service is connected.
/// This view deliberately has no inventory, provider, account, or install client.
@MainActor
public struct PluginsCatalogView: View {
    @Environment(\.colorScheme) private var colorScheme
    private let onClose: @MainActor () -> Void

    public init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    /// Shared by the visible close button and its Escape shortcut. Native
    /// keyboard dispatch still needs an installed-app check.
    func dismissCatalog() {
        onClose()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing24) {
            HStack {
                Text("Plugins")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: dismissCatalog) {
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close Plugins")
                .accessibilityLabel("Close Plugins")
                .accessibilityIdentifier("plugins.close")
            }

            HStack(spacing: OpenBotsVisualStyle.spacing12) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(OpenBotsVisualStyle.elevatedSurface(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: OpenBotsVisualStyle.radiusSmall))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
                    Text("Installed plugins")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("Inventory unavailable in this build")
                        .font(.callout)
                        .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Your plugins. Inventory unavailable in this build")
            .accessibilityIdentifier("plugins.inventoryUnavailable")

            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
                HStack(spacing: OpenBotsVisualStyle.spacing8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                        .accessibilityHidden(true)
                    TextField("Search plugins", text: .constant(""))
                        .textFieldStyle(.plain)
                        .disabled(true)
                        .accessibilityLabel("Search plugins")
                        .accessibilityHint("Unavailable until a plugin catalog is connected")
                        .accessibilityIdentifier("plugins.search")
                }
                .padding(OpenBotsVisualStyle.spacing12)
                .background(OpenBotsVisualStyle.elevatedSurface(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: OpenBotsVisualStyle.radiusSmall))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)],
                          alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
                    ForEach(["All", "Productivity", "Research", "Documents & Files", "MCP"], id: \.self) { category in
                        Button(category) {}
                            .buttonStyle(.bordered)
                            .disabled(true)
                            .accessibilityIdentifier("plugins.category.\(category)")
                            .accessibilityHint("Plugin categories are unavailable in this build")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Plugin categories")
                .accessibilityHint("Unavailable until a plugin catalog is connected; no category is selected")
                .accessibilityIdentifier("plugins.categories")
            }

            Spacer(minLength: OpenBotsVisualStyle.spacing8)

            VStack(spacing: OpenBotsVisualStyle.spacing12) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 32))
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                    .accessibilityHidden(true)
                Text("Plugin catalog isn't connected")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Browsing, installation and account setup aren't available in this local build. No installed plugins or connection states have been checked.")
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
                Text("Opening Plugins never grants a bot access.")
                    .font(.callout)
                    .foregroundStyle(OpenBotsVisualStyle.secondaryText(for: colorScheme))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("plugins.catalogUnavailable")

            Spacer(minLength: OpenBotsVisualStyle.spacing24)
        }
        .padding(OpenBotsVisualStyle.spacing24)
        .frame(minWidth: 600, idealWidth: 880, minHeight: 460, idealHeight: 620)
        .background(OpenBotsVisualStyle.surface(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: OpenBotsVisualStyle.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: OpenBotsVisualStyle.radiusLarge)
                .stroke(OpenBotsVisualStyle.border(for: colorScheme), lineWidth: 1)
        }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plugins")
        .accessibilityIdentifier("plugins.catalog")
    }
}
