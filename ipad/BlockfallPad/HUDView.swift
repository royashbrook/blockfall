import QuartzCore
import UIKit
import CBlockcore

/// Safe-area-aware iPad HUD and touch-control layer.
final class HUDView: UIView {
    struct QuestRow {
        let title: String
        let objective: String
        let state: UInt8
        let progress: Float
    }

    struct PeerMarker {
        let onScreen: Bool
        let screenPt: CGPoint
        let edgeDir: CGVector
        let distM: Int
        let color: UIColor
        let label: String
    }

    struct VillagerMarker {
        let key: UInt32
        let screenPt: CGPoint
        let worldPos: SIMD3<Float>
        let dist: Float
    }

    weak var input: GameView?
    var onPause: (() -> Void)?
    var onChestTake: ((Int) -> Void)?
    var onChestClose: (() -> Void)?

    private let lookPad = LookPad()
    private let joystick = VirtualJoystick()
    private let jumpButton = TouchActionButton(
        title: "JUMP",
        tint: UIColor(red: 0.24, green: 0.50, blue: 0.86, alpha: 1)
    )
    private let downButton = TouchActionButton(
        title: "▼",
        tint: UIColor(red: 0.42, green: 0.38, blue: 0.62, alpha: 1)
    )
    private let statusLabel = HUDView.makeLabel(size: 15, alignment: .left, padded: true)
    private let questLabel = HUDView.makeLabel(size: 15, alignment: .center, padded: true)
    private let targetLabel = HUDView.makeLabel(size: 14, alignment: .center, padded: true)
    private let villageLabel = HUDView.makeLabel(size: 14, alignment: .left, padded: true)
    private let crosshair = UILabel()
    private let pauseButton = HUDView.makeTopButton(title: "Ⅱ")
    private let inventoryButton = HUDView.makeTopButton(title: "PACK")
    private let modeButton = HUDView.makeTopButton(title: "MODE")
    private let hotbar = UIStackView()
    private var hotbarButtons: [UIButton] = []
    private var hotbarSlots: [bf_hud_slot] = []
    private var touchControlSize = TouchControlSize.saved
    private var joystickWidth: NSLayoutConstraint!
    private var joystickHeight: NSLayoutConstraint!
    private var jumpWidth: NSLayoutConstraint!
    private var jumpHeight: NSLayoutConstraint!
    private var downWidth: NSLayoutConstraint!
    private var downHeight: NSLayoutConstraint!
    private var hotbarHeight: NSLayoutConstraint!

    private let inventoryPanel = UIView()
    private var inventoryButtons: [UIButton] = []
    private var craftButtons: [UIButton] = []
    private let craftTitleLabel = HUDView.makeLabel(size: 14, alignment: .left)
    private var inventoryVisible = false

    private let chestPanel = UIView()
    private var chestButtons: [UIButton] = []

    private var playerX: Float = 0
    private var playerY: Float = 0
    private var playerZ: Float = 0
    private var playerFacing: Float = 0
    private var timeOfDay: Float = 0.5
    private var lastState = bf_hud_state()

    var isQuestLogOpen: Bool { false }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        buildControls()
        buildInventoryPanel()
        buildChestPanel()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(from state: bf_hud_state) {
        var copy = state
        let hotbar = slots(from: &copy.hotbar, count: Int(BF_HOTBAR_SLOTS))
        let inventory = slots(from: &copy.inventory, count: Int(BF_INVENTORY_SLOTS))
        let craftable = slots(from: &copy.craftable, count: Int(copy.craftable_count))
        let questTitle = cString(from: &copy.quest_title)
        let questObjective = cString(from: &copy.quest_objective)
        let lookName = cString(from: &copy.look_name)
        let biome = cString(from: &copy.biome_name)

        onMain { [weak self] in
            guard let self else { return }
            self.lastState = state
            self.hotbarSlots = hotbar
            self.refreshHotbar(selected: Int(state.selected_slot))
            self.refreshInventory(inventory, craftable: craftable)

            let mode = state.mode == BF_MODE_CREATIVE ? "Creative" : "Survival"
            let heart = Int(max(0, min(20, state.health)).rounded())
            let hunger = Int(max(0, min(20, state.hunger)).rounded())
            let compass = self.cardinal(self.playerFacing)
            let phase = self.timePhase(self.timeOfDay)
            self.statusLabel.text =
                "♥ \(heart)/20   ◆ \(hunger)/20   \(mode)\n"
                + "\(biome.isEmpty ? "Unknown biome" : biome) · \(phase)   "
                + "\(Int(self.playerX.rounded())), \(Int(self.playerY.rounded())), "
                + "\(Int(self.playerZ.rounded())) \(compass)"
            self.questLabel.text = questTitle.isEmpty
                ? ""
                : "\(questTitle)\n\(questObjective)"
            self.targetLabel.text = lookName
            self.inventoryVisible = state.inventory_open != 0
            self.inventoryPanel.isHidden = !self.inventoryVisible
            self.inventoryButton.configuration?.title = self.inventoryVisible ? "CLOSE" : "PACK"
            self.refreshWorldTouchAvailability()
        }
    }

    func setPlayerInfo(x: Float, y: Float, z: Float, facing: Float) {
        playerX = x
        playerY = y
        playerZ = z
        playerFacing = facing
    }

    func setTimeOfDay(_ time: Float) {
        timeOfDay = time
    }

    func setQuests(_ rows: [QuestRow]) {}
    func setPeers(_ markers: [PeerMarker]) {}
    func setVillagers(_ markers: [VillagerMarker], now: CFTimeInterval) {}
    func flashScreenshot() {}

    func setChestOpen(pos: bf_ivec3, view: bf_chest_view) {
        var copy = view
        let slots = slots(from: &copy.slots, count: Int(BF_CHEST_SLOTS))
        onMain { [weak self] in
            guard let self else { return }
            self.chestPanel.isHidden = false
            self.refreshWorldTouchAvailability()
            for (index, button) in self.chestButtons.enumerated() {
                self.configure(button, slot: slots[index], prefix: "\(index + 1)")
            }
        }
    }

    func setChestClosed() {
        onMain { [weak self] in
            self?.chestPanel.isHidden = true
            self?.refreshWorldTouchAvailability()
        }
    }

    func setVillage(_ village: bf_village_view?) {
        guard var village, village.present != 0 else {
            onMain { [weak self] in self?.villageLabel.text = "" }
            return
        }
        let wanted = cString(from: &village.want)
        let text: String
        if village.ward_active != 0 {
            text = "Town ward restored · tier \(village.tier)"
        } else if village.tier >= 3 {
            text = "Town built · light \(village.lights)/8 torches"
        } else {
            text = "Town tier \(village.tier) · needs \(wanted.isEmpty ? "help" : wanted)"
        }
        onMain { [weak self] in self?.villageLabel.text = text }
    }

    func resetTouchControls() {
        joystick.reset()
        lookPad.reset()
        input?.setJumping(false)
        input?.setDescending(false)
        input?.endMine()
    }

    func toggleInventoryFromExternalControl() {
        inventoryTapped()
    }

    func setTouchControlSize(_ size: TouchControlSize, animated: Bool = true) {
        touchControlSize = size
        size.save()
        let apply = {
            let scale = size.scale
            self.joystickWidth.constant = 160 * scale
            self.joystickHeight.constant = 160 * scale
            self.jumpWidth.constant = 104 * scale
            self.jumpHeight.constant = 92 * scale
            self.downWidth.constant = 86 * scale
            self.downHeight.constant = 76 * scale
            self.hotbarHeight.constant = 66 * scale
            self.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: apply)
        } else {
            apply()
        }
    }

    private func buildControls() {
        lookPad.translatesAutoresizingMaskIntoConstraints = false
        lookPad.onLook = { [weak self] dx, dy in self?.input?.addTouchLook(dx: dx, dy: dy) }
        lookPad.onTap = { [weak self, weak lookPad] point in
            guard let lookPad else { return }
            self?.input?.interact(at: point, in: lookPad.bounds.size)
        }
        lookPad.onHoldChanged = { [weak self, weak lookPad] held, point in
            guard let lookPad else { return }
            if held {
                self?.input?.beginMine(at: point, in: lookPad.bounds.size)
            } else {
                self?.input?.endMine(clearTouchAim: true)
            }
        }
        addSubview(lookPad)

        for label in [statusLabel, questLabel, targetLabel, villageLabel] {
            label.numberOfLines = 0
            label.backgroundColor = UIColor(white: 0.04, alpha: 0.56)
            label.layer.cornerRadius = 10
            label.clipsToBounds = true
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        crosshair.text = "+"
        crosshair.textAlignment = .center
        crosshair.textColor = .white
        crosshair.font = .boldSystemFont(ofSize: 28)
        crosshair.layer.shadowColor = UIColor.black.cgColor
        crosshair.layer.shadowOpacity = 0.9
        crosshair.layer.shadowRadius = 2
        crosshair.translatesAutoresizingMaskIntoConstraints = false
        addSubview(crosshair)

        joystick.translatesAutoresizingMaskIntoConstraints = false
        joystick.onChange = { [weak self] strafe, forward in
            self?.input?.setTouchMovement(strafe: strafe, forward: forward)
        }
        addSubview(joystick)

        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        jumpButton.onHoldChanged = { [weak self] held in self?.input?.setJumping(held) }
        addSubview(jumpButton)

        downButton.translatesAutoresizingMaskIntoConstraints = false
        downButton.onHoldChanged = { [weak self] held in self?.input?.setDescending(held) }
        addSubview(downButton)

        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        pauseButton.addTarget(self, action: #selector(pauseTapped), for: .touchUpInside)
        addSubview(pauseButton)
        inventoryButton.translatesAutoresizingMaskIntoConstraints = false
        inventoryButton.addTarget(self, action: #selector(inventoryTapped), for: .touchUpInside)
        addSubview(inventoryButton)
        modeButton.translatesAutoresizingMaskIntoConstraints = false
        modeButton.addTarget(self, action: #selector(modeTapped), for: .touchUpInside)
        addSubview(modeButton)

        hotbar.axis = .horizontal
        hotbar.spacing = 5
        hotbar.distribution = .fillEqually
        hotbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hotbar)
        for index in 0..<Int(BF_HOTBAR_SLOTS) {
            let button = UIButton(type: .system)
            button.tag = index
            var config = UIButton.Configuration.filled()
            config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 1, bottom: 2, trailing: 1)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .boldSystemFont(ofSize: 9)
                return outgoing
            }
            button.configuration = config
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.textAlignment = .center
            button.titleLabel?.lineBreakMode = .byClipping
            button.layer.cornerRadius = 9
            button.layer.borderWidth = 2
            button.addTarget(self, action: #selector(hotbarTapped(_:)), for: .touchUpInside)
            hotbar.addArrangedSubview(button)
            hotbarButtons.append(button)
        }

        joystickWidth = joystick.widthAnchor.constraint(equalToConstant: 160)
        joystickHeight = joystick.heightAnchor.constraint(equalToConstant: 160)
        jumpWidth = jumpButton.widthAnchor.constraint(equalToConstant: 104)
        jumpHeight = jumpButton.heightAnchor.constraint(equalToConstant: 92)
        downWidth = downButton.widthAnchor.constraint(equalToConstant: 86)
        downHeight = downButton.heightAnchor.constraint(equalToConstant: 76)
        hotbarHeight = hotbar.heightAnchor.constraint(equalToConstant: 66)

        let safe = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            lookPad.leadingAnchor.constraint(equalTo: leadingAnchor),
            lookPad.trailingAnchor.constraint(equalTo: trailingAnchor),
            lookPad.topAnchor.constraint(equalTo: topAnchor),
            lookPad.bottomAnchor.constraint(equalTo: bottomAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            statusLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            statusLabel.widthAnchor.constraint(equalToConstant: 330),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 54),

            questLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            questLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            questLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 390),
            villageLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            villageLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            villageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 330),

            pauseButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -10),
            pauseButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            pauseButton.widthAnchor.constraint(equalToConstant: 54),
            pauseButton.heightAnchor.constraint(equalToConstant: 44),
            inventoryButton.trailingAnchor.constraint(equalTo: pauseButton.leadingAnchor, constant: -8),
            inventoryButton.centerYAnchor.constraint(equalTo: pauseButton.centerYAnchor),
            inventoryButton.widthAnchor.constraint(equalToConstant: 72),
            inventoryButton.heightAnchor.constraint(equalToConstant: 44),
            modeButton.trailingAnchor.constraint(equalTo: inventoryButton.leadingAnchor, constant: -8),
            modeButton.centerYAnchor.constraint(equalTo: pauseButton.centerYAnchor),
            modeButton.widthAnchor.constraint(equalToConstant: 70),
            modeButton.heightAnchor.constraint(equalToConstant: 44),

            crosshair.centerXAnchor.constraint(equalTo: centerXAnchor),
            crosshair.centerYAnchor.constraint(equalTo: centerYAnchor),
            crosshair.widthAnchor.constraint(equalToConstant: 36),
            crosshair.heightAnchor.constraint(equalToConstant: 36),
            targetLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            targetLabel.topAnchor.constraint(equalTo: crosshair.bottomAnchor, constant: 10),
            targetLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),

            joystick.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            joystick.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -22),
            joystickWidth,
            joystickHeight,

            jumpButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -26),
            jumpButton.bottomAnchor.constraint(equalTo: hotbar.topAnchor, constant: -16),
            jumpWidth,
            jumpHeight,
            downButton.trailingAnchor.constraint(equalTo: jumpButton.leadingAnchor, constant: -10),
            downButton.centerYAnchor.constraint(equalTo: jumpButton.centerYAnchor),
            downWidth,
            downHeight,

            hotbar.centerXAnchor.constraint(equalTo: centerXAnchor),
            hotbar.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
            hotbar.widthAnchor.constraint(equalToConstant: 510),
            hotbarHeight,
        ])
        setTouchControlSize(touchControlSize, animated: false)
    }

    private func buildInventoryPanel() {
        stylePanel(inventoryPanel)
        inventoryPanel.isHidden = true
        inventoryPanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inventoryPanel)

        let title = HUDView.makeLabel(size: 22, alignment: .center)
        title.text = "Backpack"
        title.translatesAutoresizingMaskIntoConstraints = false
        inventoryPanel.addSubview(title)
        let close = HUDView.makeTopButton(title: "DONE")
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addTarget(self, action: #selector(inventoryTapped), for: .touchUpInside)
        inventoryPanel.addSubview(close)

        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 5
        grid.distribution = .fillEqually
        grid.translatesAutoresizingMaskIntoConstraints = false
        inventoryPanel.addSubview(grid)
        for row in 0..<4 {
            let line = UIStackView()
            line.axis = .horizontal
            line.spacing = 5
            line.distribution = .fillEqually
            grid.addArrangedSubview(line)
            for column in 0..<9 {
                let index = row * 9 + column
                let button = inventorySlotButton(tag: index)
                button.addTarget(self, action: #selector(inventorySlotTapped(_:)), for: .touchUpInside)
                line.addArrangedSubview(button)
                inventoryButtons.append(button)
            }
        }

        craftTitleLabel.text = "Craft now"
        craftTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        inventoryPanel.addSubview(craftTitleLabel)
        let craftScroll = UIScrollView()
        craftScroll.alwaysBounceHorizontal = true
        craftScroll.showsHorizontalScrollIndicator = true
        craftScroll.translatesAutoresizingMaskIntoConstraints = false
        inventoryPanel.addSubview(craftScroll)
        let craftRow = UIStackView()
        craftRow.axis = .horizontal
        craftRow.spacing = 6
        craftRow.distribution = .fill
        craftRow.translatesAutoresizingMaskIntoConstraints = false
        craftScroll.addSubview(craftRow)
        for index in 0..<24 {
            let button = inventorySlotButton(tag: index)
            button.addTarget(self, action: #selector(craftTapped(_:)), for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: 98).isActive = true
            craftRow.addArrangedSubview(button)
            craftButtons.append(button)
        }

        NSLayoutConstraint.activate([
            inventoryPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            inventoryPanel.centerYAnchor.constraint(equalTo: centerYAnchor),
            inventoryPanel.widthAnchor.constraint(equalToConstant: 680),
            inventoryPanel.heightAnchor.constraint(equalToConstant: 420),
            title.topAnchor.constraint(equalTo: inventoryPanel.topAnchor, constant: 14),
            title.centerXAnchor.constraint(equalTo: inventoryPanel.centerXAnchor),
            close.trailingAnchor.constraint(equalTo: inventoryPanel.trailingAnchor, constant: -14),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 76),
            close.heightAnchor.constraint(equalToConstant: 40),
            grid.leadingAnchor.constraint(equalTo: inventoryPanel.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(equalTo: inventoryPanel.trailingAnchor, constant: -18),
            grid.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            grid.heightAnchor.constraint(equalToConstant: 248),
            craftTitleLabel.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            craftTitleLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 9),
            craftScroll.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            craftScroll.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            craftScroll.topAnchor.constraint(equalTo: craftTitleLabel.bottomAnchor, constant: 4),
            craftScroll.heightAnchor.constraint(equalToConstant: 68),
            craftRow.leadingAnchor.constraint(equalTo: craftScroll.contentLayoutGuide.leadingAnchor),
            craftRow.trailingAnchor.constraint(equalTo: craftScroll.contentLayoutGuide.trailingAnchor),
            craftRow.topAnchor.constraint(equalTo: craftScroll.contentLayoutGuide.topAnchor),
            craftRow.bottomAnchor.constraint(equalTo: craftScroll.contentLayoutGuide.bottomAnchor),
            craftRow.heightAnchor.constraint(equalTo: craftScroll.frameLayoutGuide.heightAnchor),
        ])
    }

    private func buildChestPanel() {
        stylePanel(chestPanel)
        chestPanel.isHidden = true
        chestPanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chestPanel)
        let title = HUDView.makeLabel(size: 22, alignment: .center)
        title.text = "Loot Barrel"
        title.translatesAutoresizingMaskIntoConstraints = false
        chestPanel.addSubview(title)
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        chestPanel.addSubview(row)
        for index in 0..<Int(BF_CHEST_SLOTS) {
            let button = inventorySlotButton(tag: index)
            button.addTarget(self, action: #selector(chestSlotTapped(_:)), for: .touchUpInside)
            row.addArrangedSubview(button)
            chestButtons.append(button)
        }
        let close = HUDView.makeTopButton(title: "DONE")
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addTarget(self, action: #selector(chestCloseTapped), for: .touchUpInside)
        chestPanel.addSubview(close)

        NSLayoutConstraint.activate([
            chestPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            chestPanel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chestPanel.widthAnchor.constraint(equalToConstant: 680),
            chestPanel.heightAnchor.constraint(equalToConstant: 190),
            title.topAnchor.constraint(equalTo: chestPanel.topAnchor, constant: 16),
            title.centerXAnchor.constraint(equalTo: chestPanel.centerXAnchor),
            row.leadingAnchor.constraint(equalTo: chestPanel.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: chestPanel.trailingAnchor, constant: -18),
            row.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            row.heightAnchor.constraint(equalToConstant: 68),
            close.centerXAnchor.constraint(equalTo: chestPanel.centerXAnchor),
            close.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 10),
            close.widthAnchor.constraint(equalToConstant: 100),
            close.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    private func refreshHotbar(selected: Int) {
        for (index, button) in hotbarButtons.enumerated() {
            let slot = index < hotbarSlots.count ? hotbarSlots[index] : bf_hud_slot()
            configure(button, slot: slot, prefix: "\(index + 1)")
            button.layer.borderColor = (
                index == selected ? UIColor.systemYellow : UIColor.white.withAlphaComponent(0.5)
            ).cgColor
            button.layer.borderWidth = index == selected ? 4 : 2
        }
    }

    private func refreshInventory(_ inventory: [bf_hud_slot], craftable: [bf_hud_slot]) {
        for (index, button) in inventoryButtons.enumerated() {
            configure(button, slot: inventory[index], prefix: "\(index + 1)")
        }
        for (index, button) in craftButtons.enumerated() {
            if index < craftable.count {
                button.isHidden = false
                configure(button, slot: craftable[index], prefix: "CRAFT")
                button.isEnabled = true
                button.accessibilityLabel = "Craft \(itemName(craftable[index].item))"
            } else {
                button.isHidden = true
                button.isEnabled = false
            }
        }
        craftTitleLabel.text = craftable.isEmpty
            ? "Nothing craftable yet — gather wood and stone"
            : "Craft now — swipe sideways to see all \(craftable.count)"
    }

    private func configure(_ button: UIButton, slot: bf_hud_slot, prefix: String) {
        var config = button.configuration ?? .filled()
        if slot.item == 0 {
            config.title = "\(prefix)\n—"
            config.baseBackgroundColor = UIColor(white: 0.16, alpha: 0.88)
        } else {
            let shortName = itemName(slot.item).split(separator: " ").first.map(String.init) ?? "Item"
            let count = slot.count > 1 ? "×\(slot.count)" : ""
            config.title = "\(prefix)\n\(shortName) \(count)"
            config.baseBackgroundColor = itemChipColor(slot.item).withAlphaComponent(0.84)
        }
        button.configuration = config
    }

    private func inventorySlotButton(tag: Int) -> UIButton {
        let button = UIButton(type: .system)
        button.tag = tag
        var config = UIButton.Configuration.filled()
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor(white: 0.16, alpha: 0.9)
        config.cornerStyle = .medium
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .boldSystemFont(ofSize: 10)
            return outgoing
        }
        button.configuration = config
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.textAlignment = .center
        return button
    }

    private func stylePanel(_ panel: UIView) {
        panel.backgroundColor = UIColor(red: 0.08, green: 0.09, blue: 0.13, alpha: 0.96)
        panel.layer.cornerRadius = 22
        panel.layer.borderWidth = 3
        panel.layer.borderColor = UIColor(red: 0.96, green: 0.72, blue: 0.28, alpha: 1).cgColor
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.65
        panel.layer.shadowRadius = 18
    }

    @objc private func pauseTapped() { onPause?() }
    @objc private func modeTapped() { input?.toggleMode() }
    @objc private func hotbarTapped(_ sender: UIButton) { input?.selectHotbar(sender.tag) }

    @objc private func inventoryTapped() {
        let open = !inventoryVisible
        inventoryVisible = open
        inventoryPanel.isHidden = !open
        inventoryButton.configuration?.title = open ? "CLOSE" : "PACK"
        input?.toggleInventory(open: open)
        refreshWorldTouchAvailability()
    }

    @objc private func inventorySlotTapped(_ sender: UIButton) {
        if sender.tag < 9 {
            input?.selectHotbar(sender.tag)
        } else if sender.tag < inventoryButtons.count {
            var copy = lastState
            let inventory = slots(from: &copy.inventory, count: Int(BF_INVENTORY_SLOTS))
            let item = inventory[sender.tag].item
            if (104...109).contains(item) { input?.equip(sender.tag) }
        }
    }

    @objc private func craftTapped(_ sender: UIButton) { input?.craft(sender.tag) }
    @objc private func chestSlotTapped(_ sender: UIButton) { onChestTake?(sender.tag) }
    @objc private func chestCloseTapped() { onChestClose?() }

    private func refreshWorldTouchAvailability() {
        lookPad.isUserInteractionEnabled = !inventoryVisible && chestPanel.isHidden
    }

    private func cardinal(_ yaw: Float) -> String {
        let names = ["S", "SW", "W", "NW", "N", "NE", "E", "SE"]
        var degrees = Double(yaw) * 180 / .pi
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        return names[Int((degrees / 45).rounded()) % names.count]
    }

    private func timePhase(_ time: Float) -> String {
        switch time {
        case 0.23..<0.30: return "Dawn"
        case 0.30..<0.70: return "Day"
        case 0.70..<0.77: return "Dusk"
        default: return "Night"
        }
    }

    private func slots<T>(from tuple: inout T, count: Int) -> [bf_hud_slot] {
        withUnsafeBytes(of: &tuple) { raw in
            Array(raw.bindMemory(to: bf_hud_slot.self).prefix(count))
        }
    }

    private func cString<T>(from tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private static func makeLabel(
        size: CGFloat,
        alignment: NSTextAlignment,
        padded: Bool = false
    ) -> UILabel {
        let label = InsetLabel()
        if padded { label.textInsets = UIEdgeInsets(top: 7, left: 10, bottom: 7, right: 10) }
        label.font = .boldSystemFont(ofSize: size)
        label.textColor = .white
        label.textAlignment = alignment
        label.numberOfLines = 0
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static func makeTopButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = UIColor(white: 0.08, alpha: 0.82)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .boldSystemFont(ofSize: 14)
            return outgoing
        }
        button.configuration = config
        button.layer.borderWidth = 2
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.55).cgColor
        return button
    }
}

/// UILabel does not include interior margins in its drawing or intrinsic size.
private final class InsetLabel: UILabel {
    var textInsets = UIEdgeInsets.zero {
        didSet { invalidateIntrinsicContentSize() }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + textInsets.left + textInsets.right,
            height: size.height + textInsets.top + textInsets.bottom
        )
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = CGSize(
            width: max(0, size.width - textInsets.left - textInsets.right),
            height: max(0, size.height - textInsets.top - textInsets.bottom)
        )
        let fitted = super.sizeThatFits(inner)
        return CGSize(
            width: fitted.width + textInsets.left + textInsets.right,
            height: fitted.height + textInsets.top + textInsets.bottom
        )
    }
}

enum MapView {
    struct Marker {
        let x: Int32
        let z: Int32
        let kind: UInt32
        let id: UInt32
        let name: String
    }
}

enum TradeView {
    struct Offer {
        let giveItem: UInt16
        let giveCount: UInt16
        let getItem: UInt16
        let getCount: UInt16
    }
}
