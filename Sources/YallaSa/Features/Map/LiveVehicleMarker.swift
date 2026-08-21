import SwiftUI
import YallaSaKit

/// A bus on the map.
///
/// Three things must be legible at a glance over a busy map: which line it is,
/// which way it is pointing, and whether the fix is recent enough to believe.
/// The last is why this is not just a coloured dot — a stale position drawn
/// identically to a fresh one is a lie the rider has no way to detect.
struct LiveVehicleMarker: View {
    let vehicle: LiveVehicle
    let now: Date

    /// Past this the marker fades and drops its heading. Chosen against the
    /// measured ~82 s end-to-end latency of the Israeli SIRI pipeline: two
    /// minutes is "running normally", beyond that something is wrong.
    static let staleAfter: TimeInterval = 120

    private var age: TimeInterval { vehicle.position.age(at: now) }
    private var isStale: Bool { age > Self.staleAfter }
    private var tint: Color { Theme.Palette.lineColor(vehicle.color) }

    var body: some View {
        ZStack {
            // The wedge sits behind the badge so it reads as "this is pointing
            // that way" rather than as a separate arrow floating alongside.
            if let bearing = vehicle.position.bearingDegrees, !isStale {
                HeadingWedge()
                    .fill(tint.opacity(0.55))
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(bearing))
                    .accessibilityHidden(true)
            }

            Circle()
                .fill(tint)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)

            Text(vehicle.lineName)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Palette.hex(vehicle.textColor))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .frame(width: 21)
        }
        // Fading rather than removing: a bus that stopped reporting is probably
        // still there, and dropping it makes the map flicker as vehicles come
        // and go between polls.
        .opacity(isStale ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.35), value: isStale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts: [String] = [String(localized: "Line \(vehicle.lineName)")]
        if vehicle.position.isMoving {
            parts.append(String(localized: "moving"))
        } else {
            parts.append(String(localized: "stopped"))
        }
        parts.append(Format.relativeAge(of: vehicle.position.recordedAt, now: now))
        return parts.joined(separator: ", ")
    }
}

/// The triangular heading indicator behind a vehicle badge.
///
/// Drawn pointing up so `rotationEffect` takes a compass bearing directly, with
/// no offset arithmetic at the call site to get wrong.
private struct HeadingWedge: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.move(to: CGPoint(x: centre.x, y: centre.y - radius))
        path.addLine(to: CGPoint(x: centre.x - radius * 0.52, y: centre.y + radius * 0.24))
        path.addLine(to: CGPoint(x: centre.x + radius * 0.52, y: centre.y + radius * 0.24))
        path.closeSubpath()
        return path
    }
}

/// The "live" chip shown over the map while vehicles are being drawn.
///
/// It exists to answer the question the dots provoke — *are these actually
/// live?* — and it is deliberately capable of saying no.
struct LiveStatusChip: View {
    let updatedAt: Date?
    let vehicleCount: Int
    let failed: Bool
    let now: Date

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 7, height: 7)
            Text(label)
                .font(Theme.Typography.caption.weight(.medium))
                .foregroundStyle(Theme.Palette.secondaryText)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.tight + 1)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Palette.separator, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var indicatorColor: Color {
        if failed { return Theme.Palette.cancelled }
        guard let updatedAt else { return Theme.Palette.scheduled }
        return now.timeIntervalSince(updatedAt) > LiveVehicleMarker.staleAfter
            ? Theme.Palette.late
            : Theme.Palette.onTime
    }

    private var label: String {
        if failed {
            return String(localized: "Live positions unavailable")
        }
        guard let updatedAt, vehicleCount > 0 else {
            return String(localized: "No vehicles reporting here")
        }
        return String(
            localized: "\(vehicleCount) live · \(Format.relativeAge(of: updatedAt, now: now))"
        )
    }
}
