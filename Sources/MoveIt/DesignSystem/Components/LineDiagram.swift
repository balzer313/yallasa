import SwiftUI

/// Vertical route diagram used in journey detail and pattern detail.
///
/// The rail is drawn as a *background* of each row rather than as a sibling
/// column. That way the row's height is decided entirely by its text, so the line
/// keeps joining up at AX5 where a fixed-height row would have long since
/// clipped the stop name.
public struct LineDiagram: View {
    private let color: Color
    private let stops: [String]
    private let highlightFirst: Bool
    private let highlightLast: Bool

    @ScaledMetric(relativeTo: .body) private var nodeSize: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var railWidth: CGFloat = 28

    public init(color: Color, stops: [String], highlightFirst: Bool = true, highlightLast: Bool = true) {
        self.color = color
        self.stops = stops
        self.highlightFirst = highlightFirst
        self.highlightLast = highlightLast
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.offset) { index, name in
                Text(name)
                    .font(isEmphasised(index) ? Theme.Typography.rowTitle : Theme.Typography.rowSubtitle)
                    .foregroundStyle(isEmphasised(index) ? Theme.Palette.primaryText : Theme.Palette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, railWidth + Theme.Spacing.small)
                    .padding(.vertical, Theme.Spacing.small)
                    .background(alignment: .leading) { rail(at: index) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel(index: index, name: name))
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func rail(at index: Int) -> some View {
        ZStack {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(index == 0 ? Color.clear : color)
                Rectangle()
                    .fill(index == stops.count - 1 ? Color.clear : color)
            }
            .frame(width: 3)

            node(at: index)
        }
        .frame(width: railWidth)
    }

    @ViewBuilder
    private func node(at index: Int) -> some View {
        if isEmphasised(index) {
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(Theme.Palette.surface, lineWidth: 2.5))
                .frame(width: nodeSize * 1.45, height: nodeSize * 1.45)
        } else {
            Circle()
                .fill(Theme.Palette.surface)
                .overlay(Circle().strokeBorder(color, lineWidth: 2.5))
                .frame(width: nodeSize, height: nodeSize)
        }
    }

    private func isEmphasised(_ index: Int) -> Bool {
        (highlightFirst && index == 0) || (highlightLast && index == stops.count - 1)
    }

    private func accessibilityLabel(index: Int, name: String) -> String {
        if highlightFirst, index == 0 { return String(localized: "Start, \(name)") }
        if highlightLast, index == stops.count - 1 { return String(localized: "End, \(name)") }
        return name
    }
}

#Preview("Diagram") {
    ScrollView {
        LineDiagram(color: Theme.Palette.hex(0x2E7D32), stops: PreviewData.diagramStops)
            .padding(Theme.Spacing.regular)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .fill(Theme.Palette.surface)
            )
            .padding(Theme.Spacing.regular)
    }
    .background(Theme.Palette.background)
}

#Preview("Dark, AX5") {
    ScrollView {
        LineDiagram(color: Theme.Palette.hex(0xC62828), stops: PreviewData.diagramStops)
            .padding(Theme.Spacing.regular)
    }
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility5)
}
