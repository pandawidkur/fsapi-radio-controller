import Foundation
import Combine

/// A show the user wants to hear: the homelab turns the radio on and plays the station at `start`.
struct PlannedShow: Codable, Identifiable, Equatable {
    let id: String          // "<station name>|<start ISO>"
    let station: String     // preset name in the radio (the homelab looks the slot up by name)
    let slot: Int           // slot at planning time, used only if the name is no longer found
    let title: String
    let start: Date
    let end: Date?
    var fired: String?      // set by the homelab after it ran
    var ok: Bool?

    static func makeId(station: String, start: Date) -> String {
        "\(station)|\(ISO8601DateFormatter().string(from: start))"
    }
}

/// Planned shows, kept locally and pushed to the `radio-scheduler` service on the homelab.
/// Transport: direct HTTP on the LAN when the port is reachable, otherwise SSH (`ssh lab` + curl on localhost),
/// so it works without opening the homelab firewall.
final class PlanStore: ObservableObject {
    static let shared = PlanStore()

    enum SyncState: Equatable {
        case idle, syncing, synced(Date), failed(String)
    }

    @Published private(set) var plans: [PlannedShow] = []
    @Published private(set) var syncState: SyncState = .idle
    @Published private(set) var lastEvents: [String] = []

    private var settings: AppSettings { .shared }
    private let queue = DispatchQueue(label: "PlanStore.sync")

    private init() {
        plans = Self.loadLocal().filter { ($0.end ?? $0.start.addingTimeInterval(3600)) > Date().addingTimeInterval(-86400) }
    }

    // MARK: Queries

    func isPlanned(station: PresetStation, program: GuideProgram) -> Bool {
        plans.contains { $0.id == PlannedShow.makeId(station: station.name, start: program.start) }
    }

    var upcoming: [PlannedShow] {
        plans.filter { $0.start > Date().addingTimeInterval(-5 * 60) && $0.fired == nil }.sorted { $0.start < $1.start }
    }

    /// Shown in the panel: still to come, or started within the last 3 hours (with the homelab's result).
    var recent: [PlannedShow] {
        plans.filter { $0.start > Date().addingTimeInterval(-3 * 3600) }.sorted { $0.start < $1.start }
    }

    /// "dziś 21:00" / "jutro 08:00" / "13.11 08:00".
    static func dayTime(_ date: Date) -> String {
        let cal = Guide.calendar
        let day: String
        if cal.isDateInToday(date) { day = L("today") }
        else if cal.isDateInTomorrow(date) { day = L("tomorrow") }
        else { day = Guide.dayMonth(date) }
        return "\(day) \(Guide.hhmm(date))"
    }

    // MARK: Editing

    func toggle(station: PresetStation, program: GuideProgram) {
        let id = PlannedShow.makeId(station: station.name, start: program.start)
        if plans.contains(where: { $0.id == id }) {
            plans.removeAll { $0.id == id }
        } else {
            plans.append(PlannedShow(id: id, station: station.name, slot: station.id, title: program.title,
                                     start: program.start, end: program.end))
            plans.sort { $0.start < $1.start }
        }
        Self.saveLocal(plans)
        push()
    }

    func remove(_ plan: PlannedShow) {
        plans.removeAll { $0.id == plan.id }
        Self.saveLocal(plans)
        push()
    }

    // MARK: Sync with the homelab

    /// Sends the full list (the service replaces its list and keeps fired markers).
    func push() {
        let iso = ISO8601DateFormatter()
        iso.timeZone = Guide.warsaw
        iso.formatOptions = [.withInternetDateTime]
        let payload: [String: Any] = ["plans": plans.map { p in
            ["id": p.id, "station": p.station, "slot": p.slot, "title": p.title, "start": iso.string(from: p.start)] as [String: Any]
        }]
        guard settings.isSchedulerEnabled,
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        syncState = .syncing
        request(method: "PUT", path: "/schedule", body: body) { [weak self] result in
            self?.handle(result)
        }
    }

    /// Pulls fired/ok markers and recent history.
    func refreshStatus() {
        guard settings.isSchedulerEnabled else { return }
        request(method: "GET", path: "/status", body: nil) { [weak self] result in
            self?.handle(result)
        }
    }

    private func handle(_ result: Result<Data, Error>) {
        DispatchQueue.main.async {
            switch result {
            case .failure(let e):
                self.syncState = .failed(e.localizedDescription)
            case .success(let data):
                self.syncState = .synced(Date())
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                if let remote = json["plans"] as? [[String: Any]] {
                    let byId = Dictionary(remote.compactMap { r in (r["id"] as? String).map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
                    for i in self.plans.indices {
                        if let r = byId[self.plans[i].id] {
                            self.plans[i].fired = r["fired"] as? String
                            self.plans[i].ok = r["ok"] as? Bool
                        }
                    }
                    Self.saveLocal(self.plans)
                }
                if let history = json["history"] as? [[String: Any]] {
                    self.lastEvents = history.suffix(5).reversed().map { h in
                        let at = (h["at"] as? String).map { String($0.dropFirst(11).prefix(5)) } ?? ""
                        let ok = (h["ok"] as? Bool) == true
                        let station = h["station"] as? String ?? ""
                        return ok ? L("%@ turned on %@", at, station) : L("%@ error: %@ — %@", at, station, h["error"] as? String ?? "?")
                    }
                }
            }
        }
    }

    /// Connection test for the settings window; reports a human-readable result.
    func ping(_ done: @escaping (String) -> Void) {
        request(method: "GET", path: "/status", body: nil) { result in
            switch result {
            case .success(let data):
                let n = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["plans"] as? [Any])?.count ?? 0
                done(L("Scheduler OK (%d planned).", n))
            case .failure(let e):
                done(L("Scheduler unreachable: %@", e.localizedDescription))
            }
        }
    }

    // MARK: Transport

    private func request(method: String, path: String, body: Data?, completion: @escaping (Result<Data, Error>) -> Void) {
        switch settings.schedulerMode {
        case .off:
            completion(.failure(Self.error(L("scheduler is off"))))
        case .ssh:
            sshRequest(method: method, path: path, body: body, completion: completion)
        case .http:
            guard let url = URL(string: "http://\(settings.schedulerHost):\(settings.schedulerPort)\(path)"),
                  !settings.schedulerHost.isEmpty else {
                completion(.failure(Self.error(L("no scheduler host set")))); return
            }
            guard let token = AppSettings.schedulerToken() else {
                completion(.failure(Self.error(L("no token — use “Copy token” in Settings")))); return
            }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.timeoutInterval = 5
            req.setValue(token, forHTTPHeaderField: "X-Token")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            URLSession.shared.dataTask(with: req) { data, response, error in
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let data = data, code == 200 {
                    completion(.success(data))
                } else {
                    completion(.failure(error ?? Self.error(code == 401 ? L("wrong token") : "HTTP \(code)")))
                }
            }.resume()
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "PlanStore", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// SSH mode: curl on the server itself (no open port needed); the token is read there from its own file.
    private func sshRequest(method: String, path: String, body: Data?, completion: @escaping (Result<Data, Error>) -> Void) {
        let sshAlias = settings.schedulerSSH.trimmingCharacters(in: .whitespaces)
        let port = settings.schedulerPort
        guard !sshAlias.isEmpty else { completion(.failure(Self.error(L("no SSH host set")))); return }
        queue.async {
            let remote = "curl -s -f -m 8 -X \(method) -H \"X-Token: $(cat ~/radio-scheduler/token)\" "
                + "-H 'Content-Type: application/json' \(body != nil ? "--data-binary @- " : "")localhost:\(port)\(path)"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", sshAlias, remote]
            let out = Pipe(), err = Pipe(), inp = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = inp
            do {
                try p.run()
                if let body = body { inp.fileHandleForWriting.write(body) }
                try? inp.fileHandleForWriting.close()
                p.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                if p.terminationStatus == 0 {
                    completion(.success(data))
                } else {
                    let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    completion(.failure(NSError(domain: "PlanStore", code: Int(p.terminationStatus), userInfo: [
                        NSLocalizedDescriptionKey: msg.isEmpty ? L("server unreachable (ssh %@)", sshAlias) : msg
                    ])))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: Local persistence

    private static var dir: URL { AppSettings.supportDir }

    private static func loadLocal() -> [PlannedShow] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("plans.json")) else { return [] }
        return (try? JSONDecoder().decode([PlannedShow].self, from: data)) ?? []
    }

    private static func saveLocal(_ plans: [PlannedShow]) {
        if let data = try? JSONEncoder().encode(plans) {
            try? data.write(to: dir.appendingPathComponent("plans.json"), options: .atomic)
        }
    }
}
