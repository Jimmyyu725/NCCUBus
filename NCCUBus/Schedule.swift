import Foundation

// MARK: - Walking, as measured

enum Walk {
    /// 979 m, Routes API 實測，平路
    static let toCampusMinutes = 13          // 12分37秒, rounded up
    /// 同一段路反向：爬升 34.5 m、平均坡度 4.2%（約 11 層樓）
    /// Naismith 加成推估，非實測
    static let toHomeMinutes = 16

    static func minutes(_ d: Direction) -> Int {
        d == .toCampus ? toCampusMinutes : toHomeMinutes
    }

    /// 等超過這麼久就別等了。回程門檻拉高，因為那是上坡。
    static func giveUpThreshold(_ d: Direction) -> Int {
        d == .toCampus ? 13 : 25
    }
}

// MARK: - 使用者偏好：回程只搭哪一站

enum StopPreference {
    /// 回程只用「政大(聯合醫院)」—— 從校門走約 1 分鐘。
    /// 另外兩個回程站（指南山莊 5 分、萬興國小 4 分）走太遠，使用者明確表示不要。
    ///
    /// 代價：平日回程從 119 班掉到 52 班，傍晚會出現 90 分鐘空窗
    /// （19:46 → 21:16）。要放寬就把這裡改成 nil。
    static let toHomeBoardStop: String? = "政大(聯合醫院)"

    static func allows(_ trip: Trip) -> Bool {
        guard trip.direction == .toHome, let only = toHomeBoardStop else { return true }
        return trip.boardStop == only
    }
}

// MARK: - A concrete departure on a concrete day

struct Departure: Identifiable {
    let trip: Trip
    let leaveAt: Date

    var id: String { "\(trip.id)@\(leaveAt.timeIntervalSince1970)" }

    func minutesUntilLeaving(from now: Date) -> Int {
        Int((leaveAt.timeIntervalSince(now) / 60).rounded(.down))
    }

    func isToday(_ now: Date) -> Bool {
        Calendar.current.isDate(leaveAt, inSameDayAs: now)
    }
}

// MARK: - Store

@MainActor
final class Timetable: ObservableObject {
    let trips: [Trip]

    init(url override: URL? = nil) {
        guard let url = override ?? Bundle.main.url(forResource: "timetable", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Trip].self, from: data)
        else {
            assertionFailure("timetable.json missing or malformed")
            trips = []
            return
        }
        trips = decoded
    }

    /// Day index used by the data: 1 = Mon … 5 = Fri, 6 = Sat, 7 = Sun.
    /// Saturday and Sunday share one timetable (verified by repeat scans).
    private func dataWeekday(_ date: Date) -> Int {
        let c = Calendar.current.component(.weekday, from: date)  // 1 = Sun
        return c == 1 ? 7 : c - 1
    }

    func isWeekend(_ date: Date) -> Bool { dataWeekday(date) >= 6 }

    /// Upcoming departures, searching forward across days so Friday night
    /// correctly rolls to Monday morning rather than showing nothing.
    func upcoming(_ direction: Direction, from now: Date, limit: Int = 12) -> [Departure] {
        let cal = Calendar.current
        var result: [Departure] = []

        for offset in 0...7 {
            guard result.count < limit,
                  let day = cal.date(byAdding: .day, value: offset, to: now)
            else { continue }
            let weekday = dataWeekday(day)

            let midnight = cal.startOfDay(for: day)
            let todays = trips
                .filter { $0.direction == direction && $0.days.contains(weekday) }
                .filter(StopPreference.allows)
                .compactMap { trip -> Departure? in
                    let at = midnight.addingTimeInterval(TimeInterval(trip.leaveMinutes * 60))
                    return at > now ? Departure(trip: trip, leaveAt: at) : nil
                }
                .sorted { $0.leaveAt < $1.leaveAt }

            result.append(contentsOf: todays)
        }

        return Array(result.prefix(limit))
    }

    /// Largest gap between consecutive departures, for the "空窗" callout.
    func gapAfter(_ departure: Departure, in list: [Departure]) -> Int? {
        guard let i = list.firstIndex(where: { $0.id == departure.id }), i + 1 < list.count else {
            return nil
        }
        return Int(list[i + 1].leaveAt.timeIntervalSince(departure.leaveAt) / 60)
    }
}

// MARK: - The verdict

enum Verdict {
    case takeBus(waitMinutes: Int)
    case justWalk(waitMinutes: Int)

    static func decide(direction: Direction, waitMinutes: Int) -> Verdict {
        waitMinutes > Walk.giveUpThreshold(direction)
            ? .justWalk(waitMinutes: waitMinutes)
            : .takeBus(waitMinutes: waitMinutes)
    }
}
