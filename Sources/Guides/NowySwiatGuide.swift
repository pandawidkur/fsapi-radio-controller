import Foundation

/// Radio Nowy Świat (nowyswiat.online) — server-rendered HTML.
/// Schedule: /ramowka has day tabs `li.rns-week-switcher-element` (today: `.rns-today-element`) and the same
/// number of day panels `li.rns-switcher-grid-element`; programmes are `li.rns-switcher-single`.
/// Playlist: /playlista — `li.rns-vote-list-element[data-date]` with h2.rns-vote-title / div.rns-vote-names.
struct NowySwiatGuide: StationGuide {
    func fetchSchedule(for day: Date) async throws -> [GuideProgram] {
        let html = try await Guide.text("https://nowyswiat.online/ramowka")
        let tabs = html.components(separatedBy: "rns-week-switcher-element").dropFirst()
        // Tabs carry the date as "dd.MM" (rolling ~10 days).
        let wanted = ">\(Guide.dayMonth(day))<"
        guard let todayIndex = tabs.firstIndex(where: { $0.prefix(200).contains(wanted) }) else {
            throw GuideError.badResponse("Nowy Świat schedule: no tab for the day")
        }
        let panels = html.components(separatedBy: "rns-switcher-grid-element\"").dropFirst()
        let offset = todayIndex - tabs.startIndex
        guard offset < panels.count else { throw GuideError.badResponse("Nowy Świat schedule: no panel for the day") }
        let panel = panels[panels.startIndex + offset]

        let programs = panel.components(separatedBy: "class=\"rns-switcher-single").dropFirst().compactMap { item -> GuideProgram? in
            guard let time = Guide.matches(#"rns-switcher-time">\s*(\d{1,2}:\d{2})"#, in: item).first?[1],
                  let start = Guide.time(time, on: day),
                  let title = Guide.matches(#"rns-switcher-title">\s*<a[^>]*>(.*?)</a>"#, in: item).first?[1] else { return nil }
            let hosts = Guide.matches(#"rns-switcher-names[^>]*>(.*?)</div>"#, in: item).first
                .map { Guide.htmlLines($0[1]).joined(separator: " ") }
                .map(Guide.clean)
            let page = Guide.matches(#"rns-switcher-title">\s*<a href="([^"]+)""#, in: item).first?[1]
            return GuideProgram(title: Guide.clean(Guide.unescapeHTML(title)), start: start, end: nil,
                                host: (hosts?.isEmpty ?? true) ? nil : hosts, detailURL: page)
        }
        guard !programs.isEmpty else { throw GuideError.badResponse("Nowy Świat schedule") }
        return Guide.normalize(programs)
    }

    /// Show page /audycje/<slug>: `div.rns-program-desc` (empty for some shows).
    func fetchDescription(_ url: String) async throws -> String? {
        let html = try await Guide.text(url)
        return Guide.matches(#"rns-program-desc[^"]*">(.*?)</div>"#, in: html).first.flatMap { Guide.plainText($0[1]) }
    }

    func fetchTracks() async throws -> [GuideTrack] {
        let html = try await Guide.text("https://nowyswiat.online/playlista")
        let items = Guide.matches(#"rns-vote-list-element" data-date="([^"]+)"(.*?)rns-vote-names">(.*?)</div>"#, in: html)
        let today = Guide.isoDay()
        return items
            .filter { $0[1].hasPrefix(today) }
            .sorted { $0[1] > $1[1] }
            .compactMap { m in
                guard let title = Guide.matches(#"rns-vote-title">(.*?)</h2>"#, in: m[2]).first?[1] else { return nil }
                let time = String(m[1].dropFirst(11).prefix(5))     // "2026-11-11 10:36:58" → "10:36"
                return GuideTrack(artist: Guide.clean(Guide.unescapeHTML(m[3])),
                                  title: Guide.clean(Guide.unescapeHTML(title)), time: time)
            }
    }
}
