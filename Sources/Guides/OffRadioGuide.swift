import Foundation

/// Off Radio Kraków — API of off.radiokrakow.pl (dated schedule with hosts; recent tracks as an HTML fragment).
/// The broadcast day starts at 10:00 and the last slot wraps overnight (22:00–10:00).
struct OffRadioGuide: StationGuide {
    private let base = "https://off.radiokrakow.pl/api/index.php"

    func fetchSchedule(for date: Date) async throws -> [GuideProgram] {
        // Before 10:00 the running show belongs to the previous day's grid.
        let today = try await day(date)
        let yesterday = (try? await day(Guide.calendar.date(byAdding: .day, value: -1, to: date)!)) ?? []
        let overnight = yesterday.filter { ($0.end ?? $0.start) > Guide.startOfToday(date) }
        return Guide.normalize(overnight + today)
    }

    private func day(_ date: Date) async throws -> [GuideProgram] {
        guard let rows = (try await Guide.json("\(base)/articleroadmap/dayarr?date=\(Guide.isoDay(date))") as? [String: Any])?["roadmap"]
                as? [[String: Any]] else {
            throw GuideError.badResponse("Off Radio schedule")
        }
        let programs = rows.compactMap { r -> GuideProgram? in
            guard let name = r["name"] as? String,
                  let s = r["start"] as? String, let start = Guide.time(s, on: date) else { return nil }
            var end = (r["end"] as? String).flatMap { Guide.time($0, on: date) }
            if let e = end, e <= start { end = Guide.calendar.date(byAdding: .day, value: 1, to: e) }
            let hosts = (r["users"] as? [[String: Any]] ?? [])
                .map { "\(Guide.clean($0["firstname"] as? String)) \(Guide.clean($0["lastname"] as? String))".trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let text = (r["obj"] as? [String: Any])?["text"] as? String
            return GuideProgram(title: Guide.clean(name), start: start, end: end,
                                host: hosts.isEmpty ? nil : hosts.joined(separator: ", "),
                                description: Guide.plainText(text))
        }
        return Guide.normalize(programs)
    }

    func fetchTracks() async throws -> [GuideTrack] {
        let html = try await Guide.text("\(base)/index/playlist")
        // <div class="timesong">10:41 </div> … <span class="music_table_txt_blue">Artist </span>- Title</div>
        let rows = Guide.matches(#"timesong">\s*([0-9:]+)\s*</div>.*?music_table_txt_blue">(.*?)</span>\s*-\s*(.*?)</div>"#, in: html)
        return rows.map {
            GuideTrack(artist: Guide.clean(Guide.unescapeHTML($0[2])), title: Guide.clean(Guide.unescapeHTML($0[3])), time: $0[1])
        }
    }
}
