import UIKit
import CBlockcore

/// UIKit peer of the macOS HUD. #346 only establishes the shared renderer
/// boundary; #347 fills this view with the touch HUD and controls.
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

    var isQuestLogOpen: Bool { false }

    func update(from state: bf_hud_state) {}
    func setPlayerInfo(x: Float, y: Float, z: Float, facing: Float) {}
    func setTimeOfDay(_ time: Float) {}
    func setQuests(_ rows: [QuestRow]) {}
    func setPeers(_ markers: [PeerMarker]) {}
    func setVillagers(_ markers: [VillagerMarker], now: CFTimeInterval) {}
    func setChestOpen(pos: bf_ivec3, view: bf_chest_view) {}
    func setChestClosed() {}
    func setVillage(_ village: bf_village_view?) {}
    func flashScreenshot() {}
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
