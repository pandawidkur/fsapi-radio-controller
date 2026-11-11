import Foundation

/// Polskie Radio Czwórka — public Polskie Radio API (dated schedule with hosts, dated playlist).
struct CzworkaGuide: StationGuide {
    private let program = 4

    private static let prDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Guide.warsaw
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss"   // "Wed, 11 Nov 2026 10:00:00", Warsaw local
        return f
    }()

    func fetchSchedule(for day: Date) async throws -> [GuideProgram] {
        let url = "https://apipr.polskieradio.pl/api/MainSchedule?Program=\(program)&SelectedDate=\(Guide.isoDay(day))"
        guard let rows = (try await Guide.json(url) as? [String: Any])?["Schedule"] as? [[String: Any]] else {
            throw GuideError.badResponse("Czwórka schedule")
        }
        var programs: [GuideProgram] = []
        for r in rows {
            guard let title = r["Title"] as? String,
                  let start = (r["StartHour"] as? String).flatMap(Self.prDate.date(from:)) else { continue }
            let end = (r["StopHour"] as? String).flatMap(Self.prDate.date(from:))
            let leaders = (r["Leaders"] as? [[String: Any]] ?? [])
                .map { "\(Guide.clean($0["Name"] as? String)) \(Guide.clean($0["SurName"] as? String))".trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let host = leaders.isEmpty ? nil : leaders.joined(separator: ", ")
            // The API splits long shows into 1-hour slots; merge consecutive slots of the same show.
            if var last = programs.last, last.title == Guide.clean(title), last.end == start {
                last.end = end
                programs[programs.count - 1] = last
            } else {
                programs.append(GuideProgram(title: Guide.clean(title), start: start, end: end, host: host,
                                             description: Guide.plainText(r["Description"] as? String)))
            }
        }
        return Guide.normalize(programs)
    }

    func fetchTracks() async throws -> [GuideTrack] {
        let url = "https://apipr.polskieradio.pl/api/playlist?date=\(Guide.isoDay())&antenneId=\(program)"
        guard let blocks = try await Guide.json(url) as? [[String: Any]] else { throw GuideError.badResponse("Czwórka playlist") }
        var tracks: [(Date, GuideTrack)] = []
        for b in blocks {
            for s in b["Songs"] as? [[String: Any]] ?? [] {
                guard let date = (s["Start"] as? String).flatMap(Self.prDate.date(from:)) else { continue }
                let t = GuideTrack(artist: Guide.clean(s["Artist"] as? String), title: Guide.clean(s["Title"] as? String),
                                   time: Guide.hhmm(date))
                if !t.title.isEmpty { tracks.append((date, t)) }
            }
        }
        return tracks.sorted { $0.0 > $1.0 }.map { $0.1 }
    }
}
