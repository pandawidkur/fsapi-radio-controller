import Foundation
import Combine

struct PresetStation: Identifiable, Equatable, Codable {
    let id: Int          // FSAPI preset slot (0-based)
    let name: String     // name stored in the radio, e.g. "Radio Kampus 97,1 FM"

    /// Compact label for the panel: "Radio Kampus 97,1 FM" → "Kampus", "Polskie Radio Czwórka" → "Czwórka".
    var shortName: String {
        var s = name
        for prefix in ["Polskie Radio ", "Radio "] where s.hasPrefix(prefix) && s.count > prefix.count + 2 {
            s = String(s.dropFirst(prefix.count))
        }
        s = s.replacingOccurrences(of: #"\s+\d{2,3}[.,]\d\s*FM$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+(FM|Kraków)$"#, with: "", options: .regularExpression)
        return s.count > 14 ? String(s.prefix(13)) + "…" : s
    }
}

/// Presets read from the radio (source of truth) plus the user's choice of up to 10 favourites shown
/// in the panel. Favourites are remembered by slot; a cached copy of the slots makes startup instant.
final class PresetStore: ObservableObject {
    static let shared = PresetStore()
    static let maxFavourites = 10

    @Published private(set) var slots: [PresetStation] = []
    @Published private(set) var favouriteSlots: [Int] = []
    @Published private(set) var lastError: String?
    /// Short feedback after saving a preset ("Zapisano w slocie 12").
    @Published var notice: String?

    private var lastRefresh = Date.distantPast

    private let defaults = UserDefaults.standard
    private let slotsKey = "presetSlots"
    private let favouritesKey = "favouriteSlots"

    private init() {
        if let data = defaults.data(forKey: slotsKey),
           let cached = try? JSONDecoder().decode([PresetStation].self, from: data) {
            slots = cached
        }
        if let favs = defaults.array(forKey: favouritesKey) as? [Int] {
            favouriteSlots = favs
        }
    }

    /// Non-empty slots.
    var stations: [PresetStation] { slots.filter { !$0.name.isEmpty } }

    /// Favourites in the chosen order; defaults to the first 10 non-empty slots.
    var favourites: [PresetStation] {
        let bySlot = Dictionary(uniqueKeysWithValues: stations.map { ($0.id, $0) })
        if favouriteSlots.isEmpty { return Array(stations.prefix(Self.maxFavourites)) }
        return favouriteSlots.compactMap { bySlot[$0] }
    }

    func station(slot: Int) -> PresetStation? { slots.first { $0.id == slot } }

    /// Preset slot whose stored name matches the station the radio reports as playing.
    func slot(matching playingName: String) -> Int? {
        let n = playingName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !n.isEmpty else { return nil }
        return stations.first { $0.name.lowercased() == n }?.id
    }

    func isFavourite(_ slot: Int) -> Bool { favourites.contains { $0.id == slot } }

    func setFavourite(_ slot: Int, _ on: Bool) {
        var list = favourites.map(\.id)
        if on, !list.contains(slot), list.count < Self.maxFavourites { list.append(slot) }
        if !on { list.removeAll { $0 == slot } }
        favouriteSlots = list
        defaults.set(list, forKey: favouritesKey)
    }

    // MARK: Radio I/O

    /// Re-reads the presets unless that happened recently (each read opens a new FSAPI session).
    func refreshIfStale(using catalog: RadioCatalog, maxAge: TimeInterval = 15 * 60) {
        if Date().timeIntervalSince(lastRefresh) > maxAge { refresh(using: catalog) }
    }

    func refresh(using catalog: RadioCatalog) {
        lastRefresh = Date()
        Task { [store = self] in
            do {
                let raw = try await catalog.presets()
                let list = raw.map { PresetStation(id: $0.slot, name: $0.name) }
                await MainActor.run { store.apply(list) }
            } catch {
                await MainActor.run { store.lastError = L("Couldn't read the presets from the radio.") }
            }
        }
    }

    func saveCurrent(toSlot slot: Int, using catalog: RadioCatalog, completion: @escaping (Bool) -> Void) {
        Task { [store = self] in
            let ok = (try? await catalog.saveCurrentStation(toSlot: slot)) != nil
            if ok, let raw = try? await catalog.presets() {
                let list = raw.map { PresetStation(id: $0.slot, name: $0.name) }
                await MainActor.run { store.apply(list) }
            }
            await MainActor.run {
                store.notice = ok ? L("Saved to preset %d.", slot + 1) : L("Couldn't save the preset (the radio must be playing an internet station).")
                completion(ok)
            }
        }
    }

    private func apply(_ list: [PresetStation]) {
        guard !list.isEmpty else { return }
        slots = list
        lastError = nil
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: slotsKey) }
        // Drop favourites whose slot became empty.
        let valid = Set(stations.map(\.id))
        let cleaned = favouriteSlots.filter { valid.contains($0) }
        if cleaned != favouriteSlots {
            favouriteSlots = cleaned
            defaults.set(cleaned, forKey: favouritesKey)
        }
    }
}
