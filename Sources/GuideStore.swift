import Foundation
import Combine

/// Schedules ("ramówki") and recent tracks for stations, resolved by station *name* (not preset slot),
/// so reordering presets on the radio never mixes up guides. Entries are cached per guide and day.
final class GuideStore: ObservableObject {
    static let shared = GuideStore()

    struct Entry: Codable {
        var schedule: [GuideProgram] = []
        var tracks: [GuideTrack] = []
        var scheduleFetched: Date?
        var tracksFetched: Date?
        var error: String?
    }

    /// (guide id, name fragments matched case-insensitively against the preset name, guide)
    private static let registry: [(id: String, patterns: [String], guide: StationGuide)] = [
        ("kampus", ["kampus"], KampusGuide()),
        ("czworka", ["czwórka", "czworka"], CzworkaGuide()),
        ("luz", ["radio luz"], LuzGuide()),
        ("ram", ["radio ram"], RadioRAMGuide()),
        ("nowyswiat", ["nowy świat", "nowy swiat"], NowySwiatGuide()),
        ("lodz", ["radio łódź", "radio lodz"], RadioLodzGuide()),
        ("off", ["off radio"], OffRadioGuide()),
        ("ukg", ["ukg radio"], UKGGuide()),
        ("357", ["radio 357"], Radio357Guide())
    ]

    /// Guides whose today-schedule may come from a short now/next fallback; refresh those often.
    private let rollingGuides: Set<String> = ["luz", "357"]

    @Published private(set) var entries: [String: Entry] = [:]     // key: "<guideId>|yyyy-MM-dd"
    @Published var expanded: Int?                                   // preset slot expanded in the panel
    /// Lazily fetched show descriptions keyed by `detailURL` ("" = the page has none).
    @Published private(set) var descriptions: [String: Described] = [:]

    /// Show whose description is unfolded (program id); one at a time.
    @Published var openDescription: String?

    struct Described: Codable {
        var text: String
        var fetched: Date
    }

    private var timer: Timer?
    private var inFlight = Set<String>()
    private var descInFlight = Set<String>()

    private init() {
        entries = Self.loadCache()
        descriptions = Self.loadDescriptions()
    }

    // MARK: Lookup

    static func guideId(forStationName name: String) -> String? {
        let n = name.lowercased()
        return registry.first { $0.patterns.contains { n.contains($0) } }?.id
    }

    private static func guide(_ id: String) -> StationGuide? { registry.first { $0.id == id }?.guide }

    private static func key(_ id: String, _ day: Date) -> String { "\(id)|\(Guide.isoDay(day))" }

    func hasGuide(_ station: PresetStation) -> Bool { Self.guideId(forStationName: station.name) != nil }

    func entry(_ station: PresetStation, day: Date = Date()) -> Entry? {
        Self.guideId(forStationName: station.name).flatMap { entries[Self.key($0, day)] }
    }

    func current(_ station: PresetStation, at now: Date = Date()) -> GuideProgram? {
        entry(station, day: now)?.schedule.last { $0.start <= now && ($0.end ?? .distantFuture) > now }
    }

    func next(_ station: PresetStation, at now: Date = Date()) -> GuideProgram? {
        entry(station, day: now)?.schedule.first { $0.start > now }
    }

    func schedule(_ station: PresetStation, day: Date) -> [GuideProgram] {
        entry(station, day: day)?.schedule ?? []
    }

    // MARK: Show descriptions

    /// Description for the tooltip; nil while unknown (`hasDescription` tells whether to show the icon).
    func description(_ program: GuideProgram) -> String? {
        if let d = program.description { return d }
        guard let url = program.detailURL, let d = descriptions[url], !d.text.isEmpty else { return nil }
        return d.text
    }

    /// True when the show has a description or one may still be fetched.
    func hasDescription(_ program: GuideProgram) -> Bool {
        if program.description != nil { return true }
        guard let url = program.detailURL else { return false }
        return descriptions[url].map { !$0.text.isEmpty } ?? true
    }

    /// Fetches missing descriptions one by one (polite to the station sites); cached for a week.
    func loadDescriptions(_ station: PresetStation, programs: [GuideProgram]) {
        guard let id = Self.guideId(forStationName: station.name), let g = Self.guide(id) else { return }
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let urls = programs.compactMap(\.detailURL)
            .filter { url in !descInFlight.contains(url) && (descriptions[url].map { $0.fetched < weekAgo } ?? true) }
        let unique = Array(NSOrderedSet(array: urls)) as? [String] ?? []
        guard !unique.isEmpty else { return }
        unique.forEach { descInFlight.insert($0) }
        Task { [weak self] in
            for url in unique {
                var text: String??
                do {
                    text = .some(try await g.fetchDescription(url))
                } catch GuideError.badResponse(let m) where m.hasPrefix("HTTP 4") {
                    text = .some(nil)           // broken link on the station's side: remember "no description"
                } catch {
                    text = nil                  // network trouble: try again later
                }
                let result = text
                await MainActor.run { [weak self] in self?.applyDescription(url: url, text: result) }
            }
        }
    }

    private func applyDescription(url: String, text: String??) {
        descInFlight.remove(url)
        // Network error (outer nil) → don't cache, try again next time; known-empty → cache "".
        guard let value = text else { return }
        descriptions[url] = Described(text: value ?? "", fetched: Date())
        Self.saveDescriptions(descriptions)
    }

    // MARK: Lifecycle (driven by the panel / schedule window)

    func panelOpened(stations: [PresetStation]) {
        refreshSchedules(stations: stations, day: Date())
        if let slot = expanded, let s = stations.first(where: { $0.id == slot }) { refreshTracks(s) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.objectWillChange.send()          // "now" moves on even without new data
            self.refreshSchedules(stations: stations, day: Date())
            if let slot = self.expanded, let s = stations.first(where: { $0.id == slot }) { self.refreshTracks(s) }
        }
    }

    func panelClosed() {
        timer?.invalidate()
        timer = nil
    }

    func toggleExpanded(_ station: PresetStation) {
        expanded = expanded == station.id ? nil : station.id
        if expanded != nil { refreshTracks(station) }
    }

    // MARK: Fetching

    func refreshSchedules(stations: [PresetStation], day: Date) {
        let isToday = Guide.isToday(day)
        for id in Set(stations.compactMap { Self.guideId(forStationName: $0.name) }) {
            let k = Self.key(id, day)
            let fetched = entries[k]?.scheduleFetched
            let maxAge: TimeInterval = (isToday && rollingGuides.contains(id)) ? 10 * 60 : 3 * 3600
            let stale = fetched.map { Date().timeIntervalSince($0) > maxAge } ?? true
            if stale, let g = Self.guide(id) { fetch(k, g, day: day, tracks: false) }
        }
    }

    private func refreshTracks(_ station: PresetStation) {
        guard let id = Self.guideId(forStationName: station.name), let g = Self.guide(id) else { return }
        let k = Self.key(id, Date())
        if let f = entries[k]?.tracksFetched, Date().timeIntervalSince(f) < 50 { return }
        fetch(k, g, day: Date(), tracks: true)
    }

    private func fetch(_ key: String, _ guide: StationGuide, day: Date, tracks: Bool) {
        let flight = "\(key)-\(tracks)"
        guard !inFlight.contains(flight) else { return }
        inFlight.insert(flight)
        Task { [weak self] in
            var schedule: [GuideProgram]?
            var list: [GuideTrack]?
            var failure: String?
            do {
                if tracks { list = try await guide.fetchTracks() } else { schedule = try await guide.fetchSchedule(for: day) }
            } catch {
                failure = tracks ? L("Couldn't load the playlist") : L("Couldn't load the schedule")
            }
            let (newSchedule, newTracks, newFailure) = (schedule, list, failure)
            await MainActor.run { [weak self] in
                self?.apply(key: key, flight: flight, schedule: newSchedule, tracks: newTracks, failure: newFailure)
            }
        }
    }

    private func apply(key: String, flight: String, schedule: [GuideProgram]?, tracks: [GuideTrack]?, failure: String?) {
        inFlight.remove(flight)
        var e = entries[key] ?? Entry()
        if let s = schedule { e.schedule = s; e.scheduleFetched = Date(); e.error = nil }
        if let l = tracks { e.tracks = l; e.tracksFetched = Date() }
        // A failed playlist fetch keeps the schedule visible; only a failed schedule shows the error.
        if let err = failure, tracks == nil, schedule == nil, e.schedule.isEmpty {
            e.error = err
            e.scheduleFetched = Date()      // don't hammer a broken source every minute
        }
        entries[key] = e
        Self.saveCache(entries)
        // Prefetch lazily loaded descriptions so tooltips are ready when hovered.
        if let s = schedule, s.contains(where: { $0.detailURL != nil }),
           let id = key.split(separator: "|").first.map(String.init),
           let name = Self.registry.first(where: { $0.id == id })?.patterns.first {
            loadDescriptions(PresetStation(id: -1, name: name), programs: s)
        }
    }

    // MARK: Disk cache (so the panel shows something instantly)

    private static var cacheURL: URL {
        let dir = AppSettings.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("guides-v3.json")
    }

    private static func loadCache() -> [String: Entry] {
        guard let data = try? Data(contentsOf: cacheURL),
              let raw = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        // Keep only today and later.
        let today = Guide.isoDay()
        return raw.filter { ($0.key.split(separator: "|").last.map(String.init) ?? "") >= today }
    }

    private static var descriptionsURL: URL { cacheURL.deletingLastPathComponent().appendingPathComponent("descriptions.json") }

    private static func loadDescriptions() -> [String: Described] {
        guard let data = try? Data(contentsOf: descriptionsURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Described].self, from: data)) ?? [:]
    }

    private static func saveDescriptions(_ d: [String: Described]) {
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: descriptionsURL, options: .atomic) }
    }

    private static func saveCache(_ entries: [String: Entry]) {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: cacheURL, options: .atomic) }
    }
}
