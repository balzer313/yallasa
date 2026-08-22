import SwiftUI
import YallaSaKit

/// Start the trip, with שנ״צ beside it.
///
/// Pinned to the bottom of the journey screen rather than sitting at the end of
/// the scroll: it is the only action on the screen, and a rider reading a long
/// journey with five legs should not have to scroll back to it.
///
/// שנ״צ sits next to Start rather than inside a settings screen because the
/// decision is per-trip. Whether you want waking depends entirely on whether
/// this particular ride is forty minutes or four.
struct StartTripBar: View {
    let item: JourneyItem
    @ObservedObject var tracker: TripTracker

    @State private var napMode = false
    @State private var isShowingNapInfo = false

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            napRow

            if tracker.notificationsDenied {
                // Said plainly. A toggle that is on but cannot fire is worse
                // than one that is off, because the rider stops watching.
                Label(
                    String(localized: "Notifications are off, so nothing can wake you. Turn them on in Settings."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.late)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await tracker.start(item, napMode: napMode) }
            } label: {
                Label(String(localized: "Start trip"), systemImage: "play.fill")
                    .font(Theme.Typography.rowTitle)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(Theme.Spacing.regular)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Palette.separator).frame(height: 0.5)
        }
    }

    private var napRow: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(napMode ? Theme.Palette.accent : Theme.Palette.tertiaryText)

            // The Hebrew abbreviation is the name of the feature, so it is not
            // translated away in the English build — an Israeli rider looking
            // for שנ״צ should find the word they expect.
            Text(verbatim: "שנ״צ")
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(Theme.Palette.primaryText)

            Button {
                isShowingNapInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(Theme.Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("What is שנ״צ?"))

            Spacer(minLength: 0)

            Toggle("", isOn: $napMode)
                .labelsHidden()
                .accessibilityLabel(Text("Wake me before each stop"))
        }
        .onChange(of: napMode) { _, enabled in
            // Only meaningful once the trip is running; before that the choice
            // is simply carried into `start`.
            guard tracker.isRunning else { return }
            Task { await tracker.setNapMode(enabled) }
        }
        .popover(isPresented: $isShowingNapInfo) {
            napExplanation
                .presentationCompactAdaptation(.popover)
        }
    }

    private var napExplanation: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(Theme.Palette.accent)
                Text(verbatim: "שנ״צ")
                    .font(Theme.Typography.sectionTitle)
            }

            Text("Sleep on the bus. We will wake you one minute before you need to get off, and one minute before each connection.")
                .font(Theme.Typography.rowSubtitle)
                .fixedSize(horizontal: false, vertical: true)

            // Stated because the rider is about to trust it while unconscious,
            // and a promise that quietly depends on the bus being on time is
            // not a promise worth making silently.
            Text("Alarms follow the timetable, so a late bus may wake you a little early.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.regular)
        .frame(maxWidth: 320)
    }
}
