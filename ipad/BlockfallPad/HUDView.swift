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
    var onMap: (() -> Void)?
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
    private let mapButton = HUDView.makeTopButton(title: "MAP")
    private let minimap = IPadMinimapView()
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

    func setMapRenderer(_ renderer: Renderer) {
        minimap.renderer = renderer
        minimap.start()
        setMinimapVisible(UserDefaults.standard.object(forKey: "minimap") as? Bool ?? true)
    }

    func setMinimapVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: "minimap")
        minimap.isHidden = !visible
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

        minimap.translatesAutoresizingMaskIntoConstraints = false
        minimap.isUserInteractionEnabled = false
        insertSubview(minimap, aboveSubview: lookPad)

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
        mapButton.translatesAutoresizingMaskIntoConstraints = false
        mapButton.addTarget(self, action: #selector(mapTapped), for: .touchUpInside)
        addSubview(mapButton)

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
            mapButton.trailingAnchor.constraint(equalTo: modeButton.leadingAnchor, constant: -8),
            mapButton.centerYAnchor.constraint(equalTo: pauseButton.centerYAnchor),
            mapButton.widthAnchor.constraint(equalToConstant: 64),
            mapButton.heightAnchor.constraint(equalToConstant: 44),

            minimap.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -14),
            minimap.topAnchor.constraint(equalTo: pauseButton.bottomAnchor, constant: 12),
            minimap.widthAnchor.constraint(equalToConstant: 150),
            minimap.heightAnchor.constraint(equalToConstant: 150),

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
    @objc private func mapTapped() { onMap?() }
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

/// Lightweight, display-only navigation chart for iPad play.
final class IPadMinimapView: UIView {
    weak var renderer: Renderer?

    private var markers: [MapView.Marker] = []
    private var period = 32768
    private var playerX: Float = 0
    private var playerZ: Float = 0
    private var facing: Float = 0
    private var timer: Timer?
    private var markerTick = 0
    private let worldRadius: Float = 1_400

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func start() {
        refreshMarkers()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self, !self.isHidden, let renderer = self.renderer else { return }
            self.playerX = renderer.playerWorldX
            self.playerZ = renderer.playerWorldZ
            self.facing = renderer.playerWorldFacing
            self.markerTick += 1
            if self.markerTick >= 30 {
                self.markerTick = 0
                self.refreshMarkers()
            }
            self.setNeedsDisplay()
        }
    }

    deinit { timer?.invalidate() }

    private func refreshMarkers() {
        guard let snapshot = renderer?.mapQuery() else { return }
        markers = snapshot.markers
        period = snapshot.period
    }

    private func wrapSigned(_ value: Int) -> Int {
        ((value + period / 2) % period + period) % period - period / 2
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 10
        let disc = UIBezierPath(ovalIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        UIColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 0.80).setFill()
        disc.fill()

        context.saveGState()
        disc.addClip()
        UIColor.white.withAlphaComponent(0.10).setStroke()
        let middleRing = UIBezierPath(ovalIn: CGRect(
            x: center.x - radius / 2,
            y: center.y - radius / 2,
            width: radius,
            height: radius
        ))
        middleRing.lineWidth = 1
        middleRing.stroke()

        let scale = radius / CGFloat(worldRadius)
        for marker in markers {
            let dx = CGFloat(wrapSigned(Int(marker.x) - Int(playerX.rounded()))) * scale
            let dz = CGFloat(wrapSigned(Int(marker.z) - Int(playerZ.rounded()))) * scale
            let point = CGPoint(x: center.x + dx, y: center.y - dz)
            guard hypot(point.x - center.x, point.y - center.y) < radius - 3 else { continue }
            markerColor(marker.kind).setFill()
            UIColor.black.withAlphaComponent(0.75).setStroke()
            let size: CGFloat = marker.kind == 5 ? 12 : 9
            let dot = UIBezierPath(ovalIn: CGRect(
                x: point.x - size / 2,
                y: point.y - size / 2,
                width: size,
                height: size
            ))
            dot.lineWidth = 1.5
            dot.fill()
            dot.stroke()
        }
        context.restoreGState()

        UIColor(red: 0.75, green: 0.58, blue: 0.28, alpha: 0.95).setStroke()
        disc.lineWidth = 4
        disc.stroke()

        drawText("N", at: CGPoint(x: center.x, y: center.y - radius - 1), color: .systemRed)
        drawText("E", at: CGPoint(x: center.x + radius + 2, y: center.y), color: .white)
        drawText("S", at: CGPoint(x: center.x, y: center.y + radius + 1), color: .white)
        drawText("W", at: CGPoint(x: center.x - radius - 2, y: center.y), color: .white)

        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: CGFloat(-facing))
        let arrow = UIBezierPath()
        arrow.move(to: CGPoint(x: 0, y: -11))
        arrow.addLine(to: CGPoint(x: 8, y: 9))
        arrow.addLine(to: CGPoint(x: 0, y: 4))
        arrow.addLine(to: CGPoint(x: -8, y: 9))
        arrow.close()
        UIColor.white.setFill()
        UIColor.black.setStroke()
        arrow.lineWidth = 2
        arrow.fill()
        arrow.stroke()
        context.restoreGState()
    }

    private func markerColor(_ kind: UInt32) -> UIColor {
        switch kind {
        case 0: .systemRed
        case 1: UIColor(red: 0.74, green: 0.55, blue: 0.25, alpha: 1)
        case 3: .systemGray
        case 4: .systemOrange
        case 5: .systemYellow
        default: .systemPurple
        }
    }

    private func drawText(_ text: String, at point: CGPoint, color: UIColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13, weight: .black),
            .foregroundColor: color,
            .strokeColor: UIColor.black,
            .strokeWidth: -3,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
            withAttributes: attributes
        )
    }
}

/// Full explored-world map. The renderer supplies one immutable snapshot while
/// the game is paused; zooming and marker selection stay entirely in UIKit.
final class IPadWorldMapView: UIView {
    var snapshot: Renderer.MapSnapshot? {
        didSet {
            viewSpan = max(minSpan, min(viewSpan, snapshot?.period ?? viewSpan))
            rebuildImage()
        }
    }
    var biomes: [UInt8] = [] { didSet { rebuildImage() } }
    var onMarkerTapped: ((MapView.Marker) -> Void)?

    private(set) var viewSpan = UserDefaults.standard.object(forKey: "mapViewSpan") as? Int ?? 4096
    private var mapImage: UIImage?
    private var markerPoints: [(CGPoint, MapView.Marker)] = []
    private let minSpan = 1024

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func zoomIn() {
        viewSpan = max(minSpan, viewSpan / 2)
        saveZoomAndRebuild()
    }

    func zoomOut() {
        guard let snapshot else { return }
        viewSpan = min(snapshot.period, viewSpan * 2)
        saveZoomAndRebuild()
    }

    private func saveZoomAndRebuild() {
        UserDefaults.standard.set(viewSpan, forKey: "mapViewSpan")
        rebuildImage()
    }

    private var chartRect: CGRect { bounds.insetBy(dx: 16, dy: 16) }

    private var anchored: Bool {
        guard let snapshot else { return false }
        return viewSpan >= snapshot.period
    }

    private func anchor(for snapshot: Renderer.MapSnapshot) -> (Int, Int) {
        if anchored, let home = snapshot.markers.first(where: { $0.kind == 0 }) {
            return (Int(home.x), Int(home.z))
        }
        return (Int(snapshot.playerX.rounded()), Int(snapshot.playerZ.rounded()))
    }

    private func wrapSigned(_ value: Int, period: Int) -> Int {
        ((value + period / 2) % period + period) % period - period / 2
    }

    private func mapPoint(x: Int32, z: Int32, snapshot: Renderer.MapSnapshot) -> CGPoint {
        let chart = chartRect
        let (anchorX, anchorZ) = anchor(for: snapshot)
        let scale = chart.width / CGFloat(viewSpan)
        let dx = CGFloat(wrapSigned(Int(x) - anchorX, period: snapshot.period))
        let dz = CGFloat(wrapSigned(Int(z) - anchorZ, period: snapshot.period))
        return CGPoint(x: chart.midX + dx * scale, y: chart.midY - dz * scale)
    }

    private func rebuildImage() {
        guard let snapshot else { mapImage = nil; setNeedsDisplay(); return }
        let total = snapshot.cells
        let count = max(2, min(total, viewSpan / snapshot.cellSize))
        guard total > 0, snapshot.explored.count >= total * total / 8 else {
            mapImage = nil
            setNeedsDisplay()
            return
        }
        let (anchorX, anchorZ) = anchor(for: snapshot)
        let pcx = ((anchorX % snapshot.period) + snapshot.period) % snapshot.period / snapshot.cellSize
        let pcz = ((anchorZ % snapshot.period) + snapshot.period) % snapshot.period / snapshot.cellSize
        var pixels = [UInt8](repeating: 0, count: count * count * 4)
        for row in 0..<count {
            let cz = ((pcz - count / 2 + row) % total + total) % total
            for column in 0..<count {
                let cx = ((pcx - count / 2 + column) % total + total) % total
                let bit = cz * total + cx
                let explored = snapshot.explored[bit >> 3] & (1 << (bit & 7)) != 0
                let checker = (cx ^ cz) & 1 == 0
                let offset = (row * count + column) * 4
                let color = explored ? biomeColor(bit: bit, checker: checker) : (
                    checker ? (UInt8(24), UInt8(27), UInt8(38)) : (UInt8(20), UInt8(23), UInt8(34))
                )
                pixels[offset] = color.0
                pixels[offset + 1] = color.1
                pixels[offset + 2] = color.2
                pixels[offset + 3] = 255
            }
        }
        let data = Data(pixels) as CFData
        let provider = CGDataProvider(data: data)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        if let provider, let image = CGImage(
            width: count,
            height: count,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: count * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) {
            mapImage = UIImage(cgImage: image)
        }
        setNeedsDisplay()
    }

    private func biomeColor(bit: Int, checker: Bool) -> (UInt8, UInt8, UInt8) {
        let base: (UInt8, UInt8, UInt8)
        switch bit < biomes.count ? biomes[bit] : 0 {
        case 1: base = (96, 168, 88)
        case 2: base = (150, 148, 152)
        case 3: base = (232, 204, 130)
        case 4: base = (236, 240, 246)
        case 5: base = (110, 142, 110)
        case 6: base = (238, 222, 170)
        default: base = (150, 196, 110)
        }
        guard !checker else { return base }
        return (
            UInt8(Float(base.0) * 0.93),
            UInt8(Float(base.1) * 0.93),
            UInt8(Float(base.2) * 0.93)
        )
    }

    override func draw(_ rect: CGRect) {
        guard let snapshot else { return }
        let chart = chartRect
        let frame = UIBezierPath(roundedRect: chart.insetBy(dx: -10, dy: -10), cornerRadius: 16)
        UIColor(red: 0.36, green: 0.27, blue: 0.16, alpha: 1).setFill()
        frame.fill()
        UIColor(red: 0.08, green: 0.10, blue: 0.15, alpha: 1).setFill()
        UIRectFill(chart)
        mapImage?.draw(in: chart, blendMode: .normal, alpha: 1)

        markerPoints.removeAll(keepingCapacity: true)
        for marker in snapshot.markers {
            let point = mapPoint(x: marker.x, z: marker.z, snapshot: snapshot)
            guard chart.insetBy(dx: -5, dy: -5).contains(point) else { continue }
            markerPoints.append((point, marker))
            drawMarker(marker, at: point)
        }

        let playerPoint = anchored
            ? mapPoint(x: Int32(snapshot.playerX.rounded()), z: Int32(snapshot.playerZ.rounded()), snapshot: snapshot)
            : CGPoint(x: chart.midX, y: chart.midY)
        drawPlayer(at: playerPoint, facing: snapshot.facing)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        guard let hit = markerPoints.min(by: {
            hypot($0.0.x - point.x, $0.0.y - point.y) < hypot($1.0.x - point.x, $1.0.y - point.y)
        }), hypot(hit.0.x - point.x, hit.0.y - point.y) <= 34 else { return }
        onMarkerTapped?(hit.1)
    }

    private func drawMarker(_ marker: MapView.Marker, at point: CGPoint) {
        let color: UIColor
        let glyph: String
        switch marker.kind {
        case 0: color = .systemRed; glyph = "⌂"
        case 1: color = UIColor(red: 0.72, green: 0.51, blue: 0.23, alpha: 1); glyph = "⌂"
        case 3: color = .systemGray; glyph = "♜"
        case 4: color = .systemOrange; glyph = "⌂"
        case 5: color = .systemYellow; glyph = "⚔"
        default: color = .systemPurple; glyph = "◆"
        }
        color.setFill()
        UIColor.black.withAlphaComponent(0.8).setStroke()
        let icon = UIBezierPath(ovalIn: CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28))
        icon.lineWidth = 2
        icon.fill()
        icon.stroke()
        drawLabel(glyph, at: point, size: 15, color: .white)
        drawLabel(marker.name, at: CGPoint(x: point.x, y: point.y + 23), size: 11, color: .white)
    }

    private func drawPlayer(at point: CGPoint, facing: Float) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: CGFloat(-facing))
        let arrow = UIBezierPath()
        arrow.move(to: CGPoint(x: 0, y: -15))
        arrow.addLine(to: CGPoint(x: 10, y: 11))
        arrow.addLine(to: CGPoint(x: 0, y: 5))
        arrow.addLine(to: CGPoint(x: -10, y: 11))
        arrow.close()
        UIColor.white.setFill()
        UIColor.black.setStroke()
        arrow.lineWidth = 3
        arrow.fill()
        arrow.stroke()
        context.restoreGState()
    }

    private func drawLabel(_ text: String, at point: CGPoint, size: CGFloat, color: UIColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: .black),
            .foregroundColor: color,
            .strokeColor: UIColor.black.withAlphaComponent(0.9),
            .strokeWidth: -3,
        ]
        let dimensions = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: point.x - dimensions.width / 2, y: point.y - dimensions.height / 2),
            withAttributes: attributes
        )
    }
}
