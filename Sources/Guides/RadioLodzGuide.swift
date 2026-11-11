import Foundation

/// Radio Łódź — weekly schedule pages exposed via WordPress REST (slug ramowka-radia-lodz-<day>).
/// The content is free-form HTML; main blocks are lines like "09:00 - 13:00 RADIO ŁÓDŹ NA DWA GŁOSY"
/// (title in capitals). Single-time lines ("09:35 Ekologia bez ogródek") are segments inside a block.
struct RadioLodzGuide: StationGuide {
    func fetchSchedule(for day: Date) async throws -> [GuideProgram] {
        let url = "https://radiolodz.pl/wp-json/wp/v2/pages?slug=ramowka-radia-lodz-\(Guide.polishDaySlug(day))&_fields=content"
        guard let html = ((try await Guide.json(url) as? [[String: Any]])?.first?["content"] as? [String: Any])?["rendered"] as? String else {
            throw GuideError.badResponse("Radio Łódź schedule")
        }
        var programs: [GuideProgram] = []
        var segments: [String] = []
        for line in Guide.htmlLines(html) {
            let block = Guide.matches(#"^(\d{1,2}[:.]\d{2})\s*[-–]\s*(\d{1,2}[:.]\d{2})\s+(.+)$"#, in: line).first
            if let b = block, b[3] == b[3].uppercased(),
               let start = Guide.time(b[1].replacingOccurrences(of: ".", with: ":"), on: day) {
                flush(&programs, &segments)
                let end = Guide.time(b[2].replacingOccurrences(of: ".", with: ":"), on: day)
                programs.append(GuideProgram(title: Self.titleCase(b[3]), start: start, end: end, host: nil))
            } else if !programs.isEmpty, let seg = Guide.matches(#"^\d{1,2}[:.]\d{2}\s+(.+)$"#, in: line).first {
                segments.append(seg[1])
            }
        }
        flush(&programs, &segments)
        return Guide.normalize(programs)
    }

    /// Segments are shown in the host line, which is otherwise empty for this station.
    private func flush(_ programs: inout [GuideProgram], _ segments: inout [String]) {
        if !segments.isEmpty, var last = programs.popLast() {
            last.host = segments.joined(separator: " · ")
            programs.append(last)
        }
        segments = []
    }

    /// "RADIO ŁÓDŹ NA DWA GŁOSY" → "Radio Łódź na dwa głosy"
    private static func titleCase(_ s: String) -> String {
        let lower = s.lowercased(with: Locale(identifier: "pl_PL"))
            .replacingOccurrences(of: "radio łódź", with: "Radio Łódź")
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }
}
