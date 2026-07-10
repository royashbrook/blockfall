// #82 villager dialogue: loads content/dialogue/village_npcs.json and shows a simple
// branching dialogue overlay when the player right-clicks a villager (the engine fires a
// dialogue event with the villager's npc_id). Quests are driven by the engine; this is the
// flavour + objective text, so the UI only navigates nodes and never starts quests itself.
import AppKit

struct DialogueChoice: Codable {
    let label: String
    let target: Int
    enum CodingKeys: String, CodingKey { case label; case target = "goto" }
}
struct DialogueNode: Codable {
    let id: Int
    let text: String
    let gives_quest: Int?
    let choices: [DialogueChoice]
}
struct DialogueNPC: Codable {
    let npc_id: Int
    let name: String
    let root: Int?
    let nodes: [DialogueNode]
}

// #239: the dim backdrop closes the dialogue on a click outside the panel
// (the panel is a subview, so its own clicks never reach here).
private final class DialogueBackdrop: NSView {
    var onBackgroundClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onBackgroundClick?() }
}

final class DialogueController {
    // #203: trade wiring. hasTrade asks the engine whether this profession has an
    // offer sheet; onOpenTrade swaps the dialogue for the trade panel.
    var hasTrade: ((Int) -> Bool)? = nil
    var onOpenTrade: ((Int) -> Void)? = nil
    // #227: explicit donation. Set for trade-role villagers; clicking sends the
    // donate action (the engine validates the held item and toasts the result).
    var onDonate: ((Int) -> Void)? = nil
    private var currentNpcId: Int = 0
    private var npcs: [DialogueNPC] = []
    private weak var overlay: NSView?
    var onClose: (() -> Void)?
    var isOpen: Bool { overlay != nil }
    // #240: nameplate title ("Pip the Woodcutter") shown instead of the roster
    // name when the app passes one at open.
    private var titleOverride: String? = nil
    // #239: Esc closes; walking away closes. The sim keeps running behind the
    // dialogue, so a per-frame position hook drives the distance check.
    private var escMonitor: Any? = nil
    private var openPos: (x: Float, z: Float)? = nil
    func playerMoved(x: Float, z: Float) {
        guard isOpen else { openPos = nil; return }
        guard let p = openPos else { openPos = (x, z); return }
        // Nearest-image deltas: a chat at the torus seam must not read as 32k.
        let period: Float = 32768
        var dx = x - p.x; dx -= period * (dx / period).rounded()
        var dz = z - p.z; dz -= period * (dz / period).rounded()
        if dx * dx + dz * dz > 5.0 * 5.0 {
            NSLog("dlg: walk-away close (moved %.1f blocks)", (dx * dx + dz * dz).squareRoot())
            close()
        }
    }

    // #239 probe seam: how many NPC trees loaded (0 = dialogue can never open).
    var loadedNPCCount: Int { npcs.count }

    func load() {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("content/dialogue/village_npcs.json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([DialogueNPC].self, from: data) else {
            NSLog("Blockfall: dialogue load failed")
            return
        }
        npcs = list
    }

    func show(npcId: Int, in parent: NSView, title: String? = nil) {
        guard !isOpen else { return }
        // Fall back to the first NPC if the id is unknown so a villager always says something.
        let npc = npcs.first(where: { $0.npc_id == npcId }) ?? npcs.first
        guard let npc = npc else { return }

        let ov = DialogueBackdrop(frame: parent.bounds)
        ov.autoresizingMask = [.width, .height]
        ov.wantsLayer = true
        ov.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.55).cgColor
        ov.onBackgroundClick = { [weak self] in self?.close() }
        parent.addSubview(ov)
        overlay = ov
        currentNpcId = npcId
        titleOverride = (title?.isEmpty == false) ? title : nil
        openPos = nil   // first playerMoved after open anchors the walk-away check
        // #239: Esc leaves the chat, same as every other overlay.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53, self?.isOpen == true { self?.close(); return nil }
            return e
        }
        showNode(npc, npc.root ?? 0)
    }

    private func showNode(_ npc: DialogueNPC, _ nodeId: Int) {
        guard let ov = overlay else { return }
        ov.subviews.forEach { $0.removeFromSuperview() }
        guard nodeId >= 0, let node = npc.nodes.first(where: { $0.id == nodeId }) else { close(); return }

        // #240: prefer the live nameplate title ("Pip the Woodcutter") so the
        // chat header names the exact villager clicked, not a roster stand-in.
        let nameLbl = NSTextField(labelWithString: titleOverride ?? npc.name)
        nameLbl.font = .boldSystemFont(ofSize: 22); nameLbl.textColor = .white

        // #239: an X in the corner so leaving never requires picking a line.
        let xBtn = NSButton(title: "✕", target: self, action: #selector(closeClicked))
        xBtn.bezelStyle = .regularSquare; xBtn.isBordered = false; xBtn.wantsLayer = true
        xBtn.layer?.backgroundColor = NSColor(calibratedRed: 0.55, green: 0.22, blue: 0.22, alpha: 1).cgColor
        xBtn.layer?.cornerRadius = 8
        xBtn.attributedTitle = NSAttributedString(string: "✕", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.white])
        xBtn.translatesAutoresizingMaskIntoConstraints = false
        xBtn.widthAnchor.constraint(equalToConstant: 32).isActive = true
        xBtn.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let textLbl = NSTextField(wrappingLabelWithString: node.text)
        textLbl.font = .systemFont(ofSize: 16); textLbl.textColor = .white
        textLbl.alignment = .left
        textLbl.translatesAutoresizingMaskIntoConstraints = false
        textLbl.widthAnchor.constraint(equalToConstant: 460).isActive = true

        let header = NSStackView(views: [nameLbl, NSView(), xBtn])
        header.orientation = .horizontal; header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: 460).isActive = true

        var rows: [NSView] = [header, textLbl]
        let choices = node.choices.isEmpty ? [DialogueChoice(label: "Goodbye.", target: -1)] : node.choices
        for (i, ch) in choices.enumerated() {
            let b = NSButton(title: ch.label, target: self, action: #selector(choiceClicked(_:)))
            b.tag = ch.target
            b.bezelStyle = .regularSquare; b.isBordered = false; b.wantsLayer = true
            b.layer?.backgroundColor = NSColor(calibratedRed: 0.30, green: 0.62, blue: 0.42, alpha: 1).cgColor
            b.layer?.cornerRadius = 10
            b.attributedTitle = NSAttributedString(string: ch.label, attributes: [
                .font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.white])
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 460).isActive = true
            b.heightAnchor.constraint(equalToConstant: 40).isActive = true
            b.identifier = NSUserInterfaceItemIdentifier("dlg")
            rows.append(b)
            _ = i
        }
        // #227: trade-role villagers (Woodcutter 4, Mason 5, Blacksmith 6) take
        // building donations, but only when the player ASKS.
        if [4, 5, 6].contains(currentNpcId), onDonate != nil {
            let db = NSButton(title: "Donate held items to the village",
                              target: self, action: #selector(donateClicked(_:)))
            db.bezelStyle = .regularSquare; db.isBordered = false; db.wantsLayer = true
            db.layer?.backgroundColor = NSColor(calibratedRed: 0.36, green: 0.46, blue: 0.72, alpha: 1).cgColor
            db.layer?.cornerRadius = 10
            db.attributedTitle = NSAttributedString(string: "Donate held items to the village", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.white])
            db.translatesAutoresizingMaskIntoConstraints = false
            db.widthAnchor.constraint(equalToConstant: 460).isActive = true
            db.heightAnchor.constraint(equalToConstant: 40).isActive = true
            rows.append(db)
        }
        // #203: a gold Trade button above Goodbye when this profession trades.
        if hasTrade?(currentNpcId) == true {
            let tb = NSButton(title: "Trade", target: self, action: #selector(tradeClicked(_:)))
            tb.bezelStyle = .regularSquare; tb.isBordered = false; tb.wantsLayer = true
            tb.layer?.backgroundColor = NSColor(calibratedRed: 0.80, green: 0.62, blue: 0.20, alpha: 1).cgColor
            tb.layer?.cornerRadius = 10
            tb.attributedTitle = NSAttributedString(string: "Trade", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.white])
            tb.translatesAutoresizingMaskIntoConstraints = false
            tb.widthAnchor.constraint(equalToConstant: 460).isActive = true
            tb.heightAnchor.constraint(equalToConstant: 40).isActive = true
            rows.append(tb)
        }
        // Stash the current npc so the click handler can navigate.
        currentNPC = npc

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.spacing = 14; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 0.96).cgColor
        panel.layer?.cornerRadius = 16
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        ov.addSubview(panel)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -24),
            panel.centerXAnchor.constraint(equalTo: ov.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: ov.centerYAnchor),
        ])
    }

    @objc private func donateClicked(_ sender: NSButton) {
        let npc = currentNpcId
        close()   // engine toast reports the result on the HUD
        onDonate?(npc)
    }

    @objc private func tradeClicked(_ sender: NSButton) {
        let npc = currentNpcId
        closeForHandoff()   // #227: no mouse re-grab, the trade panel needs the pointer
        onOpenTrade?(npc)
    }

    private var currentNPC: DialogueNPC?
    @objc private func choiceClicked(_ sender: NSButton) {
        guard let npc = currentNPC else { close(); return }
        if sender.tag < 0 { close() } else { showNode(npc, sender.tag) }
    }

    @objc private func closeClicked() { close() }

    func close() {
        overlay?.removeFromSuperview(); overlay = nil
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        openPos = nil
        onClose?()
    }

    // #227: hand off to another overlay (the trade panel) WITHOUT firing onClose,
    // which grabs the mouse back and traps the pointer under the new panel.
    private func closeForHandoff() {
        overlay?.removeFromSuperview(); overlay = nil
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        openPos = nil
    }
}
