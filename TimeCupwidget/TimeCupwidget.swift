import WidgetKit
import SwiftUI

// MARK: - Widget Event Model

struct TCWidgetEvent: Identifiable, Codable, Equatable {
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
        String(format: "%.0f%%", progress(at: date) * 100)
    }
    
    func remainingText(at date: Date = Date()) -> String {
        if date < startDate {
            return "未开始"
        }
        
        if date >= endDate {
            return "已结束"
        }
        
        let seconds = max(Int(endDate.timeIntervalSince(date)), 0)
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        
        if days > 0 {
            return "剩 \(days)天\(hours)小时"
        } else if hours > 0 {
            return "剩 \(hours)小时\(minutes)分"
        } else {
            return "剩 \(minutes)分"
        }
    }
}

enum TCWidgetEventReader {
    static let appGroupID = "group.com.liuhua.timecup"
    static let key = "timecup_events_final_v2"
    
    static func loadEvents() -> [TCWidgetEvent] {
        guard let data = UserDefaults(suiteName: appGroupID)?.data(forKey: key) else {
            return []
        }
        
        do {
            return try JSONDecoder().decode([TCWidgetEvent].self, from: data)
                .filter { $0.showInWidget }
                .sorted { $0.endDate < $1.endDate }
        } catch {
            return []
        }
    }
}

// MARK: - Entry

struct TCYearCupEntry: TimelineEntry {
    let date: Date
    let events: [TCWidgetEvent]
}

// MARK: - Provider

struct TCYearCupProvider: TimelineProvider {
    func placeholder(in context: Context) -> TCYearCupEntry {
        TCYearCupEntry(
            date: Date(),
            events: sampleEvents
        )
    }
    
    func getSnapshot(in context: Context, completion: @escaping (TCYearCupEntry) -> Void) {
        completion(
            TCYearCupEntry(
                date: Date(),
                events: TCWidgetEventReader.loadEvents()
            )
        )
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<TCYearCupEntry>) -> Void) {
        let now = Date()
        
        let nextRefresh = Calendar.current.date(
            byAdding: .minute,
            value: 30,
            to: now
        ) ?? now.addingTimeInterval(1800)
        
        let entry = TCYearCupEntry(
            date: now,
            events: TCWidgetEventReader.loadEvents()
        )
        
        completion(
            Timeline(
                entries: [entry],
                policy: .after(nextRefresh)
            )
        )
    }
    
    private var sampleEvents: [TCWidgetEvent] {
        [
            TCWidgetEvent(
                name: "数学建模比赛",
                emoji: "🏆",
                startDate: Date().addingTimeInterval(-3600),
                endDate: Date().addingTimeInterval(86400 * 3),
                note: "",
                showInWidget: true
            ),
            TCWidgetEvent(
                name: "复习英语",
                emoji: "📚",
                startDate: Date().addingTimeInterval(-7200),
                endDate: Date().addingTimeInterval(86400),
                note: "",
                showInWidget: true
            ),
            TCWidgetEvent(
                name: "健身计划",
                emoji: "💪",
                startDate: Date().addingTimeInterval(-3600 * 6),
                endDate: Date().addingTimeInterval(86400 * 7),
                note: "",
                showInWidget: true
            )
        ]
    }
}

// MARK: - Widget

struct TCAnnualCupWidget: Widget {
    let kind = "TCAnnualCupWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: TCYearCupProvider()
        ) { entry in
            TCYearCupWidgetView(entry: entry)
        }
        .configurationDisplayName("TimeCup")
        .description("小号显示今日进度，中号显示事件，大号显示年度水杯。")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge
        ])
    }
}

// MARK: - Root View

struct TCYearCupWidgetView: View {
    let entry: TCYearCupEntry
    
    @Environment(\.widgetFamily) private var family
    
    var body: some View {
        switch family {
        case .systemLarge:
            TCLargeYearWidget(date: entry.date)
                .tcWidgetBackground()
            
        case .systemMedium:
            TCMediumEventWidget(
                date: entry.date,
                events: entry.events
            )
            .tcWidgetBackground()
            
        default:
            TCSmallTodayWidget(date: entry.date)
                .tcWidgetBackground()
        }
    }
}

// MARK: - Medium Event Widget

struct TCMediumEventWidget: View {
    let date: Date
    let events: [TCWidgetEvent]
    
    private var visibleEvents: [TCWidgetEvent] {
        Array(events.prefix(3))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            
            if visibleEvents.isEmpty {
                emptyView
            } else {
                VStack(spacing: 8) {
                    ForEach(visibleEvents) { event in
                        TCWidgetEventRow(event: event, date: date)
                    }
                }
            }
        }
        .padding()
    }
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("事件水杯")
                    .font(.headline)
                    .fontWeight(.bold)
                
                Text("正在流动的计划")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "drop.fill")
                .foregroundStyle(.blue)
        }
    }
    
    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer()
            
            Text("暂无事件")
                .font(.subheadline)
                .fontWeight(.bold)
            
            Text("在 App 里添加事件，并打开“显示在桌面小组件”。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            
            Spacer()
        }
    }
}

struct TCWidgetEventRow: View {
    let event: TCWidgetEvent
    let date: Date
    
    var body: some View {
        HStack(spacing: 9) {
            Text(event.emoji)
                .font(.title3)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                )
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.name)
                        .font(.caption)
                        .fontWeight(.bold)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(event.percentageText(at: date))
                        .font(.caption2)
                        .fontWeight(.bold)
                        .monospacedDigit()
                }
                
                ProgressView(value: event.progress(at: date))
                    .tint(.blue)
                
                Text(event.remainingText(at: date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Small Today Widget

struct TCSmallTodayWidget: View {
    let date: Date
    
    private var info: TCYearInfo {
        TCYearInfo(date: date)
    }
    
    var body: some View {
        VStack(spacing: 8) {
            Text("TimeCup")
                .font(.headline)
                .fontWeight(.bold)
            
            ZStack {
                Circle()
                    .stroke(Color.blue.opacity(0.18), lineWidth: 12)
                
                Circle()
                    .trim(from: 0, to: info.todayProgress)
                    .stroke(
                        Color.blue.opacity(0.82),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                
                VStack(spacing: 2) {
                    Text(info.todayPercentageText)
                        .font(.headline)
                        .fontWeight(.bold)
                        .monospacedDigit()
                    
                    Text("今日")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 86, height: 86)
        }
        .padding()
    }
}

// MARK: - Large Year Widget

struct TCLargeYearWidget: View {
    let date: Date
    
    private var info: TCYearInfo {
        TCYearInfo(date: date)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(info.year) 年时间水杯")
                        .font(.headline)
                        .fontWeight(.bold)
                    
                    Text("每个小杯子代表一年中的一天")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(info.completedDays)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .monospacedDigit()
                    
                    Text("/ \(info.totalDays) 天")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            TCYearCupCanvas(
                info: info,
                columns: 21,
                spacing: 3
            )
            
            HStack {
                Label("已过 / 今天：满杯", systemImage: "drop.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Text(info.yearPercentageText)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
        .padding(14)
    }
}

// MARK: - Canvas Year Cup

struct TCYearCupCanvas: View {
    let info: TCYearInfo
    let columns: Int
    let spacing: CGFloat
    
    var body: some View {
        Canvas { context, size in
            let total = info.totalDays
            let rows = Int(ceil(Double(total) / Double(columns)))
            
            let cupWidth = max(
                2,
                (size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            )
            
            let cupHeight = max(
                2,
                (size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            )
            
            for day in 1...total {
                let index = day - 1
                let col = index % columns
                let row = index / columns
                
                let rect = CGRect(
                    x: CGFloat(col) * (cupWidth + spacing),
                    y: CGFloat(row) * (cupHeight + spacing),
                    width: cupWidth,
                    height: cupHeight
                )
                
                drawCup(
                    context: &context,
                    rect: rect,
                    state: info.state(forDay: day)
                )
            }
        }
    }
    
    private func drawCup(
        context: inout GraphicsContext,
        rect: CGRect,
        state: TCDayCupState
    ) {
        let radius = min(rect.width, rect.height) * 0.28
        let cupPath = Path(roundedRect: rect, cornerRadius: radius)
        
        let backgroundColor: Color
        let waterColor: Color
        let borderColor: Color
        let borderWidth: CGFloat
        
        switch state {
        case .filled:
            backgroundColor = Color.blue.opacity(0.12)
            waterColor = Color.blue.opacity(0.72)
            borderColor = Color.blue.opacity(0.32)
            borderWidth = 0.5
            
        case .today:
            backgroundColor = Color.cyan.opacity(0.22)
            waterColor = Color.cyan.opacity(0.92)
            borderColor = Color.cyan.opacity(0.95)
            borderWidth = 1.0
            
        case .empty:
            backgroundColor = Color.secondary.opacity(0.08)
            waterColor = Color.clear
            borderColor = Color.secondary.opacity(0.18)
            borderWidth = 0.4
        }
        
        context.fill(cupPath, with: .color(backgroundColor))
        
        if state != .empty {
            let inset = max(rect.width * 0.12, 0.5)
            let waterRect = rect.insetBy(dx: inset, dy: inset)
            let waterPath = Path(
                roundedRect: waterRect,
                cornerRadius: radius * 0.75
            )
            context.fill(waterPath, with: .color(waterColor))
        }
        
        context.stroke(
            cupPath,
            with: .color(borderColor),
            lineWidth: borderWidth
        )
    }
}

// MARK: - Year Info

enum TCDayCupState {
    case filled
    case today
    case empty
}

struct TCYearInfo {
    let date: Date
    let year: Int
    let totalDays: Int
    let dayOfYear: Int
    
    init(date: Date) {
        self.date = date
        
        let calendar = Calendar.current
        self.year = calendar.component(.year, from: date)
        
        self.dayOfYear = calendar.ordinality(
            of: .day,
            in: .year,
            for: date
        ) ?? 1
        
        self.totalDays = calendar.range(
            of: .day,
            in: .year,
            for: date
        )?.count ?? 365
    }
    
    var completedDays: Int {
        min(max(dayOfYear, 1), totalDays)
    }
    
    var yearProgress: Double {
        Double(completedDays) / Double(totalDays)
    }
    
    var yearPercentageText: String {
        String(format: "%.1f%%", yearProgress * 100)
    }
    
    var todayProgress: Double {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86400)
        let total = end.timeIntervalSince(start)
        let passed = date.timeIntervalSince(start)
        
        guard total > 0 else { return 0 }
        return min(max(passed / total, 0), 1)
    }
    
    var todayPercentageText: String {
        String(format: "%.0f%%", todayProgress * 100)
    }
    
    func state(forDay day: Int) -> TCDayCupState {
        if day < dayOfYear {
            return .filled
        } else if day == dayOfYear {
            return .today
        } else {
            return .empty
        }
    }
}

// MARK: - Background

extension View {
    @ViewBuilder
    func tcWidgetBackground() -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            self.containerBackground(.fill.tertiary, for: .widget)
        } else {
            self.background(Color(.systemBackground))
        }
    }
}
