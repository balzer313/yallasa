import SwiftUI
import YallaSaKit

/// A stop in a list: search results, favourites, a journey's boarding point.
public struct StopRowView: View {
    private let item: StopItem

    public init(item: StopItem) {
        self.item = item
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            ModeIcon(item.lines.first?.mode ?? .other, size: 18)
                .foregroundStyle(Theme.Palette.secondaryText)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text(item.name.isEmpty ? String(localized: "Unnamed stop") : item.name)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.rowSubtitle)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .lineLimit(1)
                }

                if !item.lines.isEmpty {
                    FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
                        ForEach(item.lines, id: \.self) { line in
                            LineBadge(line, size: .small)
                        }
                    }
                    .padding(.top, Theme.Spacing.hairline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.accessibility == .accessible {
                Image(systemName: "figure.roll")
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Theme.Spacing.small)
        .frame(minHeight: Theme.minimumTouchTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var subtitle: String? {
        var parts: [String] = []
        if !item.code.isEmpty { parts.append(String(localized: "Stop \(item.code)")) }
        if let distanceMeters = item.distanceMeters {
            parts.append(Format.distance(meters: distanceMeters))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts: [String] = [item.name]
        if !item.code.isEmpty { parts.append(String(localized: "stop \(item.code)")) }
        if let distanceMeters = item.distanceMeters {
            parts.append(String(localized: "\(Format.distance(meters: distanceMeters)) away"))
        }
        if !item.lines.isEmpty {
            // Spoken as a list of lines rather than a run of bare numbers.
            parts.append(
                String(
                    localized: "served by \(item.lines.map(\.accessibilityLabel).joined(separator: ", "))"
                )
            )
        }
        if item.accessibility == .accessible {
            parts.append(String(localized: "wheelchair accessible"))
        }
        return parts.joined(separator: ", ")
    }
}

#Preview("Stops") {
    VStack(spacing: 0) {
        StopRowView(item: PreviewData.stop)
        Divider()
        StopRowView(item: PreviewData.farStop)
    }
    .padding(.horizontal, Theme.Spacing.regular)
    .background(Theme.Palette.background)
}

#Preview("AX5") {
    ScrollView {
        StopRowView(item: PreviewData.stop)
            .padding(.horizontal, Theme.Spacing.regular)
    }
    .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Dark") {
    StopRowView(item: PreviewData.stop)
        .padding()
        .background(Theme.Palette.background)
        .preferredColorScheme(.dark)
}
