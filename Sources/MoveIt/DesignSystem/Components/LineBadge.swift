import SwiftUI
import MoveItKit

/// A line's identity chip: "42", "M14", "Red Line".
///
/// The feed's own colours are used, but never as the only signal — the text is
/// always present, the badge carries a spoken label including the mode, and a
/// hairline border keeps a badge whose `route_color` happens to match the surface
/// from vanishing in either appearance.
public struct LineBadge: View {
    public enum Size { case small, regular, large }

    private let data: LineBadgeData
    private let size: Size

    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1

    public init(_ data: LineBadgeData, size: LineBadge.Size = .regular) {
        self.data = data
        self.size = size
    }

    public var body: some View {
        Text(data.text)
            .font(font)
            .lineLimit(1)
            // Long names ("Red Line") shrink a little before they truncate; a
            // truncated line number is useless, a slightly smaller one is not.
            .minimumScaleFactor(0.7)
            .foregroundStyle(Theme.Palette.hex(data.foregroundHex))
            .padding(.horizontal, horizontalPadding * scale)
            .padding(.vertical, verticalPadding * scale)
            .frame(minWidth: minimumWidth * scale)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius * scale, style: .continuous)
                    .fill(Theme.Palette.lineColor(data.backgroundHex))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius * scale, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(data.accessibilityLabel)
    }

    private var font: Font {
        switch size {
        case .small: return Theme.Typography.caption.weight(.bold)
        case .regular: return Theme.Typography.badge
        case .large: return Font.title3.weight(.bold)
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .small: return 5
        case .regular: return 8
        case .large: return 12
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .small: return 2
        case .regular: return 4
        case .large: return 6
        }
    }

    private var minimumWidth: CGFloat {
        switch size {
        case .small: return 24
        case .regular: return 34
        case .large: return 46
        }
    }

    private var cornerRadius: CGFloat {
        switch size {
        case .small: return 4
        case .regular: return Theme.Radius.small
        case .large: return Theme.Radius.medium
        }
    }
}

#Preview("Sizes") {
    VStack(alignment: .leading, spacing: Theme.Spacing.regular) {
        HStack(spacing: Theme.Spacing.small) {
            LineBadge(PreviewData.bus42, size: .small)
            LineBadge(PreviewData.bus42)
            LineBadge(PreviewData.bus42, size: .large)
        }
        HStack(spacing: Theme.Spacing.small) {
            LineBadge(PreviewData.redLine)
            LineBadge(PreviewData.rail)
            LineBadge(PreviewData.ferry)
            LineBadge(PreviewData.bus189)
        }
    }
    .padding()
    .background(Theme.Palette.background)
}

#Preview("AX5") {
    HStack(spacing: Theme.Spacing.small) {
        LineBadge(PreviewData.bus42)
        LineBadge(PreviewData.redLine)
    }
    .padding()
    .environment(\.dynamicTypeSize, .accessibility5)
}
