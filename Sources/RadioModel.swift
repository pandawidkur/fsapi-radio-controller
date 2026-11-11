import Foundation
import AppKit
import Combine

/// Central observable state of the radio, shared by the menu bar icon and the SwiftUI panel.
final class RadioModel: ObservableObject {
    static let modeNames: [(code: Int, name: String)] = [
        // Matches netRemote.sys.caps.validModes reported by the Napoli.
        (0, "Internet"), (1, "Podcasty"), (2, "DAB+"), (3, "FM"), (4, "BT"), (5, "AUX")
    ]

    static let maxVolume = 32

    // MARK: Published state
    @Published private(set) var isConnected = false
    @Published private(set) var isPowerOn = false
    @Published private(set) var isMuted = false
    @Published private(set) var currentMode = 0
    @Published private(set) var stationName = ""
    @Published private(set) var trackText = ""
    @Published var volume: Double = 0
    @Published private(set) var lastSelectedPreset: Int?
    @Published var panelHeight: CGFloat = 0
    /// Friendly name the radio reports (e.g. "Blaupunkt Napoli").
    @Published private(set) var radioName = ""

    private(set) var fsapi: FSAPIService
    private(set) var catalog: RadioCatalog
    private var timer: Timer?
    private var volumeSendWork: DispatchWorkItem?
    private var lastUserVolumeChange = Date.distantPast
    private var lastPresetSelection = Date.distantPast

    init() {
        let s = AppSettings.shared
        fsapi = FSAPIService(host: s.radioIP, pin: s.radioPIN)
        catalog = RadioCatalog(host: s.radioIP, pin: s.radioPIN)
    }

    // MARK: Derived

    var activePresetIndex: Int? {
        // Exact match on the name stored in the preset (the radio reports the same name while playing it).
        if let slot = PresetStore.shared.slot(matching: stationName) { return slot }
        // Station names reported by the device can differ from preset labels; fall back to last selection.
        if Date().timeIntervalSince(lastPresetSelection) < 600 { return lastSelectedPreset }
        return nil
    }

    /// Clean "Artist - Title" for YouTube, stripping the station name prefix.
    var youTubeQuery: String {
        let station = stationName.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = trackText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && text != station {
            if !station.isEmpty && text.hasPrefix("\(station) - ") {
                text = String(text.dropFirst(station.count + 3))
            }
            return text
        }
        return ""
    }

    var statusSummary: String {
        if !isConnected { return L("No connection to the radio") }
        if !isPowerOn { return L("Standby") }
        let parts = [stationName, youTubeQuery].filter { !$0.isEmpty }
        return parts.isEmpty ? L("On") : parts.joined(separator: " — ")
    }

    // MARK: Polling

    func startPolling() {
        refresh()
        if AppSettings.shared.isRadioConfigured { PresetStore.shared.refresh(using: catalog) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard AppSettings.shared.isRadioConfigured else { isConnected = false; return }
        if radioName.isEmpty {
            fsapi.fetchFriendlyName { [weak self] name in
                DispatchQueue.main.async { if let n = name, !n.isEmpty { self?.radioName = n } }
            }
        }
        fsapi.fetchAllStatus { [weak self] status in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard let status = status else {
                    self.isConnected = false
                    return
                }
                self.isConnected = true
                self.isPowerOn = status.isPowerOn
                self.isMuted = status.isMuted
                self.currentMode = status.currentMode
                self.stationName = Guide.unescapeHTML(status.nowPlayingName)
                self.trackText = Guide.unescapeHTML(status.nowPlayingText)
                // Don't fight the user while they are dragging the slider.
                if Date().timeIntervalSince(self.lastUserVolumeChange) > 2.5 {
                    self.volume = Double(status.volume)
                }
            }
        }
    }

    /// Re-creates the clients from the current settings (after the settings window saved a new IP/PIN).
    func reconnect() {
        let s = AppSettings.shared
        fsapi = FSAPIService(host: s.radioIP, pin: s.radioPIN)
        catalog = RadioCatalog(host: s.radioIP, pin: s.radioPIN)
        radioName = ""
        refresh()
        PresetStore.shared.refresh(using: catalog)
    }

    // MARK: Actions

    func togglePower() {
        let target = !isPowerOn
        isPowerOn = target
        fsapi.setPower(target) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.refresh() }
        }
    }

    func toggleMute() {
        let target = !isMuted
        isMuted = target
        fsapi.setMute(target) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    /// Debounced volume change; safe to call on every slider tick.
    func setVolume(_ value: Double) {
        let clamped = max(0, min(Double(Self.maxVolume), value.rounded()))
        volume = clamped
        lastUserVolumeChange = Date()
        volumeSendWork?.cancel()
        let level = Int(clamped)
        let work = DispatchWorkItem { [weak self] in
            self?.fsapi.setVolume(level) { _ in }
        }
        volumeSendWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func nudgeVolume(by step: Int) {
        if isMuted { toggleMute() }
        setVolume(volume + Double(step))
    }

    func setMode(_ mode: Int) {
        currentMode = mode
        fsapi.setMode(mode) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.refresh() }
        }
    }

    func selectPreset(_ index: Int) {
        lastSelectedPreset = index
        lastPresetSelection = Date()
        if let name = PresetStore.shared.station(slot: index)?.name { stationName = name }
        trackText = ""
        fsapi.selectPreset(index) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.refresh() }
        }
    }

    /// A station was started outside the preset flow (station catalog).
    func stationChangedExternally() {
        lastSelectedPreset = nil
        lastPresetSelection = .distantPast
        currentMode = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }

    func openOnYouTube(_ query: String? = nil) {
        let q = (query ?? youTubeQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty,
              let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.youtube.com/results?search_query=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }
}
