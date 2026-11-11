import AppKit
import SwiftUI
import Combine

/// Settings / connection wizard: radio (discovery, IP, PIN, test), scheduler (homelab), language.
final class SettingsWindowController: NSWindowController {
    private let state: SettingsState

    init(model: RadioModel) {
        state = SettingsState(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L("Settings")
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: SettingsView(state: state, settings: AppSettings.shared))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(tab: SettingsState.Tab = .radio) {
        state.tab = tab
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsState: ObservableObject {
    enum Tab: Hashable { case radio, scheduler, language, devices }

    @Published var tab: Tab = .radio
    @Published var ipDraft: String
    @Published var pinDraft: String
    @Published var scanning = false
    @Published var found: [DiscoveredRadio] = []
    @Published var radioTest: String?
    @Published var schedulerTest: String?
    @Published var tokenCopied = false

    let model: RadioModel
    private var scanTask: Task<Void, Never>?

    init(model: RadioModel) {
        self.model = model
        ipDraft = AppSettings.shared.radioIP
        pinDraft = AppSettings.shared.radioPIN
    }

    func scan() {
        scanTask?.cancel()
        found = []
        scanning = true
        let pin = pinDraft
        scanTask = Task { [weak self] in
            await RadioDiscovery.scan(pin: pin) { radio in
                guard let self = self, !self.found.contains(radio) else { return }
                self.found.append(radio)
                self.found.sort { $0.ip.localizedStandardCompare($1.ip) == .orderedAscending }
            }
            await MainActor.run { [weak self] in self?.scanning = false }
        }
    }

    func choose(_ radio: DiscoveredRadio) {
        ipDraft = radio.ip
        testAndSave()
    }

    /// Checks IP + PIN and, when the radio answers, saves them and reconnects.
    func testAndSave() {
        let ip = ipDraft.trimmingCharacters(in: .whitespaces)
        let pin = pinDraft.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else { radioTest = L("Enter the radio's IP address."); return }
        radioTest = L("Checking…")
        Task { [weak self] in
            let radio = await RadioDiscovery.probe(ip, pin: pin, timeout: 3)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                guard let r = radio else {
                    self.radioTest = L("No FSAPI radio answers at %@. Is it on and in the same network?", ip)
                    return
                }
                guard r.pinOK else {
                    self.radioTest = L("Found %@ (%@), but the PIN is wrong. Check it in the radio's network settings.", r.name, r.module)
                    return
                }
                AppSettings.shared.radioIP = ip
                AppSettings.shared.radioPIN = pin
                self.model.reconnect()
                self.radioTest = L("Connected: %@ (%@). Saved.", r.name, r.module)
            }
        }
    }

    func testScheduler() {
        schedulerTest = L("Checking…")
        PlanStore.shared.ping { [weak self] message in
            DispatchQueue.main.async { self?.schedulerTest = message }
        }
    }

    func copyToken() {
        guard let token = AppSettings.schedulerToken(create: true) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        tokenCopied = true
    }
}

private struct SettingsView: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var settings: AppSettings

    var body: some View {
        TabView(selection: $state.tab) {
            radioTab.tabItem { Text(L("Radio")) }.tag(SettingsState.Tab.radio)
            schedulerTab.tabItem { Text(L("Scheduler")) }.tag(SettingsState.Tab.scheduler)
            languageTab.tabItem { Text(L("Language")) }.tag(SettingsState.Tab.language)
            devicesTab.tabItem { Text(L("Compatible radios")) }.tag(SettingsState.Tab.devices)
        }
        .padding(16)
        .frame(width: 560, height: 520)
    }

    // MARK: Radio

    private var radioTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Works with internet radios built on Frontier Silicon modules (the ones controlled by the UNDOK app)."))
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(state.scanning ? L("Searching…") : L("Search the network")) { state.scan() }
                    .disabled(state.scanning)
                if state.scanning { ProgressView().controlSize(.small) }
                Spacer()
                Text(L("Subnet: %@", RadioDiscovery.localSubnets().map { "\($0).0/24" }.joined(separator: ", ")))
                    .font(.caption).foregroundColor(.secondary)
            }

            List(state.found) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name).font(.body.weight(.semibold))
                        Text("\(r.ip) · \(r.module)\(r.pinOK ? "" : " · " + L("wrong PIN"))")
                            .font(.caption).foregroundColor(r.pinOK ? .secondary : .orange)
                    }
                    Spacer()
                    Button(L("Use")) { state.choose(r) }
                }
            }
            .frame(height: 150)

            Divider()
            Text(L("Or enter it manually")).font(.headline)
            HStack {
                Text(L("IP address")).frame(width: 90, alignment: .leading)
                TextField("192.168.0.20", text: $state.ipDraft).frame(width: 160)
                Text("PIN").frame(width: 30, alignment: .trailing)
                TextField("1234", text: $state.pinDraft).frame(width: 70)
                Button(L("Test and save")) { state.testAndSave() }
            }
            Text(L("The PIN is in the radio menu: Settings → Network → NetRemote PIN (default 1234)."))
                .font(.caption).foregroundColor(.secondary)
            if let t = state.radioTest {
                Text(t).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: Scheduler

    private var schedulerTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Optional. An always-on machine on your network (e.g. a home server or Raspberry Pi) runs the small radio-scheduler service and turns the radio on for the shows you tick in “Favourites schedule”, even when this Mac sleeps."))
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

            Picker(L("Connection"), selection: $settings.schedulerMode) {
                Text(L("Off")).tag(AppSettings.SchedulerMode.off)
                Text("HTTP").tag(AppSettings.SchedulerMode.http)
                Text("SSH").tag(AppSettings.SchedulerMode.ssh)
            }
            .pickerStyle(.segmented)
            .frame(width: 300)

            switch settings.schedulerMode {
            case .off:
                EmptyView()
            case .http:
                HStack {
                    Text(L("Host")).frame(width: 90, alignment: .leading)
                    TextField("192.168.0.10", text: $settings.schedulerHost).frame(width: 180)
                    Text(L("Port"))
                    TextField("8735", value: $settings.schedulerPort, formatter: NumberFormatter()).frame(width: 70)
                }
                Text(L("The service port must be reachable from this Mac (firewall)."))
                    .font(.caption).foregroundColor(.secondary)
            case .ssh:
                HStack {
                    Text(L("SSH host")).frame(width: 90, alignment: .leading)
                    TextField("user@192.168.0.10", text: $settings.schedulerSSH).frame(width: 220)
                }
                Text(L("Uses key-based ssh (no password prompt). The app runs curl on that machine, so no port has to be opened."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if settings.isSchedulerEnabled {
                HStack {
                    Button(L("Test connection")) { state.testScheduler() }
                    Button(state.tokenCopied ? L("Token copied") : L("Copy token")) { state.copyToken() }
                }
                if let t = state.schedulerTest {
                    Text(t).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Text(L("Install the service on the server (see homelab/README.md in the repository) and save the copied token to ~/radio-scheduler/token there."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: Language

    private var languageTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("Language"), selection: $settings.language) {
                Text(L("System")).tag(AppSettings.Language.system)
                Text("English").tag(AppSettings.Language.en)
                Text("Polski").tag(AppSettings.Language.pl)
            }
            .frame(width: 260)
            Text(L("The new language is used after restarting the app."))
                .font(.caption).foregroundColor(.secondary)
            Button(L("Restart now")) { AppRelauncher.relaunch() }
            Spacer()
        }
    }

    // MARK: Compatible radios

    private var devicesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("The app talks FSAPI, the protocol of Frontier Silicon (Frontier Smart) radio modules. Rule of thumb: if the UNDOK app can control your radio, this app should too."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(L("Tested")).font(.headline)
            Text("• Blaupunkt Napoli (FS2340)")
            Text(L("Expected to work (same modules, not tested)")).font(.headline)
            Text("Roberts, Revo, Ruark, Tangent, Hama, Medion, Silvercrest, Grundig, Sangean, Lenco, auna, Majority, Bush, Denver, Imperial/Telestar, Dual, Sharp, Block, Pure, Panasonic…")
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L("Station search uses the radio's own catalogue; on other brands the menu may be organised differently. Please report your model on GitHub."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

enum AppRelauncher {
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
