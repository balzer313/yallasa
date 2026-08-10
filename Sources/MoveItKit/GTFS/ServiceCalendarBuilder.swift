import Foundation

/// Flattens `calendar.txt` + `calendar_dates.txt` into one fixed-stride bitset
/// per service.
///
/// The router asks "does service 412 run on day 37?" millions of times per query,
/// and it must answer in a couple of instructions. Every form of calendar GTFS
/// allows — weekday masks, date ranges, added days, removed days, feeds with no
/// `calendar.txt` at all — collapses here into the same flat bitmap, so the hot
/// path never branches on which form the feed used.
enum ServiceCalendarBuilder {

    /// Two dimensions bound the bitmap: a feed that declares service into 2099
    /// would otherwise allocate a bitset per service covering 70 years, and no
    /// rider plans a journey more than a year out.
    static let maximumDayCount = 400

    struct Result {
        var calendarStart: ServiceDate
        var calendarDayCount: Int
        /// Bytes per service; `ceil(calendarDayCount / 8)`.
        var bitsetStride: Int
        /// `services * bitsetStride` bytes, service-major.
        var bits: [UInt8]
        /// String-blob offsets of the surviving service ids, in emit order.
        var identifierRefs: [UInt32]
        var indexByServiceRef: [UInt32: ServiceIndex]
        /// Services whose bitset came out empty and were therefore not emitted.
        var droppedEmptyServices: Int
    }

    static func build(
        calendars: [GTFSCalendarRow],
        exceptions: [GTFSCalendarDateRow],
        window: ClosedRange<ServiceDate>?
    ) -> Result {
        // MARK: Range
        //
        // Only *added* exception dates widen the range. A removal that points far
        // outside the feed's own span — feeds do contain these — must not drag
        // 400 days of empty bitmap along with it.
        var firstDay: ServiceDate?
        var lastDay: ServiceDate?
        for row in calendars {
            firstDay = min(firstDay ?? row.startDate, row.startDate)
            lastDay = max(lastDay ?? row.endDate, row.endDate)
        }
        for row in exceptions where row.isAdded {
            firstDay = min(firstDay ?? row.date, row.date)
            lastDay = max(lastDay ?? row.date, row.date)
        }

        var start = firstDay ?? window?.lowerBound ?? ServiceDate(year: 1970, month: 1, day: 1)
        var end = lastDay ?? window?.upperBound ?? start
        if let window {
            start = max(start, window.lowerBound)
            end = min(end, window.upperBound)
        }

        var dayCount = end.days(since: start) + 1
        if dayCount < 0 { dayCount = 0 }
        if dayCount > maximumDayCount { dayCount = maximumDayCount }
        let stride = (dayCount + 7) / 8

        // MARK: Service slots
        //
        // Order of first appearance, so a rebuild of the same feed produces the
        // same indices and a cached realtime match stays valid.
        var identifierRefs: [UInt32] = []
        var slotByRef: [UInt32: Int] = [:]
        for row in calendars where slotByRef[row.serviceRef] == nil {
            slotByRef[row.serviceRef] = identifierRefs.count
            identifierRefs.append(row.serviceRef)
        }
        for row in exceptions where slotByRef[row.serviceRef] == nil {
            slotByRef[row.serviceRef] = identifierRefs.count
            identifierRefs.append(row.serviceRef)
        }

        let serviceCount = identifierRefs.count
        var bits = [UInt8](repeating: 0, count: serviceCount * stride)

        if dayCount > 0 {
            for row in calendars {
                guard row.weekdayMask != 0, let slot = slotByRef[row.serviceRef] else { continue }
                let lower = max(0, row.startDate.days(since: start))
                let upper = min(dayCount - 1, row.endDate.days(since: start))
                guard lower <= upper else { continue }
                for day in lower...upper {
                    let weekdayMask: UInt8 = 1 << UInt8(start.adding(days: day).weekdayIndex)
                    guard row.weekdayMask & weekdayMask != 0 else { continue }
                    let dayMask: UInt8 = 1 << UInt8(day & 7)
                    bits[slot * stride + (day >> 3)] |= dayMask
                }
            }

            // Exceptions are applied after every range so that a removal always
            // wins over the weekday mask that put the day there, regardless of the
            // order the two files happened to be read in.
            for row in exceptions {
                guard let slot = slotByRef[row.serviceRef] else { continue }
                let day = row.date.days(since: start)
                guard day >= 0, day < dayCount else { continue }
                let dayMask: UInt8 = 1 << UInt8(day & 7)
                let byteIndex = slot * stride + (day >> 3)
                if row.isAdded {
                    bits[byteIndex] |= dayMask
                } else {
                    bits[byteIndex] &= ~dayMask
                }
            }
        }

        // MARK: Compaction
        //
        // Expired services are the single largest source of dead weight in a
        // long-lived feed; dropping them here keeps both the bitset section and
        // the router's per-round service checks proportional to live service.
        var keptRefs: [UInt32] = []
        var keptBits: [UInt8] = []
        var indexByServiceRef: [UInt32: ServiceIndex] = [:]
        var dropped = 0
        keptRefs.reserveCapacity(serviceCount)
        keptBits.reserveCapacity(serviceCount * stride)

        for slot in 0..<serviceCount {
            var active = false
            if stride > 0 {
                for byteIndex in (slot * stride)..<((slot + 1) * stride) where bits[byteIndex] != 0 {
                    active = true
                    break
                }
            }
            guard active else {
                dropped += 1
                continue
            }
            indexByServiceRef[identifierRefs[slot]] = ServiceIndex(keptRefs.count)
            keptRefs.append(identifierRefs[slot])
            keptBits.append(contentsOf: bits[(slot * stride)..<((slot + 1) * stride)])
        }

        return Result(
            calendarStart: start,
            calendarDayCount: dayCount,
            bitsetStride: stride,
            bits: keptBits,
            identifierRefs: keptRefs,
            indexByServiceRef: indexByServiceRef,
            droppedEmptyServices: dropped
        )
    }
}
