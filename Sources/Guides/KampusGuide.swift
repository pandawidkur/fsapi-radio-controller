import Foundation

/// Radio Kampus 97,1 FM — JSON API behind radiokampus.fm (needs Accept/Origin headers, otherwise returns HTML).
/// Schedule is a weekly template keyed by Polish day slug: /ramowka/sroda/?api=true → [0].daysSchedule[].
struct KampusGuide: StationGuide {
    private let base = "https://api.radiokampus.fm"
    private let headers = ["Accept": "application/json, text/plain, */*",
                           "Origin": "https://radiokampus.fm",
                           "Referer": "https://radiokampus.fm/"]

    func fetchSchedule(for day: Date) async throws -> [GuideProgram] {
        let json = try await Guide.json("\(base)/ramowka/\(Guide.polishDaySlug(day))/?api=true", headers: headers)
        guard let rows = (json as? [[String: Any]])?.first?["daysSchedule"] as? [[String: Any]] else {
            throw GuideError.badResponse("Kampus schedule")
        }
        let programs = rows.compactMap { r -> GuideProgram? in
            guard let title = r["program_title"] as? String,
                  let s = r["program_time_start"] as? String, let start = Guide.time(s, on: day) else { return nil }
            let end = (r["program_time_end"] as? String).flatMap { Guide.time($0, on: day) }
            let page = (r["program_url"] as? String).flatMap { $0.isEmpty ? nil : "\(base)\($0)?api=true" }
            return GuideProgram(title: Guide.clean(title), start: start, end: end, host: nil, detailURL: page)
        }
        return Guide.normalize(programs)
    }

    /// /programy/<slug>/?api=true → [0].programData[0].program_full_description (HTML) or the short one.
    func fetchDescription(_ url: String) async throws -> String? {
        let json = try await Guide.json(url, headers: headers)
        guard let data = ((json as? [[String: Any]])?.first?["programData"] as? [[String: Any]])?.first else { return nil }
        return Guide.plainText(data["program_full_description"] as? String)
            ?? Guide.plainText(data["program_short_description"] as? String)
    }

    func fetchTracks() async throws -> [GuideTrack] {
        let json = try await Guide.json("\(base)/playlista/?api=true", headers: headers)
        guard let rows = json as? [[String: Any]] else { throw GuideError.badResponse("Kampus playlist") }
        return rows.compactMap { r in
            let artist = Guide.clean(r["artist"] as? String)
            let title = Guide.clean(r["title"] as? String)
            // song_id 9999 / station name = placeholder shown between songs ("Same sztosy!").
            guard !title.isEmpty, artist != "Radio Kampus 97,1 FM" else { return nil }
            return GuideTrack(artist: artist, title: title, time: r["start_time"] as? String)
        }
    }
}
