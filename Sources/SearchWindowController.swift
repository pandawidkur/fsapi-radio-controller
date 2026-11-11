import AppKit

struct RadioStationItem {
    let name: String
    let subtext: String
    let presetIndex: Int?                                  // user's preset on the radio (0-based)
    let catalogStation: CatalogStation?
    let filter: (genre: String?, poland: Bool)?            // catalog list the station was found in
}

/// On-disk copy of the radio's full list of Polish stations. Walking ~900 entries takes over a minute,
/// so it is fetched once and reused for instant name search.
private struct PolishCatalogCache: Codable {
    let fetched: Date
    let stations: [CatalogStation]

    static let maxAge: TimeInterval = 7 * 24 * 3600

    static var url: URL {
        let dir = AppSettings.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog-pl.json")
    }

    static func load() -> PolishCatalogCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PolishCatalogCache.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }

    var isStale: Bool { Date().timeIntervalSince(fetched) > Self.maxAge }
}

/// Station browser backed by the radio's own catalog (like UNDOK), so every result plays on the Napoli.
/// - Name search: instant, over the cached list of all Polish stations in the catalog.
/// - Music style: loads that genre's list from the radio ("Tylko Polska" narrows it to Poland).
final class SearchWindowController: NSWindowController, NSTableViewDelegate, NSTableViewDataSource, NSSearchFieldDelegate {
    private var searchField: NSSearchField!
    private var genrePopup: NSPopUpButton!
    private var polandOnly: NSButton!
    private var tableView: NSTableView!
    private var statusLabel: NSTextField!
    private var playButton: NSButton!
    private var refreshButton: NSButton!
    private var spinner: NSProgressIndicator!

    private let model: RadioModel
    private var genreTask: Task<Void, Never>?
    private var crawlTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var genreDebounce: Timer?

    private var polishCache: PolishCatalogCache?
    private var genreStations: [CatalogStation] = []
    private var genreTotal = 0
    private var genreFilter: (genre: String, poland: Bool)?
    private var results: [RadioStationItem] = []
    private var transientStatus: String?

    private let genres = [L("All genres")] + RadioCatalog.genres.sorted {
        $0.compare($1, locale: Locale(identifier: "pl_PL")) == .orderedAscending
    }

    init(model: RadioModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = L("Search the radio's station catalogue")
        window.minSize = NSSize(width: 520, height: 360)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        setupUI()
        polishCache = PolishCatalogCache.load()
        if polishCache == nil || polishCache!.isStale {
            crawlPolishCatalog()
        }
        rebuildResults()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: UI

    private func setupUI() {
        guard let window = window else { return }
        let content = NSView()
        window.contentView = content

        searchField = NSSearchField()
        searchField.placeholderString = L("Station name (e.g. Kampus, Akadera, 357)…")
        searchField.delegate = self

        genrePopup = NSPopUpButton()
        genres.forEach { genrePopup.addItem(withTitle: $0) }
        genrePopup.target = self
        genrePopup.action = #selector(genreChanged)

        polandOnly = NSButton(checkboxWithTitle: L("Poland only"), target: self, action: #selector(genreChanged))
        polandOnly.state = .on

        let filterRow = NSStackView(views: [searchField, genrePopup, polandOnly])
        filterRow.spacing = 8
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        genrePopup.setContentHuggingPriority(.required, for: .horizontal)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.spacing = 6

        tableView = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Station"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 40
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(playSelected)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        refreshButton = NSButton(title: L("Refresh catalogue"), target: self, action: #selector(refreshCatalog))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        playButton = NSButton(title: L("Play on the radio"), target: self, action: #selector(playSelected))
        playButton.bezelStyle = .rounded
        playButton.keyEquivalent = "\r"
        playButton.isEnabled = false
        let bottomRow = NSStackView(views: [refreshButton, NSView(), playButton])

        for v in [filterRow, statusRow, scroll, bottomRow] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            filterRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            filterRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            filterRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            statusRow.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: 10),
            statusRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusRow.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottomRow.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bottomRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bottomRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottomRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
    }

    // MARK: Filters

    private var selectedGenre: String? {
        genrePopup.indexOfSelectedItem > 0 ? genres[genrePopup.indexOfSelectedItem] : nil
    }

    private var query: String {
        searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func controlTextDidChange(_ obj: Notification) {
        transientStatus = nil
        rebuildResults()
    }

    @objc private func genreChanged() {
        transientStatus = nil
        genreTask?.cancel()
        genreTask = nil
        genreStations = []
        genreFilter = nil
        rebuildResults()
        guard selectedGenre != nil else { return }
        genreDebounce?.invalidate()
        genreDebounce = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.loadGenre()
        }
    }

    @objc private func refreshCatalog() {
        crawlPolishCatalog()
    }

    // MARK: Loading from the radio

    private func crawlPolishCatalog() {
        guard crawlTask == nil else { return }
        genreTask?.cancel()          // both walk the radio's menu; don't interleave
        genreTask = nil
        refreshButton.isEnabled = false
        updateSpinner()
        let catalog = model.catalog
        crawlTask = Task { [weak self] in
            do {
                let result = try await catalog.stations(genre: nil, polandOnly: true, limit: 3000) { msg in
                    Task { @MainActor in
                        self?.transientStatus = L("One-time download of the Polish station list from the radio (about 1–2 min): %@", msg)
                        self?.rebuildResults()
                    }
                }
                let cache = PolishCatalogCache(fetched: Date(), stations: result.items)
                cache.save()
                await MainActor.run {
                    self?.polishCache = cache
                    self?.finishCrawl(nil)
                }
            } catch is CancellationError {
                await MainActor.run { self?.finishCrawl(nil) }
            } catch {
                await MainActor.run { self?.finishCrawl(L("Couldn't load the station list: %@", error.localizedDescription)) }
            }
        }
    }

    private func finishCrawl(_ error: String?) {
        crawlTask = nil
        refreshButton.isEnabled = true
        transientStatus = error
        updateSpinner()
        rebuildResults()
        if selectedGenre != nil && genreFilter == nil { loadGenre() }
    }

    private func loadGenre() {
        guard let genre = selectedGenre, crawlTask == nil else { return }
        let poland = polandOnly.state == .on
        genreTask?.cancel()
        let catalog = model.catalog
        genreTask = Task { [weak self] in
            do {
                let result = try await catalog.stations(genre: genre, polandOnly: poland, limit: 600) { msg in
                    Task { @MainActor in
                        self?.transientStatus = msg
                        self?.rebuildResults()
                    }
                }
                await MainActor.run {
                    guard let self = self, !Task.isCancelled else { return }
                    self.genreStations = result.items
                    self.genreTotal = result.total
                    self.genreFilter = (genre, poland)
                    self.genreTask = nil
                    self.transientStatus = nil
                    self.updateSpinner()
                    self.rebuildResults()
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard let self = self, !Task.isCancelled else { return }
                    self.genreTask = nil
                    self.transientStatus = L("Couldn't load stations: %@", error.localizedDescription)
                    self.updateSpinner()
                    self.rebuildResults()
                }
            }
        }
        updateSpinner()
    }

    private func updateSpinner() {
        let busy = crawlTask != nil || genreTask != nil || playTask != nil
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    // MARK: Results

    private func rebuildResults() {
        let q = query
        var items: [RadioStationItem] = []

        if let genre = selectedGenre {
            if let f = genreFilter, f.genre == genre {
                let sub = "\(f.poland ? L("Poland") : L("Whole world")) · \(genre)"
                items = genreStations
                    .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
                    .map { RadioStationItem(name: $0.name, subtext: sub, presetIndex: nil, catalogStation: $0, filter: (genre, f.poland)) }
            }
        } else {
            items += PresetStore.shared.stations
                .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
                .map { RadioStationItem(name: $0.name, subtext: L("Your preset %d", $0.id + 1), presetIndex: $0.id, catalogStation: nil, filter: nil) }
            if let cache = polishCache {
                items += cache.stations
                    .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
                    .map { RadioStationItem(name: $0.name, subtext: L("Poland"), presetIndex: nil, catalogStation: $0, filter: (nil, true)) }
            }
        }
        results = items
        tableView.reloadData()
        playButton.isEnabled = tableView.selectedRow >= 0
        statusLabel.stringValue = transientStatus ?? idleStatus(count: items.count)
    }

    private func idleStatus(count: Int) -> String {
        if let genre = selectedGenre {
            guard let f = genreFilter, f.genre == genre else {
                return crawlTask != nil ? L("Finishing the Polish station list first…") : L("Asking the radio for stations…")
            }
            let partial = genreStations.count < genreTotal ? " " + L("(loaded %d)", genreStations.count) : ""
            return L("%@: %d stations%@. Matching: %d.", genre, genreTotal, partial, count)
        }
        guard let cache = polishCache else { return L("Loading the station list from the radio…") }
        let age = RelativeDateTimeFormatter().localizedString(for: cache.fetched, relativeTo: Date())
        if query.isEmpty {
            return L("%d Polish stations from the radio's catalogue (loaded %@). Foreign ones: choose a genre and untick “Poland only”.", cache.stations.count, age)
        }
        return count == 0 ? L("No “%@” among Polish stations. Foreign ones: choose a genre.", query) : L("Matching: %d.", count)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("StationCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? StationCellView) ?? StationCellView(identifier: id)
        cell.configure(results[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        playButton.isEnabled = tableView.selectedRow >= 0
    }

    @objc private func playSelected() {
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : tableView.clickedRow
        guard row >= 0, row < results.count else { return }
        let item = results[row]

        if let preset = item.presetIndex {
            transientStatus = L("Playing preset %d: %@", preset + 1, item.name)
            rebuildResults()
            model.selectPreset(preset)
            return
        }
        guard let station = item.catalogStation, let filter = item.filter else { return }
        if crawlTask != nil {
            transientStatus = L("Wait until the list has loaded — the radio can only do one thing at a time.")
            rebuildResults()
            return
        }
        genreTask?.cancel()
        genreTask = nil
        playTask?.cancel()
        let catalog = model.catalog
        transientStatus = L("Starting “%@” on the radio…", station.name)
        rebuildResults()
        playTask = Task { [weak self] in
            var message: String
            do {
                try await catalog.play(station, genre: filter.genre, polandOnly: filter.poland) { msg in
                    Task { @MainActor in
                        self?.transientStatus = msg
                        self?.rebuildResults()
                    }
                }
                message = L("Playing on the radio: %@", station.name)
            } catch is CancellationError {
                return
            } catch {
                message = L("Couldn't play: %@", error.localizedDescription)
            }
            let finalMessage = message
            await MainActor.run {
                guard let self = self else { return }
                self.playTask = nil
                self.transientStatus = finalMessage
                self.updateSpinner()
                self.rebuildResults()
                self.model.stationChangedExternally()
            }
        }
        updateSpinner()
    }
}

private final class StationCellView: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    convenience init(identifier: NSUserInterfaceItemIdentifier) {
        self.init(frame: .zero)
        self.identifier = identifier
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        for v in [icon, title, subtitle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1)
        ])
    }

    func configure(_ s: RadioStationItem) {
        title.stringValue = s.name
        subtitle.stringValue = s.subtext
        let isPreset = s.presetIndex != nil
        icon.image = NSImage(systemSymbolName: isPreset ? "star.fill" : "antenna.radiowaves.left.and.right",
                             accessibilityDescription: nil)
        icon.contentTintColor = isPreset ? .systemYellow : .secondaryLabelColor
    }
}
