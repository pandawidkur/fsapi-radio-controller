import Foundation
import Combine

/// User configuration (UserDefaults). Nothing network-specific is hard-coded in the app.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum SchedulerMode: String, CaseIterable, Identifiable {
        case off, http, ssh
        var id: String { rawValue }
    }

    enum Language: String, CaseIterable, Identifiable {
        case system, en, pl
        var id: String { rawValue }
    }

    private let d = UserDefaults.standard

    /// Radio IP; empty until configured (the settings window opens on first launch).
    @Published var radioIP: String { didSet { d.set(radioIP, forKey: "BlaupunktRadioIP") } }
    /// FSAPI PIN; 1234 is the factory default of Frontier Silicon radios.
    @Published var radioPIN: String { didSet { d.set(radioPIN, forKey: "BlaupunktRadioPIN") } }

    @Published var schedulerMode: SchedulerMode { didSet { d.set(schedulerMode.rawValue, forKey: "schedulerMode") } }
    /// Host of the always-on machine running radio-scheduler (HTTP mode).
    @Published var schedulerHost: String { didSet { d.set(schedulerHost, forKey: "schedulerHost") } }
    @Published var schedulerPort: Int { didSet { d.set(schedulerPort, forKey: "schedulerPort") } }
    /// `ssh` destination (alias from ~/.ssh/config or user@host) for SSH mode.
    @Published var schedulerSSH: String { didSet { d.set(schedulerSSH, forKey: "schedulerSSH") } }

    @Published var language: Language {
        didSet {
            d.set(language.rawValue, forKey: "uiLanguage")
            if language == .system { d.removeObject(forKey: "AppleLanguages") } else { d.set([language.rawValue], forKey: "AppleLanguages") }
        }
    }

    var isRadioConfigured: Bool { !radioIP.trimmingCharacters(in: .whitespaces).isEmpty }
    var isSchedulerEnabled: Bool { schedulerMode != .off }

    private init() {
        radioIP = d.string(forKey: "BlaupunktRadioIP") ?? ""
        radioPIN = d.string(forKey: "BlaupunktRadioPIN") ?? "1234"
        schedulerMode = SchedulerMode(rawValue: d.string(forKey: "schedulerMode") ?? "") ?? .off
        schedulerHost = d.string(forKey: "schedulerHost") ?? ""
        schedulerPort = d.object(forKey: "schedulerPort") as? Int ?? 8735
        schedulerSSH = d.string(forKey: "schedulerSSH") ?? ""
        language = Language(rawValue: d.string(forKey: "uiLanguage") ?? "") ?? .system
    }

    // MARK: Scheduler token (shared secret with the homelab service)

    static var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FSAPIRadioController", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var tokenURL: URL { supportDir.appendingPathComponent("scheduler-token") }

    /// Existing token, or a new random one saved with 0600 permissions.
    static func schedulerToken(create: Bool = false) -> String? {
        if let t = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        guard create else { return nil }
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? token.write(to: tokenURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        return token
    }
}
