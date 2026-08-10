import SwiftUI

/// The three states that are not "content".
///
/// Every screen in the app handles all four explicitly. A blank screen when
/// something went wrong is the single most common way a transit app loses a
/// rider's trust, because from the outside it is indistinguishable from a crash.

public struct EmptyStateView: View {
    private let systemImage: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        systemImage: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        StatePresentation(
            systemImage: systemImage,
            tint: Theme.Palette.secondaryText,
            title: title,
            message: message,
            actionTitle: actionTitle,
            action: action
        )
    }
}

public struct ErrorStateView: View {
    private let message: String
    private let retryTitle: String
    private let retry: (() -> Void)?

    public init(message: String, retryTitle: String = "Try again", retry: (() -> Void)? = nil) {
        self.message = message
        self.retryTitle = retryTitle
        self.retry = retry
    }

    public var body: some View {
        StatePresentation(
            systemImage: "exclamationmark.triangle.fill",
            tint: Theme.Palette.late,
            title: String(localized: "Something went wrong"),
            message: message,
            actionTitle: retry == nil ? nil : retryTitle,
            action: retry
        )
    }
}

public struct LoadingStateView: View {
    private let message: String

    public init(message: String) {
        self.message = message
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.regular) {
            ProgressView()
                .controlSize(.large)
            Text(message)
                .font(Theme.Typography.rowSubtitle)
                .foregroundStyle(Theme.Palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.huge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Shared presentation

private struct StatePresentation: View {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 44

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: systemImage)
                .font(.system(size: glyphSize))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(title)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.primaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .font(Theme.Typography.rowSubtitle)
                .foregroundStyle(Theme.Palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(Theme.Typography.rowTitle)
                        .frame(minHeight: Theme.minimumTouchTarget - Theme.Spacing.regular)
                        .padding(.horizontal, Theme.Spacing.regular)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, Theme.Spacing.tight)
            }
        }
        .frame(maxWidth: 420)
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

#Preview("Empty") {
    EmptyStateView(
        systemImage: "mappin.slash",
        title: "No stops nearby",
        message: "There is no service within walking distance of you in the timetable you have installed.",
        actionTitle: "Pick a different city",
        action: {}
    )
    .background(Theme.Palette.background)
}

#Preview("Error") {
    ErrorStateView(
        message: "The timetable could not be opened. It may have been interrupted while installing.",
        retry: {}
    )
    .background(Theme.Palette.background)
}

#Preview("Loading") {
    LoadingStateView(message: "Finding stops around you…")
        .background(Theme.Palette.background)
}

#Preview("Dark, AX5") {
    EmptyStateView(
        systemImage: "mappin.slash",
        title: "No stops nearby",
        message: "There is no service within walking distance of you.",
        actionTitle: "Pick a different city",
        action: {}
    )
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility5)
}
