// ============================================================================
// Blockfall — MenuController
// Kid-friendly main menu: title screen, world selection, new-world creation,
// and a How to Play overlay. Pure AppKit, no external deps.
//
// LEAD WIRING NOTES
// ─────────────────
// 1. At launch, replace the game content view:
//      menuController = MenuController()
//      menuController.onPlayWorld = { saveDir, worldName, isNew in
//          // build your Renderer / GameView with saveDir, swap contentView
//          window.contentView = gameContainerView
//      }
//      menuController.onQuit = { NSApp.terminate(nil) }
//      window.contentView = menuController.rootView
//
// 2. To return to the menu from in-game (e.g. Esc from game):
//      menuController.refresh()          // re-scan worlds folder
//      window.contentView = menuController.rootView
//
// Worlds folder: ~/Library/Application Support/Blockfall/worlds/
// Each world is a sub-directory; folder name == world name.
// saveDir passed to onPlayWorld is that subfolder's absolute path.
// ============================================================================

import AppKit
import Foundation

// MARK: - WorldInfo

private struct WorldInfo {
    let name: String
    let saveDir: String
    let lastPlayed: Date?
}

// MARK: - BlockBackground (decorative blocky backdrop)

/// Draws a grid of colorful voxel-ish squares as a menu background.
private final class BlockBackgroundView: NSView {

    private struct Block {
        var x: CGFloat, y: CGFloat, size: CGFloat
        var color: NSColor
    }
    private var blocks: [Block] = []

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        rebuildBlocks()
    }

    private func rebuildBlocks() {
        blocks.removeAll(keepingCapacity: true)
        let palette: [NSColor] = [
            NSColor(red: 0.33, green: 0.70, blue: 0.31, alpha: 1), // grass green
            NSColor(red: 0.55, green: 0.37, blue: 0.22, alpha: 1), // dirt brown
            NSColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1), // stone grey
            NSColor(red: 0.20, green: 0.55, blue: 0.85, alpha: 1), // sky blue
            NSColor(red: 0.95, green: 0.85, blue: 0.20, alpha: 1), // sand yellow
            NSColor(red: 0.72, green: 0.28, blue: 0.28, alpha: 1), // brick red
            NSColor(red: 0.27, green: 0.55, blue: 0.42, alpha: 1), // teal
            NSColor(red: 0.82, green: 0.61, blue: 0.22, alpha: 1), // oak wood
        ]
        let size: CGFloat = 48
        let cols = Int(ceil(bounds.width  / size)) + 1
        let rows = Int(ceil(bounds.height / size)) + 1
        var rng: UInt64 = 0x12345678
        func nextRand() -> Double {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Double(rng >> 33) / Double(UInt32.max)
        }
        for row in 0..<rows {
            for col in 0..<cols {
                let base = palette[Int(nextRand() * Double(palette.count)) % palette.count]
                // darken every other block slightly for a checkerboard depth
                let bright = (row + col) % 2 == 0 ? 1.0 : 0.88
                let color = base.withAlphaComponent(CGFloat(bright))
                blocks.append(Block(x: CGFloat(col) * size,
                                    y: CGFloat(row) * size,
                                    size: size,
                                    color: color))
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Sky-blue fill for anything not covered
        NSColor(red: 0.40, green: 0.72, blue: 0.95, alpha: 1).setFill()
        bounds.fill()
        for b in blocks {
            b.color.setFill()
            let r = NSRect(x: b.x, y: b.y, width: b.size - 1, height: b.size - 1)
            r.fill()
        }
        // Gradient overlay so the title area is readable (top is darker sky)
        let g = NSGradient(colors: [
            NSColor.black.withAlphaComponent(0.55),
            NSColor.black.withAlphaComponent(0.15),
            NSColor.black.withAlphaComponent(0.42),
        ], atLocations: [0, 0.35, 1.0], colorSpace: .sRGB)
        g?.draw(in: bounds, angle: 270)
    }
}

// MARK: - RoundButton (chunky kid-friendly button)

private final class RoundButton: NSButton {

    var normalColor  = NSColor(red: 0.20, green: 0.72, blue: 0.35, alpha: 1)
    var hoverColor   = NSColor(red: 0.28, green: 0.85, blue: 0.44, alpha: 1)
    var pressColor   = NSColor(red: 0.14, green: 0.55, blue: 0.26, alpha: 1)

    private var hovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 14
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true;  needsDisplay = true }
    override func mouseExited(with event: NSEvent)  { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let color = hovered ? hoverColor : normalColor
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        // Drop-shadow effect: a darker bottom edge
        let shadow = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: 5),
                                  xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.25).setFill()
        shadow.fill()
        // Label
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 18),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
            .strokeColor: NSColor.black.withAlphaComponent(0.4),
            .strokeWidth: -1.5,
        ]
        let labelStr = title as NSString
        let textH: CGFloat = 22
        let textRect = NSRect(x: 0, y: (bounds.height - textH) / 2, width: bounds.width, height: textH)
        labelStr.draw(in: textRect, withAttributes: attrs)
    }
}

// MARK: - WorldRowView

private protocol WorldRowDelegate: AnyObject {
    func worldRowDidTapPlay(name: String, saveDir: String)
    func worldRowDidTapDelete(name: String, saveDir: String)
}

private final class WorldRowView: NSView {

    private let info: WorldInfo
    private weak var delegate: WorldRowDelegate?

    init(info: WorldInfo, delegate: WorldRowDelegate) {
        self.info = info
        self.delegate = delegate
        super.init(frame: .zero)
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.cornerRadius = 12

        // World name
        let nameLabel = NSTextField(labelWithString: info.name)
        nameLabel.font = NSFont.boldSystemFont(ofSize: 17)
        nameLabel.textColor = .white
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        // Last played
        let dateStr: String
        if let d = info.lastPlayed {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium; fmt.timeStyle = .short
            dateStr = "Last played: \(fmt.string(from: d))"
        } else {
            dateStr = "New world"
        }
        let dateLabel = NSTextField(labelWithString: dateStr)
        dateLabel.font = NSFont.systemFont(ofSize: 12)
        dateLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dateLabel)

        // Play button
        let playBtn = RoundButton(frame: .zero)
        playBtn.normalColor = NSColor(red: 0.15, green: 0.65, blue: 0.30, alpha: 1)
        playBtn.hoverColor  = NSColor(red: 0.22, green: 0.80, blue: 0.40, alpha: 1)
        playBtn.title = "▶  Play"
        playBtn.target = self
        playBtn.action = #selector(tappedPlay)
        playBtn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playBtn)

        // Delete button
        let delBtn = RoundButton(frame: .zero)
        delBtn.normalColor = NSColor(red: 0.72, green: 0.18, blue: 0.18, alpha: 1)
        delBtn.hoverColor  = NSColor(red: 0.88, green: 0.25, blue: 0.25, alpha: 1)
        delBtn.title = "🗑"
        delBtn.target = self
        delBtn.action = #selector(tappedDelete)
        delBtn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(delBtn)

        // Label stack
        let labelStack = NSStackView(views: [nameLabel, dateLabel])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 2
        labelStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelStack)

        NSLayoutConstraint.activate([
            labelStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: playBtn.leadingAnchor, constant: -8),

            playBtn.trailingAnchor.constraint(equalTo: delBtn.leadingAnchor, constant: -10),
            playBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            playBtn.widthAnchor.constraint(equalToConstant: 110),
            playBtn.heightAnchor.constraint(equalToConstant: 42),

            delBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            delBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            delBtn.widthAnchor.constraint(equalToConstant: 44),
            delBtn.heightAnchor.constraint(equalToConstant: 42),

            heightAnchor.constraint(equalToConstant: 68),
        ])
    }

    @objc private func tappedPlay() {
        delegate?.worldRowDidTapPlay(name: info.name, saveDir: info.saveDir)
    }

    /// UserDefaults key for the "don't ask again" delete preference. When true,
    /// deleting a world skips the confirmation sheet. Defaults to false (ask).
    static let skipDeleteConfirmKey = "skipDeleteConfirm"

    @objc private func tappedDelete() {
        // If the player has opted out of the confirmation, delete right away.
        if UserDefaults.standard.bool(forKey: WorldRowView.skipDeleteConfirmKey) {
            delegate?.worldRowDidTapDelete(name: info.name, saveDir: info.saveDir)
            return
        }

        guard let window = self.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \"\(info.name)\"?"
        alert.informativeText = "This will erase the world forever. You can't undo this!"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Keep It")
        alert.alertStyle = .warning

        // A single checkbox that lets the player skip this sheet next time.
        let skipBox = NSButton(checkboxWithTitle: "Don't ask me again", target: nil, action: nil)
        skipBox.state = .off
        alert.accessoryView = skipBox

        alert.beginSheetModal(for: window) { [weak self] resp in
            if resp == .alertFirstButtonReturn {
                guard let self = self else { return }
                // Remember the choice only when the player confirms the delete.
                if skipBox.state == .on {
                    UserDefaults.standard.set(true, forKey: WorldRowView.skipDeleteConfirmKey)
                }
                self.delegate?.worldRowDidTapDelete(name: self.info.name, saveDir: self.info.saveDir)
            }
        }
    }
}

// MARK: - HowToPlayOverlay

private final class HowToPlayOverlay: NSView {

    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.80).cgColor

        // Panel
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(red: 0.10, green: 0.18, blue: 0.32, alpha: 0.98).cgColor
        panel.layer?.cornerRadius = 24
        panel.layer?.borderWidth = 3
        panel.layer?.borderColor = NSColor(red: 0.38, green: 0.72, blue: 1.0, alpha: 0.8).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        // Title
        let title = NSTextField(labelWithString: "How to Play 🎮")
        title.font = NSFont.boldSystemFont(ofSize: 28)
        title.textColor = NSColor(red: 0.95, green: 0.85, blue: 0.20, alpha: 1) // gold
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        // Controls list
        let controls: [(String, String)] = [
            ("🖱  Click in game",   "Lock the mouse so you can look around"),
            ("W A S D",             "Walk forward, left, backward, right"),
            ("Space",               "Jump!"),
            ("Shift",               "Sneak / go down slowly"),
            ("Hold Left Click",     "Mine a block (break it!)"),
            ("Right Click",         "Place a block from your hand"),
            ("1 – 9",               "Pick a slot in your hotbar"),
            ("E",                   "Open / close your backpack"),
            ("C",                   "Switch Creative ↔ Survival mode"),
            ("G",                   "Ask the Guide for a hint!"),
            ("Esc",                 "Release the mouse / pause"),
            ("H",                   "Host a LAN game for friends"),
            ("J",                   "Join a friend's LAN game"),
        ]

        let rows = controls.map { (key, desc) -> NSView in
            let keyLabel = NSTextField(labelWithString: key)
            keyLabel.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
            keyLabel.textColor = NSColor(red: 0.40, green: 0.90, blue: 0.55, alpha: 1)
            keyLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

            let descLabel = NSTextField(labelWithString: desc)
            descLabel.font = NSFont.systemFont(ofSize: 14)
            descLabel.textColor = NSColor.white.withAlphaComponent(0.90)
            descLabel.lineBreakMode = .byWordWrapping
            descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let row = NSStackView(views: [keyLabel, descLabel])
            row.orientation = .horizontal
            row.spacing = 16
            row.alignment = .centerY
            NSLayoutConstraint.activate([
                keyLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            ])
            return row
        }

        let encouragement = NSTextField(labelWithString: "💡 Tip: Start in Creative mode to build anything for free!")
        encouragement.font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
        encouragement.textColor = NSColor(red: 0.95, green: 0.85, blue: 0.20, alpha: 0.85)
        encouragement.alignment = .center

        let closeBtn = RoundButton(frame: .zero)
        closeBtn.normalColor = NSColor(red: 0.20, green: 0.55, blue: 0.90, alpha: 1)
        closeBtn.hoverColor  = NSColor(red: 0.30, green: 0.68, blue: 1.00, alpha: 1)
        closeBtn.title = "Got it! Let's play! 🚀"
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false

        var allViews: [NSView] = [title]
        allViews.append(contentsOf: rows)
        allViews.append(encouragement)

        let stack = NSStackView(views: allViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        panel.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(equalToConstant: 580),

            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -28),

            closeBtn.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 22),
            closeBtn.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 260),
            closeBtn.heightAnchor.constraint(equalToConstant: 50),
            closeBtn.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -28),
        ])
    }

    @objc private func closeTapped() {
        onClose?()
    }
}

// MARK: - NewWorldPanel

private protocol NewWorldPanelDelegate: AnyObject {
    func newWorldDidCreate(name: String, seed: String, saveDir: String)
    func newWorldDidCancel()
}

private final class NewWorldPanel: NSView {

    weak var delegate: NewWorldPanelDelegate?

    private let nameField: NSTextField
    private let seedField: NSTextField

    init() {
        nameField = NSTextField()
        seedField = NSTextField()
        super.init(frame: .zero)
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.08, green: 0.15, blue: 0.10, alpha: 0.96).cgColor
        layer?.cornerRadius = 20
        layer?.borderWidth = 2.5
        layer?.borderColor = NSColor(red: 0.30, green: 0.80, blue: 0.35, alpha: 0.9).cgColor

        let titleLabel = NSTextField(labelWithString: "✨ Create a New World")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 22)
        titleLabel.textColor = NSColor(red: 0.60, green: 1.00, blue: 0.55, alpha: 1)
        titleLabel.alignment = .center

        // Name field
        let nameLabel = NSTextField(labelWithString: "World Name:")
        nameLabel.font = NSFont.boldSystemFont(ofSize: 14)
        nameLabel.textColor = .white

        nameField.placeholderString = "My World"
        nameField.stringValue = ""
        nameField.font = NSFont.systemFont(ofSize: 16)
        nameField.bezelStyle = .roundedBezel
        nameField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([nameField.heightAnchor.constraint(equalToConstant: 34)])

        // Seed field
        let seedLabel = NSTextField(labelWithString: "Seed (optional):")
        seedLabel.font = NSFont.boldSystemFont(ofSize: 14)
        seedLabel.textColor = .white

        seedField.placeholderString = "Leave blank for a random world!"
        seedField.stringValue = ""
        seedField.font = NSFont.systemFont(ofSize: 14)
        seedField.bezelStyle = .roundedBezel
        seedField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([seedField.heightAnchor.constraint(equalToConstant: 34)])

        // Buttons
        let createBtn = RoundButton(frame: .zero)
        createBtn.normalColor = NSColor(red: 0.15, green: 0.65, blue: 0.30, alpha: 1)
        createBtn.hoverColor  = NSColor(red: 0.22, green: 0.80, blue: 0.40, alpha: 1)
        createBtn.title = "🌱 Create & Play!"
        createBtn.target = self
        createBtn.action = #selector(createTapped)
        createBtn.translatesAutoresizingMaskIntoConstraints = false

        let cancelBtn = RoundButton(frame: .zero)
        cancelBtn.normalColor = NSColor(red: 0.38, green: 0.38, blue: 0.38, alpha: 1)
        cancelBtn.hoverColor  = NSColor(red: 0.52, green: 0.52, blue: 0.52, alpha: 1)
        cancelBtn.title = "← Back"
        cancelBtn.target = self
        cancelBtn.action = #selector(cancelTapped)
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false

        let btnRow = NSStackView(views: [cancelBtn, createBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 16
        btnRow.distribution = .fillEqually
        NSLayoutConstraint.activate([
            cancelBtn.heightAnchor.constraint(equalToConstant: 48),
            createBtn.heightAnchor.constraint(equalToConstant: 48),
        ])

        let stack = NSStackView(views: [titleLabel, nameLabel, nameField,
                                        seedLabel, seedField, btnRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])
    }

    @objc private func createTapped() {
        let rawName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let worldName = rawName.isEmpty ? "My World" : rawName
        let seed = seedField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Pick a folder that doesn't already exist, so each new world is distinct
        // (re-using a name was collapsing the whole list to one world).
        let fm = FileManager.default
        var uniqueName = worldName
        var n = 2
        while fm.fileExists(atPath: MenuController.worldsRoot.appendingPathComponent(uniqueName).path) {
            uniqueName = "\(worldName) \(n)"; n += 1
        }
        let saveDir = MenuController.worldsRoot.appendingPathComponent(uniqueName).path
        do {
            try fm.createDirectory(atPath: saveDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            showError("Couldn't create world folder: \(error.localizedDescription)")
            return
        }
        delegate?.newWorldDidCreate(name: uniqueName, seed: seed, saveDir: saveDir)
    }

    @objc private func cancelTapped() {
        delegate?.newWorldDidCancel()
    }

    private func showError(_ msg: String) {
        guard let window = self.window else { return }
        let alert = NSAlert()
        alert.messageText = "Oops!"
        alert.informativeText = msg
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { _ in }
    }
}

// MARK: - MenuController (public API)

/// Self-contained main-menu controller for Blockfall.
/// Install `rootView` as the window's contentView, then wire
/// `onPlayWorld` and `onQuit` before showing the window.
final class MenuController: NSObject {

    // ── Public API ────────────────────────────────────────────────────────────

    /// The full-screen menu view. Set as `window.contentView` at launch.
    let rootView: NSView

    /// Called when the player picks a world to enter.
    /// - saveDir: absolute path to the world's folder (create/pass to engine)
    /// - worldName: display name
    /// - isNew: true when freshly created
    var onPlayWorld: ((_ saveDir: String, _ worldName: String, _ isNew: Bool, _ seed: UInt64) -> Void)?

    /// Called when the player taps Quit.
    var onQuit: (() -> Void)?

    /// Re-scan the worlds folder and rebuild the world list.
    func refresh() {
        worlds = MenuController.loadWorlds()
        rebuildWorldList()
    }

    // ── Internal layout pieces ────────────────────────────────────────────────

    private var worlds: [WorldInfo] = []

    /// Stack that holds world rows.
    private var worldListStack: NSStackView!

    /// Panel shown when creating a new world.
    private var newWorldPanel: NewWorldPanel!

    /// How-to-play overlay.
    private var howToPlayOverlay: HowToPlayOverlay!

    // ── Worlds-folder convention ──────────────────────────────────────────────

    static var worldsRoot: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Blockfall/worlds", isDirectory: true)
    }

    private static func loadWorlds() -> [WorldInfo] {
        let root = worldsRoot
        // Ensure the directory exists.
        try? FileManager.default.createDirectory(at: root,
                                                  withIntermediateDirectories: true,
                                                  attributes: nil)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        return entries.compactMap { url -> WorldInfo? in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard isDir.boolValue else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate
            return WorldInfo(name: url.lastPathComponent, saveDir: url.path, lastPlayed: date)
        }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    // ── Init ──────────────────────────────────────────────────────────────────

    override init() {
        // Build root first so super.init can run before we use self in callbacks.
        let root = BlockBackgroundView()
        root.translatesAutoresizingMaskIntoConstraints = false
        rootView = root

        super.init()

        worlds = MenuController.loadWorlds()
        buildMenu(in: root)
    }

    // ── View construction ─────────────────────────────────────────────────────

    private func buildMenu(in root: NSView) {
        root.wantsLayer = true

        // ── Title "BLOCKFALL" ──────────────────────────────────────────────
        let titleLabel = NSTextField(labelWithString: "BLOCKFALL")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 72)
        titleLabel.textColor = NSColor(red: 0.98, green: 0.88, blue: 0.15, alpha: 1)
        titleLabel.alignment = .center
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        // Manual text shadow via layer shadow
        titleLabel.wantsLayer = true
        titleLabel.layer?.shadowColor = NSColor.black.cgColor
        titleLabel.layer?.shadowOpacity = 0.9
        titleLabel.layer?.shadowRadius = 6
        titleLabel.layer?.shadowOffset = CGSize(width: 3, height: -3)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: "A block-building adventure!")
        subtitleLabel.font = NSFont.systemFont(ofSize: 20, weight: .medium)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.90)
        subtitleLabel.alignment = .center
        subtitleLabel.isBezeled = false
        subtitleLabel.drawsBackground = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // ── World list panel ───────────────────────────────────────────────
        let listPanel = makeListPanel()
        listPanel.translatesAutoresizingMaskIntoConstraints = false

        // ── Bottom buttons ─────────────────────────────────────────────────
        let howBtn = RoundButton(frame: .zero)
        howBtn.normalColor = NSColor(red: 0.25, green: 0.52, blue: 0.90, alpha: 1)
        howBtn.hoverColor  = NSColor(red: 0.35, green: 0.65, blue: 1.00, alpha: 1)
        howBtn.title = "❓ How to Play"
        howBtn.target = self
        howBtn.action = #selector(showHowToPlay)
        howBtn.translatesAutoresizingMaskIntoConstraints = false

        let quitBtn = RoundButton(frame: .zero)
        quitBtn.normalColor = NSColor(red: 0.60, green: 0.12, blue: 0.12, alpha: 1)
        quitBtn.hoverColor  = NSColor(red: 0.80, green: 0.18, blue: 0.18, alpha: 1)
        quitBtn.title = "✖  Quit"
        quitBtn.target = self
        quitBtn.action = #selector(quitTapped)
        quitBtn.translatesAutoresizingMaskIntoConstraints = false

        let bottomRow = NSStackView(views: [howBtn, quitBtn])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 20
        bottomRow.distribution = .fillEqually
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        // ── Big one-click quick-start (kids shouldn't have to fill a form) ──
        let playBtn = RoundButton(frame: .zero)
        playBtn.normalColor = NSColor(red: 0.20, green: 0.62, blue: 0.30, alpha: 1)
        playBtn.hoverColor  = NSColor(red: 0.28, green: 0.80, blue: 0.42, alpha: 1)
        playBtn.title = "▶  Start Adventure!"
        playBtn.target = self
        playBtn.action = #selector(quickStartTapped)
        playBtn.translatesAutoresizingMaskIntoConstraints = false

        // ── How-to-play overlay (hidden initially) ─────────────────────────
        howToPlayOverlay = HowToPlayOverlay()
        howToPlayOverlay.isHidden = true
        howToPlayOverlay.translatesAutoresizingMaskIntoConstraints = false
        howToPlayOverlay.onClose = { [weak self] in self?.hideHowToPlay() }

        // ── New-world panel (hidden initially) ────────────────────────────
        newWorldPanel = NewWorldPanel()
        newWorldPanel.isHidden = true
        newWorldPanel.delegate = self
        newWorldPanel.translatesAutoresizingMaskIntoConstraints = false

        // ── Compose ───────────────────────────────────────────────────────
        root.addSubview(titleLabel)
        root.addSubview(subtitleLabel)
        root.addSubview(playBtn)
        root.addSubview(listPanel)
        root.addSubview(bottomRow)
        root.addSubview(newWorldPanel)
        root.addSubview(howToPlayOverlay)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
            titleLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            playBtn.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18),
            playBtn.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            playBtn.widthAnchor.constraint(equalToConstant: 340),
            playBtn.heightAnchor.constraint(equalToConstant: 62),

            listPanel.topAnchor.constraint(equalTo: playBtn.bottomAnchor, constant: 20),
            listPanel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            listPanel.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.72),
            listPanel.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -24),

            bottomRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -32),
            bottomRow.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bottomRow.widthAnchor.constraint(equalToConstant: 440),
            howBtn.heightAnchor.constraint(equalToConstant: 52),
            quitBtn.heightAnchor.constraint(equalToConstant: 52),

            newWorldPanel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            newWorldPanel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            newWorldPanel.widthAnchor.constraint(equalToConstant: 500),

            howToPlayOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            howToPlayOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            howToPlayOverlay.topAnchor.constraint(equalTo: root.topAnchor),
            howToPlayOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    // MARK: World list panel

    private func makeListPanel() -> NSView {
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        panel.layer?.cornerRadius = 20
        panel.layer?.borderWidth = 2
        panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        // Section header
        let header = NSTextField(labelWithString: "🌍  Your Worlds")
        header.font = NSFont.boldSystemFont(ofSize: 20)
        header.textColor = .white
        header.translatesAutoresizingMaskIntoConstraints = false

        // New-world button
        let newBtn = RoundButton(frame: .zero)
        newBtn.normalColor = NSColor(red: 0.15, green: 0.55, blue: 0.85, alpha: 1)
        newBtn.hoverColor  = NSColor(red: 0.22, green: 0.70, blue: 1.00, alpha: 1)
        newBtn.title = "+ New World"
        newBtn.target = self
        newBtn.action = #selector(newWorldTapped)
        newBtn.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView(views: [header, newBtn])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.distribution = .equalSpacing
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        // Scrollable world list
        worldListStack = NSStackView()
        worldListStack.orientation = .vertical
        worldListStack.alignment = .centerX
        worldListStack.spacing = 8
        worldListStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = worldListStack
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(headerRow)
        panel.addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            headerRow.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            headerRow.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            newBtn.widthAnchor.constraint(equalToConstant: 140),
            newBtn.heightAnchor.constraint(equalToConstant: 40),

            scrollView.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),
        ])

        rebuildWorldList()
        return panel
    }

    private func rebuildWorldList() {
        guard let stack = worldListStack else { return }
        // Remove existing rows
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if worlds.isEmpty {
            let empty = NSTextField(labelWithString: "No worlds yet — create one! 👇")
            empty.font = NSFont.systemFont(ofSize: 16)
            empty.textColor = NSColor.white.withAlphaComponent(0.70)
            empty.alignment = .center
            empty.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(empty)
        } else {
            for w in worlds {
                let row = WorldRowView(info: w, delegate: self)
                row.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(row)
                NSLayoutConstraint.activate([
                    row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                    row.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
                ])
            }
        }

        // Force layout so the scroll view knows the content size
        stack.layoutSubtreeIfNeeded()
    }

    // MARK: Actions

    @objc private func newWorldTapped() {
        newWorldPanel.isHidden = false
        newWorldPanel.window?.makeFirstResponder(newWorldPanel)
    }

    /// One click → a fresh world with a random seed, no form. The fast path for kids.
    @objc private func quickStartTapped() {
        let fm = FileManager.default
        var name = "My World"
        var n = 2
        while fm.fileExists(atPath: MenuController.worldsRoot.appendingPathComponent(name).path) {
            name = "My World \(n)"; n += 1
        }
        let saveDir = MenuController.worldsRoot.appendingPathComponent(name).path
        do {
            try fm.createDirectory(atPath: saveDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            showError("Couldn't start a new world: \(error.localizedDescription)")
            return
        }
        let seed = UInt64.random(in: 1...999_999)
        onPlayWorld?(saveDir, name, true, seed)
    }

    private func showError(_ msg: String) {
        let alert = NSAlert()
        alert.messageText = "Oops!"
        alert.informativeText = msg
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func showHowToPlay() {
        howToPlayOverlay.isHidden = false
    }

    private func hideHowToPlay() {
        howToPlayOverlay.isHidden = true
    }

    @objc private func quitTapped() {
        onQuit?()
    }
}

// MARK: - WorldRowDelegate

extension MenuController: WorldRowDelegate {

    func worldRowDidTapPlay(name: String, saveDir: String) {
        onPlayWorld?(saveDir, name, false, 0)   // existing world → load its save
    }

    func worldRowDidTapDelete(name: String, saveDir: String) {
        do {
            try FileManager.default.removeItem(atPath: saveDir)
        } catch {
            // If removal fails, just refresh the list anyway to stay consistent.
        }
        refresh()
    }
}

// MARK: - NewWorldPanelDelegate

extension MenuController: NewWorldPanelDelegate {

    func newWorldDidCreate(name: String, seed: String, saveDir: String) {
        newWorldPanel.isHidden = true
        onPlayWorld?(saveDir, name, true, MenuController.parseSeed(seed))
    }

    /// Turn the seed text box into a world seed: numeric → that number; any other
    /// text → a stable hash; blank → a random seed (each new world is different).
    static func parseSeed(_ s: String) -> UInt64 {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return UInt64.random(in: 1...UInt64.max) }
        if let n = UInt64(t) { return n == 0 ? 1 : n }
        var h: UInt64 = 1469598103934665603        // FNV-1a
        for b in t.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h == 0 ? 1 : h
    }

    func newWorldDidCancel() {
        newWorldPanel.isHidden = true
    }
}
