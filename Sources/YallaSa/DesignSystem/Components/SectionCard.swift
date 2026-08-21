import SwiftUI

/// A titled surface. The app's one elevation.
///
/// `title` is optional so a caller that needs an interactive header — a stop name
/// that pushes to stop detail, say — can supply its own inside `content` without
/// fighting a non-tappable label.
public struct SectionCard<Content: View>: View {
    private let title: String?
    private let systemImage: String?
    private let content: Content

    public init(title: String?, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                header(title)
                    .padding(.horizontal, Theme.Spacing.regular)
                    .padding(.top, Theme.Spacing.medium)
                    .padding(.bottom, Theme.Spacing.small)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            // A hairline instead of a shadow: it reads the same in both
            // appearances and costs nothing to composite while scrolling.
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.Palette.separator.opacity(0.5), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func header(_ title: String) -> some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        } else {
            Text(title)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

#Preview("Card") {
    ScrollView {
        VStack(spacing: Theme.Spacing.regular) {
            SectionCard(title: "Rothschild / Allenby", systemImage: "bus.fill") {
                VStack(spacing: 0) {
                    ForEach(PreviewData.departures.prefix(3)) { item in
                        DepartureRowView(item: item, now: PreviewData.now, showsStop: false)
                            .padding(.horizontal, Theme.Spacing.regular)
                        Divider().padding(.leading, Theme.Spacing.regular)
                    }
                }
                .padding(.bottom, Theme.Spacing.small)
            }

            SectionCard(title: nil) {
                Text("A card with no title, for callers that build their own header.")
                    .font(Theme.Typography.rowSubtitle)
                    .padding(Theme.Spacing.regular)
            }
        }
        .padding(Theme.Spacing.regular)
    }
    .background(Theme.Palette.background)
}

#Preview("Dark") {
    SectionCard(title: "Nearby", systemImage: "location.fill") {
        Text("Contents")
            .padding(Theme.Spacing.regular)
    }
    .padding()
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
}
