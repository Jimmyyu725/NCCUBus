import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var timetable = Timetable()
    @StateObject private var live = LiveService()
    @State private var showMap = false
    @State private var direction: Direction = {
        // Testing aid: `simctl launch <dev> <id> -StartDirection toHome`
        if let raw = UserDefaults.standard.string(forKey: "StartDirection"),
           let d = Direction(rawValue: raw) {
            return d
        }
        return .toCampus
    }()
    @State private var now = Date()
    @Environment(\.scenePhase) private var scenePhase

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Debug-only clock override so weekend / after-hours states can be inspected
    /// on any day: `simctl launch <dev> <id> -FakeNow "2026-08-22 17:10"`
    private static let clockOffset: TimeInterval = {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "FakeNow") {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: raw) { return d.timeIntervalSinceNow }
        }
        #endif
        return 0
    }()

    private var departures: [Departure] { timetable.upcoming(direction, from: now) }
    private var next: Departure? { departures.first }

    /// 只追蹤畫面上真的會用到的路線，避免每分鐘打滿五條。
    private var neededRIDs: Set<Int> {
        Set(departures.prefix(8).compactMap { StopIndex.shared.rid(for: $0.trip.route) })
    }

    /// 快出門了才需要最新的位置 —— 此時把輪詢從 60 秒切到 20 秒（＝公車回報上限）。
    private var urgent: Bool {
        guard let next, next.isToday(now) else { return false }
        return next.minutesUntilLeaving(from: now) <= LiveService.fastWindow
    }

    /// ⚠️ 即時 ETA 是「這個站牌下一班車幾分鐘到」，**它不屬於任何特定班次**。
    ///
    /// 所以同一條路線、同一個上車站，只有**最早那一班**能對應到它。
    /// 把同一個 ETA 掛到後面每一班身上，就會算出「早 29 分」「早 59 分」這種鬼數字
    /// （13:29 和 13:59 兩班棕18 拿到同一台車的「將到站」）。
    private var liveEligible: Set<String> {
        var seenStop = Set<String>()
        var eligible = Set<String>()
        for d in departures {
            let key = "\(d.trip.route)|\(d.trip.boardStop)"
            if seenStop.insert(key).inserted { eligible.insert(d.id) }
        }
        return eligible
    }

    private func liveETA(for d: Departure) -> LiveETA? {
        liveEligible.contains(d.id) ? live.eta(for: d.trip) : nil
    }

    private var visibleBuses: [LiveBus] {
        neededRIDs.flatMap { live.routes[$0]?.buses ?? [] }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DirectionPicker(direction: $direction)

                    HStack {
                        LiveStatusBadge(status: live.status)
                        Spacer()
                        if !visibleBuses.isEmpty {
                            Text("線上 \(visibleBuses.count) 台車")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 4)

                    if timetable.isWeekend(now) {
                        WeekendNotice()
                    }

                    if let next {
                        NextDepartureCard(
                            departure: next,
                            direction: direction,
                            now: now,
                            gap: timetable.gapAfter(next, in: departures),
                            eta: liveETA(for: next),
                            buses: liveEligible.contains(next.id) ? live.approachingBuses(for: next.trip) : [],
                            routeOverlay: live.overlay(for: next.trip)
                        )
                    } else {
                        ContentUnavailableView(
                            "沒有班次",
                            systemImage: "bus",
                            description: Text("這個方向接下來七天都沒有掃描到班次。")
                        )
                        .padding(.vertical, 40)
                    }

                    if direction == .toHome {
                        BoardingStopWarning()
                    }

                    UpcomingList(
                        departures: Array(departures.dropFirst()),
                        now: now,
                        live: live,
                        liveEligible: liveEligible
                    )
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
                // Keep line lengths readable on iPad rather than stretching edge to edge.
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(direction.short)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showMap = true } label: {
                        Label("地圖", systemImage: "map")
                    }
                    .disabled(visibleBuses.isEmpty)
                }
            }
            .sheet(isPresented: $showMap) {
                LiveMapSheet(buses: visibleBuses, status: live.status)
            }
            .refreshable { await live.refresh() }
        }
        .onReceive(tick) { now = $0.addingTimeInterval(Self.clockOffset) }
        .task {
            live.track(rids: neededRIDs)
            live.setCadence(urgent: urgent)
            live.start()
        }
        .onChange(of: neededRIDs) { _, new in live.track(rids: new) }
        .onChange(of: urgent) { _, isUrgent in live.setCadence(urgent: isUrgent) }
        // 公車 GPS 每 20 秒回報一次，而輪詢是 60 秒 —— 位置最多可能落後 80 秒。
        // 使用者通常是「打開 App 看一眼就收起來」，所以回到前景必須立刻抓一次，
        // 否則他看到的是上次進背景前的資料。背景時停掉輪詢，別浪費電。
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                live.setCadence(urgent: urgent)
                live.start()
                Task { await live.refresh() }
            case .background, .inactive:
                live.stop()
            @unknown default:
                break
            }
        }
        .onDisappear { live.stop() }
    }
}

// MARK: - Full-screen live map

private struct LiveMapSheet: View {
    let buses: [LiveBus]
    let status: LiveService.Status
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BusMap(buses: buses, highlight: nil, height: .infinity)
                    .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle("即時位置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { LiveStatusBadge(status: status) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Direction

private struct DirectionPicker: View {
    @Binding var direction: Direction

    var body: some View {
        VStack(spacing: 6) {
            Picker("方向", selection: $direction) {
                ForEach(Direction.allCases) { d in
                    Text(d.short).tag(d)
                }
            }
            .pickerStyle(.segmented)

            Text(direction.route)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}

// MARK: - Hero card

private struct NextDepartureCard: View {
    let departure: Departure
    let direction: Direction
    let now: Date
    let gap: Int?
    let eta: LiveETA?
    let buses: [LiveBus]
    let routeOverlay: RouteOverlay?

    private var minutes: Int { max(0, departure.minutesUntilLeaving(from: now)) }
    private var verdict: Verdict { Verdict.decide(direction: direction, waitMinutes: minutes) }

    private var seconds: Int {
        let remaining = Int(departure.leaveAt.timeIntervalSince(now))
        return max(0, remaining % 60)
    }

    private var isToday: Bool { departure.isToday(now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if isToday {
                liveCountdown
            } else {
                serviceEnded
            }

            Divider()

            TripDetail(trip: departure.trip)

            // 即時到站是比班表更硬的資訊，放在判斷語之前。
            if isToday, let eta {
                LiveETALine(eta: eta, buses: buses,
                            scheduled: departure.trip.depart, now: now)

                // 下一班最需要知道「車現在到哪了」，所以主卡片直接放地圖，
                // 不用像下面的列表那樣還要點開。
                if !buses.isEmpty || routeOverlay != nil {
                    BusMap(buses: buses, highlight: nil, routeOverlay: routeOverlay, height: 170)
                }
            }

            // A walk/wait verdict only means something for a bus you could
            // actually still catch today.
            if isToday {
                VerdictBanner(verdict: verdict, direction: direction)

                if let gap, gap >= 25 {
                    Label("錯過這班要等 \(gap) 分鐘", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            } else {
                WalkOnlyBanner(direction: direction)
            }
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }

    private var liveCountdown: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("該出門了")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if minutes == 0 {
                Text("現在就走")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(.red)
                Text("剩 \(seconds) 秒")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.red.opacity(0.8))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(minutes)")
                        .font(.system(size: 76, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    VStack(alignment: .leading, spacing: -2) {
                        Text("分後")
                            .font(.title3.weight(.semibold))
                        Text(String(format: ":%02d", seconds))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("\(departure.trip.leaveHome) 出門 · \(departure.trip.depart) 發車")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var serviceEnded: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("今天沒有班次了", systemImage: "moon.zzz.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.indigo)

            Text("下一班是 " + departure.leaveAt.formatted(
                .dateTime.weekday(.wide).month(.defaultDigits).day()
            ) + " \(departure.trip.leaveHome) 出門")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TripDetail: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(trip.routeBadge)
                    .font(.footnote.weight(.bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.brown.opacity(0.18), in: .capsule)
                    .foregroundStyle(.brown)

                if !trip.runsEveryWeekday {
                    Text(trip.daysLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.18), in: .capsule)
                        .foregroundStyle(.orange)
                }

                Spacer()

                Text("全程 \(trip.totalMinutes) 分")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                stop(trip.boardStop, time: trip.depart, label: "上車")
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                stop(trip.alightStop, time: trip.arriveStop, label: "下車")
            }

            Text("\(trip.arrive) 抵達")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stop(_ name: String, time: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(name)
                .font(.subheadline.weight(.semibold))
            Text(time)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Walk vs wait

private struct VerdictBanner: View {
    let verdict: Verdict
    let direction: Direction

    var body: some View {
        switch verdict {
        case .takeBus(let wait):
            banner(
                icon: "bus.fill",
                tint: .green,
                title: "等這班划算",
                detail: "等 \(wait) 分 · 走路要 \(Walk.minutes(direction)) 分"
            )
        case .justWalk(let wait):
            banner(
                icon: "figure.walk",
                tint: direction == .toHome ? .orange : .blue,
                title: direction == .toHome ? "可以走，但是上坡" : "直接走比較快",
                detail: direction == .toHome
                    ? "等 \(wait) 分 · 走路約 \(Walk.minutes(direction)) 分，爬升 34 公尺"
                    : "等 \(wait) 分 · 走路 \(Walk.minutes(direction)) 分，平路 979 公尺"
            )
        }
    }

    private func banner(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 12))
    }
}

private struct WalkOnlyBanner: View {
    let direction: Direction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.walk")
                .font(.title3)
                .foregroundStyle(direction == .toHome ? .orange : .blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("現在只能走路")
                    .font(.subheadline.weight(.semibold))
                Text(direction == .toHome
                     ? "約 \(Walk.minutes(direction)) 分 · 979 公尺，爬升 34 公尺"
                     : "\(Walk.minutes(direction)) 分 · 979 公尺平路")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background((direction == .toHome ? Color.orange : Color.blue).opacity(0.10),
                    in: .rect(cornerRadius: 12))
    }
}

// MARK: - Notices

private struct BoardingStopWarning: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 3) {
                Text("回程只列 政大(聯合醫院)")
                    .font(.subheadline.weight(.semibold))
                Text("從校門走約 1 分鐘。指南山莊、萬興國小 也有回程車但要走 4–5 分鐘，已隱藏。19:46–21:16 有 90 分鐘空窗，那段直接走（上坡 34 公尺）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.10), in: .rect(cornerRadius: 14))
    }
}

private struct WeekendNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("週末班表")
                    .font(.subheadline.weight(.semibold))
                Text("班次比平日少約三成，空窗也更長。等超過門檻就直接走。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 14))
    }
}

// MARK: - Upcoming

private struct UpcomingList: View {
    let departures: [Departure]
    let now: Date
    @ObservedObject var live: LiveService
    /// 哪些班次可以掛即時 ETA —— 見 ContentView.liveEligible 的說明。
    let liveEligible: Set<String>

    // ⚠️ 不要用 AnyView 包住這個 body。AnyView 會抹掉視圖識別，
    // 每秒 tick 重建時子視圖的 @State（展開狀態）會被整個丟掉。
    var body: some View {
        if !departures.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("接下來")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("點一下看即時位置")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

                VStack(spacing: 0) {
                    ForEach(Array(departures.enumerated()), id: \.element.id) { index, d in
                        ExpandableDepartureRow(
                            departure: d,
                            now: now,
                            eta: liveEligible.contains(d.id) ? live.eta(for: d.trip) : nil,
                            // ⚠️ 車輛跟 ETA 同一條規則：我們無從得知「哪台車會跑 13:59 那班」。
                            // 把同一台車畫到後面每一班的地圖上，看起來就像有好幾台車要來。
                            buses: liveEligible.contains(d.id) ? live.approachingBuses(for: d.trip) : [],
                            allBuses: liveEligible.contains(d.id) ? live.buses(for: d.trip) : [],
                            routeOverlay: live.overlay(for: d.trip)
                        )
                        if index < departures.count - 1 {
                            Divider().padding(.leading, 62)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            }
            .padding(.top, 4)
        }
    }
}

#Preview {
    ContentView()
}
