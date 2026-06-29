// ============================================================================
// Blockfall — HUDView (Phase 0 / M0)
// A lightweight AppKit overlay that renders the engine's HUD snapshot: hotbar,
// health, and the active quest. Deliberately simple (Core Graphics, no Metal
// text) so M0 proves the HUD-state handoff end to end. Track E may later move
// this into the Metal layer; the data contract (bf_hud_state) stays the same.
// ============================================================================
import AppKit
import QuartzCore   // CACurrentMediaTime for the #29 FPS counter
import CBlockcore

// Item id -> (display name, chip colour). Mirrors content/items so the HUD can
// label and colour items without an ABI change. Keep in sync with content.
private struct ItemInfo { let name: String; let color: NSColor }
private func itemColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}
private let kItemTable: [UInt16: ItemInfo] = [
    1:  .init(name: "Dirt",          color: itemColor(0.55, 0.40, 0.26)),
    2:  .init(name: "Grass Block",   color: itemColor(0.40, 0.68, 0.32)),
    3:  .init(name: "Stone",         color: itemColor(0.55, 0.55, 0.57)),
    4:  .init(name: "Cobblestone",   color: itemColor(0.48, 0.48, 0.50)),
    5:  .init(name: "Sand",          color: itemColor(0.85, 0.78, 0.55)),
    6:  .init(name: "Gravel",        color: itemColor(0.52, 0.50, 0.48)),
    7:  .init(name: "Snow",          color: itemColor(0.92, 0.95, 0.98)),
    8:  .init(name: "Ice",           color: itemColor(0.68, 0.82, 0.95)),
    9:  .init(name: "Clay",          color: itemColor(0.62, 0.64, 0.68)),
    10: .init(name: "Dim Stone",     color: itemColor(0.30, 0.30, 0.36)),
    11: .init(name: "Dim Dirt",      color: itemColor(0.30, 0.26, 0.24)),
    12: .init(name: "Oak Log",       color: itemColor(0.52, 0.37, 0.20)),
    13: .init(name: "Oak Planks",    color: itemColor(0.74, 0.57, 0.34)),
    14: .init(name: "Birch Log",     color: itemColor(0.80, 0.74, 0.58)),
    15: .init(name: "Birch Planks",  color: itemColor(0.85, 0.78, 0.62)),
    16: .init(name: "Stone Brick",   color: itemColor(0.55, 0.55, 0.57)),
    17: .init(name: "Clay Brick",    color: itemColor(0.78, 0.45, 0.34)),
    18: .init(name: "Glass Pane",    color: itemColor(0.74, 0.86, 0.92)),
    19: .init(name: "Colored Glass", color: itemColor(0.40, 0.72, 0.85)),
    20: .init(name: "Wool",          color: itemColor(0.92, 0.92, 0.92)),
    21: .init(name: "Mossy Stone",   color: itemColor(0.42, 0.52, 0.36)),
    22: .init(name: "Crafting Table",color: itemColor(0.60, 0.42, 0.24)),
    23: .init(name: "Chest",         color: itemColor(0.62, 0.45, 0.24)),
    24: .init(name: "Torch",         color: itemColor(0.95, 0.72, 0.30)),
    25: .init(name: "Oak Door",      color: itemColor(0.56, 0.40, 0.22)),
    26: .init(name: "Beacon",        color: itemColor(0.40, 0.85, 0.90)),
    27: .init(name: "Glow Block",    color: itemColor(1.00, 0.90, 0.45)),
    28: .init(name: "Crystal Lamp",  color: itemColor(0.85, 0.55, 0.95)),
    29: .init(name: "Red Flower",    color: itemColor(0.88, 0.25, 0.25)),
    30: .init(name: "Yellow Flower", color: itemColor(0.95, 0.85, 0.25)),
    31: .init(name: "Color Crystal", color: itemColor(0.80, 0.45, 0.95)),
    50: .init(name: "Stick",         color: itemColor(0.60, 0.44, 0.26)),
    51: .init(name: "Coal",          color: itemColor(0.18, 0.18, 0.20)),
    52: .init(name: "Raw Copper",    color: itemColor(0.80, 0.50, 0.32)),
    53: .init(name: "Raw Iron",      color: itemColor(0.78, 0.70, 0.62)),
    54: .init(name: "Raw Crystal",   color: itemColor(0.55, 0.80, 0.90)),
    55: .init(name: "Copper Ingot",  color: itemColor(0.85, 0.55, 0.38)),
    56: .init(name: "Iron Ingot",    color: itemColor(0.82, 0.82, 0.85)),
    57: .init(name: "Crystal Shard", color: itemColor(0.60, 0.85, 0.95)),
    58: .init(name: "Clay Lump",     color: itemColor(0.62, 0.64, 0.68)),
    59: .init(name: "String",        color: itemColor(0.92, 0.92, 0.88)),
    60: .init(name: "Feather",       color: itemColor(0.95, 0.95, 0.95)),
    61: .init(name: "Color Dust",    color: itemColor(0.80, 0.45, 0.95)),
    62: .init(name: "Glow Dust",     color: itemColor(1.00, 0.92, 0.50)),
    63: .init(name: "Blank Book",    color: itemColor(0.80, 0.72, 0.55)),
    70: .init(name: "Wood Pickaxe",  color: itemColor(0.60, 0.44, 0.26)),
    71: .init(name: "Wood Axe",      color: itemColor(0.60, 0.44, 0.26)),
    72: .init(name: "Wood Shovel",   color: itemColor(0.60, 0.44, 0.26)),
    73: .init(name: "Stone Pickaxe", color: itemColor(0.55, 0.55, 0.57)),
    74: .init(name: "Stone Axe",     color: itemColor(0.55, 0.55, 0.57)),
    75: .init(name: "Stone Shovel",  color: itemColor(0.55, 0.55, 0.57)),
    76: .init(name: "Iron Pickaxe",  color: itemColor(0.82, 0.82, 0.85)),
    77: .init(name: "Iron Axe",      color: itemColor(0.82, 0.82, 0.85)),
    78: .init(name: "Iron Shovel",   color: itemColor(0.82, 0.82, 0.85)),
    79: .init(name: "Wooden Sword",  color: itemColor(0.62, 0.46, 0.28)),
    80: .init(name: "Stone Sword",   color: itemColor(0.58, 0.58, 0.60)),
    81: .init(name: "Iron Sword",    color: itemColor(0.86, 0.87, 0.90)),
    90: .init(name: "Berries",       color: itemColor(0.80, 0.20, 0.35)),
    91: .init(name: "Mushroom Stew", color: itemColor(0.70, 0.50, 0.34)),
    92: .init(name: "Honey Cake",    color: itemColor(0.92, 0.70, 0.28)),
    93: .init(name: "Mushroom",      color: itemColor(0.78, 0.36, 0.32)),
]
private func itemName(_ id: UInt16) -> String { kItemTable[id]?.name ?? "Item \(id)" }
private func itemChipColor(_ id: UInt16) -> NSColor { kItemTable[id]?.color ?? NSColor(hue: CGFloat(id % 12)/12, saturation: 0.6, brightness: 0.9, alpha: 1) }

// Kid-friendly descriptions for every item a player is likely to encounter.
// Falls back to a generic hint so tooltip text is never blank.
private func itemDescription(id: UInt16) -> String {
    switch id {
    // Blocks – terrain
    case 1:  return "Soft ground block. Easy to dig and great for building simple stuff."
    case 2:  return "Grass-covered earth. Plants grow on top of it!"
    case 3:  return "Hard underground rock. Mine it for cobblestone."
    case 4:  return "Crumbly stone that drops from mining. Good for building walls."
    case 5:  return "Loose sand found near beaches and deserts. Watch out — it falls!"
    case 6:  return "Gritty gravel. Also falls when there's nothing under it."
    case 7:  return "Fluffy snow block from cold biomes. Perfect for a snowball fight... if only."
    case 8:  return "Slippery frozen water. Makes you slide around!"
    case 9:  return "Soft clay from riverbeds. Useful for making bricks."
    case 10: return "Dark, drained stone from the Dim Barrens. Restore colour to bring it back."
    case 11: return "Dim, grey dirt from drained areas. Light a beacon to restore it!"
    // Blocks – wood & crafted
    case 12: return "Oak tree trunk. Chop it down to get logs for planks and sticks."
    case 13: return "Flat oak planks made from logs. A building basic!"
    case 14: return "Pale birch trunk. Same uses as oak — just a different look."
    case 15: return "Light-coloured birch planks. Good for bright, airy builds."
    case 16: return "Polished stone bricks. Great for sturdy walls and castles."
    case 17: return "Warm clay bricks. Fired from clay lumps. Looks cosy!"
    case 18: return "See-through glass panel. Let the light in!"
    case 19: return "Tinted glass with a coloured glow. Fancy!"
    case 20: return "Soft wool block. Colourful and bouncy-looking."
    case 21: return "Old stone covered in moss. Found deep underground or in ruins."
    case 22: return "A workbench! Place it to unlock 3×3 crafting for tools and swords."
    case 23: return "A storage chest. Open it to keep your stuff safe."
    case 24: return "Place it to light up dark caves and keep monsters away at night."
    case 25: return "A wooden door. Walk through it — it opens when you push it."
    case 26: return "A powerful beacon block. Placing it restores colour to drained regions!"
    case 27: return "A glowing block that lights up an area. Great for brightening the Dim Barrens."
    case 28: return "A sparkling crystal lamp. Beautiful and bright!"
    case 29: return "A cheerful red flower. Use it to decorate your builds."
    case 30: return "A sunny yellow flower. Makes any spot look prettier."
    case 31: return "A shiny colour crystal block. Craft it into other things or just show it off."
    // Materials
    case 50: return "Basic crafting ingredient. Make sticks from planks to craft tools."
    case 51: return "Black fuel found underground. Used in torches and as a crafting fuel."
    case 52: return "Rough copper ore chunk. Smelt it into ingots to use in crafts."
    case 53: return "Rough iron ore chunk. Smelt it into iron ingots for better tools."
    case 54: return "A raw sparkling crystal. Rare and magical!"
    case 55: return "Smelted copper bar. Used in crafting various items."
    case 56: return "Smelted iron bar. Makes the best tools and swords!"
    case 57: return "A glittering crystal chip. Used in fancy crafts and glowing items."
    case 58: return "A lump of clay dug from rivers. Craft or smelt it into bricks."
    case 59: return "Thin string fiber. Useful for crafting bows and other items."
    case 60: return "A light feather from a bird. Useful for crafting arrows."
    case 61: return "Colourful powder. Used to dye blocks and craft coloured things."
    case 62: return "Glowing dust that shimmers in the dark. For crafting glow items."
    case 63: return "An empty book. Write your adventures in it… someday."
    // Tools – pickaxes
    case 70: return "Wood Pickaxe — mines stone and ores. Slowest tier, but it's a start!"
    case 71: return "Wood Axe — chops logs and wood blocks much faster than your fists."
    case 72: return "Wood Shovel — digs dirt, sand and gravel quickly. Tier 1."
    case 73: return "Stone Pickaxe — faster than wood, mines tougher ores. Tier 2!"
    case 74: return "Stone Axe — chops wood quickly. Better than the wooden one."
    case 75: return "Stone Shovel — scoops up earth and sand fast. Tier 2."
    case 76: return "Iron Pickaxe — the best pickaxe! Mines anything really fast."
    case 77: return "Iron Axe — chops through any wood in a flash. Tier 3."
    case 78: return "Iron Shovel — digs dirt and sand at top speed. Tier 3."
    // Swords
    case 79: return "Wooden Sword — a weapon! Hit monsters harder than with your fists. Weakest tier."
    case 80: return "Stone Sword — stronger than wood. Does more damage to monsters!"
    case 81: return "Iron Sword — the most powerful sword. Monsters won't stand a chance!"
    // Food
    case 90: return "Sweet berries! Eat them to restore a little health."
    case 91: return "Hearty mushroom stew. Fills you up and heals a good chunk of health."
    case 92: return "Yummy honey cake. A tasty treat that restores lots of health."
    case 93: return "A wild mushroom. Eat it or use it to cook a stew!"
    default: return "A useful item. Try crafting with it or placing it in the world!"
    }
}

final class HUDView: NSView {
    private var hud = bf_hud_state()
    private var crosshair = true

    // --- Interactive inventory state ---
    // Closure the lead wires to BF_ACT_INV_MOVE (arg_i=from, arg_j=to, arg_k=count).
    var onMove: ((_ from: Int, _ to: Int, _ count: Int) -> Void)?
    // Called when the player clicks a craftable row. index = 0-based craftable slot.
    var onCraft: ((Int) -> Void)?
    // #15: creative item picker — clicking an item in the picker gives it to the
    // player. Wired by the lead to BF_ACT_GIVE_ITEM (or equivalent). nil = no-op.
    var onGiveItem: ((UInt16) -> Void)?
    // Slot-index (0..35) of a "picked up" stack, or nil when nothing is held.
    private var heldSlot: Int? = nil
    private var heldItem: bf_item_id = 0
    private var heldCount: UInt16 = 0
    // Last 36 slot rects we drew (index == inventory index). Empty when closed.
    private var slotRects: [NSRect] = []
    // Craftable recipe slot rects we drew, parallel to hud.craftable (index ==
    // recipe index, 0-based; the on-screen number key is index+1). Empty when
    // closed or when there are no craftable recipes. Tracked exactly like
    // slotRects so hover hit-testing stays in sync with what we draw.
    private var craftRects: [NSRect] = []
    // Current mouse position in view coords (for tooltip + held-stack ghost).
    private var mousePos: NSPoint = .zero
    private var mouseInside = false
    private var trackingAreaRef: NSTrackingArea?
    // Death feedback: respawn happens same-frame, so we detect it as health
    // jumping back to full from a near-empty state and flash a kid-readable banner.
    private var prevHealth: Float = 20
    private var deathFlashUntil: TimeInterval = 0

    // --- #12: always-visible coordinates + facing readout ---
    // The renderer calls setPlayerInfo each frame. facing is a yaw in radians
    // from atan2(forward.x, forward.z); we round coords to ints for display.
    private var playerX: Float = 0
    private var playerY: Float = 0
    private var playerZ: Float = 0
    private var playerFacing: Float = 0   // yaw radians

    // --- #30: day/night indicator ---
    // Renderer pushes the world time-of-day each frame via setTimeOfDay.
    // 0 = midnight, 0.5 = noon (one full day = 0..1, wrapping). Stored and shown
    // in the top-right status box as a sun/moon glyph + Day/Night/Dawn/Dusk label
    // and a small progress bar marking position in the cycle.
    private var timeOfDay: Float = 0.5    // default to noon so a fresh HUD reads "Day"

    // --- #34: destroy/trash slot ---
    // The lead wires this to the engine; it fires with the inventory slot index
    // (0..35) that should be emptied. Triggered by dropping a picked-up stack on
    // the trash slot while the inventory is open.
    var onDestroy: ((Int) -> Void)?
    // Rect of the trash slot we last drew (inventory open only). .zero = not shown.
    private var trashRect: NSRect = .zero

    // --- #109 chest panel ---
    // The Renderer polls bf_chest_open_pos / bf_chest_query each frame and pushes the
    // open chest's contents here (or closes it). When chestOpen is true we draw a panel
    // with the chest's slots on top and the player inventory below, and clicking moves
    // items between them. Closing on ESC / use-again is driven by the engine (the poll
    // returns no open chest), so we just mirror that state. The lead wires:
    //   onChestTake(slot)        -> bf_chest_take(pos, slot)      (chest slot -> inventory)
    //   onChestDeposit(invSlot)  -> bf_chest_deposit(pos, invSlot)(inventory slot -> chest)
    // Items are never destroyed: a full inventory leaves the stack in the chest (engine).
    var onChestTake: ((Int) -> Void)?
    var onChestDeposit: ((Int) -> Void)?
    private var chestOpen = false
    private var chestSlots: [bf_hud_slot] = []          // BF_CHEST_SLOTS live contents
    private var chestSlotRects: [NSRect] = []           // hit-test rects for chest slots
    private var chestInvRects: [NSRect] = []            // hit-test rects for the inventory grid

    // Renderer: a chest was opened (right-click on a chest). Mirror its contents.
    func setChestOpen(pos: bf_ivec3, view: bf_chest_view) {
        var slots: [bf_hud_slot] = []
        withUnsafeBytes(of: view.slots) { raw in
            let p = raw.bindMemory(to: bf_hud_slot.self)
            for i in 0..<Int(BF_CHEST_SLOTS) { slots.append(p[i]) }
        }
        let changed = !chestOpen || slots.count != chestSlots.count
            || zip(slots, chestSlots).contains { $0.item != $1.item || $0.count != $1.count }
        chestOpen = true
        chestSlots = slots
        if changed { needsDisplay = true }
    }

    // Renderer: no chest open. Hide the panel and drop any held stack.
    func setChestClosed() {
        if chestOpen {
            chestOpen = false
            chestSlots = []
            chestSlotRects = []
            chestInvRects = []
            clearHeld()
            needsDisplay = true
        }
    }

    var isChestOpen: Bool { chestOpen }

    // --- #95 living villages: the tier/donation status of the nearest village, pushed
    // each frame by the Renderer (bf_village_query). nil when no village is near. Drives
    // a small donation panel so the player can see what each villager wants and the
    // town's current tier + progress.
    private var villageView: bf_village_view? = nil
    func setVillage(_ v: bf_village_view?) {
        let was = villageView
        villageView = v
        // Repaint when presence, tier, or progress changed (cheap field compare).
        let changed: Bool = {
            guard let a = was, let b = v else { return (was == nil) != (v == nil) }
            return a.present != b.present || a.tier != b.tier
                || a.wood_cells != b.wood_cells || a.progress != b.progress
        }()
        if changed { needsDisplay = true }
    }

    // --- #29: FPS counter ---
    // Derived purely from the time between draw(_:) calls (the renderer already
    // drives one redraw per frame), so no timer is added. We keep an exponential
    // moving average of the instantaneous FPS so the number reads steadily
    // instead of flickering every frame. lastDrawTime < 0 means "no prior frame".
    private var lastDrawTime: CFTimeInterval = -1
    private var smoothedFPS: Double = 0

    // --- #16: scrollable craft list ---
    // Vertical scroll offset (in points) into the craft band. 0 = top of list.
    // Clamped to [0, maxCraftScroll] each draw against the real content height.
    private var craftScroll: CGFloat = 0
    private var maxCraftScroll: CGFloat = 0
    // The clipping rect of the craft rows viewport (set each draw); used to
    // reject clicks/hover on rows scrolled out of view.
    private var craftViewport: NSRect = .zero
    // Index parallel to craftRects: the recipe index each drawn rect represents.
    // (Only visible rows get rects, so positions in craftRects no longer equal
    // recipe indices once scrolled — keep the mapping explicit.)
    private var craftRowIndex: [Int] = []

    // --- #15: creative item picker ---
    // Scroll offset into the picker grid and its clamp/viewport, mirroring the
    // craft-list approach. Rects parallel to pickerItemIds for hit-testing.
    private var pickerScroll: CGFloat = 0
    private var maxPickerScroll: CGFloat = 0
    private var pickerViewport: NSRect = .zero
    private var pickerRects: [NSRect] = []
    private var pickerItemIds: [UInt16] = []
    // Sorted list of every known item id (built once from kItemTable).
    private static let kAllItemIds: [UInt16] = kItemTable.keys.sorted()

    // --- HUD options (#: text size + visibility) ---
    // Global multiplier applied to EVERY HUD font size (and the paddings that
    // depend on text height). 1.0 = the original sizes (the smallest acceptable);
    // up to ~2.0 for kids who want big text. Set from the pause-menu options and
    // persisted via UserDefaults by the app shell.
    var hudScale: CGFloat = 1.0 {
        didSet { if hudScale != oldValue { needsDisplay = true } }
    }
    // When false, the in-world gameplay HUD overlays are hidden. The inventory
    // and quest-log screens (explicitly opened) still draw so they remain usable.
    var hudVisible: Bool = true {
        didSet { if hudVisible != oldValue { needsDisplay = true } }
    }
    // Scale a base font size by the current HUD scale. Single funnel so every
    // text element honours the option.
    private func fs(_ base: CGFloat) -> CGFloat { base * hudScale }

    // --- #42: Quest/progression log overlay ---
    // Full quest chain, fetched by the Renderer (which owns the engine handle)
    // and pushed in via setQuests while the log is open. Toggled by 'L' in
    // GameView; closable with Esc. Drawn as a translucent panel listing every
    // quest with done / active / upcoming styling.
    private var questLogOpen = false
    private var quests: [QuestRow] = []
    private var questLogScroll: CGFloat = 0
    private var maxQuestLogScroll: CGFloat = 0
    private var questLogViewport: NSRect = .zero
    struct QuestRow { let title: String; let objective: String; let state: UInt8; let progress: Float }

    // True when the renderer should fetch + forward the quest list this frame.
    var isQuestLogOpen: Bool { questLogOpen }
    // Toggle the quest log (bound to 'L' in GameView). Returns the new open
    // state. GameView mirrors this state so Esc can close the log before pausing.
    @discardableResult
    func toggleQuestLog() -> Bool { questLogOpen.toggle(); needsDisplay = true; return questLogOpen }
    // Renderer pushes the freshly-fetched quest list each frame while open.
    func setQuests(_ rows: [QuestRow]) { quests = rows; if questLogOpen { needsDisplay = true } }

    // Screenshot confirmation flash (backslash key). A brief, non-blocking toast in
    // the corner so the player gets visible feedback that a shot was captured. Never
    // pauses the game. Set by the Renderer after a successful save; auto-clears.
    private var screenshotFlashUntil: TimeInterval = 0
    func flashScreenshot() {
        screenshotFlashUntil = Date().timeIntervalSinceReferenceDate + 1.2
        needsDisplay = true
        // Schedule a redraw after the flash window so it disappears even if the HUD
        // would not otherwise repaint (e.g. the player is standing still).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            self?.needsDisplay = true
        }
    }

    // Draw the fading "Screenshot saved" toast near the top-center. Fades out over
    // its lifetime; a no-op once expired.
    private func drawScreenshotFlash(in b: NSRect) {
        let now = Date().timeIntervalSinceReferenceDate
        guard now < screenshotFlashUntil else { return }
        let a = CGFloat(min(1, (screenshotFlashUntil - now) / 1.2))   // 1 -> 0
        let msg = "📸 Screenshot saved"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fs(15)),
            .foregroundColor: NSColor.white.withAlphaComponent(a),
            .strokeColor: NSColor.black.withAlphaComponent(a), .strokeWidth: -3.0,
        ]
        let sz = (msg as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 10
        let bx = b.midX - sz.width / 2 - pad
        let by = b.maxY - 64 - sz.height
        let bg = NSRect(x: bx, y: by - 6, width: sz.width + pad * 2, height: sz.height + 12)
        NSColor.black.withAlphaComponent(0.55 * a).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        (msg as NSString).draw(at: NSPoint(x: b.midX - sz.width / 2, y: by), withAttributes: attrs)
    }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    // Click-through during play; capture clicks only when an overlay (inventory
    // or quest log) is open so its scroll/close interactions work.
    override func hitTest(_ point: NSPoint) -> NSView? {
        (hud.inventory_open != 0 || questLogOpen || chestOpen) ? self : nil
    }
    // Never take key focus — the GameView must keep receiving Esc/E so the
    // inventory can always be closed (clicking a slot was stealing first
    // responder and killing the close keys). Mouse events still arrive via
    // hitTest regardless of first responder.
    override var acceptsFirstResponder: Bool { false }

    func update(from h: bf_hud_state) {
        let wasOpen = hud.inventory_open != 0
        hud = h
        // If the inventory just closed, drop any picked-up stack.
        if wasOpen && hud.inventory_open == 0 { clearHeld() }
        needsDisplay = true
    }

    private func clearHeld() {
        heldSlot = nil; heldItem = 0; heldCount = 0
    }

    // #12: Renderer pushes the player's world position + yaw each frame. We only
    // request a repaint when the displayed (rounded) value actually changes, so
    // the always-on readout doesn't force a redraw 60×/s while standing still.
    func setPlayerInfo(x: Float, y: Float, z: Float, facing: Float) {
        let changed = x.rounded() != playerX.rounded()
            || y.rounded() != playerY.rounded()
            || z.rounded() != playerZ.rounded()
            || cardinal(from: facing) != cardinal(from: playerFacing)
        playerX = x; playerY = y; playerZ = z; playerFacing = facing
        // Don't fight the inventory's own repaints; in-world readout only.
        if changed && hud.inventory_open == 0 { needsDisplay = true }
    }

    // Map a yaw (radians, from atan2(forward.x, forward.z)) to an 8-way compass
    // label. We bucket into 8 sectors of 45°. atan2(x,z): +z forward = 0,
    // +x (east) = +90°. Normalize to [0,360) then divide into octants.
    private func cardinal(from yaw: Float) -> String {
        let names = ["S", "SW", "W", "NW", "N", "NE", "E", "SE"]
        // yaw=0 points toward +z. We label +z as South and +x as East so the
        // compass reads naturally on the standard right-handed world layout.
        var deg = Double(yaw) * 180.0 / .pi
        deg = deg.truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        let idx = Int((deg / 45.0).rounded()) % 8
        return names[idx]
    }

    // #30: Renderer pushes the world time-of-day each frame (0=midnight,
    // 0.5=noon, wrapping at 1). We normalize into [0,1) and only request a
    // repaint when the displayed phase label or the integer clock hour changes,
    // so the always-on indicator doesn't force a redraw 60×/s while time creeps.
    func setTimeOfDay(_ t: Float) {
        var nt = t.truncatingRemainder(dividingBy: 1)
        if nt < 0 { nt += 1 }
        if !nt.isFinite { nt = 0.5 }
        let changed = timePhase(nt).0 != timePhase(timeOfDay).0
            || clockHour(nt) != clockHour(timeOfDay)
        timeOfDay = nt
        if changed && hud.inventory_open == 0 { needsDisplay = true }
    }

    // Day/night pin indicator: 0 auto, 1 always-day, 2 always-night. Set from
    // GameView's T key so the player gets visible confirmation the pin is active.
    var timeMode: Int32 = 0
    func setTimeMode(_ m: Int32) { if m != timeMode { timeMode = m; needsDisplay = true } }

    // Map time-of-day [0,1) to a (label, glyph). Day ≈ [0.25,0.75]; the ~0.05
    // bands at each transition read as Dawn (sunrise ~0.25) / Dusk (sunset ~0.75).
    private func timePhase(_ t: Float) -> (String, String) {
        switch t {
        case 0.23..<0.30: return ("Dawn", "🌅")
        case 0.30..<0.70: return ("Day",  "☀️")
        case 0.70..<0.77: return ("Dusk", "🌇")
        default:          return ("Night", "🌙")
        }
    }

    // Time-of-day as an integer 24h clock hour (0=midnight at t=0).
    private func clockHour(_ t: Float) -> Int {
        let h = Int((Double(t) * 24.0).rounded(.down)) % 24
        return h < 0 ? h + 24 : h
    }

    // --- #13: Multiplayer compass — other connected players (remote peers) ---
    // The Renderer scans the render frame for remote-player entities (kind 100),
    // works out for each whether it is on-screen/in-front (with a screen point)
    // or off-screen/behind (with an edge direction to point an arrow), plus the
    // distance + that peer's tint colour, and pushes the list here each frame.
    // We draw a floating marker for on-screen peers and a bright edge arrow for
    // off-screen ones so co-op kids can always find each other. Honours
    // hudVisible / hudScale like the rest of the HUD. Empty when no peers exist
    // (the compass draws nothing then).
    struct PeerMarker {
        let onScreen: Bool      // true = in front AND inside the viewport
        let screenPt: CGPoint   // view-pixel point (only meaningful when onScreen)
        let edgeDir:  CGVector  // unit-ish direction to point the arrow (off-screen)
        let distM:    Int       // distance to the peer, metres (rounded)
        let color:    NSColor   // the peer's per-peer tint
        let label:    String    // "Player" (peer) or "Boss" (#41 quest target)
    }
    private var peers: [PeerMarker] = []

    // Renderer pushes the per-frame peer list. We always request a repaint when
    // peers are present (or were present last frame) so markers/arrows track the
    // moving camera; an empty→empty transition is a no-op so an idle solo game
    // never forces extra redraws.
    func setPeers(_ list: [PeerMarker]) {
        let had = !peers.isEmpty
        peers = list
        if (had || !list.isEmpty) && hud.inventory_open == 0 && !questLogOpen {
            needsDisplay = true
        }
    }

    // ----- Mouse handling (active only while the inventory is open) -----

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        mousePos = convert(event.locationInWindow, from: nil)
        if hud.inventory_open != 0 { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        if hud.inventory_open != 0 { needsDisplay = true }
    }

    override func mouseMoved(with event: NSEvent) {
        mouseInside = true
        mousePos = convert(event.locationInWindow, from: nil)
        // Repaint only when an overlay is open (tooltip / held-stack ghost / chest hover);
        // during play the in-world HUD doesn't track the mouse.
        if hud.inventory_open != 0 || chestOpen { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        // #109 chest panel click-to-move: a click on a chest slot takes that stack into
        // the inventory; a click on an inventory slot deposits it into the chest. The
        // engine refreshes both sides next frame (it never destroys items: a full
        // inventory leaves the stack in the chest). No "held/ghost" stack here — kid
        // simple single-click moves, matching the panel's hint text.
        if chestOpen {
            let cp = convert(event.locationInWindow, from: nil)
            mousePos = cp
            for (i, r) in chestSlotRects.enumerated() where r.contains(cp) {
                onChestTake?(i)
                needsDisplay = true
                return
            }
            for (i, r) in chestInvRects.enumerated() where r.contains(cp) {
                onChestDeposit?(i)
                needsDisplay = true
                return
            }
            return
        }
        guard hud.inventory_open != 0 else { return }   // gameplay: ignore
        let p = convert(event.locationInWindow, from: nil)
        mousePos = p

        // #34: Trash slot — if carrying a stack and clicking the trash, destroy
        // the held stack's source slot. Checked first so the trash always wins
        // over slot/craft/picker hit-testing while a stack is held. Clicking the
        // trash with nothing held is a harmless no-op.
        if let src = heldSlot, trashRect.contains(p) {
            onDestroy?(src)
            clearHeld()                                  // engine refreshes next frame
            needsDisplay = true
            return
        }

        // #15: Creative item picker takes priority when shown — clicking an item
        // gives it to the player. Only active in creative mode (its rects are
        // empty otherwise, so this is a no-op in survival).
        if heldSlot == nil, let pid = pickerItemId(at: p) {
            onGiveItem?(pid)
            needsDisplay = true
            return
        }

        // Check craft rows next — clicking one crafts the recipe.
        if heldSlot == nil, let ci = craftIndex(at: p) {
            onCraft?(ci)
            needsDisplay = true
            return
        }

        guard let idx = slotIndex(at: p) else {
            // Click on empty space cancels a pending pickup.
            if heldSlot != nil { clearHeld(); needsDisplay = true }
            return
        }
        if let src = heldSlot {
            if idx == src {
                clearHeld()                              // same slot -> cancel
            } else {
                onMove?(src, idx, Int(heldCount))        // place onto target
                clearHeld()                              // engine refreshes next frame
            }
            needsDisplay = true
        } else {
            // First click: pick up the whole stack if the slot is non-empty.
            let s = inventorySlot(idx)
            if s.item != 0 {
                heldSlot = idx; heldItem = s.item; heldCount = s.count
                needsDisplay = true
            }
        }
    }

    // #16 / #15: mouse-wheel scrolling for the craft list and the creative
    // picker. Whichever panel the cursor is over receives the scroll; offsets
    // are clamped against the live content height (recomputed each draw). When
    // the inventory is closed we ignore the wheel entirely (pass it through is
    // unnecessary since hitTest already returns nil during play).
    override func scrollWheel(with event: NSEvent) {
        // Quest log scrolls independently of the inventory.
        if questLogOpen {
            let p = convert(event.locationInWindow, from: nil)
            if questLogViewport.contains(p) && maxQuestLogScroll > 0 {
                questLogScroll = min(max(0, questLogScroll + event.scrollingDeltaY), maxQuestLogScroll)
                needsDisplay = true
            }
            return
        }
        guard hud.inventory_open != 0 else { super.scrollWheel(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        // scrollingDeltaY: +up / -down in AppKit. Scrolling "down" should reveal
        // lower entries, i.e. increase the offset.
        let dy = event.scrollingDeltaY
        if pickerViewport.contains(p) && maxPickerScroll > 0 {
            pickerScroll = min(max(0, pickerScroll + dy), maxPickerScroll)
            needsDisplay = true
        } else if craftViewport.contains(p) && maxCraftScroll > 0 {
            craftScroll = min(max(0, craftScroll + dy), maxCraftScroll)
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds

        // --- #29: FPS from draw-to-draw timing (no timer) ---
        // Measure the delta since the previous draw. Clamp the delta to a sane
        // range so a paused/backgrounded gap can't produce a wild value, then
        // fold the instantaneous FPS into an exponential moving average. We do
        // this every frame (even with the inventory open) so the number stays
        // current and the box shows a stable reading the instant it's drawn.
        let nowT = CACurrentMediaTime()
        if lastDrawTime > 0 {
            let dt = nowT - lastDrawTime
            if dt > 0.0001 && dt < 1.0 {            // ignore zero / huge gaps
                let inst = 1.0 / dt
                // EMA: weight new samples lightly so the readout doesn't jitter.
                smoothedFPS = smoothedFPS <= 0 ? inst : smoothedFPS * 0.9 + inst * 0.1
            }
        }
        lastDrawTime = nowT

        // Detect death+respawn (health was a small positive, then jumps back to
        // full). prevHealth must be > 0.5 so a startup/zero-frame health (0) can
        // NEVER look like a death — that was firing a false "you died" on spawn.
        if hud.mode == BF_MODE_SURVIVAL {
            if prevHealth > 0.5 && prevHealth < 6 && hud.health >= prevHealth + 8 {
                deathFlashUntil = Date().timeIntervalSinceReferenceDate + 2.0
            }
            prevHealth = hud.health
        }

        // Screenshot confirmation toast (drawn in every HUD state, including over the
        // inventory / quest log, so the backslash key always gives feedback). Set by
        // the Renderer AFTER the captured frame, so it never appears in the saved PNG.
        drawScreenshotFlash(in: b)

        // #109 the chest panel replaces the in-world HUD while a chest is open. It is
        // its own screen (chest slots + player inventory + click-to-move).
        if chestOpen { drawChestPanel(in: b); return }

        // When the inventory is open it replaces the in-world HUD.
        if hud.inventory_open != 0 { drawInventory(in: b); return }

        // #42: the quest log overlay draws over the world (game keeps running).
        // It's an explicit screen, so it shows even when the gameplay HUD is
        // hidden via the visibility option.
        if questLogOpen { drawQuestLog(in: b); return }

        // #: HUD visibility toggle — when off, hide all the in-world info
        // overlays (hotbar, hearts, quest, status box, hints, toasts, etc.).
        // The crosshair stays so the player can still aim.
        if !hudVisible {
            if crosshair {
                let cx = b.midX, cy = b.midY, s: CGFloat = 8
                NSColor.white.withAlphaComponent(0.85).setStroke()
                let path = NSBezierPath()
                path.lineWidth = 2
                path.move(to: NSPoint(x: cx - s, y: cy)); path.line(to: NSPoint(x: cx + s, y: cy))
                path.move(to: NSPoint(x: cx, y: cy - s)); path.line(to: NSPoint(x: cx, y: cy + s))
                path.stroke()
            }
            return
        }

        // --- Death banner (fades over 2s) ---
        let now = Date().timeIntervalSinceReferenceDate
        if now < deathFlashUntil {
            let a = CGFloat((deathFlashUntil - now) / 2.0)   // 1 -> 0
            NSColor.systemRed.withAlphaComponent(0.35 * a).setFill()
            b.fill()
            let msg = "Oh no! You ran out of hearts!"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fs(34)),
                .foregroundColor: NSColor.white.withAlphaComponent(a),
                .strokeColor: NSColor.black.withAlphaComponent(a), .strokeWidth: -3.0,
            ]
            let sz = (msg as NSString).size(withAttributes: attrs)
            (msg as NSString).draw(at: NSPoint(x: b.midX - sz.width / 2, y: b.midY + 60), withAttributes: attrs)
        }

        // --- Crosshair ---
        if crosshair {
            let cx = b.midX, cy = b.midY, s: CGFloat = 8
            NSColor.white.withAlphaComponent(0.85).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 2
            path.move(to: NSPoint(x: cx - s, y: cy)); path.line(to: NSPoint(x: cx + s, y: cy))
            path.move(to: NSPoint(x: cx, y: cy - s)); path.line(to: NSPoint(x: cx, y: cy + s))
            path.stroke()
        }

        // --- Look-at name (what the crosshair is pointing at), under crosshair ---
        let lookName = withUnsafeBytes(of: hud.look_name) { raw -> String in
            // Guaranteed NUL-terminated by the engine; bind as CChar and read.
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        if !lookName.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fs(14)), .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black, .strokeWidth: -3.0,
            ]
            let sz = (lookName as NSString).size(withAttributes: attrs)
            (lookName as NSString).draw(at: NSPoint(x: b.midX - sz.width / 2, y: b.midY - 28 * hudScale),
                                        withAttributes: attrs)
        }

        // --- Hotbar (9 slots, centered along the bottom) ---
        // Scale the slot size with the HUD scale so larger count badges / item
        // icons stay proportionate and the hearts/quest anchors above it follow.
        let slot: CGFloat = 48 * hudScale, gap: CGFloat = 6 * hudScale
        let total = CGFloat(BF_HOTBAR_SLOTS) * slot + CGFloat(BF_HOTBAR_SLOTS - 1) * gap
        var x = b.midX - total / 2
        let y: CGFloat = 24
        withUnsafeBytes(of: hud.hotbar) { raw in
            let slots = raw.bindMemory(to: bf_hud_slot.self)
            for i in 0..<Int(BF_HOTBAR_SLOTS) {
                let rect = NSRect(x: x, y: y, width: slot, height: slot)
                let selected = (Int(hud.selected_slot) == i)
                (selected ? NSColor.white : NSColor.black.withAlphaComponent(0.45)).setFill()
                let rr = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                rr.fill()
                NSColor.white.withAlphaComponent(selected ? 1.0 : 0.5).setStroke()
                rr.lineWidth = selected ? 3 : 1.5
                rr.stroke()

                let s = slots[i]
                if s.item != 0 {
                    drawCenteredItem(id: s.item, count: s.count, in: rect, selected: selected)
                }
                x += slot + gap
            }
        }

        // --- Held item name (above the hotbar, centered) ---
        let heldName: String = withUnsafeBytes(of: hud.hotbar) { raw in
            let slots = raw.bindMemory(to: bf_hud_slot.self)
            let sel = min(Int(hud.selected_slot), Int(BF_HOTBAR_SLOTS) - 1)  // never read past the hotbar
            let s = slots[sel]
            return s.item != 0 ? itemName(s.item) : ""
        }
        if !heldName.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fs(15)), .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black, .strokeWidth: -3.0,
            ]
            let sz = (heldName as NSString).size(withAttributes: attrs)
            (heldName as NSString).draw(at: NSPoint(x: b.midX - sz.width / 2, y: y + slot + 8 * hudScale), withAttributes: attrs)
        }

        // --- Health hearts (survival) ---
        if hud.mode == BF_MODE_SURVIVAL {
            let heartsY = y + slot + 34 * hudScale
            drawHearts(value: hud.health, max: 20, at: NSPoint(x: b.midX - total / 2, y: heartsY))
            // Oxygen bubbles above the hearts, only while underwater (not full).
            if hud.oxygen < 0.999 {
                drawBubbles(value: hud.oxygen, at: NSPoint(x: b.midX - total / 2, y: heartsY + 18 * hudScale))
            }
        }

        // --- #42/#: Active quest (top-left), now wrapped in a rounded
        // translucent dark panel matching the top-right status box so it reads
        // clearly on any terrain. Keeps the ★ title, objective, and the green
        // progress bar. Sized to its content + scaled with the HUD scale.
        // questPanelBottom carries the panel's bottom edge so the coords readout
        // below can anchor under it at any size.
        var questPanelBottom = b.maxY - 24    // default top-left when no quest
        if hud.active_quest_id != 0 {
            let title = withUnsafeBytes(of: hud.quest_title) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let obj = withUnsafeBytes(of: hud.quest_objective) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let titleStr = "★ " + title

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fs(16)), .foregroundColor: NSColor.systemYellow,
                .strokeColor: NSColor.black, .strokeWidth: -2.0,
            ]
            let objAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fs(13)), .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black, .strokeWidth: -2.0,
            ]
            let tSz = (titleStr as NSString).size(withAttributes: titleAttrs)
            let oSz = (obj as NSString).size(withAttributes: objAttrs)

            let pad: CGFloat = 8 * hudScale
            let lineGap: CGFloat = 3 * hudScale
            let barH: CGFloat = 6 * hudScale
            let barGap: CGFloat = 5 * hudScale
            let contentW = max(max(tSz.width, oSz.width), 200 * hudScale)
            let boxW = contentW + pad * 2
            let boxH = tSz.height + oSz.height + barH + lineGap + barGap + pad * 2
            let margin: CGFloat = 16
            let box = NSRect(x: margin, y: b.maxY - margin - boxH, width: boxW, height: boxH)

            // Panel: same look as the status box (dark fill + subtle border).
            NSColor.black.withAlphaComponent(0.45).setFill()
            let rr = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
            rr.fill()
            NSColor.white.withAlphaComponent(0.20).setStroke()
            rr.lineWidth = 1; rr.stroke()

            // Title, objective, then the progress bar — stacked top-to-bottom.
            var ly = box.maxY - pad - tSz.height
            (titleStr as NSString).draw(at: NSPoint(x: box.minX + pad, y: ly), withAttributes: titleAttrs)
            ly -= oSz.height + lineGap
            (obj as NSString).draw(at: NSPoint(x: box.minX + pad, y: ly), withAttributes: objAttrs)
            ly -= barGap + barH
            let barRect = NSRect(x: box.minX + pad, y: ly, width: contentW, height: barH)
            NSColor.black.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: barH / 2, yRadius: barH / 2).fill()
            let p = CGFloat(max(0, min(1, hud.quest_progress)))
            NSColor.systemGreen.setFill()
            NSBezierPath(roundedRect: NSRect(x: barRect.minX, y: barRect.minY,
                                             width: barRect.width * p, height: barRect.height),
                         xRadius: barH / 2, yRadius: barH / 2).fill()
            questPanelBottom = box.minY
        }

        // --- #12: Coordinates + facing readout (top-left, always visible) ---
        // Sits under the quest panel when a quest is active so they don't
        // overlap; otherwise tucks into the top-left corner. Compact: a coord
        // line + a cardinal direction badge.
        do {
            let xi = Int(playerX.rounded())
            let yi = Int(playerY.rounded())
            let zi = Int(playerZ.rounded())
            let dir = cardinal(from: playerFacing)
            let coordStr = "X: \(xi)   Y: \(yi)   Z: \(zi)"
            let facingStr = "Facing: \(dir)"
            // Anchor just below the quest panel (its bottom edge), else top-left.
            let topY = (hud.active_quest_id != 0) ? (questPanelBottom - 8) : (b.maxY - 24)
            let coAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fs(13), weight: .semibold),
                .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black, .strokeWidth: -3.0,
            ]
            let cSz = (coordStr as NSString).size(withAttributes: coAttrs)
            let fSz = (facingStr as NSString).size(withAttributes: coAttrs)
            let pad: CGFloat = 6 * hudScale
            let boxW = max(cSz.width, fSz.width) + pad * 2
            let boxH = cSz.height + fSz.height + pad * 2 + 2
            let box = NSRect(x: 16, y: topY - boxH + cSz.height, width: boxW, height: boxH)
            NSColor.black.withAlphaComponent(0.40).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            (coordStr as NSString).draw(at: NSPoint(x: box.minX + pad, y: box.maxY - cSz.height - pad),
                                        withAttributes: coAttrs)
            (facingStr as NSString).draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad - 1),
                                         withAttributes: coAttrs)
        }

        // --- #28 / #29: Environment status box (top-right) ---
        // A single bordered panel replacing the old loose mode/weather/biome
        // labels. Lines: game mode (coloured), FPS, weather, the Grey indicator,
        // and the biome. The box is sized to the widest line and anchored to the
        // top-right with a margin so it never overlaps the top-left quest panel.
        drawStatusBox(in: b)

        // Always-visible hints (bottom-right) so kids discover the helpers:
        // the Guide companion (G) and the new quest log (#42, L). Stacked.
        let hintAttrsFor: (CGFloat) -> [NSAttributedString.Key: Any] = { size in [
            .font: NSFont.boldSystemFont(ofSize: size),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            .strokeColor: NSColor.black.withAlphaComponent(0.8), .strokeWidth: -3.0,
        ] }
        let ghAttrs = hintAttrsFor(fs(12))
        let guideHint = "❓ Stuck? Press G for the Guide"
        let questHint = "📜 Press L for the Quest Log"
        let ghSz = (guideHint as NSString).size(withAttributes: ghAttrs)
        let qhSz = (questHint as NSString).size(withAttributes: ghAttrs)
        (questHint as NSString).draw(at: NSPoint(x: b.maxX - qhSz.width - 14, y: 14), withAttributes: ghAttrs)
        (guideHint as NSString).draw(at: NSPoint(x: b.maxX - ghSz.width - 14, y: 14 + qhSz.height + 4), withAttributes: ghAttrs)

        // --- #13: Multiplayer compass (only when other players are connected) ---
        drawPeerCompass(in: b)

        // Achievement toast (top-center banner) when one was just unlocked.
        let toast = withUnsafeBytes(of: hud.achievement_toast) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        if !toast.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fs(20)),
                .foregroundColor: NSColor(red: 1.0, green: 0.86, blue: 0.30, alpha: 1),
                .strokeColor: NSColor.black, .strokeWidth: -3.0,
            ]
            let sz = (toast as NSString).size(withAttributes: attrs)
            let pad: CGFloat = 16
            let bx = b.midX - sz.width/2 - pad, by = b.maxY - 96
            let bg = NSRect(x: bx, y: by - 6, width: sz.width + pad*2, height: sz.height + 12)
            NSColor(red: 0.10, green: 0.14, blue: 0.10, alpha: 0.82).setFill()
            NSBezierPath(roundedRect: bg, xRadius: 10, yRadius: 10).fill()
            NSColor(red: 1.0, green: 0.86, blue: 0.30, alpha: 0.8).setStroke()
            let bp = NSBezierPath(roundedRect: bg, xRadius: 10, yRadius: 10); bp.lineWidth = 2; bp.stroke()
            (toast as NSString).draw(at: NSPoint(x: b.midX - sz.width/2, y: by), withAttributes: attrs)
        }

        // #95 living-villages donation panel (only when standing near a village).
        drawVillagePanel(in: b)
    }

    // #95: a compact bottom-center panel showing the nearest village's tier, what the
    // next villager wants, and a progress bar. Hidden when no village is in range.
    private func drawVillagePanel(in b: NSRect) {
        guard let v = villageView, v.present != 0 else { return }
        // Read the requested item name (a C char[16]).
        let want = withUnsafeBytes(of: v.want) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let tierName: String
        switch v.tier {
        case 0: tierName = "Village"
        case 1: tierName = "Walled Village"
        case 2: tierName = "Stone Town"
        default: tierName = "Iron-Gated Town"
        }
        // Headline + the donation hint.
        let title = "\(tierName)  ·  Tier \(v.tier)/3"
        let hint: String
        switch want {
        case "wood":  hint = "Bring the Woodcutter LOGS for the wall"
        case "stone": hint = "Bring the Stone Mason STONE to reinforce it"
        case "iron":  hint = "Bring the Blacksmith IRON for the gate + lamps"
        default:      hint = "This town is complete — safe through the night!"
        }
        // Progress fraction: wood tier uses wall cells; later tiers use the resource count.
        let frac: CGFloat
        if v.tier <= 1 && v.wood_cells < v.wood_total {
            frac = v.wood_total > 0 ? CGFloat(v.wood_cells) / CGFloat(v.wood_total) : 0
        } else if v.progress_needed > 0 {
            frac = min(1, CGFloat(v.progress) / CGFloat(v.progress_needed))
        } else {
            frac = 1
        }
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fs(15)),
            .foregroundColor: NSColor(red: 0.96, green: 0.90, blue: 0.66, alpha: 1),
            .strokeColor: NSColor.black, .strokeWidth: -2.5,
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fs(12)),
            .foregroundColor: NSColor(white: 0.92, alpha: 1),
            .strokeColor: NSColor.black, .strokeWidth: -2.0,
        ]
        let tSz = (title as NSString).size(withAttributes: titleAttrs)
        let hSz = (hint as NSString).size(withAttributes: hintAttrs)
        let pad: CGFloat = 14
        let barH: CGFloat = 8
        let w = max(tSz.width, hSz.width) + pad * 2
        let h = tSz.height + hSz.height + barH + 18
        let bx = b.midX - w / 2
        let by: CGFloat = 92   // sit just above the hotbar
        let box = NSRect(x: bx, y: by, width: w, height: h)
        NSColor(red: 0.08, green: 0.10, blue: 0.12, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        NSColor(red: 0.96, green: 0.86, blue: 0.40, alpha: 0.7).setStroke()
        let bp = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10); bp.lineWidth = 2; bp.stroke()
        var cy = box.maxY - tSz.height - 6
        (title as NSString).draw(at: NSPoint(x: box.midX - tSz.width/2, y: cy), withAttributes: titleAttrs)
        cy -= hSz.height + 2
        (hint as NSString).draw(at: NSPoint(x: box.midX - hSz.width/2, y: cy), withAttributes: hintAttrs)
        // Progress bar.
        let barRect = NSRect(x: box.minX + pad, y: box.minY + 8, width: box.width - pad*2, height: barH)
        NSColor(white: 0.20, alpha: 1).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 4, yRadius: 4).fill()
        if frac > 0 {
            let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: max(2, barRect.width * frac), height: barH)
            NSColor(red: 0.42, green: 0.82, blue: 0.40, alpha: 1).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 4, yRadius: 4).fill()
        }
    }

    // ===== #28 / #29: Environment status box ================================
    // A single tidy bordered panel in the top-right corner that gathers the
    // game mode, FPS, weather, the "In the Grey" indicator and the biome into
    // compact, aligned lines. Matches the other HUD panels (rounded rect,
    // semi-transparent dark fill, subtle border). Sized to the widest line and
    // anchored top-right with a margin, so it stays clear of the top-left quest
    // panel. The view is non-flipped: +x right, +y up.
    private func drawStatusBox(in b: NSRect) {
        // One status line = text + colour. Built top-to-bottom in reading order.
        struct StatusLine { let text: String; let color: NSColor; let bold: Bool }
        var lines: [StatusLine] = []

        // Game mode — keep the existing teal/orange colour cue.
        let creative = (hud.mode == BF_MODE_CREATIVE)
        lines.append(StatusLine(text: creative ? "CREATIVE" : "SURVIVAL",
                                color: creative ? .systemTeal : .systemOrange,
                                bold: true))

        // Day/Night indicator (#30) — sun/moon glyph + phase label + 24h clock.
        // Coloured warm for day, cool for night, so it reads at a glance.
        let (phaseLabel, phaseGlyph) = timePhase(timeOfDay)
        let hour = clockHour(timeOfDay)
        let clockStr = String(format: "%02d:00", hour)
        let isDay = (timeOfDay >= 0.25 && timeOfDay < 0.75)
        let timeColor = isDay ? NSColor(srgbRed: 1.0, green: 0.86, blue: 0.40, alpha: 1)
                              : NSColor(srgbRed: 0.66, green: 0.74, blue: 0.95, alpha: 1)
        lines.append(StatusLine(text: "\(phaseGlyph) \(phaseLabel)  \(clockStr)",
                                color: timeColor, bold: true))
        // Index of the time line within `lines`, so we can underlay a progress
        // bar at exactly its row after the box is laid out below.
        let timeLineIdx = lines.count - 1
        // Day/night pin (T key) indicator, so the player can see the pin is on.
        if timeMode != 0 {
            lines.append(StatusLine(text: timeMode == 1 ? "[ALWAYS DAY] (T)" : "[ALWAYS NIGHT] (T)",
                                    color: NSColor(srgbRed: 1.0, green: 0.55, blue: 0.85, alpha: 1),
                                    bold: true))
        }

        // FPS (#29) — rounded smoothed value. Shows "—" until the first delta.
        let fpsText = smoothedFPS > 0 ? "\(Int(smoothedFPS.rounded())) FPS" : "— FPS"
        lines.append(StatusLine(text: fpsText,
                                color: NSColor.white.withAlphaComponent(0.9), bold: false))

        // Weather: 0=Clear, 1=Rain, 2=Snow.
        let weather: (String, NSColor)
        switch hud.weather {
        case 1:  weather = ("Weather: Rain", NSColor(srgbRed: 0.62, green: 0.78, blue: 0.95, alpha: 1))
        case 2:  weather = ("Weather: Snow", NSColor(srgbRed: 0.92, green: 0.95, blue: 0.98, alpha: 1))
        default: weather = ("Weather: Clear", NSColor.white.withAlphaComponent(0.85))
        }
        lines.append(StatusLine(text: weather.0, color: weather.1, bold: false))

        // "In the Grey" indicator (#28). Make the Grey state obvious (that's the
        // whole point); when restored, show a quiet rainbow line so the contrast
        // reads clearly for kids.
        if hud.in_dim != 0 {
            lines.append(StatusLine(text: "⬛ The Grey",
                                    color: NSColor(white: 0.62, alpha: 1.0), bold: true))
        } else {
            lines.append(StatusLine(text: "🌈 Restored",
                                    color: NSColor.white.withAlphaComponent(0.85), bold: false))
        }

        // Biome name (NUL-terminated char[] like the other char fields).
        let biome = withUnsafeBytes(of: hud.biome_name) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        if !biome.isEmpty {
            lines.append(StatusLine(text: biome,
                                    color: NSColor.white.withAlphaComponent(0.85), bold: false))
        }

        // Layout: measure every line, size the box to the widest, stack them
        // with consistent padding + line spacing.
        let fontSize: CGFloat = fs(13)
        let pad: CGFloat = 8 * hudScale    // inner padding
        let lineGap: CGFloat = 3 * hudScale // gap between lines
        let margin: CGFloat = 16           // distance from the top-right corner

        func attrs(_ l: StatusLine) -> [NSAttributedString.Key: Any] {
            [
                .font: l.bold ? NSFont.boldSystemFont(ofSize: fontSize)
                              : NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: l.color,
                .strokeColor: NSColor.black, .strokeWidth: -2.0,
            ]
        }

        var maxW: CGFloat = 0
        var lineH: CGFloat = 0
        for l in lines {
            let sz = (l.text as NSString).size(withAttributes: attrs(l))
            maxW = max(maxW, sz.width)
            lineH = max(lineH, sz.height)
        }
        let count = CGFloat(lines.count)
        let boxW = maxW + pad * 2
        let boxH = count * lineH + (count - 1) * lineGap + pad * 2

        let box = NSRect(x: b.maxX - boxW - margin, y: b.maxY - boxH - margin,
                         width: boxW, height: boxH)

        // Panel: semi-transparent dark fill + subtle border (matches HUD style).
        NSColor.black.withAlphaComponent(0.45).setFill()
        let rr = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        rr.fill()
        NSColor.white.withAlphaComponent(0.20).setStroke()
        rr.lineWidth = 1; rr.stroke()

        // Draw lines top-to-bottom inside the box.
        var ly = box.maxY - pad - lineH
        for (i, l) in lines.enumerated() {
            (l.text as NSString).draw(at: NSPoint(x: box.minX + pad, y: ly),
                                      withAttributes: attrs(l))
            // #30: draw a thin day/night progress bar tucked under the time line,
            // marking where we are in the 0..1 cycle (midnight → noon → midnight).
            if i == timeLineIdx {
                let barH: CGFloat = 3
                let barY = ly - 2                          // just under the text baseline
                let barRect = NSRect(x: box.minX + pad, y: barY,
                                     width: maxW, height: barH)
                NSColor.black.withAlphaComponent(0.45).setFill()
                NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()
                let frac = CGFloat(max(0, min(1, timeOfDay)))
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: barRect.minX, y: barRect.minY,
                                                 width: max(2, barRect.width * frac),
                                                 height: barH),
                             xRadius: 1.5, yRadius: 1.5).fill()
            }
            ly -= lineH + lineGap
        }
    }

    // ===== #13: Multiplayer compass =========================================
    // Draws an indicator for every other connected player (a "remote peer").
    // The Renderer has already done the camera/projection maths and handed us,
    // per peer: whether it is on-screen (with a screen point), an off-screen
    // arrow direction, the distance, and the peer's tint colour.
    //
    //   ON-SCREEN peer  : a small floating diamond marker + "Player" + "24m"
    //                     hovering just above the peer's projected screen point.
    //   OFF-SCREEN peer : a bright filled triangle ARROW pinned just inside the
    //                     screen edge, pointing toward the peer, with the
    //                     distance beside it — kid-obvious in the peer's colour.
    //
    // Cheap NSBezierPath / NSColor like the rest of the HUD. Nothing draws when
    // there are zero peers, when the HUD is hidden, or while an overlay is up.
    private func drawPeerCompass(in b: NSRect) {
        guard !peers.isEmpty else { return }

        for peer in peers {
            if peer.onScreen {
                drawOnScreenPeer(peer, in: b)
            } else {
                drawOffScreenPeerArrow(peer, in: b)
            }
        }
    }

    // A floating marker hovering at/above a peer that is visible on screen.
    private func drawOnScreenPeer(_ peer: PeerMarker, in b: NSRect) {
        // Clamp the projected point into the view so a marker right at the edge
        // is still fully drawn.
        let mPad: CGFloat = 22 * hudScale
        let px = min(max(b.minX + mPad, peer.screenPt.x), b.maxX - mPad)
        let py = min(max(b.minY + mPad, peer.screenPt.y), b.maxY - mPad)

        // Small diamond marker in the peer's colour, hovering above their head.
        let mR: CGFloat = 9 * hudScale
        let cy = py + 26 * hudScale            // float above the projected point
        let diamond = NSBezierPath()
        diamond.move(to: NSPoint(x: px,      y: cy + mR))
        diamond.line(to: NSPoint(x: px + mR, y: cy))
        diamond.line(to: NSPoint(x: px,      y: cy - mR))
        diamond.line(to: NSPoint(x: px - mR, y: cy))
        diamond.close()
        peer.color.withAlphaComponent(0.95).setFill()
        diamond.fill()
        NSColor.black.withAlphaComponent(0.85).setStroke()
        diamond.lineWidth = 2 * hudScale
        diamond.stroke()
        // A little downward stem so it reads as a "pin" pointing at the player.
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: px, y: cy - mR))
        stem.line(to: NSPoint(x: px, y: cy - mR - 8 * hudScale))
        NSColor.black.withAlphaComponent(0.85).setStroke()
        stem.lineWidth = 2 * hudScale
        stem.stroke()

        // Label: "Player"/"Boss" + distance, centered above the marker.
        let label = "\(peer.label)  \(peer.distM)m"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fs(12)),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black, .strokeWidth: -3.0,
        ]
        let sz = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: px - sz.width / 2, y: cy + mR + 4 * hudScale),
                                 withAttributes: attrs)
    }

    // A bright triangle arrow pinned near the screen edge, pointing toward a peer
    // who is off-screen or behind the camera.
    private func drawOffScreenPeerArrow(_ peer: PeerMarker, in b: NSRect) {
        // Normalize the supplied direction (Renderer keeps it stable for the
        // behind-camera case). Guard against a zero vector.
        var dx = peer.edgeDir.dx
        var dy = peer.edgeDir.dy
        let len = (dx * dx + dy * dy).squareRoot()
        if len < 1e-4 { dx = 0; dy = 1 } else { dx /= len; dy /= len }

        // Project a ray from the screen centre to the rectangle edge, then pull
        // the arrow inward by a margin so it sits fully on screen.
        let inset: CGFloat = 46 * hudScale
        let rect = b.insetBy(dx: inset, dy: inset)
        let cx = rect.midX, cy = rect.midY
        let hw = rect.width / 2, hh = rect.height / 2
        // Largest t such that (cx + dx*t, cy + dy*t) is still inside the rect.
        var t = CGFloat.greatestFiniteMagnitude
        if abs(dx) > 1e-4 { t = min(t, hw / abs(dx)) }
        if abs(dy) > 1e-4 { t = min(t, hh / abs(dy)) }
        if !t.isFinite { t = 0 }
        let ax = cx + dx * t
        let ay = cy + dy * t

        // Triangle arrow pointing along (dx, dy), centered at (ax, ay).
        let aLen: CGFloat = 20 * hudScale   // tip length
        let aWide: CGFloat = 13 * hudScale  // half-width of the base
        let tipX = ax + dx * aLen, tipY = ay + dy * aLen
        // Perpendicular for the base corners.
        let pxx = -dy, pyy = dx
        let baseX = ax - dx * (aLen * 0.4), baseY = ay - dy * (aLen * 0.4)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: tipX, y: tipY))
        arrow.line(to: NSPoint(x: baseX + pxx * aWide, y: baseY + pyy * aWide))
        arrow.line(to: NSPoint(x: baseX - pxx * aWide, y: baseY - pyy * aWide))
        arrow.close()
        peer.color.withAlphaComponent(0.95).setFill()
        arrow.fill()
        NSColor.black.withAlphaComponent(0.85).setStroke()
        arrow.lineWidth = 2 * hudScale
        arrow.stroke()

        // Label + distance, placed just inward of the arrow (toward the centre).
        let label = "\(peer.label)  \(peer.distM)m"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fs(12)),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black, .strokeWidth: -3.0,
        ]
        let sz = (label as NSString).size(withAttributes: attrs)
        let lx = ax - dx * (24 * hudScale) - sz.width / 2
        let ly = ay - dy * (24 * hudScale) - sz.height / 2
        (label as NSString).draw(at: NSPoint(x: lx, y: ly), withAttributes: attrs)
    }

    // ===== #42: Quest / progression log overlay =============================
    // A toggleable panel (L) listing the FULL quest chain so the player can see
    // their progress. Done quests show a green check and are dimmed; the active
    // quest is highlighted with its objective + a green progress bar (same look
    // as the top-left quest bar); upcoming quests look locked with their
    // objective shown as a faint hint. Scrollable for ~15 rows. Matches the
    // translucent-dark rounded-panel HUD aesthetic. Honours the HUD text scale.
    private func drawQuestLog(in b: NSRect) {
        // Dim the world behind the overlay so the list reads clearly.
        NSColor.black.withAlphaComponent(0.55).setFill()
        b.fill()

        // Outer panel, centered, sized as a comfortable fraction of the window.
        let panelW = min(b.width - 80, 560 * hudScale)
        let panelH = min(b.height - 100, 620 * hudScale)
        let panel = NSRect(x: b.midX - panelW / 2, y: b.midY - panelH / 2,
                           width: panelW, height: panelH)
        NSColor.black.withAlphaComponent(0.55).setFill()
        let pp = NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12); pp.fill()
        NSColor.white.withAlphaComponent(0.20).setStroke()
        pp.lineWidth = 1.5; pp.stroke()

        let pad: CGFloat = 16 * hudScale

        // Title strip.
        let titleH = fs(24)
        drawText("📜 Quest Log", at: NSPoint(x: panel.minX + pad, y: panel.maxY - pad - titleH),
                 size: fs(22), color: .systemYellow, bold: true)
        drawText("Press L or Esc to close", at: NSPoint(x: panel.minX + pad, y: panel.maxY - pad - titleH - fs(16)),
                 size: fs(12), color: NSColor.white.withAlphaComponent(0.7), bold: false)

        // Empty-state message if the engine hasn't reported any quests yet.
        if quests.isEmpty {
            drawText("No quests yet — start exploring!",
                     at: NSPoint(x: panel.minX + pad, y: panel.midY),
                     size: fs(14), color: NSColor.white.withAlphaComponent(0.8), bold: false)
            questLogViewport = .zero; maxQuestLogScroll = 0
            return
        }

        // Scrollable rows region below the header.
        let viewTop = panel.maxY - pad - titleH - fs(16) - 12 * hudScale
        let viewBottom = panel.minY + pad
        let viewport = NSRect(x: panel.minX + pad, y: viewBottom,
                              width: panelW - pad * 2, height: max(40, viewTop - viewBottom))
        questLogViewport = viewport

        let rowH: CGFloat = 64 * hudScale
        let rowGap: CGFloat = 8 * hudScale
        let n = quests.count
        let contentH = CGFloat(n) * (rowH + rowGap) - rowGap
        maxQuestLogScroll = max(0, contentH - viewport.height)
        questLogScroll = min(max(0, questLogScroll), maxQuestLogScroll)

        clipped(to: [NSPoint(x: viewport.minX, y: viewport.minY),
                     NSPoint(x: viewport.maxX, y: viewport.minY),
                     NSPoint(x: viewport.maxX, y: viewport.maxY),
                     NSPoint(x: viewport.minX, y: viewport.maxY)]) {
            for (i, q) in quests.enumerated() {
                // Row 0 at the top of the viewport; scroll moves rows up.
                let ry = viewport.maxY - rowH - CGFloat(i) * (rowH + rowGap) + questLogScroll
                let rowRect = NSRect(x: viewport.minX, y: ry, width: viewport.width, height: rowH)
                if rowRect.maxY < viewport.minY || rowRect.minY > viewport.maxY { continue }
                drawQuestRow(rowRect, quest: q)
            }
        }

        if maxQuestLogScroll > 0 {
            drawScrollbar(in: viewport, contentH: contentH, scroll: questLogScroll)
        }
    }

    // One quest row: state-styled. DONE = green check + dimmed; ACTIVE =
    // highlighted with objective + progress bar; UPCOMING = locked/dimmed hint.
    private func drawQuestRow(_ rowRect: NSRect, quest q: QuestRow) {
        let active = (q.state == UInt8(BF_QUEST_ACTIVE.rawValue))
        let done   = (q.state == UInt8(BF_QUEST_DONE.rawValue))
        let pad: CGFloat = 10 * hudScale

        // Row background — the active quest is highlighted; others are subtle.
        (active ? NSColor.systemGreen.withAlphaComponent(0.18)
                : NSColor.black.withAlphaComponent(0.45)).setFill()
        let rr = NSBezierPath(roundedRect: rowRect, xRadius: 6, yRadius: 6); rr.fill()
        (active ? NSColor.systemGreen.withAlphaComponent(0.80)
                : NSColor.white.withAlphaComponent(0.18)).setStroke()
        rr.lineWidth = active ? 2 : 1; rr.stroke()

        // Leading status glyph.
        let glyph = done ? "✅" : (active ? "⭐️" : "🔒")
        let glyphAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fs(20))]
        let gSz = (glyph as NSString).size(withAttributes: glyphAttrs)
        (glyph as NSString).draw(at: NSPoint(x: rowRect.minX + pad, y: rowRect.maxY - pad - gSz.height),
                                 withAttributes: glyphAttrs)

        let textX = rowRect.minX + pad + gSz.width + 8 * hudScale
        let textW = rowRect.maxX - pad - textX

        // Title — dimmed for done/upcoming, bright for active.
        let titleColor: NSColor = active ? .systemYellow
            : (done ? NSColor.systemGreen.withAlphaComponent(0.85)
                    : NSColor.white.withAlphaComponent(0.45))
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fs(15)), .foregroundColor: titleColor,
        ]
        let title = truncated(q.title, to: textW, attrs: titleAttrs)
        let tSz = (title as NSString).size(withAttributes: titleAttrs)
        (title as NSString).draw(at: NSPoint(x: textX, y: rowRect.maxY - pad - tSz.height),
                                 withAttributes: titleAttrs)

        // Objective line — shown for active (its current goal) and upcoming (as a
        // faint hint). Done quests skip it to read as "completed".
        if !done {
            let objColor = active ? NSColor.white.withAlphaComponent(0.9)
                                  : NSColor.white.withAlphaComponent(0.40)
            let objAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fs(12)), .foregroundColor: objColor,
            ]
            let obj = truncated(q.objective, to: textW, attrs: objAttrs)
            (obj as NSString).draw(at: NSPoint(x: textX, y: rowRect.maxY - pad - tSz.height - fs(12) - 4 * hudScale),
                                   withAttributes: objAttrs)
        }

        // Progress bar for the active quest — same green-bar look as the
        // top-left quest panel.
        if active {
            let barH: CGFloat = 6 * hudScale
            let barRect = NSRect(x: textX, y: rowRect.minY + pad, width: textW, height: barH)
            NSColor.black.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: barH / 2, yRadius: barH / 2).fill()
            let p = CGFloat(max(0, min(1, q.progress)))
            NSColor.systemGreen.setFill()
            NSBezierPath(roundedRect: NSRect(x: barRect.minX, y: barRect.minY,
                                             width: barRect.width * p, height: barRect.height),
                         xRadius: barH / 2, yRadius: barH / 2).fill()
        }
    }

    // Inventory grid geometry — single source of truth for both drawing and
    // hit-testing. Returns 36 rects indexed by inventory slot (0..8 hotbar row,
    // 9..35 main grid), matching the bf_hud_state.inventory layout we draw.
    private func inventorySlotRects(in b: NSRect) -> [NSRect] {
        let slot: CGFloat = 46, gap: CGFloat = 5
        let cols = 9
        let gridW = CGFloat(cols) * slot + CGFloat(cols - 1) * gap
        let originX = b.midX - gridW / 2

        // Pre-size so we can assign by index regardless of fill order.
        var rects = [NSRect](repeating: .zero, count: 36)
        // Main inventory: slots 9..35 in 3 rows of 9, above the hotbar row.
        var topY = b.midY + 120
        for row in 0..<3 {
            var x = originX
            for col in 0..<cols {
                let i = 9 + row * 9 + col
                rects[i] = NSRect(x: x, y: topY, width: slot, height: slot)
                x += slot + gap
            }
            topY -= slot + gap
        }
        // Hotbar row (slots 0..8) a little below the main grid.
        let hy = topY - 12
        var hx = originX
        for col in 0..<9 {
            rects[col] = NSRect(x: hx, y: hy, width: slot, height: slot)
            hx += slot + gap
        }
        return rects
    }

    // #109 chest screen: the chest's slots on top, the player inventory below, with
    // single-click to move (chest slot -> inventory, inventory slot -> chest). Reuses
    // the inventory's slot cell + item rendering so it matches the existing HUD style.
    // Kid-simple: one row of chest slots, a clear "Treasure Chest" header, and a hint.
    private func drawChestPanel(in b: NSRect) {
        NSColor.black.withAlphaComponent(0.60).setFill()
        b.fill()

        let slot: CGFloat = 46, gap: CGFloat = 5
        let cols = 9
        let gridW = CGFloat(cols) * slot + CGFloat(cols - 1) * gap
        let originX = b.midX - gridW / 2

        // Shared cell renderer (same look as the inventory). `hot` highlights the
        // selected hotbar slot so the player can still see their active slot.
        func cell(_ rect: NSRect, _ s: bf_hud_slot, sel: Bool) {
            (sel ? NSColor.white : NSColor.black.withAlphaComponent(0.5)).setFill()
            let rr = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            rr.fill()
            (sel ? NSColor.white : NSColor.systemYellow.withAlphaComponent(0.5)).setStroke()
            rr.lineWidth = sel ? 2.5 : 1
            rr.stroke()
            if s.item != 0 { drawCenteredItem(id: s.item, count: s.count, in: rect, selected: sel) }
        }

        // --- Chest row (the container) sits in the upper third. ---
        let chestN = Int(BF_CHEST_SLOTS)
        let chestRowW = CGFloat(chestN) * slot + CGFloat(chestN - 1) * gap
        let chestX = b.midX - chestRowW / 2
        let chestY = b.midY + 150

        // A framed panel behind the chest row so it reads as "the chest".
        let chestPanel = NSRect(x: chestX - 14, y: chestY - 16,
                                width: chestRowW + 28, height: slot + 56)
        NSColor(srgbRed: 0.30, green: 0.20, blue: 0.10, alpha: 0.55).setFill()
        let cpp = NSBezierPath(roundedRect: chestPanel, xRadius: 10, yRadius: 10); cpp.fill()
        NSColor.systemYellow.withAlphaComponent(0.6).setStroke()
        cpp.lineWidth = 2; cpp.stroke()

        drawText("Treasure Chest", at: NSPoint(x: chestX, y: chestY + slot + 16),
                 size: fs(20), color: .systemYellow, bold: true)

        var crects = [NSRect]()
        for i in 0..<chestN {
            let r = NSRect(x: chestX + CGFloat(i) * (slot + gap), y: chestY, width: slot, height: slot)
            crects.append(r)
            let s = i < chestSlots.count ? chestSlots[i] : bf_hud_slot()
            cell(r, s, sel: false)
        }
        chestSlotRects = crects

        // --- Player inventory below (hotbar + 3 main rows). ---
        let invTopY = b.midY + 40
        var irects = [NSRect](repeating: .zero, count: 36)
        // Main inventory 9..35 (3 rows of 9).
        var topY = invTopY
        for row in 0..<3 {
            for col in 0..<cols {
                let i = 9 + row * 9 + col
                irects[i] = NSRect(x: originX + CGFloat(col) * (slot + gap), y: topY, width: slot, height: slot)
            }
            topY -= slot + gap
        }
        // Hotbar row 0..8 a little below the main grid.
        let hy = topY - 12
        for col in 0..<9 {
            irects[col] = NSRect(x: originX + CGFloat(col) * (slot + gap), y: hy, width: slot, height: slot)
        }
        chestInvRects = irects

        drawText("Your Backpack", at: NSPoint(x: originX, y: invTopY + slot + 8),
                 size: fs(18), color: .white, bold: true)

        withUnsafeBytes(of: hud.inventory) { raw in
            let inv = raw.bindMemory(to: bf_hud_slot.self)
            for i in 9..<36 { cell(irects[i], inv[i], sel: false) }
            for col in 0..<9 { cell(irects[col], inv[col], sel: Int(hud.selected_slot) == col) }
        }

        // Hints at the bottom.
        drawText("Click a chest item to take it   •   click a backpack item to store it",
                 at: NSPoint(x: originX, y: hy - 30), size: fs(13), color: .white, bold: true)
        drawText("Press Esc to close",
                 at: NSPoint(x: originX, y: 18), size: fs(12), color: .white, bold: false)

        // Hover tooltip (which item is under the cursor).
        if mouseInside {
            if let i = chestSlotRects.firstIndex(where: { $0.contains(mousePos) }),
               i < chestSlots.count, chestSlots[i].item != 0 {
                drawTooltip(name: itemName(chestSlots[i].item), count: chestSlots[i].count,
                            itemId: chestSlots[i].item, hint: "click to take", near: mousePos)
            } else if let i = chestInvRects.firstIndex(where: { $0.contains(mousePos) }) {
                let s = inventorySlot(i)
                if s.item != 0 {
                    drawTooltip(name: itemName(s.item), count: s.count, itemId: s.item,
                                hint: "click to store", near: mousePos)
                }
            }
        }
    }

    // Inventory screen: 27 main slots (3x9) + the 9-slot hotbar row, with a
    // 2x2 crafting grid + result preview at the top. Populated from
    // bf_hud_state.inventory (engine fills it when open).
    private func drawInventory(in b: NSRect) {
        NSColor.black.withAlphaComponent(0.55).setFill()
        b.fill()
        let slot: CGFloat = 46, gap: CGFloat = 5
        let cols = 9
        let gridW = CGFloat(cols) * slot + CGFloat(cols - 1) * gap
        let originX = b.midX - gridW / 2

        // Record geometry so mouseDown/mouseMoved can hit-test against it.
        let rects = inventorySlotRects(in: b)
        slotRects = rects

        func cell(_ rect: NSRect, _ s: bf_hud_slot, sel: Bool, picked: Bool) {
            (sel ? NSColor.white : NSColor.black.withAlphaComponent(0.5)).setFill()
            let rr = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            rr.fill()
            (picked ? NSColor.systemYellow : NSColor.white.withAlphaComponent(sel ? 1 : 0.4)).setStroke()
            rr.lineWidth = (picked || sel) ? 2.5 : 1
            rr.stroke()
            // The picked-up slot is drawn empty (its stack rides the cursor).
            if s.item != 0 && !picked {
                drawCenteredItem(id: s.item, count: s.count, in: rect, selected: sel)
            }
        }

        // Title sits just above the top inventory row (rects[9] is the top-left
        // main slot). Keeps the header anchored to the grid at any window size.
        let invTop = rects[9].maxY
        drawText("Inventory", at: NSPoint(x: originX, y: invTop + 14), size: fs(20), color: .white, bold: true)

        withUnsafeBytes(of: hud.inventory) { raw in
            let inv = raw.bindMemory(to: bf_hud_slot.self)
            // Main inventory: slots 9..35.
            for i in 9..<36 {
                cell(rects[i], inv[i], sel: false, picked: heldSlot == i)
            }
            // Hotbar row (slots 0..8), highlighting the selection.
            for col in 0..<9 {
                cell(rects[col], inv[col], sel: Int(hud.selected_slot) == col,
                     picked: heldSlot == col)
            }
        }

        // --- #34: Trash slot — drop a picked-up stack here to delete it. Sits
        // just to the right of the hotbar row so it reads as part of the
        // inventory area. Red box + 🗑 glyph; it lights up while a stack is held
        // so kids see exactly where to drop. Record its rect for hit-testing.
        let hotRow = rects[0]                            // hotbar's first slot
        let trash = NSRect(x: rects[8].maxX + 18, y: hotRow.minY,
                           width: hotRow.width, height: hotRow.height)
        trashRect = trash
        let holding = (heldSlot != nil)
        let trashHover = mouseInside && holding && trash.contains(mousePos)
        (trashHover ? NSColor.systemRed.withAlphaComponent(0.55)
                    : NSColor.systemRed.withAlphaComponent(holding ? 0.32 : 0.18)).setFill()
        let trr = NSBezierPath(roundedRect: trash, xRadius: 6, yRadius: 6); trr.fill()
        NSColor.systemRed.withAlphaComponent(holding ? 0.95 : 0.55).setStroke()
        trr.lineWidth = trashHover ? 3 : (holding ? 2 : 1.5); trr.stroke()
        let trashGlyph = "🗑"
        let tgAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24),
        ]
        let tgSz = (trashGlyph as NSString).size(withAttributes: tgAttrs)
        (trashGlyph as NSString).draw(at: NSPoint(x: trash.midX - tgSz.width / 2,
                                                  y: trash.midY - tgSz.height / 2),
                                      withAttributes: tgAttrs)
        drawText("Trash", at: NSPoint(x: trash.minX, y: trash.minY - 15),
                 size: fs(11), color: NSColor(srgbRed: 1.0, green: 0.55, blue: 0.55, alpha: 1),
                 bold: true)

        // --- #16: Craftable recipes — a SINGLE-column scrollable list BELOW the
        // hotbar. Rows are clipped to a fixed viewport; the mouse wheel scrolls
        // when there are more rows than fit. Each row is a clickable strip:
        // icon + name + "×N", with a number-key badge on recipes 1–9. ---
        let n = Int(hud.craftable_count)
        let hotbarBottom = rects[0].minY
        let bandGap: CGFloat = 20           // gap between hotbar and craft band
        let craftTitleH: CGFloat = 20       // title strip height
        let rowH: CGFloat = 36              // height of each recipe row
        let rowGap: CGFloat = 3             // vertical gap between rows
        let panelPad: CGFloat = 6           // inner padding of the rows viewport

        // Width: leave room on the right for the creative picker panel when it
        // is shown so the two don't overlap. The picker lives on the right edge.
        let pickerActive = (hud.mode == BF_MODE_CREATIVE)
        let craftRightLimit = pickerActive ? (kPickerPanelX(in: b) - 16) : b.maxX
        let craftLeft = originX - 10
        let craftWidth = min(gridW + 20, craftRightLimit - craftLeft)
        let colW = craftWidth - panelPad * 2 - 12   // row width inside viewport (reserve scrollbar)

        // The band spans from just under the hotbar down to a bottom margin.
        let bandBottom: CGFloat = 44        // keep clear of the bottom hint line
        let bandTop = hotbarBottom - bandGap
        let titleY = bandTop - craftTitleH + 2

        // Viewport (the clipped scroll area) sits below the title.
        let viewTop = titleY - 6
        let viewBottom = bandBottom + 4
        let viewH = max(rowH, viewTop - viewBottom)
        let viewport = NSRect(x: craftLeft, y: viewBottom, width: craftWidth, height: viewH)
        craftViewport = viewport

        // Panel background (title + viewport).
        let panel = NSRect(x: craftLeft, y: viewBottom - 2,
                           width: craftWidth, height: (titleY + craftTitleH) - (viewBottom - 2))
        NSColor.black.withAlphaComponent(0.38).setFill()
        let panelPath = NSBezierPath(roundedRect: panel, xRadius: 8, yRadius: 8)
        panelPath.fill()
        NSColor.systemYellow.withAlphaComponent(0.35).setStroke()
        panelPath.lineWidth = 1; panelPath.stroke()

        // Title strip.
        drawText(n == 0 ? "Nothing craftable yet — gather wood and stone!"
                        : "Crafting  (click a row to craft  •  1–9 = number key)",
                 at: NSPoint(x: originX, y: titleY), size: fs(12), color: .systemYellow, bold: true)

        // Total content height & scroll clamp. Top row sits at the top of the
        // viewport; subsequent rows below it. scroll moves the content UP.
        let contentH = CGFloat(n) * (rowH + rowGap) - (n > 0 ? rowGap : 0)
        maxCraftScroll = max(0, contentH - viewH)
        craftScroll = min(max(0, craftScroll), maxCraftScroll)

        // Draw visible rows clipped to the viewport. Rebuild craftRects +
        // craftRowIndex each frame so hit-testing matches exactly what we paint.
        var crafts = [NSRect]()
        var craftIdx = [Int]()
        clipped(to: [NSPoint(x: viewport.minX, y: viewport.minY),
                     NSPoint(x: viewport.maxX, y: viewport.minY),
                     NSPoint(x: viewport.maxX, y: viewport.maxY),
                     NSPoint(x: viewport.minX, y: viewport.maxY)]) {
            withUnsafeBytes(of: hud.craftable) { raw in
                let cr = raw.bindMemory(to: bf_hud_slot.self)
                let rx = viewport.minX + panelPad
                for i in 0..<n {
                    // Row i's top within content; map to view coords (non-flipped:
                    // +y up). Row 0 top aligns with viewport top + craftScroll.
                    let ry = viewport.maxY - rowH - CGFloat(i) * (rowH + rowGap) + craftScroll
                    let rowRect = NSRect(x: rx, y: ry, width: colW, height: rowH)
                    // Skip rows fully outside the viewport (cheap cull).
                    if rowRect.maxY < viewport.minY || rowRect.minY > viewport.maxY { continue }
                    crafts.append(rowRect); craftIdx.append(i)
                    let s = cr[i]
                    let hovered = mouseInside && heldSlot == nil
                        && rowRect.contains(mousePos) && viewport.contains(mousePos)
                    drawCraftRow(rowRect, slot: s, recipeIndex: i, colW: colW, hovered: hovered)
                }
            }
        }
        craftRects = crafts
        craftRowIndex = craftIdx

        // Scrollbar indicator on the right edge of the viewport.
        if maxCraftScroll > 0 {
            drawScrollbar(in: viewport, contentH: contentH, scroll: craftScroll)
        }

        // #15: Creative item picker panel (right side), scrollable. Only built in
        // creative mode; sets pickerRects/pickerItemIds (empty otherwise).
        if pickerActive {
            drawCreativePicker(in: b)
        } else {
            pickerRects = []; pickerItemIds = []
            pickerViewport = .zero; maxPickerScroll = 0
        }

        // Bottom hint — sits at the very bottom of the screen.
        drawText("Esc / E to close   •   click a stack to pick it up, click a slot to place it",
                 at: NSPoint(x: originX, y: 18), size: fs(12), color: .white, bold: false)

        // --- Hover tooltips (only when not carrying a stack, so the tooltip
        //     doesn't fight the ghost). A craftable row under the cursor takes
        //     priority and shows what the recipe makes + its number key. ---
        if mouseInside && heldSlot == nil {
            if let pid = pickerItemId(at: mousePos) {
                drawTooltip(name: itemName(pid), count: 1, itemId: pid,
                            hint: "click to get", near: mousePos)
            } else if let c = craftIndex(at: mousePos) {
                let s = craftableSlot(c)
                if s.item != 0 {
                    let keyHint = c < 9 ? "press \(c + 1)" : nil
                    drawTooltip(name: itemName(s.item), count: s.count, itemId: s.item,
                                hint: keyHint, near: mousePos)
                }
            } else if let i = slotIndex(at: mousePos) {
                let s = inventorySlot(i)
                if s.item != 0 {
                    drawTooltip(name: itemName(s.item), count: s.count, itemId: s.item, near: mousePos)
                }
            }
        }

        // --- #34: Trash hint. Shown whenever the cursor is over the trash slot,
        //     even while carrying a stack (that's exactly when it's actionable).
        if mouseInside && trashRect.contains(mousePos) {
            let hint = (heldSlot != nil) ? "🗑 Drop here to delete"
                                         : "🗑 Pick up a stack, then drop it here to delete"
            drawTooltip(name: hint, count: 1, near: mousePos)
        }

        // --- Picked-up stack ghost following the cursor. ---
        if heldSlot != nil && heldItem != 0 {
            let g = NSRect(x: mousePos.x - 18, y: mousePos.y - 18, width: 36, height: 36)
            drawCenteredItem(id: heldItem, count: heldCount, in: g, selected: false)
        }
    }

    private func inventorySlot(_ i: Int) -> bf_hud_slot {
        guard i >= 0 && i < 36 else { return bf_hud_slot() }
        return withUnsafeBytes(of: hud.inventory) { raw in
            raw.bindMemory(to: bf_hud_slot.self)[i]
        }
    }

    private func slotIndex(at p: NSPoint) -> Int? {
        for (i, r) in slotRects.enumerated() where r.contains(p) { return i }
        return nil
    }

    // Read a craftable recipe's result slot (item + count). Bounds-checked
    // against the live craftable_count so a stale rect can never read past the
    // valid recipes. Array is now 24 entries (ABI v8).
    private func craftableSlot(_ i: Int) -> bf_hud_slot {
        guard i >= 0 && i < Int(hud.craftable_count) && i < 24 else { return bf_hud_slot() }
        return withUnsafeBytes(of: hud.craftable) { raw in
            raw.bindMemory(to: bf_hud_slot.self)[i]
        }
    }

    // Craftable recipe index under a point, hit-tested against craftRects (which
    // is rebuilt every draw to mirror exactly what we painted). craftRects holds
    // only the visible (scrolled) rows, so we map the matched rect position back
    // to its true recipe index via craftRowIndex. Clicks outside the scroll
    // viewport are rejected so a row peeking past the clip can't be clicked.
    private func craftIndex(at p: NSPoint) -> Int? {
        guard craftViewport.contains(p) else { return nil }
        for (k, r) in craftRects.enumerated() where r.contains(p) {
            return k < craftRowIndex.count ? craftRowIndex[k] : nil
        }
        return nil
    }

    // ===== #16 helpers: craft row + scrollbar ==============================

    // Draw a single craft recipe row strip. Pulled out of drawInventory so the
    // scrolled list and any future layout reuse the same visuals.
    private func drawCraftRow(_ rowRect: NSRect, slot s: bf_hud_slot,
                              recipeIndex i: Int, colW: CGFloat, hovered: Bool) {
        let rx = rowRect.minX, ry = rowRect.minY, rowH = rowRect.height
        (hovered ? NSColor.systemYellow.withAlphaComponent(0.22)
                 : NSColor.black.withAlphaComponent(0.45)).setFill()
        let rr = NSBezierPath(roundedRect: rowRect, xRadius: 5, yRadius: 5); rr.fill()
        NSColor.systemYellow.withAlphaComponent(hovered ? 0.90 : 0.40).setStroke()
        rr.lineWidth = hovered ? 2 : 1; rr.stroke()

        // Icon on the left.
        let iconSize: CGFloat = rowH - 6
        let iconRect = NSRect(x: rx + 4, y: ry + (rowH - iconSize) / 2,
                              width: iconSize, height: iconSize)
        if s.item != 0 {
            drawCenteredItem(id: s.item, count: s.count, in: iconRect, selected: false)
        }
        // Number-key badge (1–9) on first 9 rows.
        if i < 9 {
            let badge = NSRect(x: rx + 2, y: ry + rowH - 15, width: 14, height: 14)
            NSColor.black.withAlphaComponent(0.70).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            drawText("\(i + 1)", at: NSPoint(x: rx + 4, y: ry + rowH - 15),
                     size: 11, color: .systemYellow, bold: true)
        }
        // Name + count to the right of the icon.
        if s.item != 0 {
            let textX = rx + iconSize + 8
            let textW = colW - iconSize - 12
            let nameStr = itemName(s.item)
            let countStr = "×\(s.count)"
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fs(12)), .foregroundColor: NSColor.white,
            ]
            let cntAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fs(11)),
                .foregroundColor: NSColor.white.withAlphaComponent(0.75),
            ]
            let nameSz = (nameStr as NSString).size(withAttributes: nameAttrs)
            let cntSz  = (countStr as NSString).size(withAttributes: cntAttrs)
            let totalTextH = nameSz.height + cntSz.height + 1
            let textY = ry + (rowH - totalTextH) / 2
            let displayName = truncated(nameStr, to: textW, attrs: nameAttrs)
            (displayName as NSString).draw(at: NSPoint(x: textX, y: textY + cntSz.height + 1),
                                           withAttributes: nameAttrs)
            (countStr as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: cntAttrs)
        }
    }

    // Truncate a string with an ellipsis so it fits maxW at the given attrs.
    private func truncated(_ s: String, to maxW: CGFloat,
                           attrs: [NSAttributedString.Key: Any]) -> String {
        if (s as NSString).size(withAttributes: attrs).width <= maxW { return s }
        var t = s
        while !t.isEmpty &&
              ((t + "…") as NSString).size(withAttributes: attrs).width > maxW {
            t = String(t.dropLast())
        }
        return t + "…"
    }

    // Subtle scrollbar on the right edge of a viewport. contentH is the full
    // (unclipped) content height; scroll is the current offset in [0, max].
    private func drawScrollbar(in viewport: NSRect, contentH: CGFloat, scroll: CGFloat) {
        guard contentH > viewport.height else { return }
        let trackW: CGFloat = 4
        let track = NSRect(x: viewport.maxX - trackW - 2, y: viewport.minY + 2,
                           width: trackW, height: viewport.height - 4)
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let frac = viewport.height / contentH                 // visible fraction
        let thumbH = max(16, track.height * frac)
        let maxScroll = max(1, contentH - viewport.height)
        // scroll=0 → thumb at top (non-flipped: top = high y).
        let t = scroll / maxScroll
        let thumbY = track.maxY - thumbH - t * (track.height - thumbH)
        let thumb = NSRect(x: track.minX, y: thumbY, width: trackW, height: thumbH)
        NSColor.systemYellow.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 2, yRadius: 2).fill()
    }

    // ===== #15 helpers: creative item picker ==============================

    // Left edge X of the creative picker panel for a given view bounds. Used both
    // to draw it and to keep the craft list from overlapping it.
    private func kPickerPanelX(in b: NSRect) -> CGFloat {
        let panelW: CGFloat = 196
        return b.maxX - panelW - 14
    }

    // Draw the "Creative Items" panel: a scrollable grid of every known item.
    // Clicking an icon calls onGiveItem. Rebuilds pickerRects/pickerItemIds each
    // frame so hit-testing matches the scrolled layout exactly.
    private func drawCreativePicker(in b: NSRect) {
        let panelW: CGFloat = 196
        let panelX = b.maxX - panelW - 14
        let titleH: CGFloat = 22
        let panelTop = b.maxY - 100        // below the mode/weather/biome badges
        let panelBottom: CGFloat = 44
        let panel = NSRect(x: panelX, y: panelBottom, width: panelW,
                           height: panelTop - panelBottom)

        NSColor.black.withAlphaComponent(0.55).setFill()
        let pp = NSBezierPath(roundedRect: panel, xRadius: 10, yRadius: 10); pp.fill()
        NSColor.systemTeal.withAlphaComponent(0.55).setStroke()
        pp.lineWidth = 1.5; pp.stroke()

        drawText("Creative Items", at: NSPoint(x: panel.minX + 12, y: panel.maxY - titleH),
                 size: fs(14), color: .systemTeal, bold: true)
        drawText("click to get one", at: NSPoint(x: panel.minX + 12, y: panel.maxY - titleH - 15),
                 size: fs(10), color: NSColor.white.withAlphaComponent(0.7), bold: false)

        // Grid geometry inside the panel.
        let pad: CGFloat = 10
        let cell: CGFloat = 40, cgap: CGFloat = 6
        let cols = Swift.max(1, Int((panelW - pad * 2 + cgap) / (cell + cgap)))
        let viewTop = panel.maxY - titleH - 24
        let viewBottom = panel.minY + 8
        let viewport = NSRect(x: panel.minX + pad, y: viewBottom,
                              width: panelW - pad * 2, height: Swift.max(cell, viewTop - viewBottom))
        pickerViewport = viewport

        let ids = HUDView.kAllItemIds
        let rows = Int(ceil(Double(ids.count) / Double(cols)))
        let contentH = CGFloat(rows) * (cell + cgap) - (rows > 0 ? cgap : 0)
        maxPickerScroll = Swift.max(0, contentH - viewport.height)
        pickerScroll = Swift.min(Swift.max(0, pickerScroll), maxPickerScroll)

        var rects = [NSRect](); var outIds = [UInt16]()
        clipped(to: [NSPoint(x: viewport.minX, y: viewport.minY),
                     NSPoint(x: viewport.maxX, y: viewport.minY),
                     NSPoint(x: viewport.maxX, y: viewport.maxY),
                     NSPoint(x: viewport.minX, y: viewport.maxY)]) {
            for (k, id) in ids.enumerated() {
                let row = k / cols, col = k % cols
                let cx = viewport.minX + CGFloat(col) * (cell + cgap)
                // Row 0 at top of viewport (non-flipped: +y up), scroll moves up.
                let cy = viewport.maxY - cell - CGFloat(row) * (cell + cgap) + pickerScroll
                let cr = NSRect(x: cx, y: cy, width: cell, height: cell)
                if cr.maxY < viewport.minY || cr.minY > viewport.maxY { continue }
                rects.append(cr); outIds.append(id)
                let hovered = mouseInside && heldSlot == nil
                    && cr.contains(mousePos) && viewport.contains(mousePos)
                (hovered ? NSColor.systemTeal.withAlphaComponent(0.30)
                         : NSColor.black.withAlphaComponent(0.45)).setFill()
                let bp = NSBezierPath(roundedRect: cr, xRadius: 5, yRadius: 5); bp.fill()
                NSColor.systemTeal.withAlphaComponent(hovered ? 0.9 : 0.35).setStroke()
                bp.lineWidth = hovered ? 2 : 1; bp.stroke()
                drawCenteredItem(id: id, count: 1, in: cr, selected: false)
            }
        }
        pickerRects = rects
        pickerItemIds = outIds

        if maxPickerScroll > 0 {
            drawScrollbar(in: viewport, contentH: contentH, scroll: pickerScroll)
        }
    }

    // Item id of the picker cell under a point, or nil. Rejects points outside
    // the scroll viewport so a partially-clipped cell can't be clicked.
    private func pickerItemId(at p: NSPoint) -> UInt16? {
        guard pickerViewport.contains(p) else { return nil }
        for (k, r) in pickerRects.enumerated() where r.contains(p) {
            return k < pickerItemIds.count ? pickerItemIds[k] : nil
        }
        return nil
    }

    private func drawTooltip(name: String, count: UInt16, itemId: UInt16 = 0,
                             hint: String? = nil, near p: NSPoint) {
        // Title line: "Wooden Pickaxe ×1  (press 3)". Count always shown for
        // craftable recipes (via hint) but only when >1 for inventory items.
        var titleLine = count > 1 ? "\(name)  ×\(count)" : name
        if let h = hint {
            titleLine = "\(name) ×\(count)  (\(h))"
        }
        // Description line — always shown; looks up the item-specific blurb.
        let desc = itemId != 0 ? itemDescription(id: itemId) : ""

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fs(13)), .foregroundColor: NSColor.white,
        ]
        let descAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fs(11)),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75),
        ]

        // Maximum tooltip width so long descriptions wrap neatly.
        let maxW: CGFloat = 260 * hudScale
        let pad: CGFloat = 7
        let titleSz = (titleLine as NSString).size(withAttributes: titleAttrs)

        // Wrap description: split into lines that fit maxW.
        var descLines: [String] = []
        if !desc.isEmpty {
            // Simple word-wrap: build lines word by word.
            var current = ""
            for word in desc.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
                let test = current.isEmpty ? word : current + " " + word
                let w = (test as NSString).size(withAttributes: descAttrs).width
                if w > maxW - pad * 2 && !current.isEmpty {
                    descLines.append(current)
                    current = word
                } else {
                    current = test
                }
            }
            if !current.isEmpty { descLines.append(current) }
        }

        let lineH: CGFloat = 14 * hudScale
        let totalH = titleSz.height + (descLines.isEmpty ? 0 : CGFloat(descLines.count) * lineH + 4) + pad
        let boxW = min(maxW, max(titleSz.width + pad * 2,
                                 descLines.map { ($0 as NSString).size(withAttributes: descAttrs).width }.max().map { $0 + pad * 2 } ?? 0))

        var box = NSRect(x: p.x + 14, y: p.y + 14, width: boxW, height: totalH)
        // Keep the tooltip on-screen (view isn't flipped: +x right, +y up).
        if box.maxX > bounds.maxX { box.origin.x = p.x - box.width - 6 }
        if box.maxY > bounds.maxY { box.origin.y = p.y - box.height - 6 }
        if box.minX < bounds.minX { box.origin.x = bounds.minX + 4 }
        if box.minY < bounds.minY { box.origin.y = bounds.minY + 4 }

        NSColor.black.withAlphaComponent(0.88).setFill()
        let rr = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5); rr.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke(); rr.lineWidth = 1; rr.stroke()

        // Title at the top of the box.
        let titleY = box.maxY - titleSz.height - pad * 0.5
        (titleLine as NSString).draw(at: NSPoint(x: box.minX + pad, y: titleY), withAttributes: titleAttrs)

        // Description lines below the title.
        if !descLines.isEmpty {
            var dy = titleY - 4
            for line in descLines {
                dy -= lineH
                (line as NSString).draw(at: NSPoint(x: box.minX + pad, y: dy), withAttributes: descAttrs)
            }
        }
    }

    private func shade(_ c: NSColor, _ f: CGFloat) -> NSColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        return NSColor(srgbRed: min(1, s.redComponent * f), green: min(1, s.greenComponent * f),
                       blue: min(1, s.blueComponent * f), alpha: 1)
    }
    private func fillPoly(_ pts: [NSPoint], _ color: NSColor) {
        let p = NSBezierPath(); p.move(to: pts[0])
        for q in pts.dropFirst() { p.line(to: q) }
        p.close(); color.setFill(); p.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke(); p.lineWidth = 0.5; p.stroke()
    }
    private func drawCenteredItem(id: bf_item_id, count: UInt16, in rect: NSRect, selected: Bool) {
        let base = itemChipColor(id)
        let chip = rect.insetBy(dx: 8, dy: 8)
        // #31: A handful of "block" ids are really props/decor, not building
        // cubes — drawing them as an iso cube reads as a meaningless coloured
        // box (the torch was the worst offender). Route those to dedicated
        // silhouettes so they're recognizable at hotbar size. Plain building
        // blocks keep the iso-cube look below. (Falls through to the count badge.)
        switch id {
        case 24: drawTorch(in: chip)                                     // torch — stick + flame
        case 25: drawDoor(in: chip, color: base)                        // wooden door
        case 29: drawFlower(in: chip, petal: itemColor(0.90, 0.28, 0.28)) // red flower
        case 30: drawFlower(in: chip, petal: itemColor(0.97, 0.86, 0.28)) // yellow flower
        case let bid where bid <= 40:
            // Block item → little isometric cube icon with a procedural texture
            // pattern on each visible face, so the material reads at a glance
            // (grass, stone, wood …) instead of three flat shaded diamonds.
            drawTexturedCube(id: id, in: chip, base: base)
        default:
            // Tool / material / food → distinct procedural icon per item, so
            // each is recognizable at a glance (no more uniform chips).
            drawItemIcon(id: id, in: chip, base: base)
        }
        if count > 1 {
            // Badge font tracks the cell size so it stays legible when the HUD
            // (and thus the hotbar/inventory cells) are scaled up.
            let badgeSize = max(10, min(16, rect.height * 0.26))
            drawText("\(count)", at: NSPoint(x: rect.maxX - badgeSize * 1.5, y: rect.minY + 3),
                     size: badgeSize, color: .white, bold: true)
        }
    }

    // ===== #31: prop / decor icons (non-cube blocks) =======================
    // A few placeable ids are props, not building cubes. These cheap silhouettes
    // make them readable at hotbar size instead of generic coloured boxes.

    // Torch (#31 priority): a short brown handle with a layered orange→yellow
    // flame and a soft warm glow, so it reads as a torch even at ~32px.
    private func drawTorch(in r: NSRect) {
        let cx = r.midX
        // Handle: a thick vertical wooden stick in the lower half.
        let handleTop = NSPoint(x: cx, y: r.minY + r.height * 0.56)
        let handleBot = NSPoint(x: cx, y: r.minY + r.height * 0.12)
        let stick = NSBezierPath()
        stick.lineCapStyle = .round
        stick.move(to: handleBot); stick.line(to: handleTop)
        HUDView.kHandleCol.setStroke(); stick.lineWidth = max(2.5, r.width * 0.16); stick.stroke()
        lighten(HUDView.kHandleCol, 0.28).setStroke()
        stick.lineWidth = max(1, r.width * 0.05); stick.stroke()

        // Warm glow halo behind the flame.
        fillCircle(NSPoint(x: cx, y: handleTop.y + r.height * 0.10),
                   r.width * 0.24,
                   NSColor(srgbRed: 1.0, green: 0.78, blue: 0.30, alpha: 0.28),
                   outline: nil)

        // Flame: an outer orange teardrop, an inner yellow core, and a white
        // hot spot — built bottom→tip→bottom so it points up like a real flame.
        func flame(halfW: CGFloat, height: CGFloat, color: NSColor) {
            let baseY = handleTop.y - r.height * 0.02
            let tipY = baseY + height
            let f = NSBezierPath()
            f.move(to: NSPoint(x: cx - halfW, y: baseY))
            f.curve(to: NSPoint(x: cx, y: tipY),
                    controlPoint1: NSPoint(x: cx - halfW, y: baseY + height * 0.55),
                    controlPoint2: NSPoint(x: cx - halfW * 0.35, y: tipY))
            f.curve(to: NSPoint(x: cx + halfW, y: baseY),
                    controlPoint1: NSPoint(x: cx + halfW * 0.35, y: tipY),
                    controlPoint2: NSPoint(x: cx + halfW, y: baseY + height * 0.55))
            f.close()
            color.setFill(); f.fill()
        }
        flame(halfW: r.width * 0.17, height: r.height * 0.42, color: itemColor(0.98, 0.45, 0.10))
        flame(halfW: r.width * 0.11, height: r.height * 0.32, color: itemColor(1.0, 0.80, 0.20))
        flame(halfW: r.width * 0.05, height: r.height * 0.20, color: itemColor(1.0, 0.97, 0.78))
    }

    // Wooden door: a tall panelled rectangle with a knob — clearly a door, not
    // a brown cube. Coloured from the door's chip colour.
    private func drawDoor(in r: NSRect, color: NSColor) {
        let dw = r.width * 0.46
        let panel = NSRect(x: r.midX - dw / 2, y: r.minY + r.height * 0.10,
                           width: dw, height: r.height * 0.80)
        let body = NSBezierPath(roundedRect: panel, xRadius: 2, yRadius: 2)
        color.setFill(); body.fill()
        NSColor.black.withAlphaComponent(0.4).setStroke(); body.lineWidth = 1; body.stroke()
        // Two recessed panels (upper + lower) for a door silhouette.
        let inset = panel.insetBy(dx: panel.width * 0.18, dy: panel.height * 0.10)
        let split = inset.minY + inset.height * 0.5
        for sub in [
            NSRect(x: inset.minX, y: split + 2, width: inset.width, height: inset.height * 0.5 - 4),
            NSRect(x: inset.minX, y: inset.minY, width: inset.width, height: inset.height * 0.5 - 4),
        ] {
            shade(color, 0.78).setFill(); NSBezierPath(rect: sub).fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            let sp = NSBezierPath(rect: sub); sp.lineWidth = 0.8; sp.stroke()
        }
        // Knob near the right edge, mid-height.
        fillCircle(NSPoint(x: panel.maxX - panel.width * 0.16, y: panel.midY),
                   max(1, r.width * 0.05),
                   lighten(NSColor(srgbRed: 0.85, green: 0.72, blue: 0.30, alpha: 1), 0.1))
    }

    // Flower: a green stem, a small leaf, and a ring of petals around a centre.
    // `petal` colours the bloom (red / yellow), so the two flowers read distinctly.
    private func drawFlower(in r: NSRect, petal: NSColor) {
        let cx = r.midX
        let centre = NSPoint(x: cx, y: r.minY + r.height * 0.66)
        // Stem.
        let stem = NSBezierPath(); stem.lineCapStyle = .round
        stem.move(to: NSPoint(x: cx, y: r.minY + r.height * 0.14))
        stem.line(to: NSPoint(x: cx, y: centre.y - r.height * 0.06))
        itemColor(0.30, 0.60, 0.26).setStroke()
        stem.lineWidth = max(1.5, r.width * 0.07); stem.stroke()
        // Leaf off the stem.
        fillCircle(NSPoint(x: cx + r.width * 0.12, y: r.minY + r.height * 0.34),
                   r.width * 0.08, itemColor(0.34, 0.66, 0.30), outline: nil)
        // Petals: 5 around the centre.
        let pr = r.width * 0.12
        for k in 0..<5 {
            let ang = CGFloat(k) / 5.0 * 2 * .pi + .pi / 2
            let p = NSPoint(x: centre.x + cos(ang) * pr * 1.4,
                            y: centre.y + sin(ang) * pr * 1.4)
            fillCircle(p, pr, petal, outline: NSColor.black.withAlphaComponent(0.2))
        }
        // Bright centre.
        fillCircle(centre, pr * 0.7, lighten(petal, 0.55), outline: nil)
    }

    // ===== Textured block cube icons =======================================
    // A small isometric cube (top diamond + left + right faces) with a cheap
    // procedural texture drawn ON each face so the material is recognizable —
    // no block icon is ever a plain flat-coloured diamond. Texture ops are
    // clipped to the exact face polygon via NSBezierPath.addClip inside a
    // save/restore pair, so nothing bleeds outside the cube. Non-flipped: +y UP.

    // Which texture "family" a block id belongs to. Keeps the dispatcher tidy.
    private enum BlockTex {
        case grass, grain, stone, sand, log, planks, leaves, snow, ice
        case bricks, table, chest, glow, plain
    }
    private func blockTexFamily(_ id: bf_item_id) -> BlockTex {
        switch id {
        case 2:              return .grass
        case 1, 6, 9, 11:    return .grain          // dirt / gravel / clay / dim dirt
        case 3, 4, 16, 10, 21: return .stone        // stone / cobble / brick / dim / mossy
        case 5:              return .sand
        case 12, 14:         return .log            // oak / birch log
        case 13, 15:         return .planks         // oak / birch planks
        case 7:              return .snow
        case 8:              return .ice
        case 17:             return .bricks         // clay brick
        case 22:             return .table          // crafting table
        case 23:             return .chest
        case 26, 27, 28, 31: return .glow           // beacon / glow / crystal lamp / crystal
        default:             return .grain          // everything else gets some grain
        }
    }

    // Run `body` with the drawing context clipped to the given polygon. Uses an
    // explicit save/restore so the clip is always balanced (no force-unwrap;
    // NSGraphicsContext.current is optional and we no-op if absent).
    private func clipped(to pts: [NSPoint], _ body: () -> Void) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        let clip = NSBezierPath()
        clip.move(to: pts[0])
        for q in pts.dropFirst() { clip.line(to: q) }
        clip.close()
        clip.addClip()
        body()
        ctx.restoreGraphicsState()
    }

    // A short line segment helper used by several textures.
    private func tick(_ a: NSPoint, _ b: NSPoint, _ color: NSColor, width: CGFloat) {
        let p = NSBezierPath(); p.lineCapStyle = .round
        p.move(to: a); p.line(to: b)
        color.setStroke(); p.lineWidth = width; p.stroke()
    }

    private func drawTexturedCube(id: bf_item_id, in chip: NSRect, base: NSColor) {
        let cx = chip.midX, cy = chip.midY
        let hw = chip.width * 0.46, qh = chip.height * 0.24, bd = chip.height * 0.34
        let topApex   = NSPoint(x: cx,      y: cy + bd*0.5 + qh)
        let rightApex = NSPoint(x: cx + hw, y: cy + bd*0.5)
        let leftApex  = NSPoint(x: cx - hw, y: cy + bd*0.5)
        let ctrTop    = NSPoint(x: cx,      y: cy + bd*0.5 - qh)
        let botLeft   = NSPoint(x: cx - hw, y: cy - bd*0.5)
        let botRight  = NSPoint(x: cx + hw, y: cy - bd*0.5)
        let botCtr    = NSPoint(x: cx,      y: cy - bd*0.5 - qh)

        let leftFace  = [leftApex, ctrTop, botCtr, botLeft]
        let rightFace = [ctrTop, rightApex, botRight, botCtr]
        let topFace   = [topApex, rightApex, ctrTop, leftApex]

        // Base shaded faces (same shading as before; texture draws on top).
        let fam = blockTexFamily(id)
        // Grass uses a dirt-brown body for the sides and a green top.
        let sideBase = (fam == .grass) ? itemColor(0.50, 0.36, 0.23) : base
        fillPoly(leftFace,  shade(sideBase, 0.74))
        fillPoly(rightFace, shade(sideBase, 0.56))
        fillPoly(topFace,   shade(base, 1.15))

        // Texture each face, clipped to its polygon, with the face's own shade so
        // the pattern reads as lit consistently with the underlying fill.
        clipped(to: topFace)   { texture(fam, face: topFace,   shaded: shade(base, 1.15), kind: .top) }
        clipped(to: leftFace)  { texture(fam, face: leftFace,  shaded: shade(sideBase, 0.74), kind: .left) }
        clipped(to: rightFace) { texture(fam, face: rightFace, shaded: shade(sideBase, 0.56), kind: .right) }
    }

    private enum FaceKind { case top, left, right }

    // Bounding box of a face polygon (used to size/iterate texture features).
    private func bbox(_ pts: [NSPoint]) -> NSRect {
        var minX = pts[0].x, maxX = pts[0].x, minY = pts[0].y, maxY = pts[0].y
        for p in pts.dropFirst() {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // Per-family texture painter. `shaded` is the face's base colour; derive
    // lighter/darker speckle colours from it so every face stays self-consistent.
    private func texture(_ fam: BlockTex, face: [NSPoint],
                         shaded: NSColor, kind: FaceKind) {
        let r = bbox(face)
        let dark = shade(shaded, 0.78)
        let light = lighten(shaded, 0.30)
        switch fam {
        case .grass:
            if kind == .top {
                // Green top speckled with short upright blade ticks.
                for o in [CGPoint(x: 0.30, y: 0.45), CGPoint(x: 0.50, y: 0.62),
                          CGPoint(x: 0.62, y: 0.40), CGPoint(x: 0.42, y: 0.30),
                          CGPoint(x: 0.55, y: 0.50), CGPoint(x: 0.38, y: 0.58)] {
                    let p = NSPoint(x: r.minX + r.width * o.x, y: r.minY + r.height * o.y)
                    tick(p, NSPoint(x: p.x, y: p.y + r.height * 0.10),
                         lighten(shaded, 0.45), width: 1)
                }
            } else {
                // Brown dirt side with a green fringe band along the top edge.
                // The outer per-face clip already constrains this to the face.
                let fringeH = r.height * 0.22
                itemColor(0.40, 0.62, 0.30).setFill()
                NSBezierPath(rect: NSRect(x: r.minX, y: r.maxY - fringeH,
                                          width: r.width, height: fringeH)).fill()
                speckle(in: r, count: 5, color: dark, size: r.width * 0.05)
            }
        case .grain:
            speckle(in: r, count: 7, color: dark, size: r.width * 0.05)
            speckle(in: r, count: 4, color: light, size: r.width * 0.04)
        case .stone:
            // Grey mottling + a few darker crack/cell lines (underground look).
            speckle(in: r, count: 6, color: dark, size: r.width * 0.06)
            speckle(in: r, count: 3, color: light, size: r.width * 0.04)
            let cracks: [(CGPoint, CGPoint)] = [
                (CGPoint(x: 0.20, y: 0.30), CGPoint(x: 0.45, y: 0.55)),
                (CGPoint(x: 0.55, y: 0.65), CGPoint(x: 0.78, y: 0.45)),
                (CGPoint(x: 0.40, y: 0.70), CGPoint(x: 0.50, y: 0.40)),
            ]
            for (a, bpt) in cracks {
                tick(NSPoint(x: r.minX + r.width * a.x, y: r.minY + r.height * a.y),
                     NSPoint(x: r.minX + r.width * bpt.x, y: r.minY + r.height * bpt.y),
                     shade(shaded, 0.62), width: 1)
            }
        case .sand:
            // Fine horizontal ripple lines.
            let n = 4
            for i in 1...n {
                let y = r.minY + r.height * CGFloat(i) / CGFloat(n + 1)
                tick(NSPoint(x: r.minX + r.width * 0.10, y: y),
                     NSPoint(x: r.maxX - r.width * 0.10, y: y),
                     dark.withAlphaComponent(0.7), width: 0.8)
            }
        case .log:
            if kind == .top {
                // Concentric rings on the cut end.
                let c = NSPoint(x: r.midX, y: r.midY)
                for f in [0.62, 0.40, 0.20] {
                    let rad = r.width * 0.5 * CGFloat(f)
                    let rect = NSRect(x: c.x - rad, y: c.y - rad * 0.6,
                                      width: rad * 2, height: rad * 1.2)
                    let p = NSBezierPath(ovalIn: rect)
                    dark.setStroke(); p.lineWidth = 1; p.stroke()
                }
            } else {
                // Vertical grain lines along the bark side.
                for fx in [0.30, 0.50, 0.70] {
                    let x = r.minX + r.width * CGFloat(fx)
                    tick(NSPoint(x: x, y: r.minY + r.height * 0.08),
                         NSPoint(x: x, y: r.maxY - r.height * 0.08),
                         dark, width: 1)
                }
            }
        case .planks:
            // Plank seam lines: horizontal boards on the top, with end nicks.
            let n = 3
            for i in 1...n {
                let y = r.minY + r.height * CGFloat(i) / CGFloat(n + 1)
                tick(NSPoint(x: r.minX + r.width * 0.08, y: y),
                     NSPoint(x: r.maxX - r.width * 0.08, y: y),
                     dark, width: 1)
            }
        case .leaves:
            for o in [CGPoint(x: 0.30, y: 0.40), CGPoint(x: 0.55, y: 0.55),
                      CGPoint(x: 0.45, y: 0.30), CGPoint(x: 0.65, y: 0.42)] {
                fillCircle(NSPoint(x: r.minX + r.width * o.x, y: r.minY + r.height * o.y),
                           r.width * 0.08, light, outline: nil)
            }
            speckle(in: r, count: 4, color: dark, size: r.width * 0.05)
        case .snow:
            // White with a few sparkle dots.
            speckle(in: r, count: 4, color: .white, size: r.width * 0.05)
            for o in [CGPoint(x: 0.35, y: 0.55), CGPoint(x: 0.60, y: 0.40)] {
                drawSparkle(at: NSPoint(x: r.minX + r.width * o.x, y: r.minY + r.height * o.y),
                            s: r.width * 0.07, color: .white)
            }
        case .ice:
            // Pale blue with thin crack-like facet lines.
            let cracks: [(CGPoint, CGPoint)] = [
                (CGPoint(x: 0.25, y: 0.30), CGPoint(x: 0.55, y: 0.65)),
                (CGPoint(x: 0.50, y: 0.35), CGPoint(x: 0.75, y: 0.55)),
            ]
            for (a, bpt) in cracks {
                tick(NSPoint(x: r.minX + r.width * a.x, y: r.minY + r.height * a.y),
                     NSPoint(x: r.minX + r.width * bpt.x, y: r.minY + r.height * bpt.y),
                     lighten(shaded, 0.55), width: 0.8)
            }
        case .bricks:
            // Offset brick courses: horizontal mortar lines + staggered verticals.
            let rows = 3
            for i in 1...rows {
                let y = r.minY + r.height * CGFloat(i) / CGFloat(rows + 1)
                tick(NSPoint(x: r.minX, y: y), NSPoint(x: r.maxX, y: y), dark, width: 0.9)
            }
            for i in 0..<rows {
                let y0 = r.minY + r.height * CGFloat(i) / CGFloat(rows + 1)
                let y1 = r.minY + r.height * CGFloat(i + 1) / CGFloat(rows + 1)
                let xoff: CGFloat = (i % 2 == 0) ? 0.34 : 0.66
                let x = r.minX + r.width * xoff
                tick(NSPoint(x: x, y: y0), NSPoint(x: x, y: y1), dark, width: 0.9)
            }
        case .table:
            if kind == .top {
                // Grid lines on the top (a 2x2 work surface).
                tick(NSPoint(x: r.midX, y: r.minY + r.height * 0.10),
                     NSPoint(x: r.midX, y: r.maxY - r.height * 0.10), dark, width: 1)
                tick(NSPoint(x: r.minX + r.width * 0.12, y: r.midY),
                     NSPoint(x: r.maxX - r.width * 0.12, y: r.midY), dark, width: 1)
            } else {
                for fx in [0.40, 0.60] {
                    let x = r.minX + r.width * CGFloat(fx)
                    tick(NSPoint(x: x, y: r.minY + r.height * 0.10),
                         NSPoint(x: x, y: r.maxY - r.height * 0.10), dark, width: 1)
                }
            }
        case .chest:
            if kind == .top {
                speckle(in: r, count: 3, color: dark, size: r.width * 0.05)
            } else {
                // Lid seam across the upper third + a small latch in the centre.
                let seamY = r.minY + r.height * 0.62
                tick(NSPoint(x: r.minX, y: seamY), NSPoint(x: r.maxX, y: seamY), dark, width: 1.2)
                let latch = NSRect(x: r.midX - r.width * 0.07, y: seamY - r.height * 0.10,
                                   width: r.width * 0.14, height: r.height * 0.18)
                shade(shaded, 0.55).setFill(); NSBezierPath(rect: latch).fill()
            }
        case .glow:
            // Bright with a sparkle/facet motif (lamp / crystal / beacon / glow).
            fillCircle(NSPoint(x: r.midX, y: r.midY), r.width * 0.16,
                       lighten(shaded, 0.6).withAlphaComponent(0.7), outline: nil)
            drawSparkle(at: NSPoint(x: r.midX, y: r.midY), s: r.width * 0.16, color: .white)
            for o in [CGPoint(x: 0.30, y: 0.40), CGPoint(x: 0.65, y: 0.55)] {
                drawSparkle(at: NSPoint(x: r.minX + r.width * o.x, y: r.minY + r.height * o.y),
                            s: r.width * 0.07, color: .white)
            }
        case .plain:
            speckle(in: r, count: 5, color: dark, size: r.width * 0.05)
        }
    }

    // Deterministic speckle: a fixed scatter of small dots inside a rect. Cheap
    // and stable frame-to-frame (no RNG), readable at ~40px.
    private func speckle(in r: NSRect, count: Int, color: NSColor, size: CGFloat) {
        // A fixed low-discrepancy-ish set of offsets in [0,1]^2.
        let pts: [CGPoint] = [
            CGPoint(x: 0.22, y: 0.34), CGPoint(x: 0.58, y: 0.24), CGPoint(x: 0.40, y: 0.52),
            CGPoint(x: 0.70, y: 0.46), CGPoint(x: 0.30, y: 0.66), CGPoint(x: 0.62, y: 0.64),
            CGPoint(x: 0.48, y: 0.38), CGPoint(x: 0.35, y: 0.45), CGPoint(x: 0.55, y: 0.58),
        ]
        for i in 0..<Swift.min(count, pts.count) {
            let o = pts[i]
            fillCircle(NSPoint(x: r.minX + r.width * o.x, y: r.minY + r.height * o.y),
                       size, color, outline: nil)
        }
    }

    // ===== Procedural item icons ============================================
    // Each item id (50..93) maps to a small recognizable silhouette drawn with
    // Core Graphics / NSBezierPath — no art assets. Helpers stay cheap (a few
    // bezier ops) because these draw several times per frame. The view is
    // non-flipped, so +y is UP throughout.

    // Tier tints for the 9 tools (head colour by material; handle is wood).
    private static let kWoodTint  = NSColor(srgbRed: 0.62, green: 0.45, blue: 0.26, alpha: 1)
    private static let kStoneTint = NSColor(srgbRed: 0.58, green: 0.58, blue: 0.60, alpha: 1)
    private static let kIronTint  = NSColor(srgbRed: 0.86, green: 0.87, blue: 0.90, alpha: 1)
    private static let kHandleCol = NSColor(srgbRed: 0.50, green: 0.34, blue: 0.18, alpha: 1)

    private func toolTint(_ id: bf_item_id) -> NSColor {
        switch id {
        case 70, 71, 72, 79: return HUDView.kWoodTint
        case 73, 74, 75, 80: return HUDView.kStoneTint
        case 76, 77, 78, 81: return HUDView.kIronTint
        default:              return HUDView.kStoneTint
        }
    }

    // Lighten toward white by fraction f (0 = unchanged, 1 = white).
    private func lighten(_ c: NSColor, _ f: CGFloat) -> NSColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        let g = max(0, min(1, f))
        return NSColor(srgbRed: s.redComponent + (1 - s.redComponent) * g,
                       green: s.greenComponent + (1 - s.greenComponent) * g,
                       blue:  s.blueComponent + (1 - s.blueComponent) * g, alpha: 1)
    }

    private func strokePoly(_ pts: [NSPoint], _ fill: NSColor,
                            outline: NSColor = NSColor.black.withAlphaComponent(0.45),
                            width: CGFloat = 1) {
        guard pts.count >= 2 else { return }
        let p = NSBezierPath(); p.move(to: pts[0])
        for q in pts.dropFirst() { p.line(to: q) }
        p.close()
        fill.setFill(); p.fill()
        outline.setStroke(); p.lineWidth = width; p.stroke()
    }

    private func fillCircle(_ center: NSPoint, _ r: CGFloat, _ fill: NSColor,
                            outline: NSColor? = NSColor.black.withAlphaComponent(0.4),
                            width: CGFloat = 1) {
        let rect = NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        let p = NSBezierPath(ovalIn: rect)
        fill.setFill(); p.fill()
        if let o = outline { o.setStroke(); p.lineWidth = width; p.stroke() }
    }

    // Dispatch an id (50..93) to its dedicated icon helper.
    private func drawItemIcon(id: bf_item_id, in r: NSRect, base: NSColor) {
        switch id {
        // --- Tools: shape by type, head colour by tier ---
        case 70, 73, 76: drawPickaxe(in: r, tint: toolTint(id))
        case 71, 74, 77: drawAxe(in: r, tint: toolTint(id))
        case 72, 75, 78: drawShovel(in: r, tint: toolTint(id))
        // --- Swords ---
        case 79, 80, 81: drawSword(in: r, tint: toolTint(id))
        // --- Materials ---
        case 50: drawStick(in: r)
        case 51: drawLumpCluster(in: r, color: base)            // coal
        case 52, 53, 54: drawOreNugget(in: r, color: base)      // raw ores
        case 55, 56: drawIngot(in: r, color: base)              // ingots
        case 57: drawGem(in: r, color: base)                    // crystal shard
        case 58: drawBlob(in: r, color: base)                   // clay lump
        case 59: drawCoil(in: r, color: base)                   // string fiber
        case 60: drawFeather(in: r, color: base)                // feather
        case 61, 62: drawDustPile(in: r, color: base)           // dusts
        case 63: drawBook(in: r, color: base)                   // blank book
        // --- Food ---
        case 90: drawBerryCluster(in: r, color: base)
        case 91: drawStewBowl(in: r, color: base)
        case 92: drawCakeSlice(in: r, color: base)
        case 93: drawMushroom(in: r, color: base)
        default: drawBlob(in: r, color: base)                   // graceful fallback
        }
    }

    // ----- Tools -----------------------------------------------------------
    // Shared: a diagonal wooden handle running lower-left → upper-right.
    private func drawHandle(in r: NSRect, from a: NSPoint, to b: NSPoint, thickness: CGFloat) {
        let p = NSBezierPath()
        p.lineCapStyle = .round
        p.move(to: a); p.line(to: b)
        HUDView.kHandleCol.setStroke(); p.lineWidth = thickness; p.stroke()
        // subtle highlight along the handle
        lighten(HUDView.kHandleCol, 0.25).setStroke(); p.lineWidth = max(1, thickness * 0.4); p.stroke()
    }

    private func drawPickaxe(in r: NSRect, tint: NSColor) {
        let handleA = NSPoint(x: r.minX + r.width * 0.30, y: r.minY + r.height * 0.18)
        let handleB = NSPoint(x: r.maxX - r.width * 0.18, y: r.maxY - r.height * 0.22)
        drawHandle(in: r, from: handleA, to: handleB, thickness: max(2, r.width * 0.13))
        // Curved double-pointed head across the top, centred over the handle top.
        let hx = handleB.x, hy = handleB.y
        let span = r.width * 0.42
        let p = NSBezierPath()
        p.lineCapStyle = .round; p.lineJoinStyle = .round
        p.move(to: NSPoint(x: hx - span, y: hy + r.height * 0.02))
        p.curve(to: NSPoint(x: hx + span, y: hy + r.height * 0.02),
                controlPoint1: NSPoint(x: hx - span * 0.3, y: hy + r.height * 0.30),
                controlPoint2: NSPoint(x: hx + span * 0.3, y: hy + r.height * 0.30))
        tint.setStroke(); p.lineWidth = max(2.5, r.width * 0.16); p.stroke()
        // tip accents
        fillCircle(NSPoint(x: hx - span, y: hy + r.height * 0.02), max(1, r.width * 0.05), lighten(tint, 0.2))
        fillCircle(NSPoint(x: hx + span, y: hy + r.height * 0.02), max(1, r.width * 0.05), lighten(tint, 0.2))
    }

    private func drawAxe(in r: NSRect, tint: NSColor) {
        let handleA = NSPoint(x: r.minX + r.width * 0.30, y: r.minY + r.height * 0.16)
        let handleB = NSPoint(x: r.maxX - r.width * 0.26, y: r.maxY - r.height * 0.18)
        drawHandle(in: r, from: handleA, to: handleB, thickness: max(2, r.width * 0.13))
        // Wedge blade on the upper-right side of the handle head.
        let hx = handleB.x, hy = handleB.y
        let blade = [
            NSPoint(x: hx - r.width * 0.04, y: hy + r.height * 0.06),
            NSPoint(x: hx + r.width * 0.30, y: hy + r.height * 0.18),
            NSPoint(x: hx + r.width * 0.34, y: hy - r.height * 0.04),
            NSPoint(x: hx + r.width * 0.16, y: hy - r.height * 0.20),
            NSPoint(x: hx - r.width * 0.02, y: hy - r.height * 0.12),
        ]
        strokePoly(blade, tint, width: 1)
        // cutting-edge highlight
        let edge = NSBezierPath()
        edge.move(to: blade[1]); edge.line(to: blade[2])
        lighten(tint, 0.45).setStroke(); edge.lineWidth = max(1, r.width * 0.06); edge.stroke()
    }

    private func drawShovel(in r: NSRect, tint: NSColor) {
        let handleA = NSPoint(x: r.minX + r.width * 0.24, y: r.minY + r.height * 0.30)
        let handleB = NSPoint(x: r.maxX - r.width * 0.22, y: r.maxY - r.height * 0.16)
        drawHandle(in: r, from: handleA, to: handleB, thickness: max(2, r.width * 0.13))
        // Spade/scoop at the bottom (lower-left) end of the handle.
        let sx = handleA.x, sy = handleA.y
        let w = r.width * 0.20, h = r.height * 0.22
        let scoop = NSBezierPath()
        scoop.lineJoinStyle = .round
        scoop.move(to: NSPoint(x: sx - w, y: sy + h * 0.2))
        scoop.line(to: NSPoint(x: sx + w, y: sy + h * 0.2))
        scoop.line(to: NSPoint(x: sx + w * 0.7, y: sy - h))
        // rounded tip
        scoop.curve(to: NSPoint(x: sx - w * 0.7, y: sy - h),
                    controlPoint1: NSPoint(x: sx + w * 0.2, y: sy - h * 1.5),
                    controlPoint2: NSPoint(x: sx - w * 0.2, y: sy - h * 1.5))
        scoop.close()
        tint.setFill(); scoop.fill()
        NSColor.black.withAlphaComponent(0.45).setStroke(); scoop.lineWidth = 1; scoop.stroke()
    }

    private func drawSword(in r: NSRect, tint: NSColor) {
        // A classic sword icon: diagonal handle lower-left → upper-right, blade
        // widens into a flat tip, with a crossguard at the grip/blade junction.
        let handleA = NSPoint(x: r.minX + r.width * 0.18, y: r.minY + r.height * 0.14)
        let handleB = NSPoint(x: r.midX - r.width * 0.04, y: r.midY - r.height * 0.06)
        drawHandle(in: r, from: handleA, to: handleB, thickness: max(2, r.width * 0.12))

        // Blade: runs from the crossguard area to the tip (upper-right).
        let bladeBase = NSPoint(x: r.midX + r.width * 0.00, y: r.midY + r.height * 0.01)
        let bladeTip  = NSPoint(x: r.maxX - r.width * 0.16, y: r.maxY - r.height * 0.18)
        let bw = r.width * 0.07     // half-width of the blade at the base
        let perp = NSPoint(x: -(bladeTip.y - bladeBase.y), y: bladeTip.x - bladeBase.x)
        let perpLen = sqrt(perp.x * perp.x + perp.y * perp.y)
        let pn = perpLen > 0 ? NSPoint(x: perp.x / perpLen, y: perp.y / perpLen) : NSPoint(x: 0, y: 1)
        let bladeShape = [
            NSPoint(x: bladeBase.x + pn.x * bw, y: bladeBase.y + pn.y * bw),
            NSPoint(x: bladeBase.x - pn.x * bw, y: bladeBase.y - pn.y * bw),
            bladeTip,
        ]
        strokePoly(bladeShape, tint, width: 1)
        // Edge highlight along the upper face of the blade.
        let edgePath = NSBezierPath()
        edgePath.move(to: NSPoint(x: bladeBase.x + pn.x * bw, y: bladeBase.y + pn.y * bw))
        edgePath.line(to: bladeTip)
        lighten(tint, 0.50).setStroke(); edgePath.lineWidth = max(1, r.width * 0.05); edgePath.stroke()

        // Crossguard: a short perpendicular bar at the blade/handle junction.
        let cgCenter = NSPoint(x: (bladeBase.x + handleB.x) / 2, y: (bladeBase.y + handleB.y) / 2)
        let cgLen = r.width * 0.24
        let cgPath = NSBezierPath(); cgPath.lineCapStyle = .round
        cgPath.move(to: NSPoint(x: cgCenter.x - pn.x * cgLen, y: cgCenter.y - pn.y * cgLen))
        cgPath.line(to: NSPoint(x: cgCenter.x + pn.x * cgLen, y: cgCenter.y + pn.y * cgLen))
        shade(tint, 0.75).setStroke(); cgPath.lineWidth = max(2, r.width * 0.10); cgPath.stroke()
    }

    // ----- Materials -------------------------------------------------------
    private func drawStick(in r: NSRect) {
        let p = NSBezierPath()
        p.lineCapStyle = .round
        p.move(to: NSPoint(x: r.minX + r.width * 0.30, y: r.minY + r.height * 0.20))
        p.line(to: NSPoint(x: r.maxX - r.width * 0.30, y: r.maxY - r.height * 0.20))
        HUDView.kHandleCol.setStroke(); p.lineWidth = max(2, r.width * 0.16); p.stroke()
        lighten(HUDView.kHandleCol, 0.3).setStroke(); p.lineWidth = max(1, r.width * 0.06); p.stroke()
    }

    private func drawLumpCluster(in r: NSRect, color: NSColor) {
        // A few overlapping dark lumps (coal). Deterministic placement.
        let cx = r.midX, cy = r.midY
        let rr = r.width * 0.22
        let offs = [CGSize(width: -0.18, height: -0.10), CGSize(width: 0.16, height: -0.14),
                    CGSize(width: 0.02, height: 0.16), CGSize(width: -0.05, height: -0.02)]
        for (i, o) in offs.enumerated() {
            let c = NSPoint(x: cx + r.width * o.width, y: cy + r.height * o.height)
            fillCircle(c, rr, shade(color, i == 3 ? 1.25 : (0.85 + CGFloat(i) * 0.1)))
        }
    }

    private func drawOreNugget(in r: NSRect, color: NSColor) {
        // Rough faceted nugget: an irregular polygon in the ore colour.
        let cx = r.midX, cy = r.midY
        let w = r.width * 0.34, h = r.height * 0.32
        let pts = [
            NSPoint(x: cx - w,        y: cy - h * 0.2),
            NSPoint(x: cx - w * 0.4,  y: cy + h),
            NSPoint(x: cx + w * 0.6,  y: cy + h * 0.7),
            NSPoint(x: cx + w,        y: cy - h * 0.3),
            NSPoint(x: cx + w * 0.2,  y: cy - h),
            NSPoint(x: cx - w * 0.6,  y: cy - h * 0.8),
        ]
        strokePoly(pts, color, width: 1)
        // a couple of bright facet flecks
        fillCircle(NSPoint(x: cx - w * 0.2, y: cy + h * 0.1), max(1, r.width * 0.06), lighten(color, 0.45), outline: nil)
        fillCircle(NSPoint(x: cx + w * 0.4, y: cy - h * 0.2), max(1, r.width * 0.045), lighten(color, 0.55), outline: nil)
    }

    private func drawIngot(in r: NSRect, color: NSColor) {
        // Trapezoid bar (wider at the bottom), with a lighter top face.
        let cx = r.midX, cy = r.midY
        let bw = r.width * 0.40, tw = r.width * 0.28
        let h = r.height * 0.20
        let body = [
            NSPoint(x: cx - bw, y: cy - h),
            NSPoint(x: cx + bw, y: cy - h),
            NSPoint(x: cx + tw, y: cy + h),
            NSPoint(x: cx - tw, y: cy + h),
        ]
        strokePoly(body, color, width: 1)
        // top face highlight (thin parallelogram on top edge)
        let top = [
            NSPoint(x: cx - tw,         y: cy + h),
            NSPoint(x: cx + tw,         y: cy + h),
            NSPoint(x: cx + tw * 0.7,   y: cy + h * 1.7),
            NSPoint(x: cx - tw * 0.7,   y: cy + h * 1.7),
        ]
        strokePoly(top, lighten(color, 0.35), outline: NSColor.black.withAlphaComponent(0.25))
    }

    private func drawGem(in r: NSRect, color: NSColor) {
        // Faceted gem: top crown + pointed pavilion, with a centre facet line.
        let cx = r.midX, cy = r.midY
        let w = r.width * 0.30, top = r.height * 0.26, bot = r.height * 0.32
        let outline = [
            NSPoint(x: cx - w,        y: cy + top * 0.4),
            NSPoint(x: cx - w * 0.45, y: cy + top),
            NSPoint(x: cx + w * 0.45, y: cy + top),
            NSPoint(x: cx + w,        y: cy + top * 0.4),
            NSPoint(x: cx,            y: cy - bot),
        ]
        strokePoly(outline, color, width: 1)
        // facets
        let f = NSBezierPath()
        f.move(to: NSPoint(x: cx - w * 0.45, y: cy + top)); f.line(to: NSPoint(x: cx, y: cy - bot))
        f.move(to: NSPoint(x: cx + w * 0.45, y: cy + top)); f.line(to: NSPoint(x: cx, y: cy - bot))
        f.move(to: NSPoint(x: cx - w, y: cy + top * 0.4)); f.line(to: NSPoint(x: cx + w, y: cy + top * 0.4))
        lighten(color, 0.5).setStroke(); f.lineWidth = 1; f.stroke()
    }

    private func drawBlob(in r: NSRect, color: NSColor) {
        // Rounded clay blob: a fat oval with a soft highlight.
        let rect = r.insetBy(dx: r.width * 0.16, dy: r.height * 0.24)
        let p = NSBezierPath(ovalIn: rect)
        color.setFill(); p.fill()
        NSColor.black.withAlphaComponent(0.4).setStroke(); p.lineWidth = 1; p.stroke()
        fillCircle(NSPoint(x: rect.midX - rect.width * 0.18, y: rect.midY + rect.height * 0.18),
                   max(1, rect.width * 0.14), lighten(color, 0.4), outline: nil)
    }

    private func drawCoil(in r: NSRect, color: NSColor) {
        // String fibre: a few stacked loops/threads.
        let cx = r.midX
        let w = r.width * 0.30
        let stroke = shade(color, 0.85)
        for i in 0..<3 {
            let y = r.midY + (CGFloat(i) - 1) * r.height * 0.18
            let rect = NSRect(x: cx - w, y: y - r.height * 0.07, width: w * 2, height: r.height * 0.14)
            let p = NSBezierPath(ovalIn: rect)
            stroke.setStroke(); p.lineWidth = max(1.5, r.width * 0.07); p.stroke()
        }
    }

    private func drawFeather(in r: NSRect, color: NSColor) {
        // Feather: a leaf-like vane with a central quill.
        let tip = NSPoint(x: r.maxX - r.width * 0.22, y: r.maxY - r.height * 0.18)
        let base = NSPoint(x: r.minX + r.width * 0.26, y: r.minY + r.height * 0.20)
        let vane = NSBezierPath()
        vane.move(to: base)
        vane.curve(to: tip,
                   controlPoint1: NSPoint(x: r.minX + r.width * 0.15, y: r.maxY - r.height * 0.30),
                   controlPoint2: NSPoint(x: r.midX, y: r.maxY - r.height * 0.10))
        vane.curve(to: base,
                   controlPoint1: NSPoint(x: r.maxX - r.width * 0.10, y: r.midY),
                   controlPoint2: NSPoint(x: r.midX + r.width * 0.10, y: r.minY + r.height * 0.18))
        vane.close()
        color.setFill(); vane.fill()
        NSColor.black.withAlphaComponent(0.3).setStroke(); vane.lineWidth = 1; vane.stroke()
        // quill / rachis
        let quill = NSBezierPath()
        quill.move(to: base); quill.line(to: tip)
        shade(color, 0.7).setStroke(); quill.lineWidth = max(1, r.width * 0.05); quill.stroke()
    }

    private func drawDustPile(in r: NSRect, color: NSColor) {
        // Small heap with sparkle specks.
        let cx = r.midX, baseY = r.minY + r.height * 0.30
        let heap = NSBezierPath()
        heap.move(to: NSPoint(x: cx - r.width * 0.30, y: baseY))
        heap.curve(to: NSPoint(x: cx + r.width * 0.30, y: baseY),
                   controlPoint1: NSPoint(x: cx - r.width * 0.10, y: baseY + r.height * 0.34),
                   controlPoint2: NSPoint(x: cx + r.width * 0.10, y: baseY + r.height * 0.34))
        heap.close()
        color.setFill(); heap.fill()
        NSColor.black.withAlphaComponent(0.3).setStroke(); heap.lineWidth = 1; heap.stroke()
        // sparkles
        let spark = lighten(color, 0.6)
        for o in [CGPoint(x: -0.10, y: 0.42), CGPoint(x: 0.16, y: 0.30), CGPoint(x: 0.02, y: 0.55)] {
            drawSparkle(at: NSPoint(x: cx + r.width * o.x, y: baseY + r.height * o.y),
                        s: r.width * 0.07, color: spark)
        }
    }

    private func drawSparkle(at c: NSPoint, s: CGFloat, color: NSColor) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x - s, y: c.y)); p.line(to: NSPoint(x: c.x + s, y: c.y))
        p.move(to: NSPoint(x: c.x, y: c.y - s)); p.line(to: NSPoint(x: c.x, y: c.y + s))
        color.setStroke(); p.lineWidth = max(1, s * 0.5); p.stroke()
    }

    private func drawBook(in r: NSRect, color: NSColor) {
        // Small closed book: cover + spine + page edge.
        let rect = r.insetBy(dx: r.width * 0.20, dy: r.height * 0.22)
        let cover = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        color.setFill(); cover.fill()
        NSColor.black.withAlphaComponent(0.4).setStroke(); cover.lineWidth = 1; cover.stroke()
        // page edge on the right
        let pages = NSRect(x: rect.maxX - rect.width * 0.16, y: rect.minY + 1,
                           width: rect.width * 0.14, height: rect.height - 2)
        lighten(color, 0.7).setFill(); NSBezierPath(rect: pages).fill()
        // spine on the left
        let spine = NSRect(x: rect.minX, y: rect.minY, width: rect.width * 0.16, height: rect.height)
        shade(color, 0.7).setFill(); NSBezierPath(rect: spine).fill()
    }

    // ----- Food ------------------------------------------------------------
    private func drawBerryCluster(in r: NSRect, color: NSColor) {
        let rr = r.width * 0.16
        let offs = [CGPoint(x: -0.16, y: 0.10), CGPoint(x: 0.16, y: 0.10),
                    CGPoint(x: 0.0, y: -0.14), CGPoint(x: -0.02, y: 0.26)]
        for o in offs {
            let c = NSPoint(x: r.midX + r.width * o.x, y: r.midY + r.height * o.y)
            fillCircle(c, rr, color)
            fillCircle(NSPoint(x: c.x - rr * 0.3, y: c.y + rr * 0.3), rr * 0.3, lighten(color, 0.5), outline: nil)
        }
    }

    private func drawStewBowl(in r: NSRect, color: NSColor) {
        // Bowl (half-disc) with stew inside.
        let cx = r.midX, cy = r.midY - r.height * 0.04
        let bw = r.width * 0.34
        // stew surface (ellipse)
        let surf = NSRect(x: cx - bw, y: cy, width: bw * 2, height: r.height * 0.16)
        color.setFill(); NSBezierPath(ovalIn: surf).fill()
        // bowl body
        let bowl = NSBezierPath()
        bowl.move(to: NSPoint(x: cx - bw, y: cy + r.height * 0.08))
        bowl.curve(to: NSPoint(x: cx + bw, y: cy + r.height * 0.08),
                   controlPoint1: NSPoint(x: cx - bw * 0.6, y: cy - r.height * 0.28),
                   controlPoint2: NSPoint(x: cx + bw * 0.6, y: cy - r.height * 0.28))
        NSColor(srgbRed: 0.85, green: 0.85, blue: 0.88, alpha: 1).setFill(); bowl.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke(); bowl.lineWidth = 1; bowl.stroke()
    }

    private func drawCakeSlice(in r: NSRect, color: NSColor) {
        // Layered triangular slice (side view): two cake layers + a top.
        let left = r.minX + r.width * 0.22
        let right = r.maxX - r.width * 0.20
        let baseY = r.minY + r.height * 0.26
        let topY = r.maxY - r.height * 0.26
        let slice = [
            NSPoint(x: left, y: baseY),
            NSPoint(x: right, y: baseY),
            NSPoint(x: right, y: topY),
        ]
        strokePoly(slice, shade(color, 0.85), width: 1)
        // filling stripe
        let midY = (baseY + topY) / 2
        let stripe = NSBezierPath()
        stripe.move(to: NSPoint(x: left + (right - left) * 0.0, y: midY))
        stripe.line(to: NSPoint(x: right, y: midY))
        lighten(color, 0.55).setStroke(); stripe.lineWidth = max(1.5, r.height * 0.07); stripe.stroke()
        // a cherry on the top corner
        fillCircle(NSPoint(x: right - r.width * 0.06, y: topY - r.height * 0.02),
                   max(1, r.width * 0.07), NSColor.systemRed)
    }

    private func drawMushroom(in r: NSRect, color: NSColor) {
        // Stem + domed cap.
        let cx = r.midX
        // stem
        let stem = NSRect(x: cx - r.width * 0.10, y: r.minY + r.height * 0.22,
                          width: r.width * 0.20, height: r.height * 0.28)
        lighten(color, 0.6).setFill()
        let sp = NSBezierPath(roundedRect: stem, xRadius: 2, yRadius: 2); sp.fill()
        NSColor.black.withAlphaComponent(0.3).setStroke(); sp.lineWidth = 1; sp.stroke()
        // cap (half dome)
        let capY = r.minY + r.height * 0.48
        let cw = r.width * 0.32
        let cap = NSBezierPath()
        cap.move(to: NSPoint(x: cx - cw, y: capY))
        cap.curve(to: NSPoint(x: cx + cw, y: capY),
                  controlPoint1: NSPoint(x: cx - cw, y: capY + r.height * 0.34),
                  controlPoint2: NSPoint(x: cx + cw, y: capY + r.height * 0.34))
        cap.close()
        color.setFill(); cap.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke(); cap.lineWidth = 1; cap.stroke()
        // spots
        fillCircle(NSPoint(x: cx - cw * 0.4, y: capY + r.height * 0.10), max(1, r.width * 0.05),
                   NSColor.white.withAlphaComponent(0.8), outline: nil)
        fillCircle(NSPoint(x: cx + cw * 0.35, y: capY + r.height * 0.14), max(1, r.width * 0.04),
                   NSColor.white.withAlphaComponent(0.8), outline: nil)
    }

    private func drawHearts(value: Float, max: Int, at origin: NSPoint) {
        let full = Int(value.rounded())
        let step = 16 * hudScale, sz = 12 * hudScale
        for i in 0..<max / 2 {
            let filled = (i * 2) < full
            (filled ? NSColor.systemRed : NSColor.black.withAlphaComponent(0.4)).setFill()
            let r = NSRect(x: origin.x + CGFloat(i) * step, y: origin.y, width: sz, height: sz)
            NSBezierPath(ovalIn: r).fill()
        }
    }

    private func drawBubbles(value: Float, at origin: NSPoint) {
        // 10 air bubbles; fill count tracks remaining oxygen (1 = full).
        let count = 10
        let step = 16 * hudScale, sz = 12 * hudScale
        let filled = Int((max(0, min(1, value)) * Float(count)).rounded())
        for i in 0..<count {
            let r = NSRect(x: origin.x + CGFloat(i) * step, y: origin.y, width: sz, height: sz)
            if i < filled {
                NSColor.systemBlue.setFill(); NSBezierPath(ovalIn: r).fill()
                NSColor.white.withAlphaComponent(0.6).setStroke()
                let p = NSBezierPath(ovalIn: r); p.lineWidth = 1; p.stroke()
            } else {
                NSColor.black.withAlphaComponent(0.4).setFill()
                NSBezierPath(ovalIn: r).fill()
            }
        }
    }

    private func drawText(_ s: String, at p: NSPoint, size: CGFloat, color: NSColor, bold: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
            .strokeColor: NSColor.black, .strokeWidth: -2.0,
        ]
        (s as NSString).draw(at: p, withAttributes: attrs)
    }
}
