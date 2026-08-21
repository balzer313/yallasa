import SwiftUI
import YallaSaKit

/// What you get when you tap a bus.
///
/// The design constraint worth naming: this data is *thin*. A SIRI position
/// gives a line, a heading, a speed and a timestamp — and nothing about where
/// the vehicle is going or when it will reach you. Padding that out with
/// plausible-looking estimates would be inventing information, so the sheet
/// shows what is known, says plainly what is not, and offers the one honest
/// next step: open the line's timetable.
struct LiveVehicleSheet: View {
    let vehicle: LiveVehicle
    let now: Date
    let openLine: () -> Void

    private var age: TimeInterval { vehicle.position.age(at: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.regular) {
            header

            Divider()

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                detail(
                    icon: vehicle.position.isMoving ? "location.north.line.fill" : "pause.circle",
                    title: vehicle.position.isMoving
                        ? String(localized: "Moving")
                        : String(localized: "Stopped"),
                    value: speedText
                )
                detail(
                    icon: "dot.radiowaves.up.forward",
                    title: String(localized: "Last reported"),
                    value: Format.relativeAge(of: vehicle.position.recordedAt, now: now)
                )
            }

            // Said out loud rather than implied by absence. A rider who taps a
            // bus expects an arrival time; not explaining why there isn't one
            // reads as a broken screen.
            Text("This is the vehicle's reported position. It does not include an arrival estimate — the live feed reports where buses are, not when they will reach you.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if vehicle.route != nil {
                Button(action: openLine) {
                    Label(String(localized: "Open this line"), systemImage: "arrow.forward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                // Happens near the edge of a metro clip: the bus is real, the
                // line is outside the installed region.
                Text("This line is not part of the installed timetable.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
        .padding(Theme.Spacing.regular)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Text(vehicle.lineName)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Palette.hex(vehicle.textColor))
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.tight)
                .frame(minWidth: 44)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.Palette.lineColor(vehicle.color))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(vehicle.mode.displayName)
                    .font(Theme.Typography.rowTitle)
                Text(Format.relativeAge(of: vehicle.position.recordedAt, now: now))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(
                        age > LiveVehicleMarker.staleAfter
                            ? Theme.Palette.late
                            : Theme.Palette.onTime
                    )
            }
            Spacer()
        }
    }

    private func detail(icon: String, title: String, value: String) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: icon)
                .foregroundStyle(Theme.Palette.secondaryText)
                .frame(width: 20)
            Text(title)
                .font(Theme.Typography.rowSubtitle)
            Spacer()
            Text(value)
                .font(Theme.Typography.rowSubtitle)
                .foregroundStyle(Theme.Palette.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private var speedText: String {
        guard let speed = vehicle.position.speedKilometresPerHour, speed > 1 else {
            return String(localized: "—")
        }
        return String(localized: "\(Int(speed.rounded())) km/h")
    }
}
