import Foundation

/// One programme (audycja) in a station's daily schedule.
struct GuideProgram: Codable, Equatable, Identifiable {
    var id: String { "\(start.timeIntervalSince1970)|\(title)" }
    let title: String
    let start: Date
    /// nil when the source gives only start times; the next programme's start is used instead.
    var end: Date?
    var host: String?
    /// Short description of the show, when the schedule source includes it.
    var description: String? = nil
    /// Page/API with the description, fetched lazily (Kampus, Nowy Świat, 357).
    var detailURL: String? = nil
}

/// One recently played track, newest first in lists.
struct GuideTrack: Codable, Equatable, Identifiable {
    var id: String { "\(time ?? "")|\(artist)|\(title)" }
    let artist: String
    let title: String
    var time: String?     // "HH:MM" local time, when the source provides it

    var display: String { artist.isEmpty ? title : "\(artist) - \(title)" }
}

/// A station's online schedule/playlist source. Each implementation talks to one station's website/API.
protocol StationGuide {
    /// Programmes of the given day (Europe/Warsaw), sorted by start.
    func fetchSchedule(for day: Date) async throws -> [GuideProgram]
    /// Recently played tracks, newest first. Empty when the station publishes none.
    func fetchTracks() async throws -> [GuideTrack]
    /// Description of a show from its `detailURL`; nil when the page has none.
    func fetchDescription(_ url: String) async throws -> String?
}

extension StationGuide {
    func fetchTracks() async throws -> [GuideTrack] { [] }
    func fetchDescription(_ url: String) async throws -> String? { nil }
}

enum GuideError: LocalizedError {
    case badResponse(String)
    var errorDescription: String? {
        if case .badResponse(let s) = self { return L("Unexpected response: %@", s) }
        return nil
    }
}

// MARK: - Shared helpers

enum Guide {
    static let warsaw = TimeZone(identifier: "Europe/Warsaw")!

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = warsaw
        return c
    }

    static func startOfToday(_ now: Date = Date()) -> Date {
        calendar.startOfDay(for: now)
    }

    static func isToday(_ day: Date) -> Bool { calendar.isDateInToday(day) }

    /// "dd.MM", as used in day tabs on station websites.
    static func dayMonth(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = warsaw
        f.dateFormat = "dd.MM"
        return f.string(from: date)
    }

    /// "HH:MM" on the given day (Warsaw time).
    static func time(_ hhmm: String, on day: Date) -> Date? {
        let parts = hhmm.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = h
        comps.minute = m
        return calendar.date(from: comps)
    }

    static func hhmm(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = warsaw
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func isoDay(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.timeZone = warsaw
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Polish weekday slug without diacritics, e.g. "sroda".
    static func polishDaySlug(_ date: Date = Date()) -> String {
        let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
        return ["niedziela", "poniedzialek", "wtorek", "sroda", "czwartek", "piatek", "sobota"][weekday - 1]
    }

    /// Fills missing end times with the next programme's start and fixes overnight wrap-around.
    /// HTML or plain text → one clean paragraph for a tooltip (nil when empty), capped at `limit` characters.
    static func plainText(_ html: String?, limit: Int = 400) -> String? {
        guard var s = html else { return nil }
        s = s.replacingOccurrences(of: #"<br\s*/?>|</p>|</h\d>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = unescapeHTML(s)
        // Remaining numeric entities (&#160; etc.).
        while let r = s.range(of: #"&#(\d+);"#, options: .regularExpression) {
            let code = Int(s[r].dropFirst(2).dropLast()) ?? 32
            s.replaceSubrange(r, with: String(UnicodeScalar(UInt32(code)).map(Character.init) ?? " "))
        }
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        s = clean(s)
        guard !s.isEmpty else { return nil }
        if s.count > limit {
            let cut = s.prefix(limit)
            s = (cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? String(cut)) + "…"
        }
        return s
    }

    static func normalize(_ programs: [GuideProgram]) -> [GuideProgram] {
        var sorted = programs.sorted { $0.start < $1.start }
        for i in sorted.indices {
            if let end = sorted[i].end, end <= sorted[i].start {
                sorted[i].end = calendar.date(byAdding: .day, value: 1, to: end)
            }
            if sorted[i].end == nil, i + 1 < sorted.count {
                sorted[i].end = sorted[i + 1].start
            }
        }
        // Drop exact duplicates some sources return.
        var seen = Set<String>()
        return sorted.filter { seen.insert($0.id).inserted }
    }

    // MARK: HTTP

    static func data(_ urlString: String, headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw GuideError.badResponse(urlString) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("FSAPIRadioController/2.0 (macOS)", forHTTPHeaderField: "User-Agent")
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GuideError.badResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    static func json(_ urlString: String, headers: [String: String] = [:]) async throws -> Any {
        let d = try await data(urlString, headers: headers)
        if let obj = try? JSONSerialization.jsonObject(with: d) { return obj }
        // Some endpoints append an HTML footer after the JSON; parse the JSON prefix only.
        guard let text = String(data: d, encoding: .utf8),
              let first = text.firstIndex(where: { $0 == "[" || $0 == "{" }) else {
            throw GuideError.badResponse("no JSON")
        }
        let closing: Character = text[first] == "[" ? "]" : "}"
        guard let last = text.lastIndex(of: closing), last > first,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[first...last].utf8)) else {
            throw GuideError.badResponse("no JSON")
        }
        return obj
    }

    static func text(_ urlString: String) async throws -> String {
        String(decoding: try await data(urlString), as: UTF8.self)
    }

    // MARK: Text

    /// Trims and collapses internal whitespace runs ("Paweł  Gołębski" → "Paweł Gołębski").
    static func clean(_ s: String?) -> String {
        (s ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func unescapeHTML(_ s: String) -> String {
        var out = s
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#039;": "'", "&apos;": "'",
                        "&nbsp;": " ", "&#8211;": "–", "&ndash;": "–", "&#8222;": "„", "&#8221;": "”"]
        for (k, v) in entities { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    /// Strips tags, turning block ends into newlines; returns trimmed non-empty lines.
    static func htmlLines(_ html: String) -> [String] {
        var t = html.replacingOccurrences(of: "<(br|/p|/li|/h\\d|/div)[^>]*>", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return unescapeHTML(t).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Splits "Artist - Title" (first " - ").
    static func splitArtistTitle(_ s: String) -> GuideTrack? {
        let t = clean(s)
        guard !t.isEmpty else { return nil }
        if let r = t.range(of: " - ") {
            return GuideTrack(artist: clean(String(t[..<r.lowerBound])), title: clean(String(t[r.upperBound...])))
        }
        return GuideTrack(artist: "", title: t)
    }

    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }
}
