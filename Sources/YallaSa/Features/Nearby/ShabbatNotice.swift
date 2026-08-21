import SwiftUI
import YallaSaKit

/// Explains a near-empty board on Shabbat.
///
/// Without this, someone opening the app in Tel Aviv at eleven on a Saturday
/// morning sees "no further departures in the timetable" — wording that means
/// the data is missing, when in fact the data is complete and correct and there
/// simply are no buses. That is the difference between a rider believing the app
/// is broken and a rider knowing when service returns.
///
/// It is careful about two things.
///
/// **It never claims there is no service at all.** About a fifth of Israel's
/// service patterns do run on Saturday, and in Haifa, Nazareth or Beit Shemesh
/// the board will be legitimately full. So the notice appears alongside whatever
/// is running rather than replacing it, and its wording says *most* lines.
///
/// **It is not religious guidance.** It says when buses come back, using the
/// common conventions, and takes no position on anything else.
struct ShabbatNotice: View {
    let now: Date

    private var endsAt: Date? {
        ShabbatClock.endOfShabbat(containing: now)
    }

    var body: some View {
        if let endsAt {
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                Image(systemName: "moon.stars.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.Palette.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    Text("Shabbat")
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.Palette.primaryText)

                    Text("Most lines do not run right now. Service returns around \(Format.clock(endsAt, in: ShabbatClock.israelTimeZone)).")
                        .font(Theme.Typography.rowSubtitle)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .fill(Theme.Palette.accent.opacity(0.10))
            )
            .accessibilityElement(children: .combine)
        }
    }
}
