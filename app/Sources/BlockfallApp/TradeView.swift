// ============================================================================
// Blockfall — TradeView (#203 kid-friendly money + trade)
// A simple centred panel listing a villager profession's offer sheet: each row
// reads "pay N x Item -> get M x Item" with a big Trade button. Coins are a
// plain inventory item; the engine validates and swaps atomically
// (bf_trade_execute), so this view is pure presentation + clicks. The world
// stays paused-by-pointer exactly like the dialogue it replaces.
// ============================================================================
import AppKit
import CBlockcore

final class TradeView: NSView {
    struct Offer {
        let giveItem: UInt16, giveCount: UInt16
        let getItem: UInt16, getCount: UInt16
    }
    private var offers: [Offer] = []
    private var npcId: Int32 = 0
    weak var renderer: Renderer?
    var onClose: (() -> Void)?
    var onTraded: (() -> Void)?   // audio hook

    private let panel = NSView()
    private var coinLabel = NSTextField(labelWithString: "")

    init(frame: NSRect, npcId: Int32, renderer: Renderer?) {
        super.init(frame: frame)
        self.npcId = npcId
        self.renderer = renderer
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.55).cgColor
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    override var acceptsFirstResponder: Bool { true }
    // #227: NO hitTest override. Returning self swallowed every click meant for
    // the child Trade/Done buttons and trapped the player in the panel; default
    // hit testing routes clicks to the buttons, and the full-screen dim view
    // still blocks the game beneath.
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onClose?() }   // Esc
    }

    private func reload() {
        offers = renderer?.tradeOffers(npcId: npcId) ?? []
        rebuildPanel()
    }

    private func rebuildPanel() {
        subviews.forEach { $0.removeFromSuperview() }
        var rows: [NSView] = []

        let title = NSTextField(labelWithString: "Trading Post")
        title.font = .boldSystemFont(ofSize: 26); title.textColor = .white
        rows.append(title)

        // Live coin balance so kids always know what they can afford.
        let coins = renderer?.inventoryCount(item: 96) ?? 0
        coinLabel = NSTextField(labelWithString: "Your coins: \(coins)")
        coinLabel.font = .boldSystemFont(ofSize: 18)
        coinLabel.textColor = NSColor(calibratedRed: 0.98, green: 0.84, blue: 0.30, alpha: 1)
        rows.append(coinLabel)

        for (i, o) in offers.enumerated() {
            let line = "\(o.giveCount) x \(itemName(o.giveItem))   \u{2192}   \(o.getCount) x \(itemName(o.getItem))"
            let lbl = NSTextField(labelWithString: line)
            lbl.font = .systemFont(ofSize: 17); lbl.textColor = .white
            let btn = NSButton(title: "Trade", target: self, action: #selector(tradeClicked(_:)))
            btn.tag = i
            btn.bezelStyle = .regularSquare; btn.isBordered = false; btn.wantsLayer = true
            btn.layer?.backgroundColor = NSColor(calibratedRed: 0.80, green: 0.62, blue: 0.20, alpha: 1).cgColor
            btn.layer?.cornerRadius = 8
            btn.attributedTitle = NSAttributedString(string: "Trade", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.white])
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: 92).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 34).isActive = true
            let row = NSStackView(views: [lbl, NSView(), btn])
            row.orientation = .horizontal; row.spacing = 12
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: 480).isActive = true
            rows.append(row)
        }

        let closeBtn = NSButton(title: "Done", target: self, action: #selector(closeClicked))
        closeBtn.bezelStyle = .regularSquare; closeBtn.isBordered = false; closeBtn.wantsLayer = true
        closeBtn.layer?.backgroundColor = NSColor(calibratedRed: 0.30, green: 0.62, blue: 0.42, alpha: 1).cgColor
        closeBtn.layer?.cornerRadius = 10
        closeBtn.attributedTitle = NSAttributedString(string: "Done", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.white])
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.widthAnchor.constraint(equalToConstant: 480).isActive = true
        closeBtn.heightAnchor.constraint(equalToConstant: 40).isActive = true
        rows.append(closeBtn)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.spacing = 14; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        panel.subviews.forEach { $0.removeFromSuperview() }
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 0.96).cgColor
        panel.layer?.cornerRadius = 16
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        addSubview(panel)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -24),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func tradeClicked(_ sender: NSButton) {
        guard let r = renderer else { return }
        if r.tradeExecute(npcId: npcId, index: UInt32(sender.tag)) {
            onTraded?()
        } else {
            NSSound.beep()   // short payment / full inventory: gentle no
        }
        reload()   // refresh coin balance (offer sheet is static)
    }

    @objc private func closeClicked() { onClose?() }
}
