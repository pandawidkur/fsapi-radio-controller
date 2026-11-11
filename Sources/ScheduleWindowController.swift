import AppKit
import SwiftUI
import Combine

/// "Ramówka ulubionych": one timeline of all favourite stations for today or tomorrow.
/// Ticking a show plans it; the homelab turns the radio on and plays the station at that time.
final class ScheduleWindowController: NSWindowController, NSWindowDelegate {
    private let state = ScheduleViewState()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L("Favourites schedule")
        window.minSize = NSSize(width: 520, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: ScheduleView(
            state: state, guides: GuideStore.shared, presets: PresetStore.shared, plans: PlanStore.shared))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() { state.reload() }

    func windowWillClose(_ notification: Notification) { state.stop() }
}

final class ScheduleViewState: ObservableObject {
    @Published var dayOffset = 0 { didSet { reload() } }      // 0 = today, 1 = tomorrow
    @Published var hidePast = true
    @Published var now = Date()
    private var timer: Timer?

    var day: Date { Guide.calendar.date(byAdding: .day, value: dayOffset, to: Guide.startOfToday()) ?? Date() }

    func reload() {
        GuideStore.shared.refreshSchedules(stations: PresetStore.shared.favourites, day: day)
        if !PlanStore.shared.plans.isEmpty { PlanStore.shared.refreshStatus() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.now = Date()
            GuideStore.shared.refreshSchedules(stations: PresetStore.shared.favourites, day: self.day)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

private struct ScheduleItem: Identifiable {
    let station: PresetStation
    let program: GuideProgram
    var id: String { "\(station.id)|\(program.start.timeIntervalSince1970)" }
}

private struct ScheduleView: View {
    @ObservedObject var state: ScheduleViewState
    @ObservedObject var guides: GuideStore
    @ObservedObject var presets: PresetStore
    @ObservedObject var plans: PlanStore

    private var items: [ScheduleItem] {
        presets.favourites
            .flatMap { s in guides.schedule(s, day: state.day).map { ScheduleItem(station: s, program: $0) } }
            .filter { !state.hidePast || ($0.program.end ?? $0.program.start.addingTimeInterval(3600)) > state.now }
            .sorted { ($0.program.start, $0.station.id) < ($1.program.start, $1.station.id) }
    }

    /// Favourites without a schedule for the chosen day (no online guide, still loading or failed).
    private var missing: [String] {
        presets.favourites.compactMap { s in
            guard guides.schedule(s, day: state.day).isEmpty else { return nil }
            if !guides.hasGuide(s) { return "\(s.shortName): " + L("no online schedule") }
            if let err = guides.entry(s, day: state.day)?.error { return "\(s.shortName): \(err.lowercased())" }
            return "\(s.shortName): " + L("loading…")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar.padding(12)
            Divider()
            List {
                ForEach(items) { item in row(item) }
                if !missing.isEmpty {
                    Text(missing.joined(separator: " · "))
                        .font(.caption).foregroundColor(.secondary)
                        .padding(.top, 6)
                }
            }
            Divider()
            footer.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onAppear { state.reload() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $state.dayOffset) {
                Text(L("Today %@", Guide.dayMonth(Date()))).tag(0)
                Text(L("Tomorrow %@", Guide.dayMonth(Date().addingTimeInterval(86400)))).tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            Toggle(L("Hide finished"), isOn: $state.hidePast)
            Spacer()
            Text(L("Tick a show — the radio turns itself on."))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private func row(_ item: ScheduleItem) -> some View {
        let p = item.program
        let started = p.start <= state.now
        let onAir = started && (p.end ?? .distantFuture) > state.now
        let planned = plans.isPlanned(station: item.station, program: p)
        return VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { planned }, set: { _ in plans.toggle(station: item.station, program: p) }))
                .labelsHidden()
                .disabled(!AppSettings.shared.isSchedulerEnabled || (started && !planned))
                .help(started ? L("The show has already started or ended") : L("Turn the radio on for this show"))
            Text("\(Guide.hhmm(p.start))–\(p.end.map(Guide.hhmm) ?? "…")")
                .font(.callout.monospacedDigit())
                .frame(width: 92, alignment: .leading)
            Text(item.station.shortName)
                .font(.callout.weight(.semibold))
                .frame(width: 96, alignment: .leading)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title).font(.callout.weight(onAir || planned ? .semibold : .regular)).lineLimit(2)
                if let host = p.host, !host.isEmpty {
                    Text(host).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            DescriptionIcon(station: item.station, program: p, guides: guides)
            if onAir {
                Text(L("ON AIR")).font(.caption2.weight(.bold)).foregroundColor(.accentColor)
            }
        }
        DescriptionText(program: p, guides: guides).padding(.leading, 230).padding(.trailing, 24)
        }
        .padding(.vertical, 2)
        .foregroundColor(started && !onAir ? .secondary : .primary)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !AppSettings.shared.isSchedulerEnabled {
                Text(L("Scheduling is off — set up the scheduler in Settings."))
            } else {
            switch plans.syncState {
            case .idle: Text(L("Plans are sent to the scheduler."))
            case .syncing: Text(L("Sending the plan to the scheduler…"))
            case .synced(let at): Text(L("The scheduler has the current plan (%@).", Guide.hhmm(at)))
            case .failed(let msg): Text(L("Scheduler unreachable: %@", msg)).foregroundColor(.orange).lineLimit(1)
            }
            }
            Spacer()
            if let last = plans.lastEvents.first { Text(L("Last: %@", last)).lineLimit(1) }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }
}
