import Foundation

/// Radio RAM (radioram.pl) — server-rendered HTML.
/// Schedule: /broadcasts/view/<1-7>/<day slug>, rows `tr.row` with td.start, strong (title), span.employee.
/// Playlist: /playedsongs/index/0 — table rows: time, "Surname, Name", title, duration (oldest first).
struct RadioRAMGuide: StationGuide {
    func fetchSchedule(for day: Date) async throws -> [GuideProgram] {
        let weekday = Guide.calendar.component(.weekday, from: day)   // 1 = Sunday
        let mondayBased = (weekday + 5) % 7 + 1
        let html = try await Guide.text("https://radioram.pl/broadcasts/view/\(mondayBased)/\(Guide.polishDaySlug(day))")
        let rows = Guide.matches(#"<td class="start">\s*(\d{1,2}:\d{2})\s*</td>(.*?)</tr>"#, in: html)
        let programs = rows.compactMap { r -> GuideProgram? in
            guard let start = Guide.time(r[1], on: day),
                  let title = Guide.matches(#"<strong>(.*?)</strong>"#, in: r[2]).first?[1] else { return nil }
            let hosts = Guide.matches(#"class="employee"><a[^>]*>(.*?)</a>"#, in: r[2]).map { Guide.clean(Guide.unescapeHTML($0[1])) }
            let desc = Guide.matches(#"<div class="desc">(.*?)</div>"#, in: r[2]).first?[1]
            return GuideProgram(title: Guide.clean(Guide.unescapeHTML(title)), start: start, end: nil,
                                host: hosts.isEmpty ? nil : hosts.joined(separator: ", "),
                                description: Guide.plainText(desc))
        }
        guard !programs.isEmpty else { throw GuideError.badResponse("RAM schedule") }
        return Guide.normalize(programs)
    }

    func fetchTracks() async throws -> [GuideTrack] {
        let html = try await Guide.text("https://radioram.pl/playedsongs/index/0")
        let rows = Guide.matches(#"<td>\s*(\d{2}:\d{2}):\d{2}\s*</td>\s*<td>(.*?)</td>\s*<td>(.*?)</td>"#, in: html)
        return rows.reversed().map {
            GuideTrack(artist: Self.flipName(Guide.clean(Guide.unescapeHTML($0[2]))),
                       title: Guide.clean(Guide.unescapeHTML($0[3])), time: $0[1])
        }
    }

    /// "Podsiadło, Dawid" → "Dawid Podsiadło" (only for the simple one-comma form).
    private static func flipName(_ s: String) -> String {
        let parts = s.components(separatedBy: ", ")
        guard parts.count == 2, !parts[1].contains(" & ") else { return s }
        return "\(parts[1]) \(parts[0])"
    }
}
