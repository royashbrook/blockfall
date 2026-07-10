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

final class DialogueController {
    // #203: trade wiring. hasTrade asks the engine whether this profession has an
    // offer sheet; onOpenTrade swaps the dialogue for the trade panel.
    var hasTrade: ((Int) -> Bool)? = nil
    var onOpenTrade: ((Int) -> Void)? = nil
    private var currentNpcId: Int = 0
    private var npcs: [DialogueNPC] = []
    private weak var overlay: NSView?
    var onClose: (() -> Void)?
    var isOpen: Bool { overlay != nil }

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

    func show(npcId: Int, in parent: NSView) {
        guard !isOpen else { return }
        // Fall back to the first NPC if the id is unknown so a villager always says something.
        let npc = npcs.first(where: { $0.npc_id == npcId }) ?? npcs.first
        guard let npc = npc else { return }

        let ov = NSView(frame: parent.bounds)
        ov.autoresizingMask = [.width, .height]
        ov.wantsLayer = true
        ov.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.55).cgColor
        parent.addSubview(ov)
        overlay = ov
        currentNpcId = npcId
        showNode(npc, npc.root ?? 0)
    }

    private func showNode(_ npc: DialogueNPC, _ nodeId: Int) {
        guard let ov = overlay else { return }
        ov.subviews.forEach { $0.removeFromSuperview() }
        guard nodeId >= 0, let node = npc.nodes.first(where: { $0.id == nodeId }) else { close(); return }

        let nameLbl = NSTextField(labelWithString: npc.name)
        nameLbl.font = .boldSystemFont(ofSize: 22); nameLbl.textColor = .white

        let textLbl = NSTextField(wrappingLabelWithString: node.text)
        textLbl.font = .systemFont(ofSize: 16); textLbl.textColor = .white
        textLbl.alignment = .left
        textLbl.translatesAutoresizingMaskIntoConstraints = false
        textLbl.widthAnchor.constraint(equalToConstant: 460).isActive = true

        var rows: [NSView] = [nameLbl, textLbl]
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

    @objc private func tradeClicked(_ sender: NSButton) {
        let npc = currentNpcId
        close()
        onOpenTrade?(npc)
    }

    private var currentNPC: DialogueNPC?
    @objc private func choiceClicked(_ sender: NSButton) {
        guard let npc = currentNPC else { close(); return }
        if sender.tag < 0 { close() } else { showNode(npc, sender.tag) }
    }

    func close() {
        overlay?.removeFromSuperview(); overlay = nil
        onClose?()
    }
}
