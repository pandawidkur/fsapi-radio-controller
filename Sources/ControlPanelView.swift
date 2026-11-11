import SwiftUI

struct ControlPanelView: View {
    @ObservedObject var model: RadioModel
    @ObservedObject var guides: GuideStore
    @ObservedObject var presets: PresetStore
    @ObservedObject var plans: PlanStore
    var onOpenSearch: () -> Void
    var onOpenSchedule: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void
    static let width: CGFloat = 380

    /// Tallest the panel may get: visible screen height minus room for the menu bar and popover arrow.
    static var maxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(300, screen - 40)
    }

    var body: some View {
        // The popover sizes itself from `model.panelHeight`; content scrolls if it exceeds the screen.
        ScrollView(.vertical, showsIndicators: model.panelHeight > Self.maxHeight) {
            content
                .background(GeometryReader { geo in
                    Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
                })
        }
        .frame(width: Self.width, height: min(max(model.panelHeight, 100), Self.maxHeight))
        .onPreferenceChange(PanelHeightKey.self) { h in
            if abs(h - model.panelHeight) > 0.5 { model.panelHeight = h }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.isConnected {
                disconnectedView
            } else if model.isPowerOn {
                Divider()
                nowPlaying
                Divider()
                volumeSection
            }
            // The favourites guide is useful even in standby: it shows what's worth listening to.
            Divider()
            favouritesSection
            if !plans.recent.isEmpty {
                Divider()
                plannedSection
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: Self.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "radio")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(model.isPowerOn ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.radioName.isEmpty ? L("Internet radio") : model.radioName).font(.headline)
                Text(statusLine).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if model.isConnected {
                Button(action: model.togglePower) {
                    Image(systemName: "power")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 30, height: 30)
                        .foregroundColor(model.isPowerOn ? .white : .primary)
                        .background(Circle().fill(model.isPowerOn ? Color.accentColor : Color.secondary.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .help(model.isPowerOn ? L("Switch to standby") : L("Turn the radio on"))
            }
        }
    }

    private var statusLine: String {
        let ip = AppSettings.shared.radioIP
        if !AppSettings.shared.isRadioConfigured { return L("Not configured") }
        if !model.isConnected { return L("No connection (%@)", ip) }
        return model.isPowerOn ? L("On · %@", ip) : L("Standby")
    }

    private var disconnectedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Can't connect to the radio. Check that it is on the same Wi-Fi network."))
                .font(.callout).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("Refresh"), action: model.refresh)
                Button(L("Settings…"), action: onOpenSettings)
            }
        }
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.stationName.isEmpty ? "—" : model.stationName)
                .font(.title3.weight(.semibold)).lineLimit(1)
            let track = model.youTubeQuery
            if !track.isEmpty {
                HStack(spacing: 6) {
                    Text(track)
                        .font(.callout).foregroundColor(.secondary).lineLimit(2)
                    Spacer(minLength: 4)
                    Button { model.openOnYouTube() } label: { Image(systemName: "heart.fill").foregroundColor(.pink) }
                        .buttonStyle(.borderless).help(L("Search on YouTube"))
                }
            }
            if model.currentMode == 0 && model.activePresetIndex == nil && !model.stationName.isEmpty {
                saveAsPresetMenu.controlSize(.small)
            }
            if let notice = presets.notice {
                Text(notice).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    /// Saves the station that is playing now into a chosen radio slot (overwrites it).
    private var saveAsPresetMenu: some View {
        Menu {
            ForEach(presets.slots) { slot in
                Button("\(slot.id + 1). \(slot.name.isEmpty ? L("(empty)") : slot.name)") {
                    presets.notice = L("Saving…")
                    presets.saveCurrent(toSlot: slot.id, using: model.catalog) { _ in model.refresh() }
                }
            }
        } label: {
            Label(L("Save as preset"), systemImage: "star")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Save the playing station to the chosen radio preset (overwrites it)"))
    }

    // MARK: Volume

    private var volumeSection: some View {
        HStack(spacing: 8) {
            Button(action: model.toggleMute) {
                Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.fill").frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(model.isMuted ? "Odcisz" : "Wycisz")

            Button { model.nudgeVolume(by: -1) } label: { Image(systemName: "minus") }
                .buttonStyle(.borderless)

            Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }),
                   in: 0...Double(RadioModel.maxVolume))
                .disabled(model.isMuted)

            Button { model.nudgeVolume(by: 1) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)

            Text(model.isMuted ? "—" : "\(Int(model.volume))")
                .font(.callout.monospacedDigit()).frame(width: 24, alignment: .trailing)
        }
    }

    // MARK: Favourites with schedules

    private var favouritesSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(L("FAVOURITES — ON AIR NOW")).font(.caption.weight(.bold)).foregroundColor(.secondary)
                Spacer()
                Button(action: onOpenSearch) { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help(L("Search stations"))
                    .disabled(!model.isConnected)
                Button(action: onOpenSchedule) { Image(systemName: "calendar") }
                    .buttonStyle(.borderless).help(L("Favourites schedule — plan listening"))
                editFavouritesMenu
                Text(Guide.hhmm(Date())).font(.caption.monospacedDigit()).foregroundColor(.secondary)
            }
            .padding(.bottom, 4)
            ForEach(presets.favourites) { p in
                FavouriteRow(preset: p, model: model, guides: guides)
            }
        }
        .onAppear {
            guides.panelOpened(stations: presets.favourites)
            presets.refreshIfStale(using: model.catalog)
            if !plans.plans.isEmpty { plans.refreshStatus() }
        }
        .onDisappear {
            guides.panelClosed()
            presets.notice = nil
        }
    }

    /// Pick up to 10 favourites out of all presets stored in the radio.
    private var editFavouritesMenu: some View {
        Menu {
            Text(L("Favourites (max. %d)", PresetStore.maxFavourites))
            ForEach(presets.stations) { s in
                let on = presets.isFavourite(s.id)
                Button("\(on ? "✓" : "   ") \(s.id + 1). \(s.name)") {
                    presets.setFavourite(s.id, !on)
                    guides.panelOpened(stations: presets.favourites)
                }
                .disabled(!on && presets.favourites.count >= PresetStore.maxFavourites)
            }
            Divider()
            Button(L("Read presets from the radio")) { presets.refresh(using: model.catalog) }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Choose favourite stations"))
    }

    // MARK: Planned shows (fired by the homelab)

    private var plannedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("PLANNED")).font(.caption.weight(.bold)).foregroundColor(.secondary)
                Spacer()
                Text(syncText).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            ForEach(plans.recent) { p in
                HStack(spacing: 6) {
                    Text(PlanStore.dayTime(p.start)).font(.caption.monospacedDigit()).frame(width: 74, alignment: .leading)
                    Text(PresetStation(id: p.slot, name: p.station).shortName).font(.caption.weight(.semibold))
                        .frame(width: 70, alignment: .leading).lineLimit(1)
                    Text(p.title).font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    if let ok = p.ok {
                        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(ok ? .green : .orange).font(.caption)
                            .help(ok ? L("Radio turned on") : L("Couldn't turn the radio on"))
                    } else {
                        Button { plans.remove(p) } label: { Image(systemName: "xmark.circle").font(.caption) }
                            .buttonStyle(.borderless).help(L("Remove from plan"))
                    }
                }
            }
        }
    }

    private var syncText: String {
        switch plans.syncState {
        case .idle: return ""
        case .syncing: return L("syncing…")
        case .synced: return L("scheduler ✓")
        case .failed: return L("scheduler unreachable")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button(action: onOpenSettings) { Image(systemName: "gearshape") }.help(L("Settings"))
            Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }.help(L("Refresh"))
            Spacer()
            Button(L("Quit"), action: onQuit)
        }
        .buttonStyle(.borderless)
    }
}

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One favourite station: compact "now on air" line; click plays the preset, chevron expands the day.
private struct FavouriteRow: View {
    let preset: PresetStation
    @ObservedObject var model: RadioModel
    @ObservedObject var guides: GuideStore

    private var isActive: Bool {
        model.isConnected && model.isPowerOn && model.currentMode == 0 && model.activePresetIndex == preset.id
    }
    private var isExpanded: Bool { guides.expanded == preset.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { if model.isConnected { model.selectPreset(preset.id) } } label: {
                    HStack(spacing: 6) {
                        Text("\(preset.id + 1)").font(.caption.monospacedDigit())
                            .foregroundColor(isActive ? .white.opacity(0.85) : .secondary)
                            .frame(width: 16, alignment: .trailing)
                        Text(preset.shortName).font(.callout.weight(.semibold)).lineLimit(1)
                            .frame(width: 74, alignment: .leading)
                        Text(nowTitle).font(.callout).lineLimit(1)
                            .foregroundColor(isActive ? .white : (guides.current(preset) == nil ? .secondary : .primary))
                        Spacer(minLength: 4)
                        if let cur = guides.current(preset) {
                            Text(range(cur)).font(.caption.monospacedDigit())
                                .foregroundColor(isActive ? .white.opacity(0.85) : .secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Play: %@", preset.name))

                if guides.hasGuide(preset) {
                    Button { guides.toggleExpanded(preset) } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(isActive ? .white : .secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? L("Collapse") : L("Schedule and recently played"))
                } else {
                    Color.clear.frame(width: 18, height: 18)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .foregroundColor(isActive ? .white : .primary)
            .background(RoundedRectangle(cornerRadius: 6).fill(isActive ? Color.accentColor : Color.clear))

            if isExpanded { details.padding(.leading, 28).padding(.trailing, 6).padding(.bottom, 6) }
        }
    }

    private var nowTitle: String {
        if let cur = guides.current(preset) { return cur.title }
        if !guides.hasGuide(preset) { return L("no online schedule") }
        if let err = guides.entry(preset)?.error { return err }
        return guides.entry(preset)?.scheduleFetched == nil ? L("loading…") : "—"
    }

    private func range(_ p: GuideProgram) -> String {
        "\(Guide.hhmm(p.start))–\(p.end.map(Guide.hhmm) ?? "…")"
    }

    @ViewBuilder private var details: some View {
        let now = Date()
        let entry = guides.entry(preset)
        VStack(alignment: .leading, spacing: 6) {
            if let cur = guides.current(preset), let host = cur.host {
                Text(host).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
            if let next = guides.next(preset) {
                Text(L("Next %@: %@", Guide.hhmm(next.start), next.title)).font(.caption).lineLimit(1)
            }
            // Only the running show and what's still to come.
            let schedule = (entry?.schedule ?? []).filter { ($0.end ?? $0.start.addingTimeInterval(3600)) > now }
            if schedule.count > 1 {
                Text(L("Today's schedule")).font(.caption.weight(.semibold)).foregroundColor(.secondary).padding(.top, 2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(schedule) { p in
                            let isNow = p.start <= now && (p.end ?? .distantFuture) > now
                            let isPast = (p.end ?? p.start) <= now
                            HStack(alignment: .top, spacing: 6) {
                                Text(Guide.hhmm(p.start)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .leading)
                                Text(p.title).font(.caption.weight(isNow ? .bold : .regular)).lineLimit(1)
                                Spacer(minLength: 2)
                                DescriptionIcon(station: preset, program: p, guides: guides)
                            }
                            .foregroundColor(isNow ? .accentColor : (isPast ? .secondary : .primary))
                            DescriptionText(program: p, guides: guides).padding(.leading, 42)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 16)          // keep ⓘ clear of the overlay scroll bar
                }
                .frame(maxHeight: 130)
            }
            if let tracks = entry?.tracks, !tracks.isEmpty {
                Text(L("Recently played")).font(.caption.weight(.semibold)).foregroundColor(.secondary).padding(.top, 2)
                ForEach(tracks.prefix(5)) { t in
                    HStack(spacing: 6) {
                        Text(t.time ?? "").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                            .frame(width: 36, alignment: .leading)
                        Text(t.display).font(.caption).lineLimit(1)
                        Spacer(minLength: 2)
                        Button { model.openOnYouTube(t.display) } label: {
                            Image(systemName: "heart").font(.caption).foregroundColor(.pink)
                        }
                        .buttonStyle(.borderless).help(L("Search on YouTube"))
                    }
                }
            } else if entry?.tracksFetched != nil {
                Text(L("The station doesn't publish a playlist.")).font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

/// Small ⓘ next to a show; clicking unfolds the description (see `DescriptionText`).
struct DescriptionIcon: View {
    let station: PresetStation
    let program: GuideProgram
    @ObservedObject var guides: GuideStore

    var body: some View {
        if guides.hasDescription(program) {
            let open = guides.openDescription == program.id
            Button {
                guides.openDescription = open ? nil : program.id
                if !open, guides.description(program) == nil {
                    guides.loadDescriptions(station, programs: [program])
                }
            } label: {
                Image(systemName: open ? "info.circle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundColor(open ? .accentColor : .secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Unfolded description under a show row (only for the show opened with `DescriptionIcon`).
struct DescriptionText: View {
    let program: GuideProgram
    @ObservedObject var guides: GuideStore

    var body: some View {
        if guides.openDescription == program.id {
            Text(guides.description(program) ?? (guides.hasDescription(program) ? L("Loading description…") : L("No description.")))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        }
    }
}
