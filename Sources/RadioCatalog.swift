import Foundation

struct CatalogStation: Equatable, Codable {
    let key: Int
    let name: String
}

enum CatalogError: LocalizedError {
    case noSession
    case unreachable
    case menuItemMissing(String)
    case notPlayable(String)

    var errorDescription: String? {
        switch self {
        case .noSession: return L("The radio rejected the control session.")
        case .unreachable: return L("The radio doesn't respond.")
        case .menuItemMissing(let n): return L("Couldn't find “%@” in the radio menu.", n)
        case .notPlayable(let n): return L("The radio can't play “%@”.", n)
        }
    }
}

/// Browses the Napoli's own internet-radio catalog through FSAPI navigation (the same way UNDOK does),
/// so every station found here is playable on the radio.
///
/// Verified menu structure (Napoli, FS2340 firmware V4.5.6):
///   root → "Znajdź" → filter screen: "Źródło: …", "Gatunek: …", "Język: …", "Pokaż stacje (N)"
///   Źródło → "Europa" → "Polska" → "Wszystko z: Polska"   (returns to the filter screen)
///   Gatunek → "<genre>" → "Wszystko w: <genre>"            (returns to the filter screen)
///   station entry (type 0) → navigate → item of type 1 → selectItem plays it.
/// Item keys shift between screens, so navigation always matches items by name.
actor RadioCatalog {
    static let genres = [
        "College", "Country", "Dekady", "Easy listening", "Elektroniczna muzyka taneczna",
        "Freeform-Eclectic", "Hip-Hop Rap", "Jazz", "Miejski", "Muzyka folkowa", "Muzyka poważna",
        "Muzyka świata-Tradycyjny", "Oldies", "Pop", "Publiczny-Społeczność", "Reggae", "Rock",
        "Ścieżka dźwiękowa", "Top 40", "Wiadomości", "Sport", "Komedia", "Dzieci", "Edukacja",
        "Musical", "Old Time Radio", "Sezonowy", "Muzyka religijna", "Religia"
    ]

    private let host: String
    private let pin: String
    private var sid: String?
    /// Filter whose result list the radio's navigation currently shows (nil = unknown).
    private var currentFilter: (genre: String?, poland: Bool)?

    init(host: String, pin: String) {
        self.host = host
        self.pin = pin
    }

    // MARK: Public API

    func stations(genre: String?, polandOnly: Bool, limit: Int,
                  progress: @Sendable (String) -> Void) async throws -> (total: Int, items: [CatalogStation]) {
        do {
            return try await stationsOnce(genre: genre, polandOnly: polandOnly, limit: limit, progress: progress)
        } catch CatalogError.noSession {
            // Another client (UNDOK, preset selection) took the radio's only session; start over.
            return try await stationsOnce(genre: genre, polandOnly: polandOnly, limit: limit, progress: progress)
        }
    }

    private func stationsOnce(genre: String?, polandOnly: Bool, limit: Int,
                              progress: @Sendable (String) -> Void) async throws -> (total: Int, items: [CatalogStation]) {
        try await openFilteredList(genre: genre, polandOnly: polandOnly, progress: progress)
        let total = Int(try await get("netRemote.nav.numItems") ?? "0") ?? 0
        let target = min(limit, total)
        progress(L("Loading the station list from the radio… %d/%d", 0, target))
        let items = try await list(max: target, onPage: { count in progress(L("Loading the station list from the radio… %d/%d", count, target)) })
        return (total, items.map { CatalogStation(key: $0.key, name: $0.name) })
    }

    func play(_ station: CatalogStation, genre: String?, polandOnly: Bool,
              progress: @Sendable (String) -> Void) async throws {
        do {
            try await playOnce(station, genre: genre, polandOnly: polandOnly, progress: progress)
        } catch CatalogError.noSession {
            // Session was taken over by another client; replay the whole path with a fresh one.
            currentFilter = nil
            try await playOnce(station, genre: genre, polandOnly: polandOnly, progress: progress)
        }
    }

    private func playOnce(_ station: CatalogStation, genre: String?, polandOnly: Bool,
                          progress: @Sendable (String) -> Void) async throws {
        // Re-open the list unless the radio is still showing exactly this result list.
        let stillThere = currentFilter.map { $0.genre == genre && $0.poland == polandOnly } ?? false
        if !stillThere {
            try await openFilteredList(genre: genre, polandOnly: polandOnly, progress: progress)
        }
        // The list supports random access, so jump straight to the cached key and verify the name.
        var key = station.key
        if try await nameAt(key: key) != station.name {
            let nearby = try await list(startAfter: max(-1, key - 31), max: 60)
            guard let match = nearby.first(where: { $0.name == station.name }) else {
                throw CatalogError.menuItemMissing(station.name)
            }
            key = match.key
        }
        progress(L("Starting “%@” on the radio…", station.name))
        try await navigate(key)
        currentFilter = nil
        let entries = try await list(max: 30)
        guard let playable = entries.first(where: { $0.type == 1 }) else {
            throw CatalogError.notPlayable(station.name)
        }
        guard try await set("netRemote.nav.action.selectItem", "\(playable.key)") else {
            throw CatalogError.notPlayable(station.name)
        }
    }

    // MARK: Presets (radio memory slots)

    /// All preset slots; empty slots have an empty name. The Napoli has 30 slots.
    func presets() async throws -> [(slot: Int, name: String)] {
        do { return try await presetsOnce() } catch CatalogError.noSession { return try await presetsOnce() }
    }

    private func presetsOnce() async throws -> [(slot: Int, name: String)] {
        try await ensureSession()
        _ = try await set("netRemote.nav.state", "1")
        for _ in 0..<6 {
            let xml = try await request("LIST_GET_NEXT/netRemote.nav.presets/-1", ["maxItems": "60"])
            if xml.contains("FS_OK") {
                return Guide.matches(#"<item key="(\d+)">(.*?)</item>"#, in: xml).map { m in
                    (Int(m[1]) ?? -1, Self.unescape(Self.field("name", in: m[2]) ?? ""))
                }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw CatalogError.unreachable
    }

    /// Stores the currently playing station in `slot` (overwrites), like holding a preset key on the remote.
    func saveCurrentStation(toSlot slot: Int) async throws {
        try await ensureSession()
        guard try await set("netRemote.play.addPreset", "\(slot)") else { throw CatalogError.notPlayable("preset \(slot + 1)") }
    }

    // MARK: Menu walking

    private func openFilteredList(genre: String?, polandOnly: Bool, progress: @Sendable (String) -> Void) async throws {
        currentFilter = nil
        try await ensureSession()
        progress(L("Switching the radio to Internet radio…"))
        if try await get("netRemote.sys.power") != "1" {
            _ = try await set("netRemote.sys.power", "1")
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if Int(try await get("netRemote.sys.mode") ?? "") != 0 {
            _ = try await set("netRemote.sys.mode", "0")
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        try await resetToRoot()
        try await go("Znajdź") { $0 == "Znajdź" }
        if polandOnly {
            progress(L("Setting source: Poland…"))
            try await go("Źródło") { $0.hasPrefix("Źródło") }
            try await go("Europa") { $0 == "Europa" }
            try await go("Polska") { $0 == "Polska" }
            try await go("Wszystko z: Polska") { $0.hasPrefix("Wszystko z") }
        }
        if let genre = genre {
            progress(L("Setting genre: %@…", genre))
            try await go("Gatunek") { $0.hasPrefix("Gatunek") }
            try await go(genre) { $0 == genre }
            try await go("Wszystko w: \(genre)") { $0.hasPrefix("Wszystko w") }
        }
        progress(L("The radio is searching for stations…"))
        try await go("Pokaż stacje") { $0.hasPrefix("Pokaż stacje") }
        currentFilter = (genre, polandOnly)
    }

    private func resetToRoot() async throws {
        _ = try await set("netRemote.nav.state", "0")
        guard try await set("netRemote.nav.state", "1") else { throw CatalogError.noSession }
        try await waitReady()
    }

    /// Finds an item by name on the current screen and enters it. Retries because the
    /// radio sometimes reports "ready" before the new list is populated.
    private func go(_ label: String, _ match: @escaping (String) -> Bool) async throws {
        for attempt in 0..<5 {
            try Task.checkCancellation()
            // Page only until the item shows up; some screens (e.g. Polish cities) are long.
            let items = try await list(max: 300, stopWhen: { match($0.name) })
            if let item = items.first(where: { match($0.name) }) {
                try await navigate(item.key)
                return
            }
            try await Task.sleep(nanoseconds: UInt64(400_000_000 + attempt * 300_000_000))
        }
        throw CatalogError.menuItemMissing(label)
    }

    private func navigate(_ key: Int) async throws {
        // The radio sometimes reports "ready" before a screen has really loaded and then
        // rejects the next navigate with FS_FAIL; give it a moment and retry.
        for attempt in 0..<5 {
            try Task.checkCancellation()
            if try await set("netRemote.nav.action.navigate", "\(key)") {
                try await waitReady()
                return
            }
            try await Task.sleep(nanoseconds: UInt64(500_000_000 + attempt * 300_000_000))
        }
        throw CatalogError.menuItemMissing("#\(key)")
    }

    /// nav.status: 0 = busy, 1 = ready, 4 = ready at root, 2/3 = failure.
    private func waitReady() async throws {
        // Status may still show the previous screen's "ready" right after an action.
        try await Task.sleep(nanoseconds: 300_000_000)
        for _ in 0..<60 {
            try Task.checkCancellation()
            let s = try await get("netRemote.nav.status")
            if let s = s, s != "0" { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw CatalogError.unreachable
    }

    /// Reads one item by key; the radio answers FS_NODE_BLOCKED while it fetches that chunk.
    private func nameAt(key: Int) async throws -> String? {
        for _ in 0..<20 {
            try Task.checkCancellation()
            let page = try await listPage(start: key - 1, maxItems: 1)
            if let item = page.first(where: { $0.key == key }) { return item.name }
            if !page.isEmpty { return nil }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    // MARK: List paging (the radio returns at most 30 items per request)

    private struct NavItem { let key: Int; let name: String; let type: Int }

    private func list(startAfter: Int = -1, max: Int, stopWhen: ((NavItem) -> Bool)? = nil,
                      onPage: (Int) -> Void = { _ in }) async throws -> [NavItem] {
        var out: [NavItem] = []
        var start = startAfter
        var emptyRetries = 0
        while out.count < max {
            try Task.checkCancellation()
            let page = try await listPage(start: start, maxItems: Swift.min(100, max - out.count))
            if page.isEmpty {
                // The radio may still be fetching the next chunk from its catalog server.
                emptyRetries += 1
                if emptyRetries > 20 { break }   // up to ~10 s per chunk
                try await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            emptyRetries = 0
            out.append(contentsOf: page)
            start = page.last!.key
            onPage(out.count)
            if let stop = stopWhen, page.contains(where: stop) { break }
        }
        return out
    }

    private func listPage(start: Int, maxItems: Int) async throws -> [NavItem] {
        let xml = try await request("LIST_GET_NEXT/netRemote.nav.list/\(start)", ["maxItems": "\(maxItems)"])
        guard xml.contains("FS_OK") else { return [] }
        var items: [NavItem] = []
        let itemRegex = try NSRegularExpression(pattern: "<item key=\"(\\d+)\">(.*?)</item>", options: [.dotMatchesLineSeparators])
        let ns = xml as NSString
        for m in itemRegex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let key = Int(ns.substring(with: m.range(at: 1))) ?? -1
            let body = ns.substring(with: m.range(at: 2))
            let name = Self.field("name", in: body).map(Self.unescape) ?? ""
            let type = Int(Self.field("type", in: body) ?? "") ?? -1
            items.append(NavItem(key: key, name: name, type: type))
        }
        return items
    }

    private static func field(_ name: String, in body: String) -> String? {
        let pattern = "<field name=\"\(name)\"><\\w+>(.*?)</\\w+></field>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) else { return nil }
        return (body as NSString).substring(with: m.range(at: 1))
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: HTTP / session

    private func ensureSession() async throws {
        let xml = try await request("CREATE_SESSION", [:], withSID: false)
        guard let r = xml.range(of: "<sessionId>"), let e = xml.range(of: "</sessionId>") else {
            throw CatalogError.noSession
        }
        sid = String(xml[r.upperBound..<e.lowerBound])
    }

    private func get(_ node: String) async throws -> String? {
        let xml = try await request("GET/\(node)", [:])
        guard xml.contains("FS_OK") else { return nil }
        let re = try NSRegularExpression(pattern: "<value><\\w+>(.*?)</\\w+></value>", options: [.dotMatchesLineSeparators])
        let ns = xml as NSString
        guard let m = re.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private func set(_ node: String, _ value: String) async throws -> Bool {
        try await request("SET/\(node)", ["value": value]).contains("FS_OK")
    }

    private func request(_ path: String, _ params: [String: String], withSID: Bool = true) async throws -> String {
        var comps = URLComponents(string: "http://\(host)/fsapi/\(path)")
        var q = [URLQueryItem(name: "pin", value: pin)]
        if withSID, let sid = sid { q.append(URLQueryItem(name: "sid", value: sid)) }
        q += params.map { URLQueryItem(name: $0.key, value: $0.value) }
        comps?.queryItems = q
        guard let url = comps?.url else { throw CatalogError.unreachable }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CatalogError.unreachable
        }
        // Another client (UNDOK, preset selection) opened a new session; ours is gone.
        if (response as? HTTPURLResponse)?.statusCode == 404, withSID {
            throw CatalogError.noSession
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
