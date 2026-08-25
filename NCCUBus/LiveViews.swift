    import SwiftUI
import MapKit

// MARK: - Known anchors

enum Anchor {
    static let home = CLLocationCoordinate2D(latitude: 24.9871031, longitude: 121.5840316)
    static let campus = CLLocationCoordinate2D(latitude: 24.9859466, longitude: 121.5764517)
}

// MARK: - Connection status

struct LiveStatusBadge: View {
    let status: LiveService.Status

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .overlay {
                    if status.isLive {
                        Circle().stroke(tint.opacity(0.35), lineWidth: 5)
                            .scaleEffect(1.8)
                    }
                }
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
        }
        .animation(.easeInOut, value: text)
    }

    private var tint: Color {
        switch status {
        case .live:        return .green
        case .loading:     return .secondary
        case .stale:       return .orange
        case .unavailable: return .secondary
        case .idle:        return .secondary
        }
    }

    private var text: String {
        switch status {
        case .live(let at):  return "即時 · \(Self.hhmm.string(from: at))"
        case .loading:       return "更新中"
        case .stale:         return "連線中斷 · 顯示班表"
        case .unavailable:   return "離線 · 顯示班表"
        case .idle:          return "班表"
        }
    }

    private static let hhmm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Taipei"); return f
    }()
}

// MARK: - Crowding pill

struct CrowdingPill: View {
    let crowding: Crowding
    let passengers: Int?
    /// nil＝即時；有值＝這筆資料是幾分鐘前的
    var ageMinutes: Int? = nil
    var compact = false

    private var isStale: Bool { (ageMinutes ?? 0) >= 20 }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: crowding.systemImage)
                .font(.caption2)
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(isStale ? 0.10 : 0.16), in: .capsule)
        .foregroundStyle(isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
    }

    private var text: String {
        let head = compact
            ? crowding.label
            : "車上 \(passengers.map(String.init) ?? "?") 人 · \(crowding.label)"
        if let m = ageMinutes { return "\(head) · \(m) 分前" }
        return head
    }

    private var tint: Color {
        switch crowding {
        case .empty:  return .green
        case .medium: return .orange
        case .full:   return .red
        }
    }
}

// MARK: - Live line inside a card

struct LiveETALine: View {
    let eta: LiveETA
    let buses: [LiveBus]
    let scheduled: String
    let now: Date

    private var delay: DelayEstimate? {
        DelayEstimate.compute(eta: eta, scheduled: scheduled, now: now)
    }

    /// 車上人數最少的那台 —— 使用者要搭的是下一班，取最接近的近似。
    /// 優先挑資料新鮮、且還沒開過你的站的那台。
    private var representative: LiveBus? {
        buses.first { $0.isCrowdingFresh && ($0.stopsAway ?? -1) >= 0 }
            ?? buses.first { ($0.stopsAway ?? -1) >= 0 }
            ?? buses.first
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: eta.hasBus ? "dot.radiowaves.left.and.right" : "clock")
                .font(.title3)
                .foregroundStyle(eta.hasBus ? .green : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(eta.hasBus ? "實際 \(eta.display)" : eta.display)
                        .font(.subheadline.weight(.semibold))

                    if let d = delay, d.isSignificant {
                        Text(d.label)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((d.isLate ? Color.orange : Color.blue).opacity(0.16),
                                        in: .capsule)
                            .foregroundStyle(d.isLate ? .orange : .blue)
                    }
                }

                if let d = delay, d.isSignificant {
                    Text("班表 \(scheduled) · 晚點為推估值")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if eta.hasBus {
                    Text("班表 \(scheduled)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if let bus = representative, let c = bus.crowding {
                CrowdingPill(crowding: c, passengers: bus.passengers, ageMinutes: bus.crowdingAgeMinutes)
            }
        }
        .padding(12)
        .background(.green.opacity(eta.hasBus ? 0.10 : 0.05), in: .rect(cornerRadius: 12))
    }
}

// MARK: - Map

/// 地圖上要畫的一段路線：從公車目前位置一路到你的下車站。
/// 不畫整條路線 —— 棕18 一路到松山車站，全畫出來你家那段會小到看不見。
struct RouteOverlay {
    struct Stop: Identifiable {
        enum Kind { case board, alight, plain }
        let id: Int
        let name: String
        let coord: CLLocationCoordinate2D
        let kind: Kind
    }
    let path: [CLLocationCoordinate2D]
    let stops: [Stop]
}

struct BusMap: View {
    let buses: [LiveBus]
    let highlight: String?
    var routeOverlay: RouteOverlay? = nil
    var height: CGFloat = 200

    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(center: Anchor.home,
                           span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
    )

    // MapContentBuilder 對「條件分支 + ForEach」混在一起的推斷能力有限，
    // 元素一多就會 "generic parameter 'V' could not be inferred"。拆開就好。
    @MapContentBuilder
    private var routeContent: some MapContent {
        if let o = routeOverlay, o.path.count > 1 {
            MapPolyline(coordinates: o.path)
                .stroke(.brown.opacity(0.75),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        ForEach(routeOverlay?.stops ?? []) { st in
            Annotation("", coordinate: st.coord) { StopDot(stop: st) }
        }
    }

    @MapContentBuilder
    private var anchorContent: some MapContent {
        Annotation("家", coordinate: Anchor.home) {
            pin(system: "house.fill", tint: .blue)
        }
        Annotation("政大", coordinate: Anchor.campus) {
            pin(system: "building.columns.fill", tint: .indigo)
        }
    }

    @MapContentBuilder
    private var busContent: some MapContent {
        // 標題留空：MapKit 自己畫的標題會跟速度標籤重疊，變成「EAL-²⁶508」。
        ForEach(buses) { bus in
            Annotation("", coordinate: bus.coordinate) {
                BusPin(bus: bus, isHighlighted: bus.plate == highlight)
            }
        }
    }

    var body: some View {
        Map(position: $camera) {
            routeContent
            anchorContent
            busContent
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: height)
        .clipShape(.rect(cornerRadius: 14))
        .overlay(alignment: .bottomLeading) {
            if buses.isEmpty {
                Text("目前沒有往這裡開的車")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.thinMaterial, in: .capsule)
                    .padding(8)
            }
        }
        .onChange(of: buses.map(\.plate)) { _, _ in fit() }
        .onChange(of: routeOverlay?.path.count ?? 0) { _, _ in fit() }
        .onAppear { fit() }
    }

    private func pin(system: String, tint: Color) -> some View {
        Image(systemName: system)
            .font(.caption)
            .foregroundStyle(.white)
            .padding(6)
            .background(tint, in: .circle)
    }

    /// 把家、政大、所有車輛一起框進畫面，不然車在山下時看不到。
    private func fit() {
        let pts = [Anchor.home, Anchor.campus] + buses.map(\.coordinate)
            + (routeOverlay?.path ?? [])
        guard pts.count > 1 else { return }
        let lats = pts.map(\.latitude), lngs = pts.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lngs.min()! + lngs.max()!) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.008, (lats.max()! - lats.min()!) * 1.6),
            longitudeDelta: max(0.008, (lngs.max()! - lngs.min()!) * 1.6))
        withAnimation(.easeInOut(duration: 0.4)) {
            camera = .region(MKCoordinateRegion(center: center, span: span))
        }
    }
}

private struct StopDot: View {
    let stop: RouteOverlay.Stop

    var body: some View {
        switch stop.kind {
        case .plain:
            Circle()
                .fill(.brown.opacity(0.5))
                .frame(width: 6, height: 6)
                .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
        case .board, .alight:
            VStack(spacing: 1) {
                Circle()
                    .fill(stop.kind == .board ? Color.green : Color.indigo)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                Text("\(stop.kind == .board ? "上車" : "下車")·\(stop.name)")
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.thinMaterial, in: .capsule)
                    .fixedSize()
            }
        }
    }
}

private struct BusPin: View {
    let bus: LiveBus
    let isHighlighted: Bool

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(tint)
                    .frame(width: isHighlighted ? 30 : 24, height: isHighlighted ? 30 : 24)
                    .shadow(radius: 2, y: 1)
                Image(systemName: "bus.fill")
                    .font(.system(size: isHighlighted ? 14 : 11))
                    .foregroundStyle(.white)
                if bus.isMoving {
                    // 車頭朝向。停等時不畫 —— 靜止的方位角沒有意義。
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(tint)
                        .padding(2)
                        .background(.white, in: .circle)
                        .rotationEffect(.degrees(bus.heading))
                        .offset(y: isHighlighted ? -20 : -17)
                }
            }

            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: .capsule)
                .fixedSize()
        }
    }

    private var label: String {
        if let l = bus.approachLabel { return "\(bus.plate) · \(l)" }
        return "\(bus.plate) · \(bus.speedKMH) km/h"
    }

    private var tint: Color {
        guard bus.isCrowdingFresh, let c = bus.crowding else { return .gray }
        switch c {
        case .empty:  return .green
        case .medium: return .orange
        case .full:   return .red
        }
    }
}

// MARK: - Expandable row

struct ExpandableDepartureRow: View {
    let departure: Departure
    let now: Date
    let eta: LiveETA?
    let buses: [LiveBus]
    /// 同方向的全部車（含已過站的）—— 展開後才列出來。
    let allBuses: [LiveBus]
    /// ⚠️ 別命名成 `overlay` —— 會跟 `View.overlay(alignment:content:)` 撞名，
    /// 在 body 裡裸寫時 Swift 會解析成那個 modifier，報 "generic parameter 'V' could not be inferred"。
    let routeOverlay: RouteOverlay?

    /// 測試用：`simctl launch <udid> <id> -ExpandRows YES` 讓所有列預設展開，
    /// 這樣不必依賴點擊注入就能檢視展開後的內容。
    @State private var expanded = {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "ExpandRows")
        #else
        false
        #endif
    }()

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: { header }
                .buttonStyle(.plain)

            if expanded { detail.transition(.opacity.combined(with: .move(edge: .top))) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(departure.trip.leaveHome)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .frame(width: 50, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(departure.trip.routeBadge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.brown)
                    if !departure.trip.runsEveryWeekday {
                        Text(departure.trip.daysLabel)
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    if let c = buses.compactMap(\.crowding).min() {
                        CrowdingPill(crowding: c, passengers: nil, ageMinutes: nil, compact: true)
                    }
                }
                Text("\(departure.trip.boardStop) → \(departure.trip.alightStop)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(max(0, departure.minutesUntilLeaving(from: now))) 分")
                    .font(.caption.weight(.medium)).monospacedDigit()
                    .foregroundStyle(.tertiary)
                if let eta, eta.hasBus {
                    Text(eta.display)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(.rect)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let eta {
                LiveETALine(eta: eta, buses: buses,
                            scheduled: departure.trip.depart, now: now)
            } else {
                Label("這班還沒發車，沒有即時資料", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }

            BusMap(buses: buses, highlight: nil, routeOverlay: routeOverlay, height: 180)

            if !allBuses.isEmpty {
                VStack(spacing: 6) {
                    ForEach(allBuses) { bus in
                        HStack(spacing: 8) {
                            Image(systemName: "bus.fill")
                                .font(.caption2).foregroundStyle(.brown)
                            Text(bus.plate)
                                .font(.caption.weight(.medium)).monospacedDigit()
                            Text("\(bus.speedKMH) km/h")
                                .font(.caption2).foregroundStyle(.secondary)
                            if let l = bus.approachLabel {
                                Text(l)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle((bus.stopsAway ?? -1) >= 0 ? .green : .secondary)
                            }
                            Spacer()
                            if let c = bus.crowding {
                                CrowdingPill(crowding: c, passengers: bus.passengers, ageMinutes: bus.crowdingAgeMinutes)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 14) {
                labeled("全程", "\(departure.trip.totalMinutes) 分")
                labeled("發車", departure.trip.depart)
                labeled("抵達", departure.trip.arrive)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private func labeled(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.caption2).foregroundStyle(.tertiary)
            Text(v).font(.caption.weight(.medium)).monospacedDigit()
        }
    }
}
