import SwiftUI
import MoveItKit

/// First run: the app has no timetable and cannot do anything until it has one.
///
/// This screen carries the whole promise of the product, so it explains it
/// rather than showing a bare list: everything runs on the phone, the download
/// happens once, and after that it works with no signal. Riders who understand
/// why they are waiting for a 100 MB download tolerate it; riders who don't,
/// delete the app.
struct FeedGateView: View {
    @EnvironmentObject private var service: TransitService
    @EnvironmentObject private var location: LocationProvider

    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let progress = service.installProgress {
                    FeedInstallProgressView(progress: progress)
                } else {
                    picker
                }
            }
            .navigationTitle(Text("Move It"))
        }
    }

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                explanation

                if let failure {
                    ErrorStateView(message: failure) { self.failure = nil }
                }

                FeedSourceList(
                    sources: orderedSources,
                    title: String(localized: "Choose your city")
                ) { source, region in
                    await install(source, region: region)
                }
            }
            .padding(Theme.Spacing.regular)
        }
    }

    private var orderedSources: [FeedSource] {
        if let here = location.coordinate {
            return FeedCatalog.nearest(to: here)
        }
        return FeedCatalog.bundled
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Everything runs on your phone")
                .font(Theme.Typography.screenTitle)

            Label {
                Text("Download your city's timetable once. Move It compiles it here, on the device.")
            } icon: {
                Image(systemName: "iphone.and.arrow.forward")
            }

            Label {
                Text("Plan trips and check departures with no signal at all.")
            } icon: {
                Image(systemName: "wifi.slash")
            }

            Label {
                Text("No account, no tracking, no server. Your location never leaves the phone.")
            } icon: {
                Image(systemName: "lock.shield")
            }
        }
        .font(Theme.Typography.rowSubtitle)
        .foregroundStyle(Theme.Palette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func install(_ source: FeedSource, region: GeoBounds?) async {
        failure = nil
        do {
            try await service.install(source, region: region)
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Reused by the gate and by Settings, so "add a city" is the same flow whether
/// it is your first or your fourth.
struct FeedSourceList: View {
    let sources: [FeedSource]
    let title: String
    let install: (FeedSource, GeoBounds?) async -> Void

    @State private var customURL: String = ""
    @State private var customError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(title)
                .font(Theme.Typography.sectionTitle)

            ForEach(sources) { source in
                FeedSourceRow(source: source) { region in
                    await install(source, region)
                }
            }

            customSection
        }
    }

    private var customSection: some View {
        SectionCard(title: String(localized: "Add a custom feed"), systemImage: "link") {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("Any public GTFS zip URL works. Most agencies publish one on their open-data page.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)

                TextField(String(localized: "https://…/gtfs.zip"), text: $customURL)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                if let customError {
                    Text(customError)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.cancelled)
                }

                Button {
                    addCustom()
                } label: {
                    Text("Add feed")
                }
                .buttonStyle(.borderedProminent)
                .disabled(customURL.isEmpty)
            }
        }
    }

    private func addCustom() {
        let trimmed = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), url.host != nil else {
            customError = String(localized: "That does not look like a valid URL.")
            return
        }
        // The app ships with no App Transport Security exceptions, so a plain
        // http URL would fail at the socket with a far less helpful message.
        guard scheme == "https" else {
            customError = String(localized: "Feed URLs must use https.")
            return
        }
        customError = nil
        let source = FeedSource.custom(staticURL: url, name: url.lastPathComponent)
        Task { await install(source, nil) }
    }
}

struct FeedSourceRow: View {
    let source: FeedSource
    let install: (GeoBounds?) async -> Void

    var body: some View {
        SectionCard(title: nil) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name)
                            .font(Theme.Typography.rowTitle)
                        Text(source.region)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                    Spacer(minLength: Theme.Spacing.small)
                    Text(Format.fileSize(bytes: source.estimatedDownloadBytes))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }

                if source.hasRealtime {
                    Label {
                        Text("Live arrivals available")
                    } icon: {
                        Image(systemName: "dot.radiowaves.up.forward")
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.onTime)
                }

                if source.needsRegionSelection, let box = source.defaultBoundingBox {
                    // A national feed is usually far more than a rider needs.
                    // Clipping is what makes it fit comfortably on a phone.
                    Text("This is a national feed. Installing just your area keeps it small and fast.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)

                    HStack {
                        Button {
                            Task { await install(box) }
                        } label: {
                            Text("Install \(source.region)")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            Task { await install(nil) }
                        } label: {
                            Text("Whole country")
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Button {
                        Task { await install(source.defaultBoundingBox) }
                    } label: {
                        Text("Install")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Text(source.attribution)
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.tertiaryText)
            }
        }
    }
}

/// Download and compile, with honest staging.
///
/// The compile phase is the slow one and it has no bytes to count, so it reports
/// its own fraction; a bar that stops at 40% and sits there for a minute reads as
/// a hang even when it is working perfectly.
struct FeedInstallProgressView: View {
    let progress: FeedInstallProgress

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            Spacer()

            Image(systemName: symbolName)
                .font(.system(size: 48))
                .foregroundStyle(Theme.Palette.accent)
                .accessibilityHidden(true)

            Text(stageTitle)
                .font(Theme.Typography.sectionTitle)

            if progress.isIndeterminate {
                ProgressView()
                    .progressViewStyle(.circular)
            } else {
                ProgressView(value: min(max(progress.fraction, 0), 1))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)
            }

            Text(progress.detail)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
                .multilineTextAlignment(.center)

            if progress.stage == .downloading, progress.totalBytes > 0 {
                Text("\(Format.fileSize(bytes: progress.bytesDownloaded)) of \(Format.fileSize(bytes: progress.totalBytes))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .monospacedDigit()
            }

            Text("This happens once. After it finishes, Move It works offline.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.tertiaryText)
                .multilineTextAlignment(.center)
                .padding(.top, Theme.Spacing.small)

            Spacer()
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(stageTitle). \(progress.detail)"))
    }

    private var stageTitle: String {
        switch progress.stage {
        case .downloading: return String(localized: "Downloading the timetable")
        case .compiling: return String(localized: "Preparing it for offline use")
        case .installing: return String(localized: "Finishing up")
        case .done: return String(localized: "Ready")
        }
    }

    private var symbolName: String {
        switch progress.stage {
        case .downloading: return "arrow.down.circle"
        case .compiling: return "gearshape.2"
        case .installing: return "internaldrive"
        case .done: return "checkmark.circle"
        }
    }
}

/// The same picker, reachable from Settings once a feed already exists.
struct FeedPickerView: View {
    @EnvironmentObject private var service: TransitService
    @EnvironmentObject private var location: LocationProvider
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                if let progress = service.installProgress {
                    FeedInstallProgressView(progress: progress)
                } else {
                    if let failure {
                        ErrorStateView(message: failure) { self.failure = nil }
                    }
                    FeedSourceList(
                        sources: available,
                        title: String(localized: "Add a city")
                    ) { source, region in
                        failure = nil
                        do {
                            try await service.install(source, region: region)
                        } catch {
                            failure = error.localizedDescription
                        }
                    }
                }
            }
            .padding(Theme.Spacing.regular)
        }
        .navigationTitle(Text("Add a city"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var available: [FeedSource] {
        let installed = Set(service.installedFeeds.map(\.source.id))
        let all = location.coordinate.map { FeedCatalog.nearest(to: $0) } ?? FeedCatalog.bundled
        return all.filter { !installed.contains($0.id) }
    }
}
