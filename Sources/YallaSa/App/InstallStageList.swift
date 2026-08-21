import SwiftUI
import YallaSaKit

/// The three steps of an install, with the current one marked.
///
/// Installing the national feed is 133 MB of download followed by a compile of
/// roughly a gigabyte of CSV. That is minutes, not seconds, and a single bar
/// creeping across the screen for that long reads as a hang — particularly at
/// the transition, where the download bar completes and the compile starts from
/// zero, which looks exactly like a restart.
///
/// Naming the steps and showing which one is running turns "is this broken?"
/// into "it is on step two of three". The same information, made legible.
struct InstallStageList: View {
    let current: FeedInstallStage

    /// `done` is not a step; it is the absence of them.
    private static let steps: [FeedInstallStage] = [.downloading, .compiling, .installing]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ForEach(Self.steps, id: \.self) { step in
                row(step)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func row(_ step: FeedInstallStage) -> some View {
        let state = state(of: step)
        return HStack(spacing: Theme.Spacing.medium) {
            marker(for: state)
                .frame(width: 22, height: 22)

            Text(title(step))
                .font(Theme.Typography.rowSubtitle)
                .foregroundStyle(
                    state == .upcoming ? Theme.Palette.tertiaryText : Theme.Palette.primaryText
                )

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title(step)))
        .accessibilityValue(Text(accessibilityValue(state)))
    }

    @ViewBuilder
    private func marker(for state: StepState) -> some View {
        switch state {
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.Palette.onTime)
                .imageScale(.large)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .upcoming:
            Image(systemName: "circle")
                .foregroundStyle(Theme.Palette.tertiaryText)
                .imageScale(.large)
        }
    }

    private enum StepState { case finished, running, upcoming }

    private func state(of step: FeedInstallStage) -> StepState {
        guard let stepIndex = Self.steps.firstIndex(of: step) else { return .upcoming }
        guard let currentIndex = Self.steps.firstIndex(of: current) else {
            // `.done` sits past the end, so every step is finished.
            return current == .done ? .finished : .upcoming
        }
        if stepIndex < currentIndex { return .finished }
        if stepIndex == currentIndex { return .running }
        return .upcoming
    }

    private func title(_ step: FeedInstallStage) -> String {
        switch step {
        case .downloading: return String(localized: "Downloading the timetable")
        case .compiling: return String(localized: "Preparing it for offline use")
        case .installing: return String(localized: "Finishing up")
        case .done: return String(localized: "Ready")
        }
    }

    private func accessibilityValue(_ state: StepState) -> String {
        switch state {
        case .finished: return String(localized: "Done")
        case .running: return String(localized: "In progress")
        case .upcoming: return String(localized: "Waiting")
        }
    }
}
