import Foundation
import Combine
import UserNotifications
import YallaSaKit

/// The journey the rider is currently on, and the alarms that go with it.
///
/// ## שנ״צ
///
/// The feature this exists for. A rider who knows their stop is forty minutes
/// away wants to sleep, read, or stop paying attention — and the thing stopping
/// them is the fear of missing it. שנ״צ schedules a notification one minute
/// before every point they have to act: each time they leave a vehicle, and
/// each time they board the next one.
///
/// It is opt-in, because an app that fires alarms nobody asked for gets its
/// notifications switched off permanently, and then cannot warn about anything.
///
/// ## Why notifications rather than a timer
///
/// A `Timer` dies when the app is suspended, which is precisely when this
/// matters: the rider has put the phone in their pocket. `UNUserNotificationCenter`
/// hands the schedule to the system, so the alarm fires whether the app is
/// backgrounded, suspended, or killed by memory pressure.
///
/// The alarms are therefore scheduled against the **timetable**, not against
/// live positions — the OS needs absolute times up front. A late bus can
/// consequently wake someone early; a rescheduling pass on every realtime tick
/// would drain the battery this feature is supposed to let them ignore.
@MainActor
final class TripTracker: ObservableObject {

    /// The journey being followed, or nil when no trip is running.
    @Published private(set) var trip: JourneyItem?
    /// Whether שנ״צ is armed for the current trip.
    @Published private(set) var isNapModeOn = false
    /// Set when alarms were requested but the system refused permission, so the
    /// UI can say the toggle will not actually wake anyone.
    @Published private(set) var notificationsDenied = false
    /// How many alarms are currently scheduled, for the trip sheet to show.
    @Published private(set) var scheduledAlarmCount = 0

    private let timeZone: TimeZone
    private let center: UNUserNotificationCenter

    /// Every alarm this trip scheduled, so stopping cancels exactly those and
    /// not somebody else's.
    private var scheduledIdentifiers: [String] = []

    private static let identifierPrefix = "yallasa.trip."

    /// One minute of warning. Long enough to stand up and reach the door,
    /// short enough that a rider who dozed off is not left wondering whether
    /// they already missed it.
    static let warningSeconds: TimeInterval = 60

    init(timeZone: TimeZone = .current, center: UNUserNotificationCenter = .current()) {
        self.timeZone = timeZone
        self.center = center
    }

    var isRunning: Bool { trip != nil }

    // MARK: - Starting and stopping

    func start(_ journey: JourneyItem, napMode: Bool) async {
        trip = journey
        isNapModeOn = napMode
        if napMode {
            await armAlarms(for: journey)
        }
    }

    func stop() {
        cancelAlarms()
        trip = nil
        isNapModeOn = false
        notificationsDenied = false
    }

    /// Toggling mid-trip, which is the common case: the rider boards, settles,
    /// and only then decides to sleep.
    func setNapMode(_ enabled: Bool) async {
        isNapModeOn = enabled
        guard let trip else { return }
        if enabled {
            await armAlarms(for: trip)
        } else {
            cancelAlarms()
        }
    }

    // MARK: - Alarms

    private func armAlarms(for journey: JourneyItem) async {
        cancelAlarms()

        let granted = await requestAuthorization()
        notificationsDenied = !granted
        guard granted else { return }

        for alarm in Self.alarms(for: journey, in: timeZone) {
            // Anything already in the past is silently skipped rather than fired
            // immediately, which is what a zero-or-negative interval does.
            let delay = alarm.fireAt.timeIntervalSinceNow
            guard delay > 1 else { continue }

            let content = UNMutableNotificationContent()
            content.title = alarm.title
            content.body = alarm.body
            content.sound = .default
            // Time-sensitive so it can break through a Focus — the entire point
            // is to reach someone who has deliberately stopped looking.
            content.interruptionLevel = .timeSensitive

            let request = UNNotificationRequest(
                identifier: alarm.identifier,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            )
            do {
                try await center.add(request)
                scheduledIdentifiers.append(alarm.identifier)
            } catch {
                // One alarm failing must not abandon the rest.
                continue
            }
        }
        scheduledAlarmCount = scheduledIdentifiers.count
    }

    private func cancelAlarms() {
        guard !scheduledIdentifiers.isEmpty else {
            scheduledAlarmCount = 0
            return
        }
        center.removePendingNotificationRequests(withIdentifiers: scheduledIdentifiers)
        scheduledIdentifiers.removeAll()
        scheduledAlarmCount = 0
    }

    private func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .timeSensitive])
        } catch {
            return false
        }
    }

    // MARK: - What to wake someone for

    struct Alarm: Equatable {
        var identifier: String
        var fireAt: Date
        var title: String
        var body: String
    }

    /// The moments worth waking someone for.
    ///
    /// Every point where the rider must *do* something: get off a vehicle, and
    /// board the next one. A walk leg needs no alarm of its own — its start is
    /// the alight it follows, and its end is the boarding it precedes.
    ///
    /// Static and pure so the schedule can be tested without a notification
    /// centre, which is the only way to be sure the alarm lands a minute early
    /// rather than a minute late.
    static func alarms(
        for journey: JourneyItem,
        in timeZone: TimeZone,
        warning: TimeInterval = warningSeconds
    ) -> [Alarm] {
        var alarms: [Alarm] = []
        let rides = journey.legs.enumerated().filter { $0.element.kind == .ride }

        for (index, leg) in rides {
            // Boarding: only worth an alarm when it is not the very first thing,
            // because the rider is awake and standing at the stop for that one.
            if index > 0, let boardAt = date(journey.baseDate, leg.departureSeconds, timeZone) {
                alarms.append(
                    Alarm(
                        identifier: "\(identifierPrefix)\(journey.id).board.\(index)",
                        fireAt: boardAt.addingTimeInterval(-warning),
                        title: String(localized: "Your next bus is coming"),
                        body: String(localized: "Board \(leg.badge?.text ?? "") at \(leg.fromName) in 1 minute.")
                    )
                )
            }

            guard let alightAt = date(journey.baseDate, leg.arrivalSeconds, timeZone) else { continue }
            let isLast = index == (rides.last?.offset ?? -1)
            alarms.append(
                Alarm(
                    identifier: "\(identifierPrefix)\(journey.id).alight.\(index)",
                    fireAt: alightAt.addingTimeInterval(-warning),
                    title: isLast
                        ? String(localized: "Almost there")
                        : String(localized: "Time to get off"),
                    body: String(localized: "Get off at \(leg.toName) in 1 minute.")
                )
            )
        }

        return alarms.sorted { $0.fireAt < $1.fireAt }
    }

    private static func date(
        _ base: ServiceDate,
        _ seconds: ServiceSeconds,
        _ timeZone: TimeZone
    ) -> Date? {
        ServiceInstant(date: base, seconds: seconds).normalised.date(in: timeZone)
    }
}
