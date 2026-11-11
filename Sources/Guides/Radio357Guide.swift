import Foundation

/// Radio 357 — full day from the server-rendered /ramowka/ page; the player's now/playing.json
/// (current programme, next programme, current song) is the fallback and the track source.
/// HTML: day tabs `.scheduleWrap` (today's `.scheduleDate` is "Dzisiaj"), then `#scheduleList` with one
/// `.swiper-slide` per day in the same order; items `div.podcastElement` with `.podcastHour .h2`,
/// `h3.podcastSubTitle`, `.podcastAuthor`.
struct Radio357Guide: StationGuide {
    private let url = "https://stream.radio357.pl/now/playing.json"

    func fetchSchedule(for day: Date) async throws -> [GuideProgram] {
        if let full = try? await fullDay(day), !full.isEmpty { return full }
        guard Guide.isToday(day) else { throw GuideError.badResponse("357 schedule") }
        return try await nowNext()
    }

    private func fullDay(_ day: Date) async throws -> [GuideProgram] {
        let html = try await Guide.text("https://radio357.pl/ramowka/")
        let dates = Guide.matches(#"scheduleDate">\s*(.*?)\s*</div>"#, in: html).map { $0[1] }
        // Tabs are labelled "Wczoraj", "Dzisiaj", "Jutro" or "dd.MM".
        let label = Guide.isToday(day) ? "Dzisiaj" : (Guide.calendar.isDateInTomorrow(day) ? "Jutro" : Guide.dayMonth(day))
        guard let todayIndex = dates.firstIndex(of: label),
              let listStart = html.range(of: "id=\"scheduleList\"") else { throw GuideError.badResponse("357") }
        let slides = html[listStart.upperBound...].components(separatedBy: "<div class=\"swiper-slide").dropFirst()
        guard todayIndex < slides.count else { throw GuideError.badResponse("357") }
        let slide = slides[slides.startIndex + todayIndex]
        let items = slide.components(separatedBy: "class=\"podcastElement").dropFirst()
        let programs = items.compactMap { item -> GuideProgram? in
            guard let hour = Guide.matches(#"podcastHour">\s*<span class="h2">\s*(\d{1,2}:\d{2})"#, in: item).first?[1],
                  let start = Guide.time(hour, on: day),
                  let title = Guide.matches(#"podcastSubTitle[^>]*>(.*?)</h3>"#, in: item).first?[1] else { return nil }
            let host = Guide.matches(#"podcastAuthor[^>]*>(.*?)</div>"#, in: item).first.map { Guide.clean(Guide.unescapeHTML($0[1])) }
            // /podcasty/audycje/<slug> → the content API has the show description.
            let page = Guide.matches(#"href="/podcasty/audycje/([^/"]+)/?""#, in: item).first
                .map { "https://static.radio357.pl/api/content/v1/programs/\($0[1])" }
            return GuideProgram(title: Guide.clean(Guide.unescapeHTML(title)), start: start, end: nil,
                                host: (host?.isEmpty ?? true) ? nil : host, detailURL: page)
        }
        return Guide.normalize(programs)
    }

    private func nowNext() async throws -> [GuideProgram] {
        guard let json = try await Guide.json(url) as? [String: Any] else { throw GuideError.badResponse("Radio 357") }
        var programs: [GuideProgram] = []
        var currentEnd: Date?
        if let p = json["p"] as? [String: Any], let title = p["n"] as? String {
            let duration = Self.number(p["d"]) ?? 0
            let elapsed = Self.number(p["p"]) ?? 0
            // Shows start on the grid; round to 5 minutes (also keeps the id stable between refreshes).
            let rawStart = Date().addingTimeInterval(-elapsed)
            let start = Date(timeIntervalSince1970: (rawStart.timeIntervalSince1970 / 300).rounded() * 300)
            currentEnd = duration > 0 ? start.addingTimeInterval(duration) : nil
            let host = Guide.clean(p["a"] as? String)
            programs.append(GuideProgram(title: Guide.clean(title), start: start, end: currentEnd,
                                         host: host.isEmpty ? nil : host))
        }
        if let n = json["n"] as? [String: Any], let title = n["n"] as? String,
           let start = (n["t"] as? String).flatMap({ Guide.time($0, on: Date()) }) {
            programs.append(GuideProgram(title: Guide.clean(title), start: start, end: nil, host: nil))
        }
        return Guide.normalize(programs)
    }

    func fetchDescription(_ url: String) async throws -> String? {
        Guide.plainText((try await Guide.json(url) as? [String: Any])?["description"] as? String)
    }

    func fetchTracks() async throws -> [GuideTrack] {
        guard let json = try await Guide.json(url) as? [String: Any], let s = json["s"] as? String,
              !s.hasPrefix("Radio 357"), let track = Guide.splitArtistTitle(s) else { return [] }
        return [track]
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
