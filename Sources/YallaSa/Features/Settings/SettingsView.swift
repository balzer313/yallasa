import SwiftUI
import YallaSaKit

/// The control panel, and the place the "no cloud" promise is made checkable
/// rather than merely claimed.
struct SettingsView: View {
    @EnvironmentObject private var service: TransitService
    @EnvironmentObject private var router: AppRouter

    @AppStorage("planner.maximumTransfers") private var maximumTransfers: Int = 4
    @AppStorage("planner.maximumWalkMeters") private var maximumWalkMeters: Double = 1000
    @AppStorage("planner.requiresWheelchairAccess") private var requiresWheelchairAccess: Bool = false
    @AppStorage("planner.walkingSpeed") private var walkingSpeed: Double = 1.33
    @AppStorage("realtime.enabled") private var realtimeEnabled: Bool = true
    @AppStorage("realtime.intervalSeconds") private var realtimeInterval: Double = 30

    @State private var failure: String?
    @State private var isRefreshing = false
    @State private var feedPendingRemoval: InstalledFeed?

    var body: some View {
        List {
            if let failure {
                Section {
                    Text(failure)
                        .foregroundStyle(Theme.Palette.cancelled)
                        .font(Theme.Typography.caption)
                }
            }

            feedsSection
            routingSection
            realtimeSection
            storageSection
            aboutSection
        }
        .navigationTitle(Text("Settings"))
        .alert(
            Text("Remove this timetable?"),
            isPresented: Binding(
                get: { feedPendingRemoval != nil },
                set: { if !$0 { feedPendingRemoval = nil } }
            ),
            presenting: feedPendingRemoval
        ) { feed in
            Button(role: .destructive) {
                remove(feed)
            } label: {
                Text("Remove")
            }
            Button(role: .cancel) { feedPendingRemoval = nil } label: { Text("Keep") }
        } message: { feed in
            Text("\(feed.source.name) will be deleted from this phone. You can download it again later.")
        }
    }

    // MARK: - Feeds

    private var feedsSection: some View {
        Section {
            ForEach(service.installedFeeds) { feed in
                NavigationLink {
                    FeedDetailView(feed: feed)
                } label: {
                    feedRow(feed)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        feedPendingRemoval = feed
                    } label: {
                        Label(String(localized: "Remove"), systemImage: "trash")
                    }
                }
            }

            Button {
                router.show(.feedPicker, in: .settings)
            } label: {
                Label(String(localized: "Add a city"), systemImage: "plus.circle")
            }

            Button {
                refresh()
            } label: {
                HStack {
                    Label(String(localized: "Check for timetable updates"), systemImage: "arrow.clockwise")
                    if isRefreshing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isRefreshing || service.activeFeed == nil)
        } header: {
            Text("Timetables")
        } footer: {
            if let progress = service.installProgress {
                Text(progress.detail)
            } else {
                Text("Timetables are stored on this phone. Nothing is uploaded and nothing is fetched while you plan.")
            }
        }
    }

    private func feedRow(_ feed: InstalledFeed) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(feed.source.name)
                    .font(Theme.Typography.rowTitle)
                if feed.id == service.activeFeed?.id {
                    Text("Active")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.Palette.accent.opacity(0.18)))
                }
            }
            Text("\(Format.fileSize(bytes: feed.byteSize)) · \(coverageText(feed))")
                .font(Theme.Typography.caption)
                .foregroundStyle(coverageIsUrgent(feed) ? Theme.Palette.late : Theme.Palette.secondaryText)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard feed.id != service.activeFeed?.id else { return }
            activate(feed)
        }
    }

    /// An expired timetable is this app's worst failure mode: it does not look
    /// broken, it just quietly reports that no buses exist. So coverage is stated
    /// on the row, and it turns amber a week out rather than on the day.
    private func coverageText(_ feed: InstalledFeed) -> String {
        guard let end = feed.metadata.calendarEnd else {
            return String(localized: "no calendar")
        }
        let today = ServiceDate(date: Date(), in: feed.metadata.timeZone)
        let daysLeft = end.days(since: today)
        if daysLeft < 0 { return String(localized: "expired — refresh needed") }
        if daysLeft == 0 { return String(localized: "valid through today") }
        if daysLeft <= 7 { return String(localized: "expires in \(daysLeft) days") }
        return String(localized: "valid for \(daysLeft) more days")
    }

    private func coverageIsUrgent(_ feed: InstalledFeed) -> Bool {
        guard let end = feed.metadata.calendarEnd else { return true }
        let today = ServiceDate(date: Date(), in: feed.metadata.timeZone)
        return end.days(since: today) <= 7
    }

    // MARK: - Routing

    private var routingSection: some View {
        Section {
            Stepper(value: $maximumTransfers, in: 0...5) {
                LabeledContent(String(localized: "Maximum transfers"), value: "\(maximumTransfers)")
            }

            VStack(alignment: .leading) {
                LabeledContent(
                    String(localized: "Maximum walk"),
                    value: Format.distance(meters: maximumWalkMeters)
                )
                Slider(value: $maximumWalkMeters, in: 200...2500, step: 100)
                    .accessibilityValue(Text(Format.distance(meters: maximumWalkMeters)))
            }

            VStack(alignment: .leading) {
                LabeledContent(String(localized: "Walking speed"), value: walkingSpeedLabel)
                Slider(value: $walkingSpeed, in: 0.8...2.0, step: 0.05)
                    .accessibilityValue(Text(walkingSpeedLabel))
            }

            Toggle(isOn: $requiresWheelchairAccess) {
                Text("Only step-free journeys")
            }
        } header: {
            Text("Planning")
        } footer: {
            Text("Walking legs are straight-line distances with an allowance for detours. Yalla Sa does not download street maps, which is part of how it stays small and offline.")
        }
    }

    private var walkingSpeedLabel: String {
        // Expressed as pace, because "1.33 m/s" means nothing to a rider.
        let metersPerMinute = walkingSpeed * 60
        return String(localized: "\(Int(metersPerMinute.rounded())) m per minute")
    }

    // MARK: - Realtime

    private var realtimeSection: some View {
        Section {
            Toggle(isOn: $realtimeEnabled) {
                Text("Live arrival times")
            }
            .onChange(of: realtimeEnabled) { _, enabled in
                if enabled {
                    service.startRealtimePolling(interval: realtimeInterval)
                } else {
                    service.stopRealtimePolling()
                }
            }

            if realtimeEnabled {
                VStack(alignment: .leading) {
                    LabeledContent(
                        String(localized: "Check every"),
                        value: String(localized: "\(Int(realtimeInterval)) seconds")
                    )
                    Slider(value: $realtimeInterval, in: 15...120, step: 15)
                }

                LabeledContent(String(localized: "Last update")) {
                    if let updated = service.realtimeUpdatedAt {
                        Text(Format.relativeAge(of: updated))
                    } else {
                        Text("never")
                    }
                }
            }
        } header: {
            Text("Live data")
        } footer: {
            if service.activeFeed?.source.hasRealtime == true {
                Text("Live times come straight from the agency's public feed. Turning this off makes the app fully offline.")
            } else {
                Text("This timetable has no public live feed, so all times shown are scheduled.")
            }
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            LabeledContent(String(localized: "Timetables on disk"), value: Format.fileSize(bytes: totalBytes))
        } header: {
            Text("Storage")
        } footer: {
            Text("Compiled timetables can be deleted and downloaded again at any time.")
        }
    }

    private var totalBytes: Int64 {
        service.installedFeeds.reduce(0) { $0 + $1.byteSize }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutView()
            } label: {
                Label(String(localized: "How Yalla Sa works"), systemImage: "info.circle")
            }

            ForEach(service.installedFeeds) { feed in
                if let license = feed.source.licenseURL {
                    Link(destination: license) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feed.source.name).font(Theme.Typography.rowSubtitle)
                            Text(feed.source.attribution)
                                .font(.caption2)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feed.source.name).font(Theme.Typography.rowSubtitle)
                        Text(feed.source.attribution)
                            .font(.caption2)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                }
            }
        } header: {
            Text("About and data credits")
        } footer: {
            Text("Transit data is published by the agencies above under their own licences.")
        }
    }

    // MARK: - Actions

    private func activate(_ feed: InstalledFeed) {
        Task {
            do {
                failure = nil
                try await service.activate(feedID: feed.id)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func remove(_ feed: InstalledFeed) {
        feedPendingRemoval = nil
        Task {
            do {
                failure = nil
                try await service.removeFeed(id: feed.id)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func refresh() {
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            do {
                failure = nil
                let changed = try await service.refreshActiveFeed()
                if !changed { failure = String(localized: "The timetable is already up to date.") }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// What the importer actually built, shown honestly — including what it threw
/// away. Transit data is dirty, and a rider who wonders why a line is missing
/// deserves somewhere to look.
struct FeedDetailView: View {
    let feed: InstalledFeed

    var body: some View {
        List {
            Section(String(localized: "Coverage")) {
                LabeledContent(String(localized: "Region"), value: feed.source.region)
                LabeledContent(String(localized: "Installed"), value: feed.installedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent(String(localized: "Time zone"), value: feed.metadata.timeZoneIdentifier)
                if feed.metadata.calendarDayCount > 0 {
                    LabeledContent(
                        String(localized: "Valid from"),
                        value: feed.metadata.calendarStart.gtfsString
                    )
                    if let end = feed.metadata.calendarEnd {
                        LabeledContent(String(localized: "Valid until"), value: end.gtfsString)
                    }
                }
            }

            Section(String(localized: "Network")) {
                let counts = feed.metadata.counts
                LabeledContent(String(localized: "Stops"), value: "\(counts.stops)")
                LabeledContent(String(localized: "Lines"), value: "\(counts.routes)")
                LabeledContent(String(localized: "Patterns"), value: "\(counts.patterns)")
                LabeledContent(String(localized: "Trips"), value: "\(counts.trips)")
                LabeledContent(String(localized: "Stop times"), value: "\(counts.stopTimes)")
                LabeledContent(String(localized: "Footpaths"), value: "\(counts.transfers)")
                LabeledContent(String(localized: "Size on disk"), value: Format.fileSize(bytes: feed.byteSize))
            }

            Section {
                let report = feed.metadata.report
                if report.totalDropped == 0 && report.warnings.isEmpty {
                    Text("Nothing was dropped — this feed imported cleanly.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.onTime)
                } else {
                    droppedRow(String(localized: "Stops without coordinates"), report.droppedStopsMissingCoordinate)
                    droppedRow(String(localized: "Unreadable times"), report.droppedStopTimesUnparsableTime)
                    droppedRow(String(localized: "Times for unknown stops"), report.droppedStopTimesUnknownStop)
                    droppedRow(String(localized: "Trips on unknown lines"), report.droppedTripsUnknownRoute)
                    droppedRow(String(localized: "Trips with no service days"), report.droppedTripsUnknownService)
                    droppedRow(String(localized: "Trips too short to use"), report.droppedTripsTooShort)
                    droppedRow(String(localized: "Interpolated times"), report.interpolatedStopTimes)
                    ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                }
            } header: {
                Text("Import report")
            } footer: {
                Text("Published transit data often contains errors. Anything Yalla Sa could not use is listed here rather than hidden.")
            }
        }
        .navigationTitle(Text(feed.source.name))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func droppedRow(_ title: String, _ count: Int) -> some View {
        if count > 0 {
            LabeledContent(title, value: "\(count)")
        }
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Text("Everything runs here")
                    .font(Theme.Typography.screenTitle)

                Text("Most transit apps send your starting point and destination to a server, which works out the route and sends it back. Yalla Sa does that work on your phone instead.")

                Text("When you install a city, Yalla Sa downloads the timetable that the transit agency publishes for free, and compiles it into a compact index stored on the device. Searching for a journey then reads that index directly — typically in well under a second — with no network involved.")

                Text("What this means for you")
                    .font(Theme.Typography.sectionTitle)

                Label { Text("Journey planning and departure boards work with no signal.") }
                    icon: { Image(systemName: "wifi.slash") }
                Label { Text("Your location and your trips are never sent anywhere.") }
                    icon: { Image(systemName: "lock.shield") }
                Label { Text("No account, and nothing to pay for — there is no server to run.") }
                    icon: { Image(systemName: "dollarsign.circle") }

                Text("The trade-offs")
                    .font(Theme.Typography.sectionTitle)

                Text("Walking directions are straight-line estimates rather than turn-by-turn routes, because street maps are far larger than timetables and would undo the point of staying small.")

                Text("Live delays still need a connection, and only some agencies publish them. When there is no live data, Yalla Sa shows scheduled times and says so rather than pretending to know.")

                Text("Timetables also expire. Yalla Sa warns you before yours does, because an out-of-date timetable that looks fine is worse than none at all.")
            }
            .font(Theme.Typography.rowSubtitle)
            .padding(Theme.Spacing.regular)
        }
        .navigationTitle(Text("How it works"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
