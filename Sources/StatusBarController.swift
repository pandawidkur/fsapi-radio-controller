import AppKit
import SwiftUI
import Combine

/// Menu bar icon (radio glyph only). Left click opens the control panel popover,
/// right click opens a short utility menu, scrolling over the icon changes the volume.
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model = RadioModel()
    private var searchWindowController: SearchWindowController?
    private var scheduleWindowController: ScheduleWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var scrollMonitor: Any?
    private var scrollAccumulator: CGFloat = 0

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        setupButton()
        setupPopover()
        setupScrollToChangeVolume()
        observeModel()
        model.startPolling()
        // First launch: nothing is configured yet, so start with the connection wizard.
        if !AppSettings.shared.isRadioConfigured {
            DispatchQueue.main.async { [weak self] in self?.openSettings() }
        }
    }

    // MARK: Status item

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.radioIcon(slashed: false)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "FSAPI Radio Controller"
    }

    private func observeModel() {
        model.objectWillChange
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.updateButton() }
            .store(in: &cancellables)
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.radioIcon(slashed: !model.isConnected)
        button.appearsDisabled = !model.isConnected || !model.isPowerOn
        var tip = model.statusSummary
        if model.isConnected && model.isPowerOn {
            tip += "\n" + (model.isMuted ? L("Volume: muted") : L("Volume: %d/%d", Int(model.volume), RadioModel.maxVolume))
            tip += "\n" + L("(scroll over the icon to change the volume)")
        }
        button.toolTip = tip
    }

    /// Template radio glyph; when `slashed`, a diagonal stroke marks the missing connection.
    static func radioIcon(slashed: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let base = NSImage(systemSymbolName: "radio", accessibilityDescription: "Radio")?
            .withSymbolConfiguration(config) else { return NSImage() }
        guard slashed else {
            base.isTemplate = true
            return base
        }
        let size = base.size
        let img = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX + 1, y: rect.maxY - 1))
            path.line(to: NSPoint(x: rect.maxX - 1, y: rect.minY + 1))
            path.lineWidth = 1.8
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showUtilityMenu()
        } else {
            togglePopover()
        }
    }

    // MARK: Popover

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = false
        let view = ControlPanelView(
            model: model,
            guides: GuideStore.shared,
            presets: PresetStore.shared,
            plans: PlanStore.shared,
            onOpenSearch: { [weak self] in self?.openStationSearch() },
            onOpenSchedule: { [weak self] in self?.openSchedule() },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { [weak self] in self?.quitApp() }
        )
        let hosting = NSHostingController(rootView: view)
        if #available(macOS 13.0, *) {
            // Size is driven explicitly via `panelHeight`; don't let SwiftUI push its own size.
            hosting.sizingOptions = []
        }
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: ControlPanelView.width, height: 400)

        // Keep the popover exactly as tall as the SwiftUI content (capped to the screen),
        // otherwise NSPopover keeps a stale size and the top of the panel gets clipped.
        model.$panelHeight
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] h in self?.applyPopoverHeight(h) }
            .store(in: &cancellables)
    }

    private func applyPopoverHeight(_ contentHeight: CGFloat) {
        guard contentHeight > 0 else { return }
        let height = min(contentHeight, ControlPanelView.maxHeight).rounded(.up)
        guard abs(popover.contentSize.height - height) > 0.5 else { return }
        popover.contentSize = NSSize(width: ControlPanelView.width, height: height)
        // A shown popover grows upwards (window origin is bottom-left) and slides under the
        // top of the screen; re-anchoring it to the button puts it back below the menu bar.
        if popover.isShown, let button = statusItem.button {
            popover.positioningRect = button.bounds
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            model.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: Right-click menu

    private func showUtilityMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: model.statusSummary, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        if model.isConnected {
            menu.addItem(item(model.isPowerOn ? L("Turn off (standby)") : L("Turn on"), "power", #selector(menuTogglePower)))
            menu.addItem(item(L("Search stations…"), "magnifyingglass", #selector(menuOpenSearch)))
        }
        menu.addItem(item(L("Favourites schedule…"), "calendar", #selector(menuOpenSchedule)))
        menu.addItem(item(L("Refresh connection"), "arrow.clockwise", #selector(menuRefresh)))
        menu.addItem(item(L("Settings…"), "gearshape", #selector(menuSettings)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit"), action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // restore left-click → popover
    }

    private func item(_ title: String, _ symbol: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return i
    }

    @objc private func menuTogglePower() { model.togglePower() }
    @objc private func menuOpenSearch() { openStationSearch() }
    @objc private func menuOpenSchedule() { openSchedule() }
    @objc private func menuRefresh() { model.refresh() }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuQuit() { quitApp() }

    // MARK: Scroll wheel → volume

    private func setupScrollToChangeVolume() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self,
                  let button = self.statusItem.button,
                  event.window === button.window,
                  self.model.isConnected, self.model.isPowerOn else { return event }
            // Trackpads emit many small deltas; accumulate them into whole volume steps.
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
            self.scrollAccumulator += event.isDirectionInvertedFromDevice ? -delta : delta
            let steps = Int(self.scrollAccumulator)
            if steps != 0 {
                self.scrollAccumulator -= CGFloat(steps)
                self.model.nudgeVolume(by: steps)
            }
            return nil
        }
    }

    // MARK: Windows

    private func openStationSearch() {
        popover.performClose(nil)
        if searchWindowController == nil {
            let controller = SearchWindowController(model: model)
            searchWindowController = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        searchWindowController?.showWindow(self)
        searchWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func openSchedule() {
        popover.performClose(nil)
        if scheduleWindowController == nil { scheduleWindowController = ScheduleWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        scheduleWindowController?.showWindow(self)
        scheduleWindowController?.window?.makeKeyAndOrderFront(nil)
        scheduleWindowController?.reload()
    }

    private func openSettings(tab: SettingsState.Tab = .radio) {
        popover.performClose(nil)
        if settingsWindowController == nil { settingsWindowController = SettingsWindowController(model: model) }
        settingsWindowController?.show(tab: tab)
    }

    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
