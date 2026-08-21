import SwiftUI

/// A left-to-right wrapping row.
///
/// Exists because a stop that is served by eight lines has to show eight badges,
/// and at AX5 two of them already fill the width. An `HStack` would either clip
/// or squeeze; this wraps, which is the only behaviour that stays readable across
/// the whole Dynamic Type range.
public struct FlowLayout: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat

    public init(spacing: CGFloat = Theme.Spacing.small, lineSpacing: CGFloat = Theme.Spacing.small) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let maximumWidth = proposal.width ?? .infinity
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > 0, cursorX + spacing + size.width > maximumWidth {
                widest = max(widest, cursorX)
                cursorY += lineHeight + lineSpacing
                cursorX = 0
                lineHeight = 0
            }
            cursorX += (cursorX > 0 ? spacing : 0) + size.width
            lineHeight = max(lineHeight, size.height)
        }
        widest = max(widest, cursorX)

        let width = maximumWidth.isFinite ? min(widest, maximumWidth) : widest
        return CGSize(width: width, height: cursorY + lineHeight)
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > 0, cursorX + spacing + size.width > bounds.width {
                cursorY += lineHeight + lineSpacing
                cursorX = 0
                lineHeight = 0
            }
            if cursorX > 0 { cursorX += spacing }
            subview.place(
                at: CGPoint(x: bounds.minX + cursorX, y: bounds.minY + cursorY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            cursorX += size.width
            lineHeight = max(lineHeight, size.height)
        }
    }
}

#Preview("Wrapping badges") {
    FlowLayout {
        ForEach(0..<9, id: \.self) { index in
            LineBadge(
                LineBadgeData(
                    text: "\(index * 13 + 4)",
                    backgroundHex: 0x2E7D32,
                    foregroundHex: 0xFFFFFF,
                    mode: .bus,
                    accessibilityLabel: "Bus \(index * 13 + 4)"
                ),
                size: .small
            )
        }
    }
    .padding()
    .frame(width: 240)
    .background(Theme.Palette.surface)
}
