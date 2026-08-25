import Foundation
import Combine
import CoreLocation
import os

private let log = Logger(subsystem: "com.jingtianyu.NCCUBus", category: "live")

/// 即時資料來源：臺北市公車動態資訊系統的 `RouteDyna` 端點。
///
/// 為什麼不用 Google：Routes API **完全沒有即時欄位**（`realtime`／`delay`／
/// `occupancy` 全部回 INVALID_ARGUMENT），只給班表時刻。TDX 有即時到站但**沒有擁擠度**。
/// 三者之中只有 RouteDyna 同時具備位置、到站秒數、車上人數與擁擠度。
///
/// 代價：這是未公開端點，沒有 SLA。所以本服務的每一條路徑都必須能安全失敗 ——
/// 失敗時 UI 退回 `timetable.json` 的排定時刻，而不是顯示錯誤或空白。
@MainActor
final class LiveService: ObservableObject {

    enum Status: Equatable {
        case idle
        case loading
        case live(Date)
        case stale(Date)      // 有舊資料但最近一次更新失敗
        case unavailable      // 從未成功取得

        var isLive: Bool { if case .live = self { return true }; return false }
    }

    @Published private(set) var routes: [Int: LiveRoute] = [:]
    @Published private(set) var status: Status = .idle

    /// 公車 GPS **固定每 20 秒**回報一次（實測 10 個樣本全是 20，零抖動）。
    /// 所以 20 秒是有意義的最快輪詢 —— 再快只會拿到一模一樣的資料。
    ///
    /// 但不必一直用 20 秒：使用者在看「43 分後那班」時，位置精不精確沒有意義。
    /// 只有快要出門時才需要最新的位置，所以依緊急程度切換。
    static let fastInterval: TimeInterval = 20
    static let idleInterval: TimeInterval = 60
    private var interval: TimeInterval = idleInterval

    /// 下一班在 `fastWindow` 分鐘內就切到 20 秒。
    static let fastWindow = 15
    private var timer: Task<Void, Never>?
    private var wanted: Set<Int> = []

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // MARK: Lifecycle

    /// 只抓畫面上真正用得到的路線，通常 2–4 條而非全部。
    func track(rids: Set<Int>) {
        log.notice("track(\(rids.map(String.init).joined(separator: ","), privacy: .public))")
        guard rids != wanted else { return }
        wanted = rids
        Task { await refresh() }
    }

    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(self?.interval ?? Self.idleInterval))
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 由畫面告知「快出門了沒」。切換時立刻重啟輪詢，不用等當前這輪睡完。
    func setCadence(urgent: Bool) {
        let new = urgent ? Self.fastInterval : Self.idleInterval
        guard new != interval else { return }
        interval = new
        log.notice("cadence → \(Int(new))s")
        if timer != nil { stop(); start() }
    }

    var currentInterval: TimeInterval { interval }

    // MARK: Fetch

    func refresh() async {
        log.notice("refresh start, wanted=\(self.wanted.map(String.init).joined(separator: ","), privacy: .public)")
        guard !wanted.isEmpty else { log.error("wanted is empty"); return }
        if routes.isEmpty { status = .loading }

        var fetched: [Int: LiveRoute] = [:]
        await withTaskGroup(of: (Int, LiveRoute?).self) { group in
            for rid in wanted {
                group.addTask { [weak self] in (rid, await self?.fetch(rid: rid) ?? nil) }
            }
            for await (rid, route) in group {
                if let route { fetched[rid] = route }
            }
        }

        log.notice("fetched \(fetched.count) routes, buses=\(fetched.values.map(\.buses.count).reduce(0,+)), etas=\(fetched.values.map(\.etas.count).reduce(0,+))")
        if fetched.isEmpty {
            // 一條都沒拿到：保留舊資料，只降級狀態。
            status = routes.isEmpty ? .unavailable : .stale(lastUpdate ?? Date())
            return
        }

        routes.merge(fetched) { _, new in new }
        status = .live(fetched.values.map(\.updatedAt).max() ?? Date())
    }

    private func fetch(rid: Int) async -> LiveRoute? {
        guard var comps = URLComponents(string: "https://pda5284.gov.taipei/MQS/RouteDyna") else {
            return nil
        }
        comps.queryItems = [URLQueryItem(name: "routeid", value: String(rid))]
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url)
        // 端點會檢查來源，缺 Referer 時可能被擋。
        req.setValue("https://pda5284.gov.taipei/MQS/route.jsp?rid=\(rid)", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // ⚠️ 伺服器會對 URLSession 的預設 UA（含 CFNetwork/Darwin）回 HTTP 500。
        // 實測任何其他 UA 都正常，所以明確覆寫掉，別讓系統帶預設值。
        req.setValue("NCCUBus/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            log.notice("rid \(rid) HTTP \(code) bytes=\(data.count)")
            guard code == 200 else { return nil }
            let parsed = RouteDynaParser.parse(data, rid: rid)
            if parsed == nil { log.error("rid \(rid) parse FAILED") }
            return parsed
        } catch {
            log.error("rid \(rid) network error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    var lastUpdate: Date? { routes.values.map(\.updatedAt).max() }

    // MARK: Lookups used by the views

    func eta(for trip: Trip) -> LiveETA? {
        guard let rid = StopIndex.shared.rid(for: trip.route),
              let sid = StopIndex.shared.boardingSid(route: trip.route,
                                                     board: trip.boardStop,
                                                     alight: trip.alightStop),
              let route = routes[rid]
        else { return nil }
        return route.eta(sid: sid)
    }

    /// 回傳**跑同一個方向**的車，並標上距離你上車站還有幾站。
    ///
    /// 反方向那台跟你無關，一定要濾（實測棕11 兩台車，一台去程一台返程）。
    /// 但**不能用「還沒過你的站」當硬條件** —— 公車循環跑，剛過站的等一下就繞回來，
    /// 用那條濾完常常一台不剩。改成全部保留、標明「還有幾站 / 已過站」。
    ///
    /// ⚠️ 環狀路線上同一個站名會出現兩次（棕11副線 的普羅旺世在第 20 和第 23 站）。
    /// 算距離時要取**最近一個還沒到的**，不是第一個 —— 否則車在第 22 站、
    /// 下一站就是第 23 站的普羅旺世，卻會被算成「已過站 -2」。
    func buses(for trip: Trip) -> [LiveBus] {
        guard let rid = StopIndex.shared.rid(for: trip.route),
              let all = routes[rid]?.buses
        else { return [] }
        guard let leg = StopIndex.shared.fullLeg(route: trip.route,
                                                 board: trip.boardStop,
                                                 alight: trip.alightStop)
        else { return all }

        // 上車站在這個方向出現的所有位置
        let boardIndices = leg.stops.enumerated()
            .filter { $0.element.name == trip.boardStop }
            .map(\.offset)
        guard !boardIndices.isEmpty else { return all }

        var order: [Int: [Int]] = [:]
        for (i, s) in leg.stops.enumerated() { order[s.sid, default: []].append(i) }

        return all.compactMap { bus -> LiveBus? in
            guard let sid = bus.currentStopSid, let idxs = order[sid] else { return nil }
            // 車也可能在重複站；每種組合都算，取「還沒到」裡最小的那個距離
            let deltas = idxs.flatMap { i in boardIndices.map { $0 - i } }
            let ahead = deltas.filter { $0 >= 0 }.min()
            return bus.with(stopsAway: ahead ?? deltas.max())
        }
        .sorted { a, b in
            let x = a.stopsAway ?? 99, y = b.stopsAway ?? 99
            if (x >= 0) != (y >= 0) { return x >= 0 }
            return abs(x) < abs(y)
        }
    }

    /// 這趟車要畫在地圖上的路線與停靠點：從最前面那台車的位置，一路到你的下車站。
    func overlay(for trip: Trip) -> RouteOverlay? {
        guard let leg = StopIndex.shared.fullLeg(route: trip.route,
                                                 board: trip.boardStop,
                                                 alight: trip.alightStop)
        else { return nil }

        // 起點取「還沒經過你的車」裡最靠近你的那台；沒有車就從上車站開始畫。
        // 起點取「還沒過你的站、且最靠近你」的那台；沒有就從上車站開始畫。
        let approaching = buses(for: trip).filter { ($0.stopsAway ?? -1) >= 0 }
        let busIdx = approaching.compactMap { $0.currentStopSid.flatMap(leg.index(ofSid:)) }.max()
        let from = min(busIdx ?? leg.boardIndex, leg.boardIndex)
        let slice = Array(leg.stops[from...leg.alightIndex])

        let path = slice.compactMap { s -> CLLocationCoordinate2D? in
            guard let la = s.lat, let ln = s.lng else { return nil }
            return CLLocationCoordinate2D(latitude: la, longitude: ln)
        }
        guard path.count > 1 else { return nil }

        let stops: [RouteOverlay.Stop] = slice.enumerated().compactMap { i, s in
            guard let la = s.lat, let ln = s.lng else { return nil }
            let abs = from + i
            let kind: RouteOverlay.Stop.Kind =
                abs == leg.boardIndex ? .board : (abs == leg.alightIndex ? .alight : .plain)
            return RouteOverlay.Stop(id: s.sid, name: s.name,
                                     coord: CLLocationCoordinate2D(latitude: la, longitude: ln),
                                     kind: kind)
        }
        return RouteOverlay(path: path, stops: stops)
    }

    /// **只有正在往你這站開的車。** 主卡片的小地圖用這個。
    ///
    /// 已經開過去的車對「這趟要不要搭」沒有任何用處，畫在小地圖上只會讓人問
    /// 「為什麼兩台車」。但也不能在 `buses(for:)` 就濾掉 —— 全部過站時會一台不剩，
    /// 畫面看起來像壞了。所以分兩層：小地圖只給要來的，展開的詳情給全部。
    func approachingBuses(for trip: Trip) -> [LiveBus] {
        buses(for: trip).filter { ($0.stopsAway ?? -1) >= 0 }
    }

    /// 整條路線上的所有車，不分方向 —— 給「看全部」的地圖用。
    func allBuses(for trip: Trip) -> [LiveBus] {
        guard let rid = StopIndex.shared.rid(for: trip.route) else { return [] }
        return routes[rid]?.buses ?? []
    }

    var allBuses: [(rid: Int, bus: LiveBus)] {
        routes.flatMap { rid, r in r.buses.map { (rid, $0) } }
    }
}

// MARK: - Delay, derived rather than reported

/// ⚠️ **推估值，非觀測值。**
///
/// 兩個資料源都不會標明「這台車是 12:10 那班」。這裡是拿即時預估到站時刻，
/// 去比對班表上最接近的排定發車時刻 —— 誤差可能來自班表本身（Routes API 掃描而得，
/// 非官方班表），也可能是配錯了班次。所以 UI 一律標示「推估」，且不作為主要判斷依據。
struct DelayEstimate {
    let minutes: Int        // 正 = 晚點，負 = 提前
    var isLate: Bool { minutes > 0 }

    var label: String {
        if minutes == 0 { return "準點" }
        return minutes > 0 ? "晚 \(minutes) 分" : "早 \(-minutes) 分"
    }

    /// 差距在 2 分鐘內視為準點 —— 低於這個數字的差異沒有意義。
    var isSignificant: Bool { abs(minutes) >= 2 }

    static func compute(eta: LiveETA, scheduled: String, now: Date) -> DelayEstimate? {
        guard eta.hasBus else { return nil }
        let parts = scheduled.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }

        let cal = Calendar.current
        let midnight = cal.startOfDay(for: now)
        let scheduledAt = midnight.addingTimeInterval(TimeInterval(parts[0] * 3600 + parts[1] * 60))
        let predicted = now.addingTimeInterval(TimeInterval(eta.seconds))

        var diff = Int(predicted.timeIntervalSince(scheduledAt) / 60)
        // 跨午夜的班次不要算成差了 23 小時。
        if diff > 720 { diff -= 1440 } else if diff < -720 { diff += 1440 }
        // 公車不會早到或晚到半小時以上而還算「同一班」。超過就是配錯了，寧可不顯示。
        guard abs(diff) <= 20 else { return nil }

        return DelayEstimate(minutes: diff)
    }
}
