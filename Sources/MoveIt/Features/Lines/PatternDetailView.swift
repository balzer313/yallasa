import SwiftUI
import MoveItKit

/// One direction of one line: where it goes, when the next ones leave, and the
/// whole timetable for a day you choose.
struct PatternDetailView: View {
    let route: RouteIndex?
    let pattern: PatternIndex?
    let position: Int?

    @EnvironmentObject private var service: TransitService
    @EnvironmentObject private var favorites: FavoriteLinesStore

    @StateObject private var model = PatternDetailViewModel()

    init(route: RouteIndex) {
        self.route = route
        self.pattern = nil
        self.position = nil
    }

    init(pattern: PatternIndex, position: Int = 0) {
        self.route = nil
        self.pattern = pattern
        self.position = position
    }

    var body: some View {
        content
            .navigationTitle(Text(model.detail?.badge.text ?? String(localized: "Line")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let detail = model.detail, !detail.routeIdentifier.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        let isFavorite = favorites.containsRoute(detail.routeIdentifier)
                        Button {
                            favorites.toggleRoute(detail.routeIdentifier, index: detail.route)
                        } label: {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                        }
                        .tint(.yellow)
                        .accessibilityLabel(
                            isFavorite
                                ? Text("Remove line from favourites")
                                : Text("Add line to favourites")
                        )
                    }
                }
            }
            .task {
                model.start(route: route, pattern: pattern, position: position, service: service)
            }
            .onChange(of: service.activeFeed?.id) { _, _ in
                model.start(route: route, pattern: pattern, position: position, service: service)
            }
            .refreshable {
                model.reloadDepartures()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingStateView(message: String(localized: "Loading the line…"))
        case .error(let message):
            ErrorStateView(message: message) {
                model.start(route: route, pattern: pattern, position: position, service: service)
            }
        case .content:
            if let detail = model.detail {
                loaded(detail)
            } else {
                EmptyStateView(
                    systemImage: "tram",
                    title: String(localized: "Line unavailable"),
                    message: String(localized: "This line is not part of the installed timetable.")
                )
            }
        }
    }

    private func loaded(_ detail: PatternDetailData) -> some View {
        List {
            Section {
                PatternHeaderCard(detail: detail)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if detail.directions.count > 1 || detail.optionsInSelectedDirection.count > 1 {
                Section {
                    PatternDirectionPicker(
                        detail: detail,
                        direction: directionBinding,
                        variant: variantBinding
                    )
                } header: {
                    Text("Direction")
                }
            }

            Section {
                PatternRouteSummary(detail: detail)
            } header: {
                Text("Route")
            }

            departuresSection(detail)
            timetableSection(detail)
            stopsSection(detail)
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Departures

    @ViewBuilder
    private func departuresSection(_ detail: PatternDetailData) -> some View {
        Section {
            stopPicker(detail)

            switch model.departuresPhase {
            case .loading:
                LoadingStateView(message: String(localized: "Checking departures…"))
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            case .error(let message):
                ErrorStateView(message: message) { model.reloadDepartures() }
                    .listRowBackground(Color.clear)
            case .empty:
                EmptyStateView(
                    systemImage: "moon.zzz",
                    title: String(localized: "Nothing more today"),
                    message: String(localized: "No further departures from this stop in the next few hours. Check the timetable below for another day.")
                )
                .listRowBackground(Color.clear)
            case .content:
                // One clock for the whole section. A `Timer` per row would wake
                // the CPU dozens of times a second to redraw the same minute.
                //
                // The rows live in a `VStack` inside a single list row rather
                // than as list rows of their own: a `TimelineView` is one view,
                // so a `ForEach` inside it collapses into one cell either way,
                // and stacking them explicitly at least keeps the separators
                // where a rider expects them.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let now = model.seconds(at: context.date)
                    VStack(spacing: 0) {
                        ForEach(Array(model.departures.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
                            DepartureRowView(item: item, now: now, showsStop: false)
                                .padding(.vertical, Theme.Spacing.small)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(
                    top: 0, leading: Theme.Spacing.regular,
                    bottom: 0, trailing: Theme.Spacing.regular
                ))
            }
        } header: {
            Text("Next departures")
        } footer: {
            if case .content = model.departuresPhase {
                Text("Times shown for \(currentStopName(detail)).")
            }
        }
    }

    private func stopPicker(_ detail: PatternDetailData) -> some View {
        Menu {
            Picker(selection: positionBinding) {
                ForEach(detail.stops) { item in
                    Text(item.name).tag(item.position)
                }
            } label: {
                Text("Departing from")
            }
        } label: {
            HStack {
                Label(String(localized: "Departing from"), systemImage: "mappin.and.ellipse")
                    .foregroundStyle(Theme.Palette.secondaryText)
                Spacer()
                Text(currentStopName(detail))
                    .foregroundStyle(Theme.Palette.primaryText)
                    .multilineTextAlignment(.trailing)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.tertiaryText)
            }
            .frame(minHeight: Theme.minimumTouchTarget)
        }
        .accessibilityLabel(Text("Departing from \(currentStopName(detail))"))
        .accessibilityHint(Text("Choose another stop along this line"))
    }

    // MARK: Timetable

    @ViewBuilder
    private func timetableSection(_ detail: PatternDetailData) -> some View {
        Section {
            datePicker

            switch model.timetablePhase {
            case .loading:
                LoadingStateView(message: String(localized: "Expanding the timetable…"))
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            case .error(let message):
                ErrorStateView(message: message) { model.reloadTimetable() }
                    .listRowBackground(Color.clear)
            case .empty:
                EmptyStateView(
                    systemImage: "calendar.badge.exclamationmark",
                    title: String(localized: "No service that day"),
                    message: String(localized: "This line does not run from this stop on the chosen date.")
                )
                .listRowBackground(Color.clear)
            case .content:
                TimetableGridView(hours: model.timetable)
            }
        } header: {
            Text("Timetable")
        } footer: {
            if case .content = model.timetablePhase {
                Text("\(model.timetableTotal) scheduled departures from \(currentStopName(detail)). Timetable only — live times are shown above.")
            }
        }
    }

    @ViewBuilder
    private var datePicker: some View {
        if let coverage = model.coverage {
            DatePicker(
                selection: dateBinding,
                in: coverage,
                displayedComponents: .date
            ) {
                Label(String(localized: "Service date"), systemImage: "calendar")
            }
        } else {
            DatePicker(selection: dateBinding, displayedComponents: .date) {
                Label(String(localized: "Service date"), systemImage: "calendar")
            }
        }
    }

    // MARK: Stops

    private func stopsSection(_ detail: PatternDetailData) -> some View {
        Section {
            ForEach(detail.stops) { item in
                NavigationLink(value: AppDestination.stop(item.stop)) {
                    PatternStopRow(
                        item: item,
                        isFirst: item.position == 0,
                        isLast: item.position == detail.stops.count - 1,
                        isSelected: item.position == model.selectedPosition,
                        lineColor: Theme.Palette.lineColor(detail.badge.backgroundHex)
                    )
                }
                .accessibilityAction(named: Text("Show departures from here")) {
                    model.select(position: item.position)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        model.select(position: item.position)
                    } label: {
                        Label(String(localized: "Departures"), systemImage: "clock")
                    }
                    .tint(Theme.Palette.accent)
                }
            }
        } header: {
            Text("All stops · \(Format.stopCount(detail.stops.count))")
        }
    }

    // MARK: Bindings

    private var directionBinding: Binding<UInt8> {
        Binding(
            get: { model.detail?.direction ?? 0 },
            set: { model.select(direction: $0) }
        )
    }

    private var variantBinding: Binding<PatternIndex> {
        Binding(
            get: { model.detail?.pattern ?? -1 },
            set: { model.select(pattern: $0) }
        )
    }

    private var positionBinding: Binding<Int> {
        Binding(
            get: { model.selectedPosition },
            set: { model.select(position: $0) }
        )
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { model.timetableDate },
            set: { model.setTimetableDate($0) }
        )
    }

    private func currentStopName(_ detail: PatternDetailData) -> String {
        guard model.selectedPosition < detail.stops.count else { return "" }
        return detail.stops[model.selectedPosition].name
    }
}

// MARK: - Header

struct PatternHeaderCard: View {
    let detail: PatternDetailData

    var body: some View {
        SectionCard(title: nil) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                    LineBadge(detail.badge, size: .large)
                    VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                        Text(detail.routeLongName.isEmpty ? detail.badge.text : detail.routeLongName)
                            .font(Theme.Typography.sectionTitle)
                            .foregroundStyle(Theme.Palette.primaryText)
                        if !detail.agencyName.isEmpty {
                            Text(detail.agencyName)
                                .font(Theme.Typography.rowSubtitle)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        }
                    }
                    Spacer(minLength: 0)
                }

                Label(
                    String(localized: "Towards \(detail.terminus)"),
                    systemImage: "arrow.forward"
                )
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(Theme.Palette.primaryText)

                HStack(spacing: Theme.Spacing.medium) {
                    Label(Format.stopCount(detail.stops.count), systemImage: "mappin.and.ellipse")
                    Label(String(localized: "\(detail.tripCount) trips"), systemImage: "clock.arrow.circlepath")
                    if detail.accessibility == .accessible {
                        Label(String(localized: "Accessible"), systemImage: "figure.roll")
                    }
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.secondaryText)

                if !detail.routeDescription.isEmpty {
                    Text(detail.routeDescription)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Direction and variant

struct PatternDirectionPicker: View {
    let detail: PatternDetailData
    @Binding var direction: UInt8
    @Binding var variant: PatternIndex

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if detail.directions.count > 1 {
                Picker(selection: $direction) {
                    ForEach(detail.directions, id: \.self) { value in
                        Text(label(for: value)).tag(value)
                    }
                } label: {
                    Text("Direction")
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text("Direction of travel"))
            }

            let variants = detail.optionsInSelectedDirection
            if variants.count > 1 {
                Picker(selection: $variant) {
                    ForEach(variants) { option in
                        Text(option.headsign.isEmpty ? option.lastStopName : option.headsign)
                            .tag(option.pattern)
                    }
                } label: {
                    Label(String(localized: "Variant"), systemImage: "arrow.triangle.branch")
                }
                .pickerStyle(.menu)

                if let current = variants.first(where: { $0.pattern == variant }) {
                    Text(current.subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
    }

    /// The end of the line is the only label a rider recognises. "Direction 0"
    /// is a GTFS implementation detail and means nothing at a bus stop.
    private func label(for value: UInt8) -> String {
        guard let option = detail.options.first(where: { $0.direction == value }) else {
            return String(localized: "Direction \(Int(value))")
        }
        let name = option.headsign.isEmpty ? option.lastStopName : option.headsign
        return name.isEmpty ? String(localized: "Direction \(Int(value))") : name
    }
}

// MARK: - Route summary

/// A compact spine for the line.
///
/// Deliberately a *summary*, not the full stop list that follows: `LineDiagram`
/// renders names, not tappable rows, so drawing all sixty stops here would
/// duplicate the section below without letting the rider touch any of them.
struct PatternRouteSummary: View {
    let detail: PatternDetailData

    var body: some View {
        LineDiagram(
            color: Theme.Palette.lineColor(detail.badge.backgroundHex),
            stops: summaryStops
        )
        .padding(.vertical, Theme.Spacing.small)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("From \(detail.origin) to \(detail.terminus), \(Format.stopCount(detail.stops.count))")
        )
    }

    private var summaryStops: [String] {
        let names = detail.stops.map(\.name)
        guard names.count > 3 else { return names }
        let middle = String(localized: "\(names.count - 2) stops in between")
        return [names[0], middle, names[names.count - 1]]
    }
}

// MARK: - Stop row

struct PatternStopRow: View {
    let item: PatternStopItem
    let isFirst: Bool
    let isLast: Bool
    let isSelected: Bool
    let lineColor: Color

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            // A two-tone marker rather than colour alone: the selected stop is
            // also the only filled ring, so the state survives greyscale.
            ZStack {
                Circle()
                    .strokeBorder(lineColor, lineWidth: 2)
                    .frame(width: 14, height: 14)
                if isSelected || isFirst || isLast {
                    Circle().fill(lineColor).frame(width: 8, height: 8)
                }
            }
            .frame(width: 16)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(item.name)
                    .font(isSelected ? Theme.Typography.rowTitle : Theme.Typography.rowSubtitle)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .lineLimit(2)
                if !item.code.isEmpty {
                    Text("Stop \(item.code)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }

            Spacer(minLength: 0)

            if item.accessibility == .accessible {
                Image(systemName: "figure.roll")
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: Theme.minimumTouchTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var accessibilityLabel: String {
        var parts: [String] = [item.name]
        if !item.code.isEmpty { parts.append(String(localized: "stop \(item.code)")) }
        if isFirst { parts.append(String(localized: "start of the line")) }
        if isLast { parts.append(String(localized: "end of the line")) }
        if item.accessibility == .accessible { parts.append(String(localized: "step-free access")) }
        if isSelected { parts.append(String(localized: "showing departures from here")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Timetable grid

struct TimetableGridView: View {
    let hours: [TimetableHour]

    private let columns = [GridItem(.adaptive(minimum: 44, maximum: 80), spacing: Theme.Spacing.small)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ForEach(hours) { hour in
                HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(hour.label)
                            .font(Theme.Typography.countdown(20))
                            .foregroundStyle(Theme.Palette.primaryText)
                        if hour.isAfterMidnight {
                            Text("next day")
                                .font(.caption2)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        }
                    }
                    .frame(minWidth: 40, alignment: .leading)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.small) {
                        ForEach(hour.entries) { entry in
                            HStack(spacing: 2) {
                                Text(entry.minuteText)
                                    .font(Theme.Typography.clock)
                                if entry.isAccessible {
                                    Image(systemName: "figure.roll")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.Palette.secondaryText)
                                }
                            }
                            .foregroundStyle(Theme.Palette.primaryText)
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.tight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilityLabel(for: hour)))
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
    }

    private func accessibilityLabel(for hour: TimetableHour) -> String {
        let times = hour.entries.map(\.clockText).joined(separator: ", ")
        if hour.isAfterMidnight {
            return String(localized: "\(hour.label) hundred, next day: \(times)")
        }
        return String(localized: "\(hour.label) hundred: \(times)")
    }
}

// MARK: - Previews

#if DEBUG
extension PatternDetailData {
    static var preview: PatternDetailData {
        let badge = LineBadgeData(
            text: "M14",
            backgroundHex: 0x2E7D32,
            foregroundHex: 0xFFFFFF,
            mode: .bus,
            accessibilityLabel: "Bus M14"
        )
        let names = [
            "Union Square", "6th Ave & 14th St", "8th Ave & 14th St",
            "Chelsea Market", "Hudson Yards", "Chelsea Piers"
        ]
        let stops = names.enumerated().map { index, name in
            PatternStopItem(
                position: index,
                stop: StopIndex(100 + index),
                name: name,
                code: "\(4400 + index)",
                accessibility: index % 2 == 0 ? .accessible : .unknown,
                distanceMeters: Int32(index * 420)
            )
        }
        let options = [
            PatternOption(
                pattern: 7, headsign: "Chelsea Piers", direction: 0,
                stopCount: 6, tripCount: 214,
                firstStopName: "Union Square", lastStopName: "Chelsea Piers"
            ),
            PatternOption(
                pattern: 8, headsign: "Union Square", direction: 1,
                stopCount: 6, tripCount: 209,
                firstStopName: "Chelsea Piers", lastStopName: "Union Square"
            )
        ]
        return PatternDetailData(
            pattern: 7,
            route: 42,
            routeIdentifier: "MTA_M14",
            badge: badge,
            mode: .bus,
            routeLongName: "14th Street Crosstown",
            routeDescription: "Runs 24 hours. Select bus service east of 8th Avenue.",
            agencyName: "Metropolitan Transit",
            headsign: "Chelsea Piers",
            direction: 0,
            accessibility: .accessible,
            tripCount: 214,
            stops: stops,
            options: options
        )
    }
}

extension TimetableHour {
    static var previewSet: [TimetableHour] {
        func entries(hour: Int, minutes: [Int]) -> [TimetableEntry] {
            minutes.map { minute in
                TimetableEntry(
                    id: "\(hour)-\(minute)",
                    seconds: ServiceSeconds(hour * 3600 + minute * 60),
                    minuteText: String(format: "%02d", minute),
                    clockText: String(format: "%02d:%02d", hour % 24, minute),
                    isAccessible: minute % 3 == 0
                )
            }
        }
        return [
            TimetableHour(id: 6, label: "06", isAfterMidnight: false, entries: entries(hour: 6, minutes: [12, 32, 52])),
            TimetableHour(id: 7, label: "07", isAfterMidnight: false, entries: entries(hour: 7, minutes: [2, 12, 22, 32, 42, 52])),
            TimetableHour(id: 24, label: "00", isAfterMidnight: true, entries: entries(hour: 24, minutes: [8, 38]))
        ]
    }
}

#Preview("Pattern header") {
    ScrollView {
        PatternHeaderCard(detail: .preview)
            .padding()
    }
    .background(Theme.Palette.background)
}

#Preview("Stop rows") {
    List {
        ForEach(PatternDetailData.preview.stops) { item in
            PatternStopRow(
                item: item,
                isFirst: item.position == 0,
                isLast: item.position == 5,
                isSelected: item.position == 2,
                lineColor: Theme.Palette.lineColor(0x2E7D32)
            )
        }
    }
}

#Preview("Timetable") {
    List {
        Section("Timetable") {
            TimetableGridView(hours: TimetableHour.previewSet)
        }
    }
}

#Preview("Timetable · dark AX3") {
    List {
        TimetableGridView(hours: TimetableHour.previewSet)
    }
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
