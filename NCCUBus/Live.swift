import Foundation
import CoreLocation

// MARK: - What the live feed can tell us

/// 車廂擁擠度。官方分三級；缺值時用車上人數推算（>32 擠、>22 中）。
enum Crowding: Int, Comparable {
    case empty = 1, medium = 2, full = 3

    var label: String {
        switch self {
        case .empty:  return "空"
        case .medium: return "中"
        case .full:   return "擠"
        }
    }

    var systemImage: String {
        switch self {
        case .empty:  return "person"
        case .medium: return "person.2"
        case .full:   return "person.3.fill"
        }
    }

    static func < (a: Crowding, b: Crowding) -> Bool { a.rawValue < b.rawValue }

    /// a3[6] 為 0 時官方前端的推算規則，照抄以免兩邊顯示不一致。
    static func infer(passengers: Int) -> Crowding {
        if passengers > 32 { return .full }
        if passengers > 22 { return .medium }
        return .empty
    }
}

struct LiveBus: Identifiable {
    let plate: String
    let coordinate: CLLocationCoordinate2D
    let speedKMH: Int
    let heading: Double
    /// 這台車目前所在／即將抵達的站 sid（來自 a2[7]）。
    /// 用來判斷它跑哪個方向、有沒有還沒經過你的站。
    let currentStopSid: Int?
    private let rawPassengers: Int?
    private let rawCrowding: Crowding?
    /// 擁擠度資料自己的時間戳離伺服器時間多久（秒）。位置和人數是**兩條獨立的資料流**，
    /// 車子在動不代表人數是新的 —— 實測看過位置每秒更新、人數卻是 75 分鐘前的。
    let crowdingAge: TimeInterval?

    init(plate: String, coordinate: CLLocationCoordinate2D, speedKMH: Int, heading: Double,
         currentStopSid: Int?, passengers: Int?, crowding: Crowding?, crowdingAge: TimeInterval?) {
        self.plate = plate
        self.coordinate = coordinate
        self.speedKMH = speedKMH
        self.heading = heading
        self.currentStopSid = currentStopSid
        self.rawPassengers = passengers
        self.rawCrowding = crowding
        self.crowdingAge = crowdingAge
    }

    /// 官方前端只採信 20 分鐘內的擁擠度資料。我們**不隱藏**過期資料，改成灰掉並標明
    /// 「幾分鐘前」—— 直接消失會讓人以為壞了（實測有一半的車資料是舊的，
    /// 全部藏起來畫面就一片空白，反而更難理解）。
    static let staleAfter: TimeInterval = 20 * 60

    var isCrowdingFresh: Bool {
        guard let age = crowdingAge else { return false }
        return age <= Self.staleAfter
    }

    var passengers: Int? { rawPassengers }
    var crowding: Crowding? { rawCrowding }

    /// 資料幾分鐘前的。90 秒內視為即時，回 nil。
    var crowdingAgeMinutes: Int? {
        guard let age = crowdingAge, age > 90 else { return nil }
        return Int(age / 60)
    }

    /// 距離你的上車站還有幾站。正數＝還沒到，0＝就在你這站，負數＝已經開過去了。
    /// 由 LiveService 依路線站序算出來填進去。
    var stopsAway: Int?

    var id: String { plate }
    var isMoving: Bool { speedKMH > 0 }

    func with(stopsAway n: Int?) -> LiveBus {
        var copy = self
        copy.stopsAway = n
        return copy
    }

    var approachLabel: String? {
        guard let n = stopsAway else { return nil }
        if n > 0 { return "還有 \(n) 站" }
        if n == 0 { return "就在你這站" }
        return "已過站"
    }
}

/// 某站的到站預估。`seconds` 為 -1 或超過 99 分代表尚未發車。
struct LiveETA {
    let sid: Int
    let seconds: Int
    /// 首站才有的排定發車時刻（例如 "12:25"）
    let scheduledDeparture: String?

    var hasBus: Bool { seconds >= 0 && seconds <= 5940 }
    var minutes: Int { max(0, seconds / 60) }

    var display: String {
        guard hasBus else {
            if let s = scheduledDeparture { return "\(s) 發車" }
            return "未發車"
        }
        if seconds < 180 { return "將到站" }
        return "\(minutes) 分"
    }
}

struct LiveRoute {
    let rid: Int
    let updatedAt: Date
    let buses: [LiveBus]
    let etas: [Int: LiveETA]      // sid → ETA

    func eta(sid: Int) -> LiveETA? { etas[sid] }
}

// MARK: - Parsing RouteDyna

/// `RouteDyna` 回傳的欄位是逗號打包的字串，欄位含義從官方前端 JS 反推而來。
/// 這是**未公開端點**，格式可能無預警改變 —— 所有解析失敗都必須能安全退回班表。
enum RouteDynaParser {

    private struct Payload: Decodable {
        struct Bus: Decodable { let num: String?; let a1: String?; let a2: String?; let a3: String? }
        struct Stop: Decodable { let n1: String? }
        let UpdateTime: String?
        let Bus: [Bus]?
        let Stop: [Stop]?
    }

    static func parse(_ data: Data, rid: Int) -> LiveRoute? {
        guard let p = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }

        let updated = p.UpdateTime.flatMap(parseUpdateTime) ?? Date()

        let buses: [LiveBus] = (p.Bus ?? []).compactMap { b in
            guard let num = b.num, !num.hasPrefix("TEST") else { return nil }
            let a1 = (b.a1 ?? "").split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            // a1[7]=lng a1[8]=lat a1[9]=速度 a1[10]=方位角
            guard a1.count > 10, let lng = Double(a1[7]), let lat = Double(a1[8]),
                  lat != 0, lng != 0 else { return nil }

            let a2 = (b.a2 ?? "").split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let currentSid = a2.count > 7 ? Int(a2[7]) : nil

            var passengers: Int?
            var crowding: Crowding?
            var age: TimeInterval?
            let a3 = (b.a3 ?? "").split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if a3.count > 6 {
                passengers = Int(a3[5])
                if let level = Int(a3[6]), let c = Crowding(rawValue: level) {
                    crowding = c
                } else if let n = passengers {
                    crowding = .infer(passengers: n)
                }
            }
            // a3[7] = 擁擠度資料自己的時間戳（YYMMDDHHMMSS，台北時間）。
            if a3.count > 7, let stamped = Self.parseCompact(a3[7]) {
                age = updated.timeIntervalSince(stamped)
            }

            return LiveBus(
                plate: num,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                speedKMH: Int(a1[9]) ?? 0,
                heading: Double(a1[10]) ?? 0,
                currentStopSid: currentSid,
                passengers: passengers,
                crowding: crowding,
                crowdingAge: age
            )
        }

        var etas: [Int: LiveETA] = [:]
        for s in p.Stop ?? [] {
            let n1 = (s.n1 ?? "").split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            // n1[1]=sid  n1[3]=首站發車時刻  n1[7]=到站秒數
            guard n1.count > 7, let sid = Int(n1[1]) else { continue }
            let sched = n1[3].contains(":") ? n1[3] : nil
            etas[sid] = LiveETA(sid: sid, seconds: Int(n1[7]) ?? -1, scheduledDeparture: sched)
        }

        return LiveRoute(rid: rid, updatedAt: updated, buses: buses, etas: etas)
    }

    /// "260820124438" → Date（YYMMDDHHMMSS，台北時間）
    private static func parseCompact(_ raw: String) -> Date? {
        guard raw.count == 12, raw.allSatisfy(\.isNumber) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyMMddHHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        return f.date(from: raw)
    }

    /// "2026-08-20 12&#x3a;04&#x3a;30" — 時間欄位帶 HTML 實體，要先還原。
    private static func parseUpdateTime(_ raw: String) -> Date? {
        let cleaned = raw.replacingOccurrences(of: "&#x3a;", with: ":")
                         .replacingOccurrences(of: "&#x3A;", with: ":")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        return f.date(from: cleaned)
    }
}

// MARK: - Which stop id belongs to this trip

/// 同一個站名在一條路線上會有多個 sid（去返程各一，環狀路段還會重複）。
/// 靠「上車站序 < 下車站序」挑出唯一方向 —— 27 種組合已全數驗證可唯一判定。
struct StopIndex {
    struct RouteStops: Decodable {
        struct Stop: Decodable { let sid: Int; let name: String; let lat: Double?; let lng: Double? }
        let rid: Int
        let go: [Stop]
        let back: [Stop]
    }

    private let routes: [String: RouteStops]

    static let shared = StopIndex()

    private init() {
        guard let url = Bundle.main.url(forResource: "stops", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: RouteStops].self, from: data)
        else {
            assertionFailure("stops.json missing or malformed")
            routes = [:]
            return
        }
        routes = decoded
    }

    func rid(for route: String) -> Int? { routes[route]?.rid }

    /// 這趟車的上車站 sid。找不到就回 nil，呼叫端退回班表顯示。
    func boardingSid(route: String, board: String, alight: String) -> Int? {
        guard let r = routes[route] else { return nil }
        for list in [r.go, r.back] {
            let names = list.map(\.name)
            guard let bi = names.firstIndex(of: board) else { continue }
            guard let ai = names.lastIndex(of: alight), ai > bi else { continue }
            return list[bi].sid
        }
        return nil
    }

    /// 這趟車走的那個方向：站序、座標、上下車站的序號。
    /// 有座標才畫得出路線和停靠點。
    struct Leg {
        let stops: [RouteStops.Stop]
        let boardIndex: Int
        let alightIndex: Int
        func index(ofSid sid: Int) -> Int? { stops.firstIndex { $0.sid == sid } }
    }

    func fullLeg(route: String, board: String, alight: String) -> Leg? {
        guard let r = routes[route] else { return nil }
        for list in [r.go, r.back] {
            let names = list.map(\.name)
            guard let bi = names.firstIndex(of: board) else { continue }
            guard let ai = names.lastIndex(of: alight), ai > bi else { continue }
            return Leg(stops: list, boardIndex: bi, alightIndex: ai)
        }
        return nil
    }

    /// 這趟車走的那個方向的完整 sid 順序，以及上車站在其中的序號。
    /// 有了它才能判斷「哪台車還沒經過我的站」。
    func leg(route: String, board: String, alight: String) -> (sids: [Int], boardIndex: Int)? {
        guard let r = routes[route] else { return nil }
        for list in [r.go, r.back] {
            let names = list.map(\.name)
            guard let bi = names.firstIndex(of: board) else { continue }
            guard let ai = names.lastIndex(of: alight), ai > bi else { continue }
            return (list.map(\.sid), bi)
        }
        return nil
    }

    var allRIDs: [Int] { Array(Set(routes.values.map(\.rid))).sorted() }
}
