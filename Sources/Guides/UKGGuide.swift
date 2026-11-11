import Foundation

/// UKG Radio (ukgradio.co.uk) — hosted on radio.co; public schedule (UTC) and status endpoints.
struct UKGGuide: StationGuide {
    private let station = "s9549b306a"

    func fetchSchedule(for day: Date) async throws -> [GuideProgram] {
        guard let rows = (try await Guide.json("https://public.radio.co/stations/\(station)/embed/schedule") as? [String: Any])?["data"]
                as? [[String: Any]] else {
            throw GuideError.badResponse("UKG schedule")
        }
        let iso = ISO8601DateFormatter()
        let dayStart = Guide.startOfToday(day)
        let dayEnd = Guide.calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let programs = rows.compactMap { r -> GuideProgram? in
            guard let s = (r["start"] as? String).flatMap(iso.date(from:)),
                  let e = (r["end"] as? String).flatMap(iso.date(from:)),
                  e > dayStart, s < dayEnd,
                  let playlist = r["playlist"] as? [String: Any] else { return nil }
            let title = Guide.clean((playlist["title"] as? String) ?? (playlist["name"] as? String))
            return GuideProgram(title: title, start: s, end: e, host: nil)
        }
        return Guide.normalize(programs)
    }

    func fetchTracks() async throws -> [GuideTrack] {
        guard let status = try await Guide.json("https://public.radio.co/stations/\(station)/status") as? [String: Any] else {
            throw GuideError.badResponse("status UKG")
        }
        var titles: [String] = []
        if let current = (status["current_track"] as? [String: Any])?["title"] as? String { titles.append(current) }
        titles += (status["history"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
        var seen = Set<String>()
        return titles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { t in   // station jingles / promos
                let l = t.lowercased()
                return !l.contains("ukg radio") && !l.hasPrefix("www.") && !l.contains("your home for")
            }
            .filter { seen.insert($0).inserted }
            .compactMap(Guide.splitArtistTitle)
    }
}
