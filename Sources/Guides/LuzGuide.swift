import Foundation

/// Radio LUZ (radioluz.pl, WordPress).
/// Full day: /ramowka/ HTML — one `.js-schedule-<englishday>` container per broadcast, with `data-week`
/// ("" = every week, otherwise alternating weeks), time in `p.schedule__broadcast-p`, title in
/// `header.schedule__broadcast-title`, hosts in `p.schedule__broadcast-authors`.
/// Fallback and current week number: admin-ajax `action=schedule` (~5 slots around now).
/// Tracks: admin-ajax `action=histoprylog`.
struct LuzGuide: StationGuide {
    private let ajax = "https://radioluz.pl/wp-admin/admin-ajax.php"

    func fetchSchedule(for date: Date) async throws -> [GuideProgram] {
        let window = try? await ajaxWindow()
        if let full = try? await fullDay(date, week: window?.week), !full.isEmpty { return full }
        guard Guide.isToday(date), let w = window else { throw GuideError.badResponse("LUZ schedule") }
        return w.programs
    }

    private func fullDay(_ date: Date, week: String?) async throws -> [GuideProgram] {
        let html = try await Guide.text("https://radioluz.pl/ramowka/")
        let english = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let day = english[Guide.calendar.component(.weekday, from: date) - 1]
        let containers = html.components(separatedBy: "js-schedule-\(day)\"").dropFirst()
        var bySlot: [String: [(week: String, program: GuideProgram)]] = [:]
        for c in containers {
            let body = c.components(separatedBy: "js-schedule__container").first ?? c
            guard let time = Guide.matches(#"schedule__broadcast-p">\s*(\d{1,2}:\d{2})"#, in: body).first?[1],
                  let start = Guide.time(time, on: date),
                  let title = Guide.matches(#"schedule__broadcast-title">(.*?)</header>"#, in: body).first?[1] else { continue }
            let w = Guide.matches(#"data-week="([^"]*)""#, in: body).first?[1] ?? ""
            let authors = Guide.matches(#"schedule__broadcast-authors">(.*?)</p>"#, in: body).first
                .map { Guide.clean(Guide.unescapeHTML($0[1]))
                    .replacingOccurrences(of: "^autorzy:\\s*", with: "", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ", ")) } ?? ""
            let text = Guide.matches(#"schedule__broadcast-text">(.*?)</main>"#, in: body).first?[1]
            let p = GuideProgram(title: Guide.clean(Guide.unescapeHTML(title)), start: start, end: nil,
                                 host: authors.isEmpty ? nil : authors, description: Guide.plainText(text))
            bySlot[time, default: []].append((w, p))
        }
        // Alternating-week shows share a slot: prefer this week's, then the every-week one.
        let programs = bySlot.values.compactMap { options in
            options.first { week != nil && $0.week == week }?.program
                ?? options.first { $0.week.isEmpty }?.program
                ?? options.first?.program
        }
        return Guide.normalize(programs)
    }

    private func ajaxWindow() async throws -> (week: String, programs: [GuideProgram]) {
        guard let json = try await Guide.json("\(ajax)?action=schedule") as? [String: Any],
              let slots = json["broadcasts"] as? [[String: Any]] else {
            throw GuideError.badResponse("LUZ schedule")
        }
        // Alternating-week shows share a slot; `week` on the item matches the top-level week number.
        let week = "\(json["week"] ?? "")"
        let programs = slots.compactMap { slot -> GuideProgram? in
            let items = slot["broadcasts"] as? [[String: Any]] ?? []
            let item = items.first { "\($0["week"] ?? "")" == week } ?? items.first { "\($0["week"] ?? "")".isEmpty } ?? items.first
            guard let item = item,
                  let title = item["title"] as? String,
                  let start = (item["time"] as? String).flatMap({ Guide.time($0, on: Date()) }) else { return nil }
            let authors = Guide.clean(item["authors"] as? String).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
            return GuideProgram(title: Guide.clean(Guide.unescapeHTML(title)), start: start, end: nil,
                                host: authors.isEmpty ? nil : authors)
        }
        return (week, Guide.normalize(programs))
    }

    func fetchTracks() async throws -> [GuideTrack] {
        // [["11.11.2026","10:36:16","Artist","Title","Album","4:20","Label"], …] oldest first
        guard let rows = try await Guide.json("\(ajax)?action=histoprylog") as? [[Any]] else {
            throw GuideError.badResponse("LUZ playlist")
        }
        return rows.reversed().compactMap { r in
            guard r.count >= 4 else { return nil }
            let time = (r[1] as? String).map { String($0.prefix(5)) }
            return GuideTrack(artist: Guide.clean(r[2] as? String), title: Guide.clean(r[3] as? String), time: time)
        }
    }
}
