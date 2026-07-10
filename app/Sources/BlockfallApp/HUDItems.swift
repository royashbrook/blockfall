import AppKit

// Item id -> (display name, chip colour). Mirrors content/items so the HUD can
// label and colour items without an ABI change. Keep in sync with content.
private struct ItemInfo { let name: String; let color: NSColor }
func itemColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
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
    95: .init(name: "Magnet Charm",  color: itemColor(0.75, 0.55, 0.95)),
    96: .init(name: "Gold Coin",     color: itemColor(0.95, 0.80, 0.25)),
]
func itemName(_ id: UInt16) -> String { kItemTable[id]?.name ?? "Item \(id)" }
func itemChipColor(_ id: UInt16) -> NSColor { kItemTable[id]?.color ?? NSColor(hue: CGFloat(id % 12)/12, saturation: 0.6, brightness: 0.9, alpha: 1) }
func allItemIds() -> [UInt16] { kItemTable.keys.sorted() }

// Kid-friendly descriptions for every item a player is likely to encounter.
// Falls back to a generic hint so tooltip text is never blank.
func itemDescription(id: UInt16) -> String {
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
