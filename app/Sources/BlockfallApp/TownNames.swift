// ============================================================================
// Blockfall — TownNames (#187)
// Deterministic, kid-friendly names for discovered villages. The engine records
// villages by anchor coordinate; we name them CLIENT-SIDE from those coords so
// the same town keeps the same name forever (across sessions, on the big map and
// the minimap alike) with zero ABI churn. Two very distant towns can share a name
// on a hash collision; harmless and rare at this world scale.
// ============================================================================
import Foundation

enum TownNames {
    // Cozy, whimsical, easy-to-read. Kept deliberately un-scary for ages 7-10.
    static let list: [String] = [
        "Bramblewick", "Puddlejump", "Marshmallow Hollow", "Sunny Sprout",
        "Giggle Grove", "Pebblebrook", "Honeywood", "Sparkle Springs",
        "Muffin Meadow", "Dandelion Dell", "Cloudberry", "Snugglebrook",
        "Fuzzy Fenn", "Bubblewick", "Twinkle Town", "Cocoa Corner",
        "Wobblewood", "Jellybean Junction", "Mossy Nook", "Sprinkleton",
        "Pancake Point", "Buttercup Bay", "Gingersnap", "Waffleford",
        "Pumpkin Patch", "Berryburg", "Toadstool Towne", "Whisker Hollow",
        "Noodle Nook", "Cricket Creek", "Lollipop Lane", "Marble Meadows",
        "Dewdrop Dale", "Acorn Alley", "Peppermint Pass", "Cuddlecove",
        "Fernwhistle", "Glimmerbrook", "Hushabye Harbor", "Quokka Quarry",
        "Turnip Town", "Sugarplum", "Meadowmuffin", "Pinecone Point",
        "Butterscotch", "Cozywick", "Snapdragon", "Tumbleweed Trace",
    ]

    // Stable pick from a village's world anchor. Mix x and z through a couple of
    // integer avalanche steps so neighbouring towns do not land on adjacent names.
    static func name(x: Int32, z: Int32) -> String {
        var h = UInt64(bitPattern: Int64(x)) &* 0x9E3779B97F4A7C15
        h ^= UInt64(bitPattern: Int64(z)) &* 0xC2B2AE3D27D4EB4F
        h = (h ^ (h >> 29)) &* 0xBF58476D1CE4E5B9
        h = h ^ (h >> 32)
        return list[Int(h % UInt64(list.count))]
    }
}
