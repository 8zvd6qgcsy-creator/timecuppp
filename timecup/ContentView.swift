import WidgetKit
import SwiftUI
import Foundation
import Combine
import CoreMotion
import QuartzCore
import UIKit

// MARK: - 数据模型

struct TimeEvent: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var emoji: String
    var startDate: Date
    var endDate: Date
    var note: String
    var showInWidget: Bool
    
    func progress(at date: Date = Date()) -> Double {
        let total = endDate.timeIntervalSince(startDate)
        let passed = date.timeIntervalSince(startDate)
        
        guard total > 0 else { return 0 }
        return min(max(passed / total, 0), 1)
    }
    
    func percentageText(at date: Date = Date()) -> String {
        String(format: "%.2f%%", progress(at: date) * 100)
    }
    
    func statusText(at date: Date = Date()) -> String {
        if date < startDate {
            return "未开始 · 距开始 \(TimeHelper.preciseDuration(startDate.timeIntervalSince(date)))"
        } else if date >= endDate {
            return "已结束"
        } else {
            return "进行中 · 剩余 \(TimeHelper.preciseDuration(endDate.timeIntervalSince(date)))"
        }
    }
}

// MARK: - 排序方式

enum EventSortMode: String, CaseIterable, Identifiable {
    case endDate = "按结束时间"
    case startDate = "按开始时间"
    case name = "按名称"
    case progress = "按进度"
    
    var id: String { rawValue }
}

// MARK: - 掉落触发

struct DropRequest: Equatable {
    let eventID: UUID
    let token: UUID
    
    init(eventID: UUID) {
        self.eventID = eventID
        self.token = UUID()
    }
}

// MARK: - 时间工具

enum TimeHelper {
    private static func dayBounds(for date: Date) -> (start: Date, end: Date, total: TimeInterval) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return (start, end, end.timeIntervalSince(start))
    }
    
    static func todayProgress(at date: Date = Date()) -> Double {
        let bounds = dayBounds(for: date)
        let passed = date.timeIntervalSince(bounds.start)
        
        guard bounds.total > 0 else { return 0 }
        return min(max(passed / bounds.total, 0), 1)
    }
    
    static func todayPercentageText(at date: Date = Date()) -> String {
        String(format: "%.3f%%", todayProgress(at: date) * 100)
    }
    
    static func todayPassedText(at date: Date = Date()) -> String {
        let bounds = dayBounds(for: date)
        return preciseDuration(max(date.timeIntervalSince(bounds.start), 0))
    }
    
    static func todayRemainingText(at date: Date = Date()) -> String {
        let bounds = dayBounds(for: date)
        return preciseDuration(max(bounds.end.timeIntervalSince(date), 0))
    }
    
    static func preciseDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(Int(interval), 0)
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        
        if days > 0 {
            return "\(days)天\(hours)小时\(minutes)分\(seconds)秒"
        } else if hours > 0 {
            return "\(hours)小时\(minutes)分\(seconds)秒"
        } else if minutes > 0 {
            return "\(minutes)分\(seconds)秒"
        } else {
            return "\(seconds)秒"
        }
    }
}

// MARK: - 震动反馈

enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let defaults = UserDefaults.standard
        let hasValue = defaults.object(forKey: "hapticsEnabled") != nil
        let enabled = hasValue ? defaults.bool(forKey: "hapticsEnabled") : true
        
        guard enabled else { return }
        
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
    
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let defaults = UserDefaults.standard
        let hasValue = defaults.object(forKey: "hapticsEnabled") != nil
        let enabled = hasValue ? defaults.bool(forKey: "hapticsEnabled") : true
        
        guard enabled else { return }
        
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}

// MARK: - 全局共享高刷新计时器

final class SharedAnimationClock: NSObject, ObservableObject {
    static let shared = SharedAnimationClock()
    
    @Published private(set) var timestamp: CFTimeInterval = CACurrentMediaTime()
    
    private var displayLink: CADisplayLink?
    private var subscriberCount = 0
    private var appIsActive = true
    
    private override init() {
        super.init()
    }
    
    func subscribe() {
        subscriberCount += 1
        updateRunningState()
    }
    
    func unsubscribe() {
        subscriberCount = max(subscriberCount - 1, 0)
        updateRunningState()
    }
    
    func setAppActive(_ active: Bool) {
        appIsActive = active
        updateRunningState()
    }
    
    private func updateRunningState() {
        if subscriberCount > 0 && appIsActive {
            start()
        } else {
            stop()
        }
    }
    
    private func start() {
        guard displayLink == nil else { return }
        
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 80,
                maximum: 120,
                preferred: 90
            )
        } else {
            link.preferredFramesPerSecond = 90
        }
        
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    
    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func tick(_ link: CADisplayLink) {
        timestamp = link.timestamp
    }
}

// MARK: - 运动感应

final class MotionManager: ObservableObject {
    static let shared = MotionManager()
    
    private let manager = CMMotionManager()
    private var running = false
    
    @Published var x: Double = 0
    @Published var y: Double = 0
    
    private init() { }
    
    func resume() {
        guard !running else { return }
        running = true
        
        if manager.isDeviceMotionAvailable {
            manager.deviceMotionUpdateInterval = 1.0 / 90.0
            
            manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                
                let gravity = data.gravity
                let user = data.userAcceleration
                
                self?.x = gravity.x + user.x * 0.45
                self?.y = gravity.y + user.y * 0.38
            }
        } else if manager.isAccelerometerAvailable {
            manager.accelerometerUpdateInterval = 1.0 / 90.0
            
            manager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                
                self?.x = data.acceleration.x
                self?.y = data.acceleration.y
            }
        }
    }
    
    func pause() {
        running = false
        manager.stopDeviceMotionUpdates()
        manager.stopAccelerometerUpdates()
        x = 0
        y = 0
    }
}

// MARK: - 存储

final class EventStore: ObservableObject {
    @Published var events: [TimeEvent] = []
    
    private let key = "timecup_events_final_v2"
    private let appGroupID = "group.com.liuhua.timecup"
    
    private var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }
    
    init() {
        load()
    }
    
    func load() {
        guard let data = sharedDefaults.data(forKey: key) else {
            events = []
            return
        }
        
        do {
            events = try JSONDecoder().decode([TimeEvent].self, from: data)
                .sorted { $0.endDate < $1.endDate }
        } catch {
            print("读取失败：\(error)")
            events = []
        }
    }
    
    func save() {
        do {
            let data = try JSONEncoder().encode(events)
            sharedDefaults.set(data, forKey: key)
            
            // 关键：通知桌面小组件刷新
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            print("保存失败：\(error)")
        }
    }
    
    func add(
        name: String,
        emoji: String,
        startDate: Date,
        endDate: Date,
        note: String,
        showInWidget: Bool
    ) -> UUID {
        let event = TimeEvent(
            name: name,
            emoji: emoji.isEmpty ? "💧" : emoji,
            startDate: startDate,
            endDate: endDate,
            note: note,
            showInWidget: showInWidget
        )
        
        events.append(event)
        events.sort { $0.endDate < $1.endDate }
        save()
        return event.id
    }
    
    func update(_ event: TimeEvent) -> UUID {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else {
            return event.id
        }
        
        events[index] = event
        events.sort { $0.endDate < $1.endDate }
        save()
        return event.id
    }
    
    func delete(_ event: TimeEvent) {
        events.removeAll { $0.id == event.id }
        save()
    }
    
    func delete(ids: Set<UUID>) {
        events.removeAll { ids.contains($0.id) }
        save()
    }
}
// MARK: - Sheet

enum ActiveSheet: Identifiable {
    case add
    case edit(TimeEvent)
    case detail(TimeEvent)
    
    var id: String {
        switch self {
        case .add:
            return "add"
        case .edit(let event):
            return "edit-\(event.id.uuidString)"
        case .detail(let event):
            return "detail-\(event.id.uuidString)"
        }
    }
}

// MARK: - 主页面

struct ContentView: View {
    @StateObject private var store = EventStore()
    
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var activeSheet: ActiveSheet?
    @State private var dropRequest: DropRequest?
    @State private var showSettings = false
    
    @State private var searchText = ""
    @State private var isBatchEditing = false
    @State private var selectedIDs: Set<UUID> = []
    
    @AppStorage("hideEndedEvents") private var hideEndedEvents = false
    @AppStorage("eventSortMode") private var sortModeRaw = EventSortMode.endDate.rawValue
    
    private var sortMode: EventSortMode {
        EventSortMode(rawValue: sortModeRaw) ?? .endDate
    }
    
    private var visibleEvents: [TimeEvent] {
        let now = Date()
        var result = store.events
        
        if hideEndedEvents {
            result = result.filter { $0.endDate > now }
        }
        
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(keyword) ||
                $0.emoji.contains(keyword) ||
                $0.note.localizedCaseInsensitiveContains(keyword)
            }
        }
        
        switch sortMode {
        case .endDate:
            result.sort { $0.endDate < $1.endDate }
        case .startDate:
            result.sort { $0.startDate < $1.startDate }
        case .name:
            result.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .progress:
            result.sort { $0.progress(at: now) > $1.progress(at: now) }
        }
        
        return result
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    HeaderView()
                    
                    InteractiveCupCard(
                        events: visibleEvents,
                        dropRequest: dropRequest
                    ) { event in
                        activeSheet = .detail(event)
                    }
                    
                    EventControlPanel(
                        searchText: $searchText,
                        hideEndedEvents: $hideEndedEvents,
                        sortModeRaw: $sortModeRaw
                    )
                    
                    EventListCard(
                        events: visibleEvents,
                        isBatchEditing: isBatchEditing,
                        selectedIDs: $selectedIDs,
                        onTap: { event in
                            if isBatchEditing {
                                toggleSelection(event.id)
                            } else {
                                Haptics.impact(.light)
                                activeSheet = .detail(event)
                            }
                        },
                        onEdit: { event in
                            Haptics.impact(.medium)
                            activeSheet = .edit(event)
                        },
                        onDeleteSelected: {
                            store.delete(ids: selectedIDs)
                            selectedIDs.removeAll()
                            isBatchEditing = false
                            Haptics.notify(.success)
                        }
                    )
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("时间水杯")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                        Haptics.impact(.light)
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title3)
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isBatchEditing.toggle()
                        selectedIDs.removeAll()
                        Haptics.impact(.light)
                    } label: {
                        Text(isBatchEditing ? "完成" : "编辑")
                    }
                    .disabled(store.events.isEmpty)
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        activeSheet = .add
                        Haptics.impact(.medium)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                AppSettingsView()
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .add:
                    EventEditorView(store: store, editingEvent: nil) { id in
                        dropRequest = DropRequest(eventID: id)
                        Haptics.notify(.success)
                    }
                    
                case .edit(let event):
                    EventEditorView(store: store, editingEvent: event) { id in
                        dropRequest = DropRequest(eventID: id)
                        Haptics.notify(.success)
                    }
                    
                case .detail(let event):
                    EventDetailView(event: event) {
                        activeSheet = nil
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            activeSheet = .edit(event)
                        }
                    }
                }
            }
            .onAppear {
                SharedAnimationClock.shared.setAppActive(true)
                MotionManager.shared.resume()
            }
            .onChange(of: scenePhase) { _, newValue in
                let active = newValue == .active
                
                SharedAnimationClock.shared.setAppActive(active)
                
                if active {
                    MotionManager.shared.resume()
                } else {
                    MotionManager.shared.pause()
                }
            }
        }
    }
    
    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        
        Haptics.impact(.light)
    }
}

// MARK: - 顶部实时信息

struct HeaderView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                Text("今天的时间")
                    .font(.largeTitle.bold())
                
                Text("已过去 \(TimeHelper.todayPercentageText(at: context.date))")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("已用：\(TimeHelper.todayPassedText(at: context.date))")
                    Text("剩余：\(TimeHelper.todayRemainingText(at: context.date))")
                }
                .font(.headline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                
                Text("每一秒都在流动，杯中的水位和事件会跟着你的时间一起变化。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 水杯卡片

struct InteractiveCupCard: View {
    let events: [TimeEvent]
    let dropRequest: DropRequest?
    let onTapEvent: (TimeEvent) -> Void
    
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let progress = TimeHelper.todayProgress(at: context.date)
            
            VStack(spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Time Cup")
                            .font(.title2.bold())
                        
                        Text("高刷新流动水面 · 长按 emoji 确认打开")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Text(TimeHelper.todayPercentageText(at: context.date))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                
                FlowCupView(
                    progress: progress,
                    events: Array(events.prefix(12)),
                    dropRequest: dropRequest,
                    onTapEvent: onTapEvent
                )
                .frame(height: 370)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 30)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .shadow(color: Color.black.opacity(0.08), radius: 20, x: 0, y: 10)
            )
        }
    }
}

// MARK: - 流动水杯

struct FlowCupView: View {
    let progress: Double
    let events: [TimeEvent]
    let dropRequest: DropRequest?
    let onTapEvent: (TimeEvent) -> Void
    
    @ObservedObject private var clock = SharedAnimationClock.shared
    @ObservedObject private var motion = MotionManager.shared
    
    @AppStorage("motionStrength") private var motionStrength = 1.0
    @AppStorage("waveStrength") private var waveStrength = 1.0
    
    @State private var subscribed = false
    
    var body: some View {
        let phase = clock.timestamp
        let motionX = motion.x * motionStrength
        let motionY = motion.y * motionStrength
        
        GeometryReader { geo in
            ZStack {
                CupBackgroundView()
                
                WaterLayer(
                    progress: progress,
                    phase: phase,
                    motionX: motionX,
                    motionY: motionY,
                    waveStrength: waveStrength
                )
                .padding(18)
                .clipShape(RoundedRectangle(cornerRadius: 34))
                
                BubbleLayer(
                    progress: progress,
                    phase: phase,
                    motionX: motionX,
                    size: geo.size
                )
                .padding(18)
                .clipShape(RoundedRectangle(cornerRadius: 34))
                
                EventTokenLayer(
                    events: events,
                    progress: progress,
                    phase: phase,
                    motionX: motionX,
                    motionY: motionY,
                    size: geo.size,
                    dropRequest: dropRequest,
                    onTapEvent: onTapEvent
                )
                
                CupGlassOverlay()
            }
        }
        .onAppear {
            if !subscribed {
                subscribed = true
                SharedAnimationClock.shared.subscribe()
            }
            
            MotionManager.shared.resume()
        }
        .onDisappear {
            if subscribed {
                subscribed = false
                SharedAnimationClock.shared.unsubscribe()
            }
        }
    }
}

struct CupBackgroundView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 38)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(.systemBackground).opacity(0.70),
                            Color(.secondarySystemBackground).opacity(0.35)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            RoundedRectangle(cornerRadius: 38)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1.5)
        }
    }
}

struct CupGlassOverlay: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 38)
                    .stroke(Color.primary.opacity(0.16), lineWidth: 2)
                
                RoundedRectangle(cornerRadius: 38)
                    .stroke(Color(.systemBackground).opacity(0.65), lineWidth: 4)
                
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(.systemBackground).opacity(0.24))
                    .frame(width: geo.size.width * 0.10, height: geo.size.height * 0.48)
                    .offset(x: -geo.size.width * 0.28, y: -geo.size.height * 0.05)
                
                Capsule()
                    .fill(Color(.systemBackground).opacity(0.30))
                    .frame(width: geo.size.width * 0.65, height: 8)
                    .offset(y: -geo.size.height * 0.34)
            }
        }
    }
}

// MARK: - 水面层

struct WaterLayer: View {
    let progress: Double
    let phase: TimeInterval
    let motionX: Double
    let motionY: Double
    let waveStrength: Double
    
    var body: some View {
        ZStack {
            FlowingWaterShape(
                progress: progress,
                phase: phase,
                motionX: motionX,
                motionY: motionY,
                waveHeight: 18 * CGFloat(waveStrength)
            )
            .fill(
                LinearGradient(
                    colors: [
                        Color.cyan.opacity(0.70),
                        Color.blue.opacity(0.84)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            
            FlowingWaterShape(
                progress: progress,
                phase: phase + 1.7,
                motionX: motionX * 0.75,
                motionY: motionY,
                waveHeight: 10 * CGFloat(waveStrength)
            )
            .fill(Color(.systemBackground).opacity(0.12))
            
            FlowingSurfaceShape(
                progress: progress,
                phase: phase,
                motionX: motionX,
                motionY: motionY,
                waveStrength: waveStrength
            )
            .stroke(
                Color(.systemBackground).opacity(0.74),
                style: StrokeStyle(lineWidth: 4, lineCap: .round)
            )
        }
    }
}

struct FlowingWaterShape: Shape {
    var progress: Double
    var phase: TimeInterval
    var motionX: Double
    var motionY: Double
    var waveHeight: CGFloat
    
    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get {
            AnimatablePair(progress, AnimatablePair(motionX, motionY))
        }
        set {
            progress = newValue.first
            motionX = newValue.second.first
            motionY = newValue.second.second
        }
    }
    
    func path(in rect: CGRect) -> Path {
        let safeProgress = min(max(progress, 0), 1)
        let waterHeight = rect.height * CGFloat(safeProgress)
        let baseY = rect.maxY - waterHeight
        let samples = 48
        
        var points: [CGPoint] = []
        
        for i in 0...samples {
            let t = CGFloat(i) / CGFloat(samples)
            let x = rect.minX + rect.width * t
            
            let wave1 = sin(Double(t) * .pi * 2.0 + phase * 3.2)
            let wave2 = sin(Double(t) * .pi * 4.0 + phase * 2.4)
            let tilt = CGFloat(motionX) * 52 * (t - 0.5)
            
            let y = baseY
                + CGFloat(wave1) * waveHeight
                + CGFloat(wave2) * waveHeight * 0.36
                + tilt
                + CGFloat(motionY) * 20
            
            points.append(
                CGPoint(
                    x: x,
                    y: min(max(y, rect.minY), rect.maxY)
                )
            )
        }
        
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        
        for point in points.reversed() {
            path.addLine(to: point)
        }
        
        path.closeSubpath()
        return path
    }
}

struct FlowingSurfaceShape: Shape {
    var progress: Double
    var phase: TimeInterval
    var motionX: Double
    var motionY: Double
    var waveStrength: Double
    
    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get {
            AnimatablePair(progress, AnimatablePair(motionX, motionY))
        }
        set {
            progress = newValue.first
            motionX = newValue.second.first
            motionY = newValue.second.second
        }
    }
    
    func path(in rect: CGRect) -> Path {
        let safeProgress = min(max(progress, 0), 1)
        let waterHeight = rect.height * CGFloat(safeProgress)
        let baseY = rect.maxY - waterHeight
        let samples = 48
        
        var path = Path()
        
        for i in 0...samples {
            let t = CGFloat(i) / CGFloat(samples)
            let x = rect.minX + rect.width * t
            
            let wave1 = sin(Double(t) * .pi * 2.0 + phase * 3.2)
            let wave2 = sin(Double(t) * .pi * 4.0 + phase * 2.4)
            let tilt = CGFloat(motionX) * 52 * (t - 0.5)
            
            let y = baseY
                + CGFloat(wave1) * 18 * CGFloat(waveStrength)
                + CGFloat(wave2) * 7 * CGFloat(waveStrength)
                + tilt
                + CGFloat(motionY) * 20
            
            let point = CGPoint(
                x: x,
                y: min(max(y, rect.minY), rect.maxY)
            )
            
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        
        return path
    }
}

// MARK: - 水泡层

struct BubbleLayer: View {
    let progress: Double
    let phase: TimeInterval
    let motionX: Double
    let size: CGSize
    
    var body: some View {
        let safeProgress = min(max(progress, 0), 1)
        let waterTop = size.height * (1 - safeProgress)
        
        ZStack {
            ForEach(0..<20, id: \.self) { index in
                let baseX = CGFloat((index * 47) % 100) / 100.0 * size.width
                let speed = Double(index % 5 + 4)
                let offset = CGFloat((phase * speed + Double(index * 31)).truncatingRemainder(dividingBy: Double(max(size.height, 1))))
                let bubbleSize = CGFloat(4 + (index % 4) * 3)
                let x = baseX + CGFloat(motionX) * 24 + CGFloat(sin(phase * 2 + Double(index))) * 12
                let y = size.height - offset
                
                if y > waterTop {
                    Circle()
                        .fill(Color(.systemBackground).opacity(0.24))
                        .frame(width: bubbleSize, height: bubbleSize)
                        .position(x: x, y: y)
                }
            }
        }
    }
}

// MARK: - 事件 emoji 物理层

struct EventTokenLayer: View {
    let events: [TimeEvent]
    let progress: Double
    let phase: TimeInterval
    let motionX: Double
    let motionY: Double
    let size: CGSize
    let dropRequest: DropRequest?
    let onTapEvent: (TimeEvent) -> Void
    
    @StateObject private var physics = CupTokenPhysicsModel()
    
    @State private var pendingOpenEvent: TimeEvent?
    @State private var showOpenConfirm = false
    
    @State private var activeEventID: UUID?
    @State private var draggingEventID: UUID?
    @State private var pressStartPoint: CGPoint?
    @State private var longPressWorkItem: DispatchWorkItem?
    
    private let hitRadius: CGFloat = 34
    
    var body: some View {
        ZStack {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                if let state = physics.states[event.id] {
                    EventEmojiTokenVisual(
                        event: event,
                        state: state
                    )
                    .zIndex(zIndexValue(for: event, index: index))
                    .allowsHitTesting(false)
                }
            }
        }
        .contentShape(Rectangle())
        .coordinateSpace(name: "cupSpace")
        .gesture(parentDragGesture)
        .confirmationDialog(
            "确认打开这个事件？",
            isPresented: $showOpenConfirm,
            titleVisibility: .visible
        ) {
            if let event = pendingOpenEvent {
                Button("打开「\(event.name)」") {
                    Haptics.impact(.medium)
                    onTapEvent(event)
                    pendingOpenEvent = nil
                }
            }
            
            Button("取消", role: .cancel) {
                pendingOpenEvent = nil
            }
        } message: {
            if let event = pendingOpenEvent {
                Text("你长按了 \(event.emoji) \(event.name)")
            } else {
                Text("确认要打开这个事件吗？")
            }
        }
        .onAppear {
            updatePhysics()
        }
        .onChange(of: phase) { _, newValue in
            physics.step(timestamp: newValue)
        }
        .onChange(of: events) { _, _ in
            updatePhysics()
        }
        .onChange(of: progress) { _, _ in
            updatePhysics()
        }
        .onChange(of: motionX) { _, _ in
            updatePhysics()
        }
        .onChange(of: motionY) { _, _ in
            updatePhysics()
        }
        .onChange(of: dropRequest) { _, _ in
            updatePhysics()
        }
    }
    
    private var parentDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("cupSpace"))
            .onChanged { value in
                handleTouchChanged(value)
            }
            .onEnded { value in
                handleTouchEnded(value)
            }
    }
    
    private func handleTouchChanged(_ value: DragGesture.Value) {
        let location = value.location
        
        if activeEventID == nil {
            guard let hitEvent = hitTestEvent(at: location) else {
                return
            }
            
            activeEventID = hitEvent.id
            pressStartPoint = location
            
            scheduleLongPress(for: hitEvent)
        }
        
        guard let activeID = activeEventID else { return }
        guard let startPoint = pressStartPoint else { return }
        
        let distance = hypot(
            location.x - startPoint.x,
            location.y - startPoint.y
        )
        
        if distance > 8 {
            cancelLongPress()
            
            draggingEventID = activeID
            physics.beginDrag(eventID: activeID)
            physics.drag(eventID: activeID, to: location)
        }
    }
    
    private func handleTouchEnded(_ value: DragGesture.Value) {
        if let draggingID = draggingEventID {
            physics.drag(eventID: draggingID, to: value.location)
            physics.endDrag(eventID: draggingID)
        }
        
        cancelLongPress()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            draggingEventID = nil
            activeEventID = nil
            pressStartPoint = nil
        }
    }
    
    private func scheduleLongPress(for event: TimeEvent) {
        cancelLongPress()
        
        let workItem = DispatchWorkItem {
            guard activeEventID == event.id else { return }
            guard draggingEventID == nil else { return }
            
            pendingOpenEvent = event
            showOpenConfirm = true
            Haptics.impact(.medium)
        }
        
        longPressWorkItem = workItem
        
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.7,
            execute: workItem
        )
    }
    
    private func cancelLongPress() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
    }
    
    private func hitTestEvent(at point: CGPoint) -> TimeEvent? {
        let indexedEvents = Array(events.enumerated())
        
        let candidates = indexedEvents.compactMap { index, event -> (event: TimeEvent, z: Double, distance: CGFloat)? in
            guard let state = physics.states[event.id] else {
                return nil
            }
            
            let dx = point.x - state.position.x
            let dy = point.y - state.position.y
            let distance = sqrt(dx * dx + dy * dy)
            
            guard distance <= hitRadius else {
                return nil
            }
            
            return (
                event: event,
                z: zIndexValue(for: event, index: index),
                distance: distance
            )
        }
        
        return candidates
            .sorted {
                if $0.z == $1.z {
                    return $0.distance < $1.distance
                } else {
                    return $0.z > $1.z
                }
            }
            .first?
            .event
    }
    
    private func zIndexValue(for event: TimeEvent, index: Int) -> Double {
        if draggingEventID == event.id {
            return 10_000
        }
        
        if activeEventID == event.id {
            return 9_000
        }
        
        return Double(events.count - index)
    }
    
    private func updatePhysics() {
        physics.setInputs(
            events: events,
            size: size,
            progress: progress,
            motionX: motionX,
            motionY: motionY,
            dropRequest: dropRequest
        )
    }
}

struct EventEmojiTokenVisual: View {
    let event: TimeEvent
    let state: CupTokenPhysicsModel.TokenState
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(.systemBackground).opacity(0.90))
                .shadow(
                    color: Color.black.opacity(0.18),
                    radius: 10,
                    x: 0,
                    y: 6
                )
            
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: 2)
            
            Text(event.emoji)
                .font(.system(size: 30))
        }
        .frame(width: 58, height: 58)
        .scaleEffect(state.scale)
        .rotationEffect(.degrees(state.rotation))
        .position(x: state.position.x, y: state.position.y)
    }
}
// MARK: - emoji 轻量物理引擎

final class CupTokenPhysicsModel: ObservableObject {
    struct TokenState {
        var position: CGPoint
        var velocity: CGVector
        var rotation: Double
        var angularVelocity: Double
        var scale: CGFloat
    }
    
    @Published var states: [UUID: TokenState] = [:]
    
    private var lastTimestamp: CFTimeInterval = 0
    
    private var events: [TimeEvent] = []
    private var size: CGSize = .zero
    private var progress: Double = 0
    private var motionX: Double = 0
    private var motionY: Double = 0
    private var dropRequest: DropRequest?
    private var lastDropToken: UUID?
    private var draggingIDs: Set<UUID> = []
    
    private let radius: CGFloat = 29
    private let padding: CGFloat = 36
    
    func setInputs(
        events: [TimeEvent],
        size: CGSize,
        progress: Double,
        motionX: Double,
        motionY: Double,
        dropRequest: DropRequest?
    ) {
        self.events = events
        self.size = size
        self.progress = min(max(progress, 0), 1)
        self.motionX = motionX
        self.motionY = motionY
        self.dropRequest = dropRequest
        
        syncStates()
        
        if let dropRequest,
           dropRequest.token != lastDropToken {
            lastDropToken = dropRequest.token
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                self.drop(eventID: dropRequest.eventID, stronger: true)
            }
        }
    }
    
    func beginDrag(eventID: UUID) {
        draggingIDs.insert(eventID)
        
        if var state = states[eventID] {
            state.velocity = .zero
            state.angularVelocity *= 0.35
            state.scale = 1.12
            states[eventID] = state
        }
    }
    
    func drag(eventID: UUID, to point: CGPoint) {
        guard var state = states[eventID] else { return }
        
        state.position = point
        state.velocity = .zero
        state.angularVelocity *= 0.85
        state.scale = 1.12
        
        states[eventID] = state
    }
    
    func endDrag(eventID: UUID) {
        draggingIDs.remove(eventID)
        
        if var state = states[eventID] {
            state.scale = 1.0
            state.velocity = CGVector(
                dx: CGFloat(motionX) * 180,
                dy: CGFloat(motionY) * -140
            )
            states[eventID] = state
        }
    }
    
    func step(timestamp: CFTimeInterval) {
        if lastTimestamp == 0 {
            lastTimestamp = timestamp
            return
        }
        
        let rawDT = timestamp - lastTimestamp
        lastTimestamp = timestamp
        
        let dt = CGFloat(min(max(rawDT, 1.0 / 240.0), 1.0 / 30.0))
        step(dt: dt, time: timestamp)
    }
    
    private func syncStates() {
        guard size.width > 20, size.height > 20 else { return }
        
        let ids = Set(events.map { $0.id })
        
        for id in Array(states.keys) {
            if !ids.contains(id) {
                states.removeValue(forKey: id)
                draggingIDs.remove(id)
            }
        }
        
        for (index, event) in events.enumerated() {
            if states[event.id] == nil {
                let target = targetPosition(for: index)
                
                states[event.id] = TokenState(
                    position: CGPoint(x: size.width - 20, y: -60),
                    velocity: CGVector(
                        dx: CGFloat.random(in: -260 ... -120),
                        dy: CGFloat.random(in: 80 ... 220)
                    ),
                    rotation: Double.random(in: -35 ... 35),
                    angularVelocity: Double.random(in: -260 ... 260),
                    scale: 0.35
                )
                
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.08) {
                    if var state = self.states[event.id] {
                        state.position = CGPoint(
                            x: target.x + CGFloat.random(in: -20...20),
                            y: -50
                        )
                        state.velocity = CGVector(
                            dx: CGFloat.random(in: -220 ... -80),
                            dy: CGFloat.random(in: 120 ... 260)
                        )
                        self.states[event.id] = state
                    }
                }
            }
        }
    }
    
    private func drop(eventID: UUID, stronger: Bool) {
        guard size.width > 20, size.height > 20 else { return }
        guard var state = states[eventID] else { return }
        
        state.position = CGPoint(x: size.width - 22, y: -58)
        state.velocity = CGVector(
            dx: stronger ? CGFloat.random(in: -360 ... -180) : CGFloat.random(in: -240 ... -120),
            dy: stronger ? CGFloat.random(in: 140 ... 300) : CGFloat.random(in: 100 ... 230)
        )
        state.rotation = Double.random(in: -50 ... 50)
        state.angularVelocity = stronger ? Double.random(in: -480 ... 480) : Double.random(in: -280 ... 280)
        state.scale = 0.35
        
        states[eventID] = state
    }
    
    private func step(dt: CGFloat, time: TimeInterval) {
        guard size.width > 20, size.height > 20 else { return }
        guard !events.isEmpty else { return }
        
        var newStates = states
        
        for (index, event) in events.enumerated() {
            guard var state = newStates[event.id] else { continue }
            
            if draggingIDs.contains(event.id) {
                newStates[event.id] = state
                continue
            }
            
            let target = targetPosition(for: index)
            let bounds = cupBounds()
            let waterTop = waterSurfaceY()
            let isUnderWater = state.position.y > waterTop - radius * 0.45
            
            var ax: CGFloat = 0
            var ay: CGFloat = 760
            
            ax += CGFloat(motionX) * 1550
            ay += CGFloat(motionY) * -320
            
            if isUnderWater {
                let depth = min(max((state.position.y - waterTop) / 120, 0), 1)
                
                ay += -680 * depth
                
                ax += (target.x - state.position.x) * 5.8
                ay += (target.y - state.position.y) * 4.2
                
                let fluidDrag = pow(0.88, dt * 60)
                state.velocity.dx *= fluidDrag
                state.velocity.dy *= fluidDrag
                
                ax += CGFloat(sin(time * 2.9 + Double(index))) * 82
                ay += CGFloat(cos(time * 3.2 + Double(index) * 0.7)) * 58
                
                state.angularVelocity *= Double(pow(0.88, dt * 60))
            } else {
                let airDrag = pow(0.985, dt * 60)
                state.velocity.dx *= airDrag
                state.velocity.dy *= airDrag
                
                ax += (target.x - state.position.x) * 0.85
            }
            
            state.velocity.dx += ax * dt
            state.velocity.dy += ay * dt
            
            state.velocity.dx = clamp(state.velocity.dx, -1100, 1100)
            state.velocity.dy = clamp(state.velocity.dy, -1100, 1100)
            
            state.position.x += state.velocity.dx * dt
            state.position.y += state.velocity.dy * dt
            
            state.rotation += state.angularVelocity * Double(dt)
            state.rotation += Double(state.velocity.dx * dt * 0.08)
            
            state.scale += (1 - state.scale) * min(dt * 11, 1)
            
            collideWithCupBounds(state: &state, bounds: bounds)
            
            newStates[event.id] = state
        }
        
        resolveCircleCollisions(states: &newStates)
        states = newStates
    }
    
    private func collideWithCupBounds(state: inout TokenState, bounds: CGRect) {
        if state.position.x < bounds.minX + radius {
            state.position.x = bounds.minX + radius
            state.velocity.dx = abs(state.velocity.dx) * 0.58
            state.angularVelocity += 120
        }
        
        if state.position.x > bounds.maxX - radius {
            state.position.x = bounds.maxX - radius
            state.velocity.dx = -abs(state.velocity.dx) * 0.58
            state.angularVelocity -= 120
        }
        
        if state.position.y > bounds.maxY - radius {
            state.position.y = bounds.maxY - radius
            state.velocity.dy = -abs(state.velocity.dy) * 0.45
            state.velocity.dx *= 0.92
            state.angularVelocity *= -0.55
        }
        
        if state.position.y < -100 {
            state.position.y = -100
            state.velocity.dy = abs(state.velocity.dy) * 0.35
        }
    }
    
    private func resolveCircleCollisions(states: inout [UUID: TokenState]) {
        let ids = events.map { $0.id }
        guard ids.count > 1 else { return }
        
        let minDistance = radius * 2 + 3
        let restitution: CGFloat = 0.32
        
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                let idA = ids[i]
                let idB = ids[j]
                
                if draggingIDs.contains(idA) || draggingIDs.contains(idB) {
                    continue
                }
                
                guard var a = states[idA], var b = states[idB] else { continue }
                
                let dx = b.position.x - a.position.x
                let dy = b.position.y - a.position.y
                let distance = max(sqrt(dx * dx + dy * dy), 0.001)
                
                if distance < minDistance {
                    let nx = dx / distance
                    let ny = dy / distance
                    let overlap = minDistance - distance
                    
                    a.position.x -= nx * overlap * 0.5
                    a.position.y -= ny * overlap * 0.5
                    b.position.x += nx * overlap * 0.5
                    b.position.y += ny * overlap * 0.5
                    
                    let relativeVX = b.velocity.dx - a.velocity.dx
                    let relativeVY = b.velocity.dy - a.velocity.dy
                    let velocityAlongNormal = relativeVX * nx + relativeVY * ny
                    
                    if velocityAlongNormal < 0 {
                        let impulse = -(1 + restitution) * velocityAlongNormal / 2
                        let impulseX = impulse * nx
                        let impulseY = impulse * ny
                        
                        a.velocity.dx -= impulseX
                        a.velocity.dy -= impulseY
                        b.velocity.dx += impulseX
                        b.velocity.dy += impulseY
                    }
                    
                    states[idA] = a
                    states[idB] = b
                }
            }
        }
    }
    
    private func cupBounds() -> CGRect {
        CGRect(
            x: padding,
            y: 18,
            width: max(size.width - padding * 2, 1),
            height: max(size.height - 36, 1)
        )
    }
    
    private func waterSurfaceY() -> CGFloat {
        let bounds = cupBounds()
        let safeProgress = min(max(progress, 0.08), 1)
        return bounds.maxY - bounds.height * CGFloat(safeProgress)
    }
    
    private func targetPosition(for index: Int) -> CGPoint {
        let bounds = cupBounds()
        let waterTop = waterSurfaceY()
        
        let columns = 4
        let col = index % columns
        let row = index / columns
        
        let x = bounds.minX + bounds.width * (CGFloat(col) + 0.5) / CGFloat(columns)
        let baseY = bounds.maxY - radius - CGFloat(row) * 58
        
        let y = min(
            max(baseY, waterTop + radius + 12),
            bounds.maxY - radius
        )
        
        return CGPoint(x: x, y: y)
    }
    
    private func clamp(_ value: CGFloat, _ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minValue), maxValue)
    }
}

// MARK: - 事件控制面板

struct EventControlPanel: View {
    @Binding var searchText: String
    @Binding var hideEndedEvents: Bool
    @Binding var sortModeRaw: String
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                
                TextField("搜索事件、emoji 或备注", text: $searchText)
                    .textInputAutocapitalization(.never)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            
            HStack {
                Toggle("隐藏已结束", isOn: $hideEndedEvents)
                    .font(.subheadline)
                
                Spacer()
                
                Picker("排序", selection: $sortModeRaw) {
                    ForEach(EventSortMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

// MARK: - 事件列表

struct EventListCard: View {
    let events: [TimeEvent]
    let isBatchEditing: Bool
    @Binding var selectedIDs: Set<UUID>
    let onTap: (TimeEvent) -> Void
    let onEdit: (TimeEvent) -> Void
    let onDeleteSelected: () -> Void
    
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("事件池")
                        .font(.title3.bold())
                    
                    Spacer()
                    
                    Text("\(events.count) 个事件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                if isBatchEditing && !selectedIDs.isEmpty {
                    Button(role: .destructive) {
                        onDeleteSelected()
                    } label: {
                        Label("删除选中的 \(selectedIDs.count) 个事件", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                
                if events.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有事件")
                            .font(.headline)
                        
                        Text("点击右上角 +，添加考试、比赛、纪念日、旅行计划等。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(events) { event in
                        EventRow(
                            event: event,
                            date: context.date,
                            isBatchEditing: isBatchEditing,
                            isSelected: selectedIDs.contains(event.id),
                            onTap: {
                                onTap(event)
                            },
                            onEdit: {
                                onEdit(event)
                            }
                        )
                    }
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 26)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .shadow(color: Color.black.opacity(0.05), radius: 12, x: 0, y: 6)
            )
        }
    }
}

struct EventRow: View {
    let event: TimeEvent
    let date: Date
    let isBatchEditing: Bool
    let isSelected: Bool
    let onTap: () -> Void
    let onEdit: () -> Void
    
    @State private var pressed = false
    
    var body: some View {
        HStack(spacing: 12) {
            if isBatchEditing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                    .font(.title3)
            }
            
            Text(event.emoji)
                .font(.system(size: 28))
                .frame(width: 50, height: 50)
                .background(Circle().fill(Color.blue.opacity(0.10)))
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(event.name)
                        .font(.headline)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(event.percentageText(at: date))
                        .font(.headline)
                        .monospacedDigit()
                }
                
                ProgressView(value: event.progress(at: date))
                
                Text(event.statusText(at: date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            
            if !isBatchEditing {
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .scaleEffect(pressed ? 0.98 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            onEdit()
        } onPressingChanged: { value in
            withAnimation(.easeOut(duration: 0.12)) {
                pressed = value
            }
        }
    }
}

// MARK: - 详情页

struct EventDetailView: View {
    let event: TimeEvent
    let onEdit: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            NavigationStack {
                VStack(spacing: 22) {
                    Text(event.emoji)
                        .font(.system(size: 82))
                        .frame(width: 130, height: 130)
                        .background(Circle().fill(Color.blue.opacity(0.12)))
                    
                    Text(event.name)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    
                    VStack(spacing: 10) {
                        Text(event.percentageText(at: context.date))
                            .font(.system(size: 52, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        
                        ProgressView(value: event.progress(at: context.date))
                        
                        Text(event.statusText(at: context.date))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                    
                    VStack(alignment: .leading, spacing: 10) {
                        InfoLine(title: "开始时间", value: event.startDate.formatted(date: .abbreviated, time: .standard))
                        InfoLine(title: "结束时间", value: event.endDate.formatted(date: .abbreviated, time: .standard))
                        
                        if !event.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Divider()
                            Text(event.note)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                    
                    Spacer()
                }
                .padding()
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
                .navigationTitle("事件详情")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") {
                            dismiss()
                        }
                    }
                    
                    ToolbarItem(placement: .confirmationAction) {
                        Button("编辑") {
                            dismiss()
                            onEdit()
                        }
                    }
                }
            }
        }
    }
}

struct InfoLine: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - 添加 / 编辑事件

struct EventEditorView: View {
    @Environment(\.dismiss) private var dismiss
    
    @ObservedObject var store: EventStore
    let editingEvent: TimeEvent?
    let onSaved: (UUID) -> Void
    
    @State private var name: String
    @State private var emoji: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var note: String
    @State private var showInWidget: Bool
    
    private let emojiSuggestions = [
        "📚", "📝", "🏆", "✈️", "🎂", "💼",
        "🎮", "💪", "🎧", "❤️", "⭐️", "💧",
        "🔥", "🌙", "☀️", "🍀", "🚀", "📅"
    ]
    
    init(store: EventStore, editingEvent: TimeEvent?, onSaved: @escaping (UUID) -> Void) {
        self.store = store
        self.editingEvent = editingEvent
        self.onSaved = onSaved
        
        _name = State(initialValue: editingEvent?.name ?? "")
        _emoji = State(initialValue: editingEvent?.emoji ?? "📚")
        _startDate = State(initialValue: editingEvent?.startDate ?? Date())
        _endDate = State(
            initialValue: editingEvent?.endDate ??
            Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        )
        _note = State(initialValue: editingEvent?.note ?? "")
        _showInWidget = State(initialValue: editingEvent?.showInWidget ?? true)
    }
    
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        endDate > startDate
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("事件外观") {
                    TextField("Emoji，例如 📚", text: $emoji)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(emojiSuggestions, id: \.self) { item in
                                Button {
                                    emoji = item
                                    Haptics.impact(.light)
                                } label: {
                                    Text(item)
                                        .font(.system(size: 28))
                                        .frame(width: 48, height: 48)
                                        .background(
                                            Circle()
                                                .fill(emoji == item ? Color.blue.opacity(0.22) : Color.gray.opacity(0.10))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                Section("事件内容") {
                    TextField("事件名称，例如 数学建模比赛", text: $name)
                    
                    DatePicker(
                        "开始时间",
                        selection: $startDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    
                    DatePicker(
                        "结束时间",
                        selection: $endDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    
                    Toggle("显示在桌面小组件", isOn: $showInWidget)
                }
                
                Section("备注") {
                    TextField("可以写目标、地点、提醒事项", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }
                
                if endDate <= startDate {
                    Section {
                        Text("结束时间必须晚于开始时间。")
                            .foregroundStyle(.red)
                    }
                }
                
                if let event = editingEvent {
                    Section {
                        Button("删除这个事件", role: .destructive) {
                            store.delete(event)
                            Haptics.notify(.success)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(editingEvent == nil ? "添加事件" : "编辑事件")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
    
    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let savedID: UUID
        
        if var event = editingEvent {
            event.name = cleanName
            event.emoji = cleanEmoji
            event.startDate = startDate
            event.endDate = endDate
            event.note = note
            event.showInWidget = showInWidget
            
            savedID = store.update(event)
        } else {
            savedID = store.add(
                name: cleanName,
                emoji: cleanEmoji,
                startDate: startDate,
                endDate: endDate,
                note: note,
                showInWidget: showInWidget
            )
        }
        
        onSaved(savedID)
        dismiss()
    }
}

// MARK: - 设置页

struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("motionStrength") private var motionStrength = 1.0
    @AppStorage("waveStrength") private var waveStrength = 1.0
    @AppStorage("hideEndedEvents") private var hideEndedEvents = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("动画") {
                    VStack(alignment: .leading) {
                        Text("重力灵敏度：\(motionStrength, specifier: "%.1f")")
                        Slider(value: $motionStrength, in: 0.5...1.8, step: 0.1)
                    }
                    
                    VStack(alignment: .leading) {
                        Text("水面波动：\(waveStrength, specifier: "%.1f")")
                        Slider(value: $waveStrength, in: 0.5...1.8, step: 0.1)
                    }
                }
                
                Section("交互") {
                    Toggle("震动反馈", isOn: $hapticsEnabled)
                    Toggle("隐藏已结束事件", isOn: $hideEndedEvents)
                }
                
                Section("说明") {
                    Text("动画会在 App 进入后台时自动暂停，回到前台后恢复。高刷新效果取决于你的 iPhone 屏幕刷新率。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
