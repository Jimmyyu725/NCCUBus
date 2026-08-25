import Foundation

enum Direction: String, Codable, CaseIterable, Identifiable {
    case toCampus, toHome

    var id: String { rawValue }
    var short: String { self == .toCampus ? "去學校" : "回家" }
    var route: String {
        self == .toCampus ? "政大二街70號 → 政大" : "政大 → 政大二街70號"
    }
    var flipped: Direction { self == .toCampus ? .toHome : .toCampus }
}

struct Trip: Codable, Identifiable, Hashable {
    let direction: Direction
    let leaveHome: String      // 出門時刻 — the number that actually matters
    let depart: String         // 發車
    let route: String
    let boardStop: String
    let alightStop: String
    let arriveStop: String     // 到站
    let arrive: String         // 抵達目的地
    let totalMinutes: Int
    let days: [Int]            // 1 = Mon … 5 = Fri
    let leaveMinutes: Int

    var id: String { "\(direction.rawValue)|\(depart)|\(route)|\(boardStop)" }

    var isWeekendTrip: Bool { days == [6, 7] }

    /// True when this trip needs no day caveat shown next to it.
    var runsEveryWeekday: Bool { days.count == 5 || isWeekendTrip }

    var daysLabel: String {
        if isWeekendTrip { return "週末" }
        if days.count == 5 { return "週一~五" }
        let n = ["", "一", "二", "三", "四", "五"]
        return "只在週" + days.map { n[$0] }.joined()
    }

    /// 棕11副線 → 棕11副, for the compact route badge
    var routeBadge: String {
        route.replacingOccurrences(of: "延駛松山車站", with: "→松山")
    }
}
