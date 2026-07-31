// ============================================================================
// Blockfall — Renderer (Track E, M1 + M5 Cinematic Lighting)
// Owns the engine + Metal queue. Per frame: read GameView input -> drive the
// engine -> acquire the render frame -> draw each chunk mesh (greedy-meshed
// BFVertex buffers, UMA storageModeShared, referenced by handle) with a
// runtime-compiled stylized shader. Buffers freed by the engine are retired
// for a few frames so the GPU never reads a released buffer (threading.md §2).
//
// M5 lighting additions:
//   • Ambient occlusion from packed vertex bits [3:5]
//   • Sun shadow mapping  (2048²  depth32Float, PCF 3×3)
//   • HDR offscreen scene (rgba16Float + depth32Float)
//   • Bloom (bright-pass → half-res Gaussian blur H + V × 2 iterations)
//   • Composite / tonemap: ACES filmic + colour grade + vignette → drawable
// ============================================================================
import MetalKit
import simd
import CBlockcore
#if os(macOS)
import AppKit
typealias BlockfallColor = NSColor
#else
import UIKit
typealias BlockfallColor = UIColor
#endif
#if canImport(MetalFX)
import MetalFX
#endif

// MARK: - Renderer

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let registry: BufferRegistry
    private let perfLogEnabled = ProcessInfo.processInfo.environment["BF_PERF_LOG"] == "1"
    private var perfLogLastTime: CFTimeInterval = 0
    private var perfLogFrames = 0
    // Scene pipelines (chunk terrain + sky + underwater)
    private var pipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var skyPipeline: MTLRenderPipelineState!
    private var skyDepthState: MTLDepthStencilState!
    private var underwaterPipeline: MTLRenderPipelineState!
    // World-space voxel sun shadows: no shadow-map render pass (see uploadShadowVolume).
    // Post-processing pipelines
    private var bloomBrightPipeline: MTLRenderPipelineState!  // bright-pass (HDR → half-res)
    private var bloomBlurHPipeline: MTLRenderPipelineState!  // horizontal Gaussian
    private var bloomBlurVPipeline: MTLRenderPipelineState!  // vertical Gaussian
    private var compositePipeline: MTLRenderPipelineState!   // ACES + grade + vignette → drawable
    private var godrayPipeline: MTLRenderPipelineState!      // #167 half-res god-ray march pre-pass
    // Ambient life (birds + fireflies) — renderer-owned visual state
    private var ambientLifePipeline: MTLRenderPipelineState!
    private var ambientLifeDepthState: MTLDepthStencilState!
    private var ambientLifeBuffer: MTLBuffer!   // AmbientSprite array (CPU-updated each frame)
    private let kMaxAmbientSprites = 120   // birds + fireflies + pollen + grey ash motes
    private let ambientBirdSystem = AmbientBirdSystem()

    // ---- Sub-voxel props (#51/#52: GPU-instanced) ---------------------------
    private var propPipeline: MTLRenderPipelineState!
    private var propModelTable: MTLBuffer!       // static: 4 types × 4 cuboids (PropCuboidGPU)
    private var viewModelPipeline: MTLRenderPipelineState!   // #70 first-person arm
    private var viewModelDepthState: MTLDepthStencilState!   // always-on-top
    private var viewModelArmBuf: MTLBuffer!
    private var viewModelArmCount = 0
    // #71 the player's own skin/shirt, applied to the first-person arm.
    private var charSkin  = SIMD3<Float>(0.85, 0.66, 0.52)
    private var charShirt = SIMD3<Float>(0.30, 0.50, 0.82)
    func setRenderDistance(_ chunks: Int) {   // #85 live render-distance slider
        if let e = engine { bf_set_render_distance(e, UInt32(max(8, min(40, chunks)))) }
    }
    func setCharacterAppearance(_ appearance: CharacterAppearance) {
        charSkin = appearance.skinRGB; charShirt = appearance.shirtRGB
        let arm = makeViewModelArm(skin: charSkin, sleeve: charShirt)
        viewModelArmCount = arm.count
        viewModelArmBuf = device.makeBuffer(bytes: arm, length: arm.count * MemoryLayout<PropCuboidGPU>.stride,
                                            options: .storageModeShared)
        if let e = engine {
            var value = appearance.engineValue
            _ = bf_player_appearance_set(e, &value)
        }
    }
    private var heldItemBuf: MTLBuffer?            // #70 v2: equipped item in hand
    private var heldItemCount = 0
    private var lastHeldItem = -1
    private var swingPulse: Double = -100          // #: time of last mine/place/attack (tool swing)
    // CPU writes the prop list every frame. Keep one shared buffer per GPU frame in
    // flight; overwriting a single buffer made static trees/bushes read a later frame's
    // instances while an older command buffer was still drawing them.
    static let propInstanceBufferRingSize = 3
    private let inFlightSemaphore = DispatchSemaphore(value: Renderer.propInstanceBufferRingSize)
    private var propInstanceBuffers = [MTLBuffer?](
        repeating: nil, count: Renderer.propInstanceBufferRingSize)
    private var propDrawBuckets = Array(repeating: [bf_prop_instance](), count: Renderer.propRowCount)

    // ---- Graphics effect toggles (pause-menu Options) ------------------------
    // Each effect can be switched on/off live. Persisted in UserDefaults; loaded
    // here so even the --playtest path picks them up. Waving foliage and god rays
    // default OFF (too busy/realistic for the kid target); most other effects default ON.
    var gfxFoliage = UserDefaults.standard.object(forKey: "gfxFoliage") as? Bool ?? false
    var gfxWater   = UserDefaults.standard.object(forKey: "gfxWater")   as? Bool ?? true
    // #167: default OFF again. Even quarter-res shafts are a large forest/village GPU hit;
    // keep them as an optional quality toggle instead of a baseline cost.
    var gfxGodRays: Bool = {
        if let s = ProcessInfo.processInfo.environment["BF_GODRAYS"], let v = Int(s) {
            return v != 0
        }
        return UserDefaults.standard.object(forKey: "gfxGodRays") as? Bool ?? false
    }()
    // #132 lens flare: classic screen-space flare when the sun is on-screen and not
    // occluded. Separate toggle from God Rays (which drives the descending shafts).
    // Defaults ON; OFF removes the flare entirely (no cost, byte-identical to no-flare).
    var gfxLensFlare = UserDefaults.standard.object(forKey: "gfxLensFlare") as? Bool ?? true
    var gfxPollen  = UserDefaults.standard.object(forKey: "gfxPollen")  as? Bool ?? true
    // World-space voxel sun shadows. The old camera-following shadow map had a residual
    // sun-angle / camera-yaw wipe and shipped OFF. This is the from-scratch world-space
    // rebuild: a fixed world point's shadow is identical from every camera, so it defaults ON.
    var gfxShadows = UserDefaults.standard.object(forKey: "gfxShadows") as? Bool ?? true
    // Soft shadows: a few jittered sun rays for a penumbra instead of one hard ray. Costs
    // ~5x the march, so it is a quality knob gated behind its own toggle (default OFF, Air-safe).
    var gfxSoftShadows = UserDefaults.standard.object(forKey: "gfxSoftShadows") as? Bool ?? false
    // #116 character shadows: dynamic entities (mobs, villagers, animals, the player) are not in
    // the static voxel occupancy grid, so they cannot be ray-marched as casters. This toggle drives
    // (a) entities RECEIVING the world voxel sun shadow (they darken in shade, marched the same way
    // the terrain is) and (b) a cheap stylized CAST contact-shadow blob on the ground under each
    // entity, offset/stretched along the sun direction. Daylight-gated. Defaults ON.
    var gfxCharShadows = UserDefaults.standard.object(forKey: "gfxCharShadows") as? Bool ?? true
    // #338 cel-shade remains an optional bold-outline treatment, while the softer
    // whimsical render is the primary look. Preserve an explicit saved preference,
    // but keep the first-run/default presentation free of the cel post-process.
    var gfxCelShade = UserDefaults.standard.object(forKey: "gfxCelShade") as? Bool ?? false
    // #136 per-effect intensity (0..1) for the effects that have a meaningful strength
    // knob, each beside its on/off checkbox in the pause menu and persisted alongside its
    // toggle. The fraction multiplies that effect's shader strength:
    //   gfxGodRayStr  -> scales kGodRayStrength (the god-ray master). Default 0.5 so the
    //                    out-of-the-box look is HALF the old full strength (the old build
    //                    ran the equivalent of 1.0, which read too strong); 1.0 restores it.
    //   gfxBloomStr   -> scales the composite bloom add. Default 0.5 (the previous fixed
    //                    look maps to ~0.5 on this 0..2x range; 1.0 doubles the glow).
    //   gfxCelOutlineStr -> scales the cel ink-outline darkness. Default 1.0 (current look).
    // BF_GODRAY_STR (0..1) overrides the persisted/default god-ray slider, so the headless
    // --shot harness can render the rays at a fixed intensity for the 0/50/100 verification.
    var gfxGodRayStr: Float = {
        if let s = ProcessInfo.processInfo.environment["BF_GODRAY_STR"], let v = Float(s) {
            return max(0, min(1, v))
        }
        return Float(UserDefaults.standard.object(forKey: "gfxGodRayStr") as? Double ?? 0.5)
    }()
    var gfxBloomStr      = Float(UserDefaults.standard.object(forKey: "gfxBloomStr")      as? Double ?? 0.5)
    // #205: bloom on/off toggle (default on) so it matches the other effect rows.
    var gfxBloom         = (UserDefaults.standard.object(forKey: "gfxBloom") as? Bool ?? true)
    var gfxCelOutlineStr = Float(UserDefaults.standard.object(forKey: "gfxCelOutlineStr") as? Double ?? 1.0)
    // #47 volumetric clouds: real raymarched, bold/toy-styled cumulus over the sky dome,
    // day/night gated. Defaults ON. The pause-menu checkbox is owned by the UI layer
    // (main.swift); this reads the same persisted "gfxClouds" key so wiring a checkbox there
    // is a one-liner, and BF_CLOUDS=0/1 overrides headless for the clouds-off comparison shot.
    // Wired: the pause menu has a "Volumetric Clouds" checkbox (tag 8) bound to "gfxClouds".
    var gfxClouds = Renderer.cloudsDefault > 0.5
    // #47 stylized PBR: procedural per-material roughness/metalness drives a restrained
    // specular that complements the cel bands (wet/shiny vs matte). Strength 0..1; default
    // 0.6 (a tasteful sheen that does not flatten the toon banding). BF_PBR overrides headless.
    var gfxPBRStr: Float = Renderer.pbrDefault
    // Env-driven look defaults, shared by the live renderer AND the WaterUniforms struct
    // defaults the headless --shot harness builds (so a shot ships the same look). BF_CLOUDS
    // and BF_PBR let the verification shots compare clouds-off / pbr-off without a harness edit.
    static let cloudsDefault: Float = {
        if let s = ProcessInfo.processInfo.environment["BF_CLOUDS"], let v = Float(s) { return v > 0.5 ? 1 : 0 }
        return (UserDefaults.standard.object(forKey: "gfxClouds") as? Bool ?? true) ? 1 : 0
    }()
    static let pbrDefault: Float = {
        if let s = ProcessInfo.processInfo.environment["BF_PBR"], let v = Float(s) { return max(0, min(1, v)) }
        return Float(UserDefaults.standard.object(forKey: "gfxPBRStr") as? Double ?? 0.6)
    }()
    // #180 render-only horizon curvature (phase 2 of the #173 looping-world epic).
    // The world is a 32768-block torus (#179); to make it READ as a round little
    // planet, every world-space vertex shader drops geometry by k * d^2 where d is
    // the horizontal distance to the camera and k = 1 / (2 * R). Purely visual: the
    // engine, physics, fog distances and the world-space voxel shadow march all stay
    // on the FLAT world (o.worldPos is the undropped position everywhere), so a fixed
    // world point's shadow is still camera-invariant. With R = 7000 the drop is
    // ~2.9 blocks at 200 and ~10.5 blocks at the 384-block render edge, which sinks
    // the far chunk ring below the horizon line and hides pop-in.
    // BF_HORIZON=<radius> overrides for shots (0 = flat/off). Baked into the shader
    // source at library-compile time; per-pass uniforms only carry the camera pos +
    // an enable flag (w), so default-built uniforms (harness gates) render flat.
    static let kHorizonRadius: Float = {
        if let s = ProcessInfo.processInfo.environment["BF_HORIZON"], let v = Float(s) { return max(0, v) }
        return 7000
    }()
    static let horizonK: Float = kHorizonRadius > 0 ? 1.0 / (2.0 * kHorizonRadius) : 0
    // MSL float literal for baking into the runtime-compiled shader sources.
    static let horizonKLiteral: String = String(format: "%.9e", Double(horizonK)) + "f"
    // #162 weather control. The engine owns weather (a deterministic function of
    // seed + world_clock) and packs it into frame.camera.weather: integer part =
    // precip mode (0 none, 1 rain, 2 snow), fraction = cloud coverage * 0.98.
    // BF_WEATHER forces the precip mode and BF_CLOUDCOVER forces coverage (0..1)
    // so headless shots can render any weather without waiting for it.
    static let weatherOverride: Int? =
        ProcessInfo.processInfo.environment["BF_WEATHER"].flatMap { Int($0) }
    static let cloudCoverOverride: Float? =
        ProcessInfo.processInfo.environment["BF_CLOUDCOVER"].flatMap { Float($0) }
    // Default WaterUniforms.weatherPack for paths that never see an engine frame
    // (the headless --shot harness): env overrides, else a mid partly-cloudy sky.
    static let weatherPackDefault: Float =
        packWeather(precip: weatherOverride ?? 0, cover: cloudCoverOverride ?? 0.5)
    // Shader-side packing (see WaterUniforms.weatherPack): states land at 0/2/4
    // so the 0..0.98 coverage fraction can never bleed into the state.
    static func packWeather(precip: Int, cover: Float) -> Float {
        Float(max(0, min(2, precip))) * 2 + max(0, min(1, cover)) * 0.98
    }
    // Decode the engine's camera.weather packing, applying the env overrides.
    static func decodeWeather(_ packed: Float) -> (precip: Int, cover: Float) {
        var p = max(0, min(2, Int(packed)))
        var c = max(0, min(1, (packed - Float(Int(packed))) / 0.98))
        if let f = weatherOverride { p = max(0, min(2, f)) }
        if let cc = cloudCoverOverride { c = max(0, min(1, cc)) }
        return (p, c)
    }
    // World-space precipitation (rain streaks / snow flakes) — renderer-owned,
    // instanced billboards in a volume around the camera. Drives off frame.camera.weather.
    private var precipPipeline: MTLRenderPipelineState!
    private var precipDepthState: MTLDepthStencilState!
    private var precipBuffer: MTLBuffer!           // PrecipParticlePod array (filled once at init)
    private let kPrecipCount = 6000                // #32: doubled (was 3000) — denser rain/snow; recycled in-shader
    private let kPrecipBox: Float = 48.0           // edge length of the spawn cube around the camera
    // Water translucency pass — re-draws chunks with alpha blend, water-only
    private var waterPipeline: MTLRenderPipelineState!
    private var waterDepthState: MTLDepthStencilState!
    // Sub-systems
    private var entityRenderer: EntityRenderer!
    private var particles: ParticleSystem!
    // Engine state
    private var engine: OpaquePointer?
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    // #127 cosmetic animation clock. Drives grass sway, creature/leaf wiggle, pollen,
    // ambient sprites, and precipitation. It accumulates frame dt ONLY when the world is
    // not paused, so on pause every cosmetic motion freezes in place and on unpause it
    // resumes from the exact same value (no jump). This replaces the old wall-clock read
    // (CACurrentMediaTime), which kept ticking through a pause and made the world look
    // alive while the player expected it stopped. The world_clock / sun is already held by
    // ticking the engine with dt = 0 while paused (see worldPaused below).
    private var animClock: CFTimeInterval = 0
    private var frameCounter = 0
    private weak var gameView: GameView?
    weak var hud: HUDView?
    weak var audio: GameAudio?
    private var lastUnderwater = false

    // #109 chest moves requested by HUD clicks this frame, applied at the top of the
    // next draw against the currently open chest. Each is (take: true => chest->inv from
    // chest slot N; false => inv->chest from inventory slot N). Drained per frame. The
    // engine resolves the position from its own open-chest state, so we only pass slots.
    private var pendingChestMoves: [(take: Bool, slot: Int)] = []
    private var openChestPos: bf_ivec3?
    func enqueueChestTake(_ slot: Int) { pendingChestMoves.append((true, slot)) }
    func enqueueChestDeposit(_ slot: Int) { pendingChestMoves.append((false, slot)) }
    // ESC from GameView closes the engine's open chest; the next poll clears the panel.
    func closeChest() { if let e = engine { bf_chest_close(e) } }

    // #182 world map: the last camera position/facing (feeds the map centring)
    // plus the one-shot query + teleport calls. The map UI is fed once on open,
    // so there is no per-frame engine cost while it is closed OR open.
    private var lastPlayerX: Float = 0
    private var lastPlayerZ: Float = 0
    private var lastPlayerFacing: Float = 0

    // #187 minimap: cheap read-only player state, polled by the HUD minimap each
    // tick (the heavy explored-mask copy in mapQuery is not needed for it).
    var playerWorldX: Float { lastPlayerX }
    var playerWorldZ: Float { lastPlayerZ }
    var playerWorldFacing: Float { lastPlayerFacing }

    struct MapSnapshot {
        let explored: [UInt8]
        let period: Int
        let cellSize: Int
        let cells: Int
        let markers: [MapView.Marker]
        let playerX: Float
        let playerZ: Float
        let facing: Float
    }

    // Query the engine's explored mask + markers (bf_map_query, ABI v23).
    func mapQuery() -> MapSnapshot? {
        guard let e = engine else { return nil }
        var explored = [UInt8](repeating: 0, count: Int(BF_MAP_EXPLORED_BYTES))
        // bf_map_view is ~2 KiB of fixed arrays; heap-allocate to keep it off the stack.
        let viewPtr = UnsafeMutablePointer<bf_map_view>.allocate(capacity: 1)
        defer { viewPtr.deallocate() }
        viewPtr.pointee = bf_map_view()
        var ok = false
        explored.withUnsafeMutableBufferPointer { buf in
            viewPtr.pointee.explored = buf.baseAddress
            viewPtr.pointee.explored_cap = UInt32(buf.count)
            ok = bf_map_query(e, viewPtr) == BF_OK
        }
        guard ok else { return nil }
        let v = viewPtr.pointee
        var markers: [MapView.Marker] = []
        withUnsafeBytes(of: v.markers) { raw in
            let p = raw.bindMemory(to: bf_map_marker.self)
            for i in 0..<min(Int(v.marker_count), Int(BF_MAP_MAX_MARKERS)) {
                let m = p[i]
                let engineName = withUnsafeBytes(of: m.name) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
                }
                // #187: villages get a fun kid name derived from their coords
                // (stable across sessions); home and totems keep the engine label.
                // #221: settlements get the fun town name; cities read as "City of X".
                let name: String
                switch m.kind {
                case 1: name = TownNames.name(x: m.pos.x, z: m.pos.z)
                case 4: name = "Town of " + TownNames.name(x: m.pos.x, z: m.pos.z)
                case 3, 5: name = "City of " + TownNames.name(x: m.pos.x, z: m.pos.z)
                default: name = engineName
                }
                markers.append(MapView.Marker(x: m.pos.x, z: m.pos.z,
                                              kind: m.kind, id: m.id, name: name))
            }
        }
        return MapSnapshot(explored: explored,
                           period: Int(v.world_period),
                           cellSize: Int(v.cell_size),
                           cells: Int(v.cells_per_axis),
                           markers: markers,
                           playerX: lastPlayerX, playerZ: lastPlayerZ,
                           facing: lastPlayerFacing)
    }

    // #224: whole-planet biome layer (one byte per map cell), for the map's
    // biome tint. Pure worldgen engine-side; fetched once per map open.
    func mapBiomes(cells: Int) -> [UInt8]? {
        guard let e = engine, cells > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: cells * cells)
        let ok = buf.withUnsafeMutableBufferPointer { b in
            bf_map_biomes(e, b.baseAddress, UInt32(b.count)) == BF_OK
        }
        return ok ? buf : nil
    }

    // #203 trade: offer sheet + execute + coin/goods balance for the panel.
    private var lastHudState: bf_hud_state?
    // #239: per-frame player x/z for the dialogue walk-away close.
    var onPlayerPos: ((Float, Float) -> Void)?
    // #240: the current look-at nameplate ("Pip the Woodcutter"), so the
    // dialogue header can name the exact villager that was clicked.
    var lookName: String {
        guard var h = lastHudState else { return "" }
        return withUnsafeBytes(of: &h.look_name) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
    func tradeOffers(npcId: Int32) -> [TradeView.Offer]? {
        guard let e = engine else { return nil }
        var v = bf_trade_view()
        guard bf_trade_offers(e, npcId, &v) == BF_OK, v.active == 1 else { return nil }
        var out: [TradeView.Offer] = []
        withUnsafeBytes(of: v.offers) { raw in
            let p = raw.bindMemory(to: bf_trade_offer.self)
            for i in 0..<min(Int(v.offer_count), 6) {
                out.append(TradeView.Offer(giveItem: p[i].give_item, giveCount: p[i].give_count,
                                           getItem: p[i].get_item, getCount: p[i].get_count))
            }
        }
        return out.isEmpty ? nil : out
    }
    func tradeExecute(npcId: Int32, index: UInt32) -> Bool {
        guard let e = engine else { return false }
        return bf_trade_execute(e, npcId, index) != 0
    }
    func sideQuestTalk(questId: UInt32) {
        guard let e = engine else { return }
        _ = bf_side_quest_talk(e, questId)
    }
    func inventoryCount(item: UInt16) -> Int {
        guard let h = lastHudState else { return 0 }
        var n = 0
        withUnsafeBytes(of: h.hotbar) { raw in
            for s in raw.bindMemory(to: bf_hud_slot.self) where s.item == item { n += Int(s.count) }
        }
        withUnsafeBytes(of: h.inventory) { raw in
            for s in raw.bindMemory(to: bf_hud_slot.self) where s.item == item { n += Int(s.count) }
        }
        return n
    }

    // Teleport to a marker (bf_map_teleport). The charge-up happens app-side.
    @discardableResult
    func mapTeleport(_ id: UInt32) -> Bool {
        guard let e = engine else { return false }
        return bf_map_teleport(e, id) != 0
    }

    // ---- #135 first-load readiness signal -----------------------------------
    // The app shows a loading overlay from launch and hides it once the spawn
    // neighbourhood has actually meshed + uploaded and the framerate has settled.
    // We detect that from state we already have per frame: the resident chunk
    // draw count (frame.draw_count, i.e. spawn-area meshes uploaded) crossing a
    // threshold AND a short run of consecutive healthy frame times. We prefer
    // the mesh-count signal over a pure timer because a timer alone is fragile.
    // isWorldReady latches true once and onReady fires exactly once.
    private(set) var isWorldReady = false
    var onReady: (() -> Void)?
    // Called each loading frame with the live progress fraction so the overlay can
    // animate a bar. Cleared by the app once the overlay is gone.
    var onLoadProgress: (() -> Void)?
    // The first-load stutter is the spawn chunks meshing/uploading; once this
    // many chunk draws are resident the spawn neighbourhood is on the GPU.
    private let kReadyChunkDraws = 24
    // ...and the frame loop must have settled: this many back-to-back frames
    // under the healthy-frame budget (the 1-2 fps load frames blow way past it).
    private let kReadyHealthyFrames = 6
    private let kHealthyFrameSecs: CFTimeInterval = 1.0 / 40.0   // <=25ms = settled
    private let kReadyFallbackSecs: CFTimeInterval = 12.0
    private let kReadyFallbackChunkDraws = 4
    private let loadStartedAt: CFTimeInterval = CACurrentMediaTime()
    private var healthyFrameRun = 0
    // Progress fraction (0..1) for a bar: resident chunk draws / threshold.
    private(set) var loadProgress: Float = 0

    private let saveDir: String
    private let freshWorld: Bool       // true = start a brand-new world (ignore any save)
    private let worldSeed: UInt64

    // ---- HDR offscreen textures (rebuilt on resize) --------------------------
    private var hdrColor: MTLTexture?     // rgba16Float  — scene rendered here
    private var hdrDepth: MTLTexture?     // depth32Float — shared by shadow + scene
    // Bloom intermediates (half scene size)
    private var bloomBright: MTLTexture?  // rgba16Float half-res bright pass
    private var bloomBlurA:  MTLTexture?  // rgba16Float blur ping
    // #167 half-res god-ray in-scatter (r = shaft, g = litFrac debug, b = hit distance)
    private var godrayTex:   MTLTexture?
    private var currentDrawableSize: CGSize = .zero
    // Capped internal render size (the long edge is limited to kRenderLongEdge).
    // The final composite upscales to the full drawable; only the HDR/scene/bloom
    // textures are at this reduced size — saves ~4× fragment cost on Retina.
    // Lowered to 1280 now that MetalFX spatial upscaling recovers quality.
    private let kRenderLongEdge: CGFloat = 1280
    private var sceneSize: CGSize = .zero   // actual HDR texture size (≤ drawable)

    // ---- MetalFX spatial upscaler (optional — macOS 13+, Apple GPU) ---------
    // compositeLowRes: ACES composite writes here at sceneSize (LDR bgra8Unorm).
    // spatialOutput:   private full-resolution MetalFX output; copied to drawable.
    // spatialScaler:   upscales compositeLowRes → spatialOutput.
    // If MetalFX is unavailable the composite writes straight to the drawable (bilinear fallback).
    private var compositeLowRes: MTLTexture?
    private var spatialOutput: MTLTexture?
#if canImport(MetalFX)
    @available(macOS 13.0, iOS 16.0, *)
    private var _spatialScaler: MTLFXSpatialScaler?
#endif
    // True when the scaler was successfully created and can be used this frame.
    private var metalFXEnabled: Bool = false

    // ---- World-space voxel sun shadows --------------------------------------
    // Shadows are a property of the WORLD: a point is in shadow iff a solid voxel
    // sits between it and the sun. The engine exports a compact occupancy grid
    // (bf_world_shadow_volume) for the resident region around the player; the
    // renderer uploads it to a 3D texture and DDA-marches each fragment toward the
    // sun. No shadow map, no cascades, no coverage ring, no crawl, no camera
    // dependence whatsoever.
    //
    // THE PRIMARY QUALITY/PERF KNOB: the march distance (world units). A fragment is sun-lit
    // if no casting voxel is hit within this distance toward the sun. The per-fragment march
    // is THE cost (the spec flagged this), and it scales with this distance. Keep the default
    // tight for the M1 target: contact shadows under trees / structures survive, while long
    // grazing shadows remain a BF_MARCH_DIST quality override.
    static let kShadowMarchDist: Float = {
        if let s = ProcessInfo.processInfo.environment["BF_MARCH_DIST"], let v = Float(s) {
            return max(8, min(256, v))
        }
        return 8.0
    }()
    // Coverage radius used by world-space terrain/prop shadow uniforms.
    private let kShadowFarR:  Float = 384
    // #119 THE GOD-RAY TUNING KNOB. Overall strength of the volumetric light shafts at
    // full daylight; daylight + the toggle scale it down further (0 = off). Raise for
    // more dramatic beams, lower (or toggle God Rays off in graphics settings) on a weak
    // GPU like the M1 Air. The raymarch only runs when this resolves > 0.
    // #136 this is the 100%-slider CEILING. The pause-menu God Rays intensity slider scales
    // it by gfxGodRayStr (0..1), which DEFAULTS to 0.5 — so the shipped look is half this,
    // Halved again after playtest (the 1.5 ceiling still read too strong even at the 0.5 default).
    // Ceiling 1.5 with the 0.5 default gives ~0.75 effective; slider at 100% = 1.5 (the prior default).
    static let kGodRayStrength: Float = 1.5
    // #167 god-ray march downscale: the radial depth march runs at scene/N resolution and
    // the composite upsamples it depth-aware. 4 = quarter res (16x fewer marched
    // pixels). #188: the overcast "cubing" was NOT a resolution problem (half res
    // did not fix it), it was aliased crepuscular shafts over a flat cloudy sky;
    // the real fix fades god rays out in cloudy weather (see grStrength), so this
    // stays at the cheap quarter res.
    static let kGodRayDownscale: Float = 4
    // #132 LENS-FLARE GATE KNOBS (CPU side; shader has its own element knobs FLARE_*).
    //   kFlareEdgeFade : how far (in centre-distance, 0=centre ~1.4=corner) the flare keeps
    //                    fading to zero. Larger = the flare reaches further toward the edges.
    static let kFlareEdgeFade: Float = 1.25

    // World occupancy 3D texture (r8uint, 1 = casting voxel) + the persistent CPU
    // buffer the engine fills, and the region metadata for the current upload.
    private var shadowVolTex: MTLTexture?
    // Coarse 1/CO occupancy mip (1 = ANY casting voxel in the CO^3 block) for empty-space
    // skipping: open-air rays step CO blocks at a time instead of one voxel, the big perf win.
    private var shadowVolCoarseTex: MTLTexture?
    private var shadowVolBuf: [UInt8] = []
    private var shadowVolCoarseBuf: [UInt8] = []
    private var shadowVolOrigin: SIMD3<Float> = .zero
    private var shadowVolDims: SIMD3<Float> = .zero
    private var shadowVolRevision: UInt32 = .max   // last uploaded revision (forces first upload)
    private var shadowVolTexDims: (Int, Int, Int) = (0, 0, 0)
    static let kShadowCoarse = 4   // coarse cell size (voxels per axis)

    // ---- No-write depth state (sky + bloom quads) ----------------------------
    private var noDepthState: MTLDepthStencilState!

    // ---- In-game screenshot (backslash key) ---------------------------------
    // A shared-storage bgra8 texture the screenshot path composites the final
    // scene into so the CPU can read it back (the swapchain drawable is
    // framebufferOnly and cannot be getBytes'd). Lazily sized to the drawable.
    // The HUD (a separate AppKit NSView) is composited on top on the CPU, so the
    // saved PNG matches exactly what the player sees, overlay included.
    private var screenshotReadback: MTLTexture?

    init(view: MTKView, device: MTLDevice, saveDir: String, audio: GameAudio?,
         fresh: Bool = false, seed: UInt64 = 0) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.registry = BufferRegistry(device: device)
        self.gameView = view as? GameView
        self.saveDir = saveDir
        self.freshWorld = fresh
        self.worldSeed = seed
        self.audio = audio
        super.init()
        view.depthStencilPixelFormat = .depth32Float
#if canImport(MetalFX)
        if #available(macOS 13.0, iOS 16.0, *) {
            // MTLFXSpatialScaler writes to the drawable via a compute kernel that
            // requires MTLTextureUsageShaderWrite. MTKView's default framebufferOnly=true
            // restricts drawable textures to renderTarget-only usage, blocking the
            // compute write. Clearing framebufferOnly allows both. On Apple Silicon
            // UMA there is no meaningful performance cost for doing this.
            if MTLFXSpatialScalerDescriptor.supportsDevice(device) {
                view.framebufferOnly = false
            }
        }
#endif
        buildPipeline(colorFormat: view.colorPixelFormat)
        // World occupancy 3D texture is created lazily on the first uploadShadowVolume()
        // (its dims come from the engine), so there is no shadow-map allocation here.
        entityRenderer = EntityRenderer(device: device, colorFormat: .rgba16Float)
        particles = ParticleSystem(device: device, colorFormat: .rgba16Float)
        createEngine()
    }

    // MARK: Pipeline build

    private func buildPipeline(colorFormat: MTLPixelFormat) {
        let src = Renderer.shaderSource
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: src, options: nil) }
        catch { fatalError("shader compile failed: \(error)") }

        // ---- Terrain pipeline (renders into rgba16Float HDR target) ----------
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction   = lib.makeFunction(name: "vmain")
        desc.fragmentFunction = lib.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        desc.depthAttachmentPixelFormat = .depth32Float
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { fatalError("terrain pipeline failed: \(error)") }

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)

        // ---- Sky pipeline (HDR target, no depth write) -----------------------
        let sdesc = MTLRenderPipelineDescriptor()
        sdesc.vertexFunction   = lib.makeFunction(name: "skyVmain")
        sdesc.fragmentFunction = lib.makeFunction(name: "skyFmain")
        sdesc.colorAttachments[0].pixelFormat = .rgba16Float
        sdesc.depthAttachmentPixelFormat = .depth32Float
        do { skyPipeline = try device.makeRenderPipelineState(descriptor: sdesc) }
        catch { fatalError("sky pipeline failed: \(error)") }

        let sdd = MTLDepthStencilDescriptor()
        sdd.depthCompareFunction = .always
        sdd.isDepthWriteEnabled  = false
        skyDepthState = device.makeDepthStencilState(descriptor: sdd)

        // ---- No-depth state (used by bloom quads too) ------------------------
        let ndd = MTLDepthStencilDescriptor()
        ndd.depthCompareFunction = .always
        ndd.isDepthWriteEnabled  = false
        noDepthState = device.makeDepthStencilState(descriptor: ndd)

        // ---- Underwater post-pass pipeline (HDR target, alpha blend) ---------
        let udesc = MTLRenderPipelineDescriptor()
        udesc.vertexFunction   = lib.makeFunction(name: "underwaterVmain")
        udesc.fragmentFunction = lib.makeFunction(name: "underwaterFmain")
        udesc.colorAttachments[0].pixelFormat = .rgba16Float
        udesc.colorAttachments[0].isBlendingEnabled = true
        udesc.colorAttachments[0].sourceRGBBlendFactor        = .sourceAlpha
        udesc.colorAttachments[0].destinationRGBBlendFactor   = .oneMinusSourceAlpha
        udesc.colorAttachments[0].sourceAlphaBlendFactor      = .one
        udesc.colorAttachments[0].destinationAlphaBlendFactor = .zero
        udesc.depthAttachmentPixelFormat = .depth32Float
        do { underwaterPipeline = try device.makeRenderPipelineState(descriptor: udesc) }
        catch { fatalError("underwater pipeline failed: \(error)") }

        // ---- Water translucency pipeline (alpha blend, depth test, NO depth write) ----
        // Re-draws chunk meshes; fragment discards any fragment whose material != 9 (water).
        // Depth test lessEqual so water surfaces at the right depth blend over the lake bottom.
        let wdesc = MTLRenderPipelineDescriptor()
        wdesc.vertexFunction   = lib.makeFunction(name: "vmain")
        wdesc.fragmentFunction = lib.makeFunction(name: "waterFmain")
        wdesc.colorAttachments[0].pixelFormat = .rgba16Float
        wdesc.colorAttachments[0].isBlendingEnabled = true
        wdesc.colorAttachments[0].sourceRGBBlendFactor        = .sourceAlpha
        wdesc.colorAttachments[0].destinationRGBBlendFactor   = .oneMinusSourceAlpha
        wdesc.colorAttachments[0].sourceAlphaBlendFactor      = .one
        wdesc.colorAttachments[0].destinationAlphaBlendFactor = .zero
        wdesc.depthAttachmentPixelFormat = .depth32Float
        do { waterPipeline = try device.makeRenderPipelineState(descriptor: wdesc) }
        catch { fatalError("water pipeline failed: \(error)") }

        let wdd = MTLDepthStencilDescriptor()
        wdd.depthCompareFunction = .lessEqual
        wdd.isDepthWriteEnabled  = false   // don't write depth — lake bottom must stay visible
        waterDepthState = device.makeDepthStencilState(descriptor: wdd)

        // World-space voxel sun shadows: no shadow-map render pass, so there is no
        // depth-only shadow pipeline. Shadows are marched per-fragment against the
        // engine occupancy 3D texture (see uploadShadowVolume / fmain).

        // ---- Bloom bright-pass (HDR → half-res rgba16Float) ------------------
        let bpd = MTLRenderPipelineDescriptor()
        bpd.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
        bpd.fragmentFunction = lib.makeFunction(name: "bloomBrightFrag")
        bpd.colorAttachments[0].pixelFormat = .rgba16Float
        do { bloomBrightPipeline = try device.makeRenderPipelineState(descriptor: bpd) }
        catch { fatalError("bloom bright pipeline failed: \(error)") }

        // ---- Bloom blur H -------------------------------------------------------
        let bhd = MTLRenderPipelineDescriptor()
        bhd.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
        bhd.fragmentFunction = lib.makeFunction(name: "bloomBlurHFrag")
        bhd.colorAttachments[0].pixelFormat = .rgba16Float
        do { bloomBlurHPipeline = try device.makeRenderPipelineState(descriptor: bhd) }
        catch { fatalError("bloom blurH pipeline failed: \(error)") }

        // ---- Bloom blur V -------------------------------------------------------
        let bvd = MTLRenderPipelineDescriptor()
        bvd.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
        bvd.fragmentFunction = lib.makeFunction(name: "bloomBlurVFrag")
        bvd.colorAttachments[0].pixelFormat = .rgba16Float
        do { bloomBlurVPipeline = try device.makeRenderPipelineState(descriptor: bvd) }
        catch { fatalError("bloom blurV pipeline failed: \(error)") }

        // ---- #167 God-ray pre-pass (radial depth march at low res) -------------
        let grd = MTLRenderPipelineDescriptor()
        grd.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
        grd.fragmentFunction = lib.makeFunction(name: "godrayHalfFrag")
        grd.colorAttachments[0].pixelFormat = .rgba16Float
        do { godrayPipeline = try device.makeRenderPipelineState(descriptor: grd) }
        catch { fatalError("godray pipeline failed: \(error)") }

        // ---- Composite / tonemap (rgba16Float HDR + bloom → drawable bgra8) ---
        let cpd = MTLRenderPipelineDescriptor()
        cpd.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
        cpd.fragmentFunction = lib.makeFunction(name: "compositeFrag")
        cpd.colorAttachments[0].pixelFormat = colorFormat   // drawable bgra8
        do { compositePipeline = try device.makeRenderPipelineState(descriptor: cpd) }
        catch { fatalError("composite pipeline failed: \(error)") }

        // ---- Ambient life (birds / fireflies): alpha-blended billboards --------
        let ald = MTLRenderPipelineDescriptor()
        ald.vertexFunction   = lib.makeFunction(name: "ambientLifeVert")
        ald.fragmentFunction = lib.makeFunction(name: "ambientLifeFrag")
        ald.colorAttachments[0].pixelFormat = .rgba16Float
        ald.colorAttachments[0].isBlendingEnabled             = true
        ald.colorAttachments[0].sourceRGBBlendFactor          = .sourceAlpha
        ald.colorAttachments[0].destinationRGBBlendFactor     = .oneMinusSourceAlpha
        ald.colorAttachments[0].sourceAlphaBlendFactor        = .one
        ald.colorAttachments[0].destinationAlphaBlendFactor   = .oneMinusSourceAlpha
        ald.depthAttachmentPixelFormat = .depth32Float
        do { ambientLifePipeline = try device.makeRenderPipelineState(descriptor: ald) }
        catch { fatalError("ambient life pipeline failed: \(error)") }

        // ---- Sub-voxel props (#51/#52): GPU-instanced toy models ----------------
        let propd = MTLRenderPipelineDescriptor()
        propd.vertexFunction   = lib.makeFunction(name: "propInstVmain")
        propd.fragmentFunction = lib.makeFunction(name: "propFmain")
        propd.colorAttachments[0].pixelFormat = .rgba16Float
        propd.depthAttachmentPixelFormat = .depth32Float
        do { propPipeline = try device.makeRenderPipelineState(descriptor: propd) }
        catch { fatalError("prop pipeline failed: \(error)") }

        // Props no longer need a depth-only shadow pipeline: prop blocks live in the
        // engine occupancy grid (the engine stamps their casting voxels), so they cast
        // world-space shadows without any extra render pass here.

        propModelTable = Renderer.makePropModelTable(device: device)

        // ---- First-person viewmodel (#70): view-space arm, always on top ---------
        let vmd = MTLRenderPipelineDescriptor()
        vmd.vertexFunction   = lib.makeFunction(name: "viewModelVmain")
        vmd.fragmentFunction = lib.makeFunction(name: "viewModelFmain")
        vmd.colorAttachments[0].pixelFormat = .rgba16Float
        vmd.depthAttachmentPixelFormat = .depth32Float
        do { viewModelPipeline = try device.makeRenderPipelineState(descriptor: vmd) }
        catch { fatalError("viewmodel pipeline failed: \(error)") }
        let vmdd = MTLDepthStencilDescriptor()
        vmdd.depthCompareFunction = .always   // draw over the scene; parts ordered back-to-front
        vmdd.isDepthWriteEnabled  = false
        viewModelDepthState = device.makeDepthStencilState(descriptor: vmdd)
        let ap0 = CharacterAppearance.load()                 // #71 own arm reflects your skin/shirt
        charSkin = ap0.skinRGB; charShirt = ap0.shirtRGB
        let arm = makeViewModelArm(skin: charSkin, sleeve: charShirt)
        viewModelArmCount = arm.count
        viewModelArmBuf = device.makeBuffer(bytes: arm, length: arm.count * MemoryLayout<PropCuboidGPU>.stride,
                                            options: .storageModeShared)

        // Ambient life hides behind terrain and structures but never writes depth.
        let aldd = MTLDepthStencilDescriptor()
        aldd.depthCompareFunction = .lessEqual
        aldd.isDepthWriteEnabled  = false
        ambientLifeDepthState = device.makeDepthStencilState(descriptor: aldd)

        // Allocate the CPU-writable sprite buffer (updated every frame)
        ambientLifeBuffer = device.makeBuffer(
            length: kMaxAmbientSprites * MemoryLayout<AmbientSpritePod>.stride,
            options: .storageModeShared)!

        // ---- World-space precipitation pipeline (alpha-blended billboards) -----
        // Rain = thin vertical streaks; snow = small soft flakes. Standard
        // src-alpha / one-minus-src-alpha blend over the scene; depth-tested so
        // particles behind terrain are hidden, but no depth write.
        let ppd = MTLRenderPipelineDescriptor()
        ppd.vertexFunction   = lib.makeFunction(name: "precipVert")
        ppd.fragmentFunction = lib.makeFunction(name: "precipFrag")
        ppd.colorAttachments[0].pixelFormat = .rgba16Float
        ppd.colorAttachments[0].isBlendingEnabled             = true
        ppd.colorAttachments[0].sourceRGBBlendFactor          = .sourceAlpha
        ppd.colorAttachments[0].destinationRGBBlendFactor     = .oneMinusSourceAlpha
        ppd.colorAttachments[0].sourceAlphaBlendFactor        = .one
        ppd.colorAttachments[0].destinationAlphaBlendFactor   = .zero
        ppd.depthAttachmentPixelFormat = .depth32Float
        do { precipPipeline = try device.makeRenderPipelineState(descriptor: ppd) }
        catch { fatalError("precip pipeline failed: \(error)") }

        let ppdd = MTLDepthStencilDescriptor()
        ppdd.depthCompareFunction = .lessEqual
        ppdd.isDepthWriteEnabled  = false   // precipitation never writes depth
        precipDepthState = device.makeDepthStencilState(descriptor: ppdd)

        // Fill the precipitation particle buffer ONCE: each particle gets a stable
        // pseudo-random offset within the unit box [-0.5..0.5]^3 plus a fall phase.
        // The vertex shader animates the world position from these each frame, so no
        // per-frame CPU work and the particles recycle (wrap) entirely on the GPU.
        precipBuffer = device.makeBuffer(
            length: kPrecipCount * MemoryLayout<PrecipParticlePod>.stride,
            options: .storageModeShared)!
        let pptr = precipBuffer.contents().bindMemory(to: PrecipParticlePod.self, capacity: kPrecipCount)
        func h(_ n: UInt32) -> Float {   // cheap deterministic hash → [0,1)
            var v = n &* 0x9E3779B1
            v ^= v >> 16; v = v &* 0x85EBCA6B
            v ^= v >> 13; v = v &* 0xC2B2AE35
            v ^= v >> 16
            return Float(v) / Float(UInt32.max)
        }
        for i in 0..<kPrecipCount {
            let n = UInt32(i)
            pptr[i] = PrecipParticlePod(seed: SIMD4<Float>(
                h(n &* 3 &+ 1) - 0.5,         // x offset in [-0.5, 0.5]
                h(n &* 7 &+ 13) - 0.5,        // y offset in [-0.5, 0.5]
                h(n &* 11 &+ 101) - 0.5,      // z offset in [-0.5, 0.5]
                h(n &* 17 &+ 271)))           // phase 0..1
        }
    }

    // Upload the engine's world occupancy grid into the 3D shadow texture. Pulls
    // bf_world_shadow_volume into a persistent CPU buffer, (re)creates the r8uint
    // 3D texture if the grid dims changed, and re-uploads the bytes only when the
    // engine bumped the revision (so a stationary scene costs one cheap call). The
    // texture + region metadata are then bound by the terrain / water / composite
    // passes. Returns true if a usable occupancy texture is ready.
    @discardableResult
    private func uploadShadowVolume(_ e: bf_engine) -> Bool {
        // Probe call (nil buffer): cheap, returns dims + revision + dirty box, NO 4 MB copy.
        var vol = bf_shadow_volume()
        vol.voxels = nil
        vol.voxel_cap = 0
        _ = bf_world_shadow_volume(e, &vol)
        let dx = Int(vol.dim_x), dy = Int(vol.dim_y), dz = Int(vol.dim_z)
        let need = dx * dy * dz
        if need <= 0 { return false }
        let dimsKnownSame = (shadowVolTex != nil && shadowVolTexDims == (dx, dy, dz))
        // Standing still / nothing changed: textures are current, skip the fill + upload.
        if dimsKnownSame && vol.revision == shadowVolRevision { return true }

        if shadowVolBuf.count < need { shadowVolBuf = [UInt8](repeating: 0, count: need) }
        // v22 (#163): the engine also hands us its incrementally-maintained coarse mip,
        // so the old per-frame buildCoarseRegion fine-grid rescan is gone entirely.
        let CO = Renderer.kShadowCoarse
        let cdx = (dx + CO - 1) / CO, cdy = (dy + CO - 1) / CO, cdz = (dz + CO - 1) / CO
        let cneed = cdx * cdy * cdz
        if shadowVolCoarseBuf.count < cneed {
            shadowVolCoarseBuf = [UInt8](repeating: 0, count: cneed)
        }
        // Fill call: the engine copies the toroidal fine + coarse buffers into our storage.
        let ok: Bool = shadowVolBuf.withUnsafeMutableBufferPointer { p -> Bool in
            vol.voxels = p.baseAddress
            vol.voxel_cap = UInt32(p.count)
            return shadowVolCoarseBuf.withUnsafeMutableBufferPointer { cp -> Bool in
                vol.coarse = cp.baseAddress
                vol.coarse_cap = UInt32(cp.count)
                return bf_world_shadow_volume(e, &vol) == BF_OK
            }
        }
        if !ok { return false }

        shadowVolOrigin = SIMD3<Float>(Float(vol.origin.x), Float(vol.origin.y), Float(vol.origin.z))
        shadowVolDims   = SIMD3<Float>(Float(dx), Float(dy), Float(dz))

        // (Re)create the toroidal 3D textures when the dims change (rare).
        if shadowVolTex == nil || shadowVolTexDims != (dx, dy, dz) {
            func make3D(_ w: Int, _ h: Int, _ d: Int) -> MTLTexture? {
                let td = MTLTextureDescriptor()
                td.textureType = .type3D; td.pixelFormat = .r8Uint
                td.width = w; td.height = h; td.depth = d
                td.usage = [.shaderRead]; td.storageMode = .shared
                return device.makeTexture(descriptor: td)
            }
            shadowVolTex = make3D(dx, dy, dz)
            shadowVolCoarseTex = make3D(cdx, cdy, cdz)
            shadowVolTexDims = (dx, dy, dz)
            shadowVolRevision = .max   // force a full upload into the new textures
        }
        guard let tex = shadowVolTex, let ctex = shadowVolCoarseTex else { return false }

        // Nothing changed since our last upload: keep the textures, skip the GPU work.
        if vol.revision == shadowVolRevision { return true }

        // Collect the dirty boxes the engine reported (a list, to avoid one giant L-shaped
        // bounding box on a diagonal scroll). On the first upload into fresh textures, force
        // the full window.
        let boxes = Renderer.shadowDirtyBoxes(vol, dx: dx, dy: dy, dz: dz,
                                              forceFull: shadowVolRevision == .max)
        for (wlo, whi) in boxes {
            // The engine maintains the coarse mip; we just upload both sub-regions.
            uploadToroidalRegion(tex, ctex, buf: shadowVolBuf, coarseBuf: shadowVolCoarseBuf,
                                 dx: dx, dy: dy, dz: dz, cdx: cdx, cdy: cdy, cdz: cdz, co: CO,
                                 wlo: wlo, whi: whi)
        }
        shadowVolRevision = vol.revision
        return true
    }

    // Decode the engine's dirty-box list (a C fixed array, imported as a Swift tuple) into
    // clamped world-voxel AABBs. forceFull (first upload into fresh textures) returns the
    // whole window regardless of what the engine reported.
    static func shadowDirtyBoxes(_ vol: bf_shadow_volume, dx: Int, dy: Int, dz: Int,
                                 forceFull: Bool) -> [(SIMD3<Int>, SIMD3<Int>)] {
        let ox = Int(vol.origin.x), oy = Int(vol.origin.y), oz = Int(vol.origin.z)
        if forceFull {
            return [(SIMD3<Int>(ox, oy, oz), SIMD3<Int>(ox + dx - 1, oy + dy - 1, oz + dz - 1))]
        }
        var los = vol.dirty_lo, his = vol.dirty_hi
        let nlo = withUnsafeBytes(of: &los) { $0.bindMemory(to: bf_ivec3.self) }
        let nhi = withUnsafeBytes(of: &his) { $0.bindMemory(to: bf_ivec3.self) }
        var out: [(SIMD3<Int>, SIMD3<Int>)] = []
        let n = min(Int(vol.dirty_count), nlo.count)
        for i in 0..<n {
            let lo = SIMD3<Int>(max(Int(nlo[i].x), ox), max(Int(nlo[i].y), oy), max(Int(nlo[i].z), oz))
            let hi = SIMD3<Int>(min(Int(nhi[i].x), ox + dx - 1),
                                min(Int(nhi[i].y), oy + dy - 1),
                                min(Int(nhi[i].z), oz + dz - 1))
            if hi.x >= lo.x && hi.y >= lo.y && hi.z >= lo.z { out.append((lo, hi)) }
        }
        return out
    }

    // Upload a world-voxel AABB [wlo, whi] into the toroidal fine + coarse textures, splitting
    // the box at the wrap seam on x and z (y does not wrap). The buffers are the full toroidal
    // arrays; we copy each wrapped sub-rect with MTLTexture.replace on just that region.
    private func uploadToroidalRegion(_ tex: MTLTexture, _ ctex: MTLTexture,
                                      buf: [UInt8], coarseBuf: [UInt8],
                                      dx: Int, dy: Int, dz: Int,
                                      cdx: Int, cdy: Int, cdz: Int, co: Int,
                                      wlo: SIMD3<Int>, whi: SIMD3<Int>) {
        func wrap(_ v: Int, _ d: Int) -> Int { let m = v % d; return m < 0 ? m + d : m }
        // Build the up-to-2 contiguous cell spans for an axis range [lo,hi] of length n<=dim.
        func spans(_ lo: Int, _ hi: Int, _ dim: Int) -> [(g0: Int, len: Int)] {
            let n = hi - lo + 1
            if n >= dim { return [(0, dim)] }
            let g0 = wrap(lo, dim)
            if g0 + n <= dim { return [(g0, n)] }
            return [(g0, dim - g0), (0, n - (dim - g0))]   // wraps: tail + head
        }
        let xs = spans(wlo.x, whi.x, dx)
        let zs = spans(wlo.z, whi.z, dz)
        let gy0 = wlo.y - Int(shadowVolOrigin.y)          // y does not wrap
        let yh  = whi.y - wlo.y + 1
        // Fine grid: for each (x-span, z-span) rect, replace that sub-volume from the buffer.
        buf.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            for zsp in zs {
                for xsp in xs {
                    let region = MTLRegionMake3D(xsp.g0, gy0, zsp.g0, xsp.len, yh, zsp.len)
                    // Source pointer to the buffer cell (xsp.g0, gy0, zsp.g0); the buffer is
                    // contiguous with bytesPerRow=dx, bytesPerImage=dx*dy, so a sub-rect upload
                    // reads strided directly from it.
                    let off = (zsp.g0 * dy + gy0) * dx + xsp.g0
                    tex.replace(region: region, mipmapLevel: 0, slice: 0,
                                withBytes: base + off, bytesPerRow: dx, bytesPerImage: dx * dy)
                }
            }
        }
        // Coarse grid: the same AABB mapped to coarse cells (floor on lo, ceil on hi).
        let cxs = spans(Int(floor(Double(wlo.x) / Double(co))), Int(floor(Double(whi.x) / Double(co))), cdx)
        let czs = spans(Int(floor(Double(wlo.z) / Double(co))), Int(floor(Double(whi.z) / Double(co))), cdz)
        let cgy0 = (gy0) / co
        let cyh  = (gy0 + yh + co - 1) / co - cgy0
        coarseBuf.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            for zsp in czs {
                for xsp in cxs {
                    let region = MTLRegionMake3D(xsp.g0, cgy0, zsp.g0, xsp.len, cyh, zsp.len)
                    let off = (zsp.g0 * cdy + cgy0) * cdx + xsp.g0
                    ctex.replace(region: region, mipmapLevel: 0, slice: 0,
                                 withBytes: base + off, bytesPerRow: cdx, bytesPerImage: cdx * cdy)
                }
            }
        }
    }

    // ---- Resize: rebuild HDR + bloom textures when drawable size changes -----
    // The HDR scene is rendered at a capped internal resolution so the long edge
    // never exceeds kRenderLongEdge pixels (e.g. 1280 on a 5K Retina display).
    // The ACES composite writes to compositeLowRes (bgra8Unorm at sceneSize), then
    // an MTLFXSpatialScaler upscales it to the full drawable with much higher quality
    // than bilinear. Falls back to bilinear if MetalFX is unavailable.
    private func rebuildHDRTextures(size: CGSize) {
        guard size.width > 0 && size.height > 0 else { return }

        // Compute capped scene size: scale down if the long edge exceeds the cap.
        let longEdge = max(size.width, size.height)
        let scale = longEdge > kRenderLongEdge ? kRenderLongEdge / longEdge : 1.0
        let SW = max(1, Int((size.width  * scale).rounded()))
        let SH = max(1, Int((size.height * scale).rounded()))
        sceneSize = CGSize(width: SW, height: SH)

        let HW = max(1, SW / 2), HH = max(1, SH / 2)
        let DW = max(1, Int(size.width.rounded()))
        let DH = max(1, Int(size.height.rounded()))

        func make2D(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, usage: MTLTextureUsage) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
            td.usage = usage; td.storageMode = .private
            return device.makeTexture(descriptor: td)!
        }

        hdrColor    = make2D(.rgba16Float,  SW,  SH, usage: [.renderTarget, .shaderRead])
        // #119 god rays: the composite volumetric pass raymarches from the camera to the
        // scene depth, so the depth buffer must be readable (shaderRead) and survive the
        // scene pass (store, set on the depth attachment below). Was render-target-only.
        hdrDepth    = make2D(.depth32Float, SW,  SH, usage: [.renderTarget, .shaderRead])
        bloomBright = make2D(.rgba16Float, HW,  HH, usage: [.renderTarget, .shaderRead])
        bloomBlurA  = make2D(.rgba16Float, HW,  HH, usage: [.renderTarget, .shaderRead])
        // #167 god rays march at a fraction of the scene res (kGodRayDownscale); the
        // composite upsamples this depth-aware so shaft edges stay full-res crisp.
        let gds = Int(Renderer.kGodRayDownscale)
        godrayTex   = make2D(.rgba16Float, max(1, SW / gds), max(1, SH / gds),
                             usage: [.renderTarget, .shaderRead])
        currentDrawableSize = size

        // ---- MetalFX spatial upscaler setup ---------------------------------
        // compositeLowRes is the ACES composite output at sceneSize (LDR bgra8Unorm).
        // MetalFX reports the usage flags its input and output require. Its output must
        // use private storage, which a physical iPad CAMetalDrawable does not, so the
        // scaler writes to spatialOutput and a blit copies that image to the drawable.
        metalFXEnabled = false
        compositeLowRes = nil
        spatialOutput = nil
#if canImport(MetalFX)
        if #available(macOS 13.0, iOS 16.0, *) {
            _spatialScaler = nil
            // Only build the scaler when the scene is actually smaller than the drawable
            // (if already 1:1 the spatial scaler would be a no-op but still costs memory).
            let needsUpscale = SW < DW || SH < DH
            if needsUpscale && MTLFXSpatialScalerDescriptor.supportsDevice(device) {
                let scalerDesc = MTLFXSpatialScalerDescriptor()
                scalerDesc.inputWidth           = SW
                scalerDesc.inputHeight          = SH
                scalerDesc.outputWidth          = DW
                scalerDesc.outputHeight         = DH
                // bgra8Unorm: the ACES composite already produces a tone-mapped LDR image,
                // so we use .perceptual colour processing (designed for LDR gamma-correct input).
                scalerDesc.colorTextureFormat   = .bgra8Unorm
                scalerDesc.outputTextureFormat  = .bgra8Unorm
                scalerDesc.colorProcessingMode  = .perceptual

                if let scaler = scalerDesc.makeSpatialScaler(device: device) {
                    _spatialScaler = scaler
                    let inputDesc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .bgra8Unorm, width: SW, height: SH, mipmapped: false)
                    inputDesc.usage = scaler.colorTextureUsage.union(.renderTarget)
                    inputDesc.storageMode = .private
                    compositeLowRes = device.makeTexture(descriptor: inputDesc)

                    let outputDesc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .bgra8Unorm, width: DW, height: DH, mipmapped: false)
                    outputDesc.usage = scaler.outputTextureUsage
                    outputDesc.storageMode = .private
                    spatialOutput = device.makeTexture(descriptor: outputDesc)
                    if compositeLowRes != nil && spatialOutput != nil {
                        metalFXEnabled = true
                    }
                }
            }
        }
#endif
    }

    // MARK: Engine create

    private func createEngine() {
        var cfg = bf_engine_config()
        cfg.abi_version = BF_ABI_VERSION
        cfg.role = BF_ROLE_SINGLEPLAYER
        cfg.start_mode = BF_MODE_SURVIVAL
        // #85 streaming radius (chunks), persisted + adjustable via the pause-menu slider.
        #if os(iOS)
        let defaultRenderDistance = 16
        let memoryBudget: UInt64 = 3 * 1024 * 1024 * 1024
        #else
        let defaultRenderDistance = 24
        let memoryBudget: UInt64 = 10 * 1024 * 1024 * 1024
        #endif
        let rd = UserDefaults.standard.object(forKey: "gfxRenderDist") as? Int ?? defaultRenderDistance
        cfg.render_distance_chunks = UInt32(max(8, min(40, rd)))
        cfg.memory_budget_bytes = memoryBudget
        // Content is bundled at Resources/content (build.sh copies it there).
        // The registry loads <dir>/blocks, <dir>/items, … so point at that folder,
        // not Resources itself — otherwise NO blocks/items/recipes load and there
        // are no drops, starter items, or recipes.
        let resDir = Bundle.main.resourcePath ?? "."
        let contentDir = FileManager.default.fileExists(atPath: resDir + "/content/blocks")
            ? resDir + "/content" : resDir
        cfg.content_dir = persistentCString(contentDir)
        cfg.save_dir = persistentCString(saveDir)
        cfg.player_name = persistentCString("kid")
        var err = BF_OK
        engine = bf_engine_create(&cfg, &err)
        guard let e = engine, err == BF_OK else {
            fatalError("engine create failed: \(String(cString: bf_last_error_global()))")
        }
        var appearance = CharacterAppearance.load().engineValue
        _ = bf_player_appearance_set(e, &appearance)
        var alloc = bf_gpu_allocator()
        alloc.user = Unmanaged.passUnretained(registry).toOpaque()
        alloc.alloc = allocTrampoline
        alloc.free_ = freeTrampoline
        _ = bf_set_gpu_allocator(e, &alloc)
        bf_set_event_callback(e, eventTrampoline, Unmanaged.passUnretained(self).toOpaque())
        // A brand-new world starts fresh (ignore any stale save in this folder);
        // an existing world loads its save.
        if freshWorld {
            _ = bf_world_new(e, worldSeed)
            _ = bf_world_save(e)          // write an initial save so the world persists immediately
        } else {
            _ = bf_world_load(e)
        }
        // #238: difficulty is engine-runtime-only; re-apply this world's saved pick.
        bf_set_difficulty(e, difficulty)
    }

    // #238 difficulty (0 easy = no bad guys, 1 normal, 2 hard), persisted PER
    // WORLD so a kid's gentle world stays gentle while a sibling's world is hard.
    private var difficultyKey: String { "difficulty." + (saveDir as NSString).lastPathComponent }
    var difficulty: Int32 {
        Int32(UserDefaults.standard.object(forKey: difficultyKey) as? Int ?? 1)
    }
    func setDifficulty(_ d: Int32) {
        UserDefaults.standard.set(Int(d), forKey: difficultyKey)
        if let e = engine { bf_set_difficulty(e, d) }
    }

    private let discovery = NetDiscovery()
    private let coopPort: Int32 = 27355

    func startHost() {
        guard let e = engine else { return }
        _ = bf_net_host_start(e, UInt16(coopPort))
        discovery.publish(port: coopPort)
    }
    func joinLAN() {
        discovery.onHostFound = { [weak self] ip, port in
            DispatchQueue.main.async {
                guard let self = self, let e = self.engine else { return }
                ip.withCString { _ = bf_net_client_connect(e, $0, port) }
                NSLog("Blockfall: joining \(ip):\(port)")
            }
        }
        discovery.browse()
    }

    var onDialogue: ((Int) -> Void)?   // #82 villager dialogue hook (npc_id), wired by the app
    func handleEvent(_ ev: bf_event) {
        guard ev.kind == BF_EVT_SFX else { return }
        switch ev.i {
        case 0:                                    // packed: (blockId<<4 | soundClass)
            let packed = Int(ev.j)
            audio?.playBreak(materialClass: packed & 0xF)
            spawnBreakParticles(ev.pos, blockId: packed >> 4)
            ambientBirdSystem.disturb(at: SIMD3<Float>(Float(ev.pos.x), Float(ev.pos.y), Float(ev.pos.z)))
        case 1:
            audio?.play(.place)
            ambientBirdSystem.disturb(at: SIMD3<Float>(Float(ev.pos.x), Float(ev.pos.y), Float(ev.pos.z)))
        case 2: audio?.playStep(Int(ev.j))   // ev.j = terrain class (soft/hard/sand/snow/wood)
        case 3: audio?.play(.jump)
        case 4: audio?.play(.craft)
        case 5: audio?.play(.befriend)
        case 6: audio?.play(.questComplete)
        case 7: audio?.play(.pickup)
        case 8:
            audio?.play(.mine)             // melee hit on a creature
            ambientBirdSystem.disturb(at: SIMD3<Float>(Float(ev.pos.x), Float(ev.pos.y), Float(ev.pos.z)))
        case 9: audio?.play(.hurt)         // player took damage
        case 20: onDialogue?(Int(ev.j))    // #82 right-clicked a villager: open dialogue (npc_id = j)
        default: break
        }
    }

    func spawnBreakParticles(_ pos: bf_ivec3, blockId: Int = 0) { particles.spawn(at: pos, blockId: blockId) }

    /// Write an explicit checkpoint without tearing down the renderer. iPadOS
    /// calls this before the scene becomes inactive because the process may be
    /// suspended without receiving a later termination callback.
    @discardableResult
    func saveWorld() -> Bool {
        guard let e = engine else { return false }
        let result = bf_world_save(e)
        if result != BF_OK {
            NSLog("Blockfall: world checkpoint failed (%d)", result.rawValue)
        }
        return result == BF_OK
    }

    func shutdown() {
        guard let e = engine else { return }
        engine = nil   // stop draw(in:) from touching the engine from here on
        // The frame loop only waitUntilScheduled()s before present, so the GPU may
        // still be reading chunk mesh buffers that bf_engine_destroy is about to
        // free. Fence on a fresh command buffer to ensure all submitted work has
        // completed before we free those buffers (prevents a GPU use-after-free
        // when quitting to the menu mid-frame).
        let fence = queue.makeCommandBuffer()
        fence?.commit(); fence?.waitUntilCompleted()
        _ = bf_world_save(e)
        bf_engine_destroy(e)
    }
    deinit { shutdown() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildHDRTextures(size: size)
    }

    // MARK: Draw

    func draw(in view: MTKView) {
        guard let e = engine,
              let drawable = view.currentDrawable else { return }

        let now = CACurrentMediaTime()
        let dt = now - lastTime; lastTime = now
        frameCounter += 1
        perfLogFrames += 1
        registry.currentFrame = frameCounter
        registry.collect()

        // Lazy texture init / resize check
        // The drawable is authoritative. During rotation, view.drawableSize can briefly
        // describe the next drawable while currentDrawable still has the prior size.
        let dSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        if currentDrawableSize != dSize { rebuildHDRTextures(size: dSize) }
        guard let hdrColor = hdrColor, let hdrDepth = hdrDepth,
              let bloomBright = bloomBright, let bloomBlurA = bloomBlurA else { return }

        // 1) input -> engine
        var input = gameView?.makeFrameInput() ?? bf_frame_input()
        // #77 world pause: when you are alone and the pause menu is up, freeze the sim by
        // ticking with dt = 0 (creatures, day/night, physics all hold). In multiplayer
        // (any peer connected) never pause the shared world, so dt stays real.
        let worldPaused = (gameView?.worldIsPaused ?? false) && bf_net_peer_count(e) == 0
        _ = bf_frame_begin(e, &input, worldPaused ? 0.0 : dt)
        // #127 advance the cosmetic animation clock only while NOT paused, so grass sway,
        // creature/leaf wiggle, pollen, ambient sprites, and precipitation all freeze on
        // pause and resume from the same value on unpause (no jump). It tracks the same
        // dt = 0 hold the engine clock uses, so the render-side motion and the sun stop
        // together. Always advance when a peer is connected (multiplayer never pauses).
        if !worldPaused { animClock += dt }
        if let actions = gameView?.drainActions() {
            for var a in actions {
                // #: trigger a tool swing on mine/place/attack (continuous mining is
                // handled separately via mine_progress in the viewmodel draw).
                if a.kind == BF_ACT_MINE_START || a.kind == BF_ACT_PLACE
                   || a.kind == BF_ACT_ATTACK || a.kind == BF_ACT_INTERACT {
                    swingPulse = now
                }
                bf_input_action(e, &a)
            }
        }

        // #109 apply any chest moves requested by HUD clicks this frame. The engine
        // resolves the chest position from its own open-chest state (set by INTERACT);
        // we use the last polled position. Items are never destroyed: a full inventory
        // leaves the stack in the chest (engine-side). Done before acquire so the panel
        // reflects the change on the same frame.
        if !pendingChestMoves.isEmpty, let cpos = openChestPos {
            for mv in pendingChestMoves {
                if mv.take {
                    _ = bf_chest_take(e, cpos, UInt32(mv.slot))
                } else {
                    _ = bf_chest_deposit(e, cpos, UInt32(mv.slot))
                }
            }
        }
        pendingChestMoves.removeAll(keepingCapacity: true)

        // 2) acquire render
        var frame = bf_render_frame()
        _ = bf_frame_acquire_render(e, &frame)
        var entityRoles = bf_entity_role_action_view()
        _ = bf_entity_role_actions(e, &entityRoles)
        var entityAppearances = bf_entity_appearance_view()
        _ = bf_entity_appearances(e, &entityAppearances)

        // Snapshot the buffer registry AFTER acquire: this frame's update/remesh
        // (inside frame_begin/acquire) may have allocated brand-new mesh buffers,
        // and the draw list references them. Snapshotting earlier missed those, so
        // a just-remeshed chunk wasn't drawn for a frame — flashing holes that let
        // you see the caves below, especially while chunks stream/light settles.
        let bufs = registry.snapshot()

        // #135 first-load readiness: while the spawn neighbourhood is meshing and
        // uploading the loop runs at 1-2 fps and few chunk draws are resident. Treat
        // the world as "ready to play" once enough chunk draws are on the GPU AND the
        // frame loop has held a healthy frame time for a short run. Latches once and
        // fires onReady so the app can lift the loading overlay. Costs a couple of
        // comparisons per frame and nothing after it latches.
        if !isWorldReady {
            let residentDraws = Int(frame.draw_count)
            loadProgress = min(1.0, Float(residentDraws) / Float(kReadyChunkDraws))
            if let cb = onLoadProgress { DispatchQueue.main.async { cb() } }
            // dt on the very first frame is ~0 (lastTime seeded at init); only count
            // real frames toward the healthy run.
            if dt > 0 && dt <= kHealthyFrameSecs && residentDraws >= kReadyChunkDraws {
                healthyFrameRun += 1
            } else {
                healthyFrameRun = 0
            }
            let fallbackReady = now - loadStartedAt >= kReadyFallbackSecs && residentDraws >= kReadyFallbackChunkDraws
            if healthyFrameRun >= kReadyHealthyFrames || fallbackReady {
                isWorldReady = true
                loadProgress = 1.0
                NSLog("[Blockfall #135/#159] world ready: %d chunk draws resident, %d healthy frames, fallback=%d (frame %d) — hiding loading overlay",
                      residentDraws, healthyFrameRun, fallbackReady ? 1 : 0, frameCounter)
                let cb = onReady
                DispatchQueue.main.async { cb?() }
            }
        }

        // 3) camera matrices
        let aspect = Float(dSize.width / max(1, dSize.height))
        let fovy: Float = 1.20
        let proj  = Renderer.perspective(fovy: fovy, aspect: aspect, near: 0.05, far: 512)
        let viewM = Renderer.mat(frame.camera.view)
        let viewProj = proj * viewM
        let sun = frame.camera.sun_dir

        // #127 cosmetic animation time. Was `now` (CACurrentMediaTime) which kept ticking
        // through a pause; now sourced from animClock, which only advances while unpaused, so
        // all wallClock-driven motion (sway / wiggle / pollen / sprites / precip) holds still
        // while paused and resumes without a jump. Wrapped to keep the float precise.
        let wallClock = Float(animClock.truncatingRemainder(dividingBy: 3600.0))
        let isUnderwater = frame.camera.underwater

        // Feed the HUD the player's world position + facing so it can show
        // coordinates. facing = heading angle (radians) from forward.x/forward.z.
        hud?.setPlayerInfo(x: frame.camera.position.x,
                           y: frame.camera.position.y,
                           z: frame.camera.position.z,
                           facing: atan2(frame.camera.forward.x, frame.camera.forward.z))
        // #182 world map: remember where the player is (map centring on open).
        lastPlayerX = frame.camera.position.x
        lastPlayerZ = frame.camera.position.z
        lastPlayerFacing = atan2(frame.camera.forward.x, frame.camera.forward.z)

        // Feed the HUD the time of day for a day/night indicator (HUDView method
        // added by another agent; guarded so it's a no-op until then).
        hud?.setTimeOfDay(Renderer.clockPhase(frame.camera.time_of_day))

        // #42: when the quest log overlay is open, fetch the FULL quest chain
        // from the engine and forward it to the HUD. Done only while open so the
        // closed-log path stays free of the extra ABI call. This is the only
        // Renderer touchpoint for the quest log — fetch + forward, nothing more.
        if let hud = hud, hud.isQuestLogOpen {
            let cap = 32
            var buf = [bf_quest_entry](repeating: bf_quest_entry(), count: cap)
            let total = Int(bf_quest_list(e, &buf, UInt32(cap)))
            let count = min(total, cap)
            var rows: [HUDView.QuestRow] = []
            rows.reserveCapacity(count)
            for i in 0..<count {
                let title = withUnsafeBytes(of: buf[i].title) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
                }
                let objective = withUnsafeBytes(of: buf[i].objective) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
                }
                rows.append(HUDView.QuestRow(title: title, objective: objective,
                                             state: buf[i].state, progress: buf[i].progress))
            }
            hud.setQuests(rows)
        }

        // Weather is engine-owned: frame.camera.weather packs precip mode (integer
        // part: 0=clear, 1=rain, 2=snow) + cloud coverage (fraction, #162). Coverage
        // drives how much sky the #146 cloud layer fills. BF_WEATHER/BF_CLOUDCOVER
        // override for headless shots (decodeWeather applies them).
        let (engineWeather, cloudCover) = Renderer.decodeWeather(frame.camera.weather)
        let rainStrength: Float = (engineWeather == 1) ? 1.0 : 0.0
        let weatherPack = Renderer.packWeather(precip: engineWeather, cover: cloudCover)

        // Wind uniforms (index 3 on vertex shaders — new dedicated buffer)
        var windU = WindUniforms(wallClockSecs: wallClock, rainStrength: rainStrength,
                                 swayScale: gfxFoliage ? 1 : 0)   // #: foliage toggle

        // Camera basis for sky dome
        let camRight = SIMD3<Float>(viewM.columns.0.x, viewM.columns.1.x, viewM.columns.2.x)
        let camUp    = SIMD3<Float>(viewM.columns.0.y, viewM.columns.1.y, viewM.columns.2.y)
        let camFwd   = SIMD3<Float>(-viewM.columns.0.z, -viewM.columns.1.z, -viewM.columns.2.z)
        let tanHalfFov = tan(fovy * 0.5)

        let vt = viewM.columns.3
        // #183: camera of a world-to-view [R | t] is -(R transpose * t), i.e. a dot
        // with each rotation COLUMN. The old form used rows, i.e. -(R * t), which is
        // only exact near the coordinate origin; in the near-seam frames the torus
        // (#179) emits (coords up to ~32768) it was hundreds of blocks off, feeding
        // bad camera positions to distance fog, water shading, the compass, ambient
        // life, and the lens-flare gate.
        let camPosW = SIMD4<Float>(
            -(viewM.columns.0.x * vt.x + viewM.columns.0.y * vt.y + viewM.columns.0.z * vt.z),
            -(viewM.columns.1.x * vt.x + viewM.columns.1.y * vt.y + viewM.columns.1.z * vt.z),
            -(viewM.columns.2.x * vt.x + viewM.columns.2.y * vt.y + viewM.columns.2.z * vt.z),
            0)

        // #180/#286: use the engine's authoritative camera position directly.
        // Recovering it by inverting an absolute ~32K float matrix is itself
        // ill-conditioned during yaw—the exact failure camera-relative projection
        // exists to avoid. The engine builds `view` from this same ABI position.
        let cameraWorld = SIMD3<Float>(frame.camera.position.x,
                                       frame.camera.position.y,
                                       frame.camera.position.z)
        let horizonCamH = SIMD4<Float>(cameraWorld.x, cameraWorld.y, cameraWorld.z, 1)
        windU.camPosH = horizonCamH
        // #286: terrain furnishings and GPU props contain details as small as
        // 1/16 block (and smaller interpenetration offsets). Projecting their
        // absolute ~32K torus coordinates makes those details compete with fp32
        // rounding as the view rotates. Match the proven entity path (#192):
        // remove the camera before local detail is added, then project with a VP
        // whose input space is camera-relative. Absolute world positions remain
        // available in the shaders for wind, fog, materials and voxel shadows.
        let viewProjRel = Renderer.cameraRelativeViewProj(projection: proj, view: viewM)

        // ---- #13: Multiplayer compass — find other connected players --------
        // Scan the render frame for remote-player entities (kind == 100) and,
        // for each, work out an on-screen marker point or an off-screen edge
        // arrow direction + distance + the peer's tint colour, then push the
        // list to the HUD which draws the compass. Pure read + forward; touches
        // no Metal pipeline / frame-lifecycle state. The HUD overlay is laid out
        // in the GameView's POINT space (it shares the MTKView frame), so we
        // project NDC into points using the view's bounds size, not the (Retina)
        // drawable pixel size.
        if let hud = hud {
            buildPeerCompass(hud: hud, frame: frame, viewProj: viewProj,
                             camPos: SIMD3<Float>(frame.camera.position.x,
                                                  frame.camera.position.y,
                                                  frame.camera.position.z),
                             camFwd: camFwd, camRight: camRight, camUp: camUp)
        }

        // 4) World-space voxel sun shadows: pull the engine occupancy grid into the
        //    3D shadow texture. Cheap when nothing changed (the engine only bumps the
        //    revision on a real change, and we re-upload only then). This REPLACES the
        //    old shadow-map cascade render pass entirely.
        let haveShadowVol = gfxShadows ? uploadShadowVolume(e) : false

        // Must release the acquired frame even on this early-out, or `borrowed`
        // sticks true and every later acquire returns the same frame forever.
        guard let cmd = queue.makeCommandBuffer() else { bf_frame_end(e); return }
        // currentDrawable normally limits the layer to three outstanding presents, but
        // it is not a lifetime fence across drawable reconfiguration. Make the three-slot
        // dynamic-buffer contract explicit and release a slot only on GPU completion.
        inFlightSemaphore.wait()

        // PASS 1 (the camera-following shadow-map cascade render) is RETIRED. World-space
        // voxel shadows need no shadow geometry pass: the occupancy 3D texture was uploaded
        // above (uploadShadowVolume) and each fragment marches it toward the sun. Trees and
        // structures cast because their voxels live in the engine occupancy grid.

        // Per-fragment voxel-shadow uniform fields shared by terrain + water + composite.
        // voxOrigin.xyz = grid origin (world block coords), voxOrigin.w = march distance.
        // voxDims.xyz   = grid dims (voxels),               voxDims.w   = soft-shadow flag.
        // When the grid is not ready (haveShadowVol == false) the shadow toggle reads 0 so
        // fmain skips the march cleanly (fully lit).
        let voxOriginU = SIMD4<Float>(shadowVolOrigin.x, shadowVolOrigin.y, shadowVolOrigin.z,
                                      Renderer.kShadowMarchDist)
        let voxDimsU   = SIMD4<Float>(shadowVolDims.x, shadowVolDims.y, shadowVolDims.z,
                                      gfxSoftShadows ? 1 : 0)
        let shadowOn: Float = (gfxShadows && haveShadowVol) ? 1 : 0

        // Shadows are marched directly per fragment in the terrain pass (fmain) against the
        // occupancy 3D textures bound below. The march distance (voxOrigin.w) is THE perf knob.

        // =====================================================================
        // PASS 2: Main scene → HDR colour texture (rgba16Float)
        //   Sub-passes: sky, terrain, entities, particles, underwater
        // =====================================================================
        let sky = skyColor(Renderer.clockPhase(frame.camera.time_of_day))
        let hdrRP = MTLRenderPassDescriptor()
        hdrRP.colorAttachments[0].texture     = hdrColor
        hdrRP.colorAttachments[0].loadAction  = .clear
        hdrRP.colorAttachments[0].storeAction = .store
        hdrRP.colorAttachments[0].clearColor  = MTLClearColor(red: sky.0, green: sky.1, blue: sky.2, alpha: 1)
        hdrRP.depthAttachment.texture         = hdrDepth
        hdrRP.depthAttachment.loadAction      = .clear
        // #119 god rays: keep the depth buffer so the composite volumetric pass can read it.
        hdrRP.depthAttachment.storeAction     = .store
        hdrRP.depthAttachment.clearDepth      = 1.0

        if let enc = cmd.makeRenderCommandEncoder(descriptor: hdrRP) {

            // --- Sky pass ---
            if skyPipeline != nil {
                enc.setRenderPipelineState(skyPipeline)
                enc.setDepthStencilState(skyDepthState)
                enc.setCullMode(.none)
                var su = SkyUniforms(
                    sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                    camRight:   SIMD4<Float>(camRight.x, camRight.y, camRight.z, tanHalfFov),
                    camUp:      SIMD4<Float>(camUp.x,    camUp.y,    camUp.z,    aspect),
                    camFwd:     SIMD4<Float>(camFwd.x,   camFwd.y,   camFwd.z,   frame.camera.underground))
                enc.setVertexBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                enc.setFragmentBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                var wuSky = WaterUniforms(wallClockSecs: wallClock, underwater: isUnderwater,
                                          cameraPosW: camPosW)
                let ug = max(0, min(1, (frame.camera.underground - 0.05) / 0.40))
                let undergroundCloudFade = 1 - ug * ug * (3 - 2 * ug)
                wuSky.cloudsOn = gfxClouds ? undergroundCloudFade : 0   // #47 volumetric cloud toggle (sky pass)
                wuSky.weatherPack = weatherPack   // #162 coverage + precip drive the sky
                enc.setFragmentBytes(&wuSky, length: MemoryLayout<WaterUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

            // --- Terrain pass ---
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            enc.setCullMode(.back)
            enc.setFrontFacing(.counterClockwise)

            var wu = WaterUniforms(wallClockSecs: wallClock, underwater: isUnderwater,
                                   reflectScale: gfxWater ? 1 : 0,      // #: water-reflection toggle
                                   shadowScale:  shadowOn,              // #: world-shadow toggle (0 = off / grid not ready)
                                   cameraPosW: camPosW,
                                   sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day))
            wu.cameraPosW.w = kShadowFarR
            wu.celShade = gfxCelShade ? 1 : 0   // #130 toon-band the diffuse term in fmain
            wu.pbrStr   = gfxPBRStr             // #47 stylized PBR specular strength (terrain)
            wu.voxOrigin = voxOriginU           // world-space voxel sun-shadow grid
            wu.voxDims   = voxDimsU
            wu.weatherPack = weatherPack        // #162 water reflection mirrors the weather sky
            enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
            if let occ = shadowVolTex { enc.setFragmentTexture(occ, index: 0) }  // world occupancy grid (fine)
            if let occc = shadowVolCoarseTex { enc.setFragmentTexture(occc, index: 1) }  // coarse mip (empty-space skip)
            // Wind/weather available to terrain frag at index 3 (rain wet-darkening)
            enc.setFragmentBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 3)
            // Wind uniforms to terrain vertex shader at index 3 (foliage sway)
            enc.setVertexBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 3)

            for i in 0..<Int(frame.draw_count) {
                let d = frame.draws[i]
                guard d.index_count > 0,
                      let vbuf = bufs[d.vertex_buffer],
                      let ibuf = bufs[d.index_buffer] else { continue }
                var u = Uniforms(
                    viewProj:      viewProjRel,
                    chunkOrigin:   SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                    sunDirTime:    SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                    lightViewProj: matrix_identity_float4x4,
                    dimSatN:       SIMD4<Float>(d.dim_sat_px, d.dim_sat_pz, d.dim_sat_pxz, Float(d.material_id & 1)))
                enc.setVertexBuffer(vbuf, offset: Int(d.vertex_offset), index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                          indexType: .uint32, indexBuffer: ibuf,
                                          indexBufferOffset: Int(d.index_offset))
            }

            // --- Sub-voxel props (#52: GPU-instanced) — upload the tiny instance
            //     list and let the GPU expand the models. No per-frame CPU rebuild. ---
            let propN = Int(frame.prop_instance_count)
            if propN > 0, let insts = frame.prop_instances {
                for i in propDrawBuckets.indices {
                    propDrawBuckets[i].removeAll(keepingCapacity: true)
                }
                var batchedPropN = 0
                for i in 0..<propN {
                    let inst = insts[i]
                    let row = Renderer.propRow(for: inst.type)
                    if row >= 0 {
                        propDrawBuckets[row].append(inst)
                        batchedPropN += 1
                    }
                }
                let stride = MemoryLayout<bf_prop_instance>.stride
                let need = batchedPropN * stride
                let propBufferSlot = Renderer.propInstanceBufferSlot(for: frameCounter)
                if propInstanceBuffers[propBufferSlot] == nil
                    || propInstanceBuffers[propBufferSlot]!.length < need {
                    propInstanceBuffers[propBufferSlot] = device.makeBuffer(
                        length: max(need, 64 * 1024), options: .storageModeShared)
                }
                if let ib = propInstanceBuffers[propBufferSlot], batchedPropN > 0 {
                    let dayBright = 0.30 + 0.70 * Renderer.dayLight(frame.camera.time_of_day)
                    let pu2 = PropUniforms(viewProj: viewProjRel,
                                           params: SIMD4<Float>(dayBright, wallClock, gfxFoliage ? 1 : 0, 0),
                                           camPosH: horizonCamH)   // #180 horizon curvature
                    enc.setRenderPipelineState(propPipeline)
                    enc.setDepthStencilState(depthState)
                    enc.setCullMode(.none)   // small opaque cuboids; skip winding concerns
                    enc.setVertexBuffer(propModelTable, offset: 0, index: 2)
                    var offsetBytes = 0
                    for row in 0..<Renderer.propRowCount {
                        let bucket = propDrawBuckets[row]
                        if bucket.isEmpty { continue }
                        _ = bucket.withUnsafeBytes { raw in
                            memcpy(ib.contents().advanced(by: offsetBytes), raw.baseAddress!, raw.count)
                        }
                        enc.setVertexBuffer(ib, offset: offsetBytes, index: 0)
                        var rowPu = pu2
                        rowPu.params.w = Float(Renderer.propRowVertsPerShape[row])
                        enc.setVertexBytes(&rowPu, length: MemoryLayout<PropUniforms>.stride, index: 1)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0,
                                           vertexCount: Renderer.propRowVertexCounts[row],
                                           instanceCount: bucket.count)
                        offsetBytes += bucket.count * stride
                    }
                }
            }

            // Entities + particles
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            // #116 character shadows: entities both RECEIVE the world voxel sun shadow and CAST a
            // cheap stylized ground blob. Gate on gfxCharShadows AND the shared world-shadow toggle
            // (shadowOn already folds in gfxShadows + grid-ready); pass the same voxel grid uniforms
            // + occupancy textures the terrain marches, so a creature's shade matches the ground.
            let es = EntityShadowUniforms(
                sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                voxOrigin:  voxOriginU,
                voxDims:    voxDimsU,
                params:     SIMD4<Float>((gfxCharShadows && shadowOn > 0.5) ? 1 : 0, 0, 0, 0))
            entityRenderer.encode(enc, viewProj: viewProj, entities: frame.entities,
                                  count: Int(frame.entity_count), shadow: es,
                                  occ: shadowVolTex, occCoarse: shadowVolCoarseTex,
                                  camPosH: horizonCamH,
                                  roleActions: entityRoles.entries,
                                  roleActionCount: Int(entityRoles.count),
                                  appearances: entityAppearances.entries,
                                  appearanceCount: Int(entityAppearances.count))
            particles.update(Float(dt))
            particles.encode(enc, viewProj: viewProj)

            // --- Ambient life: birds (day) + fireflies (night) ---
            let spriteCount = updateAmbientSprites(
                deltaTime: worldPaused ? 0 : Float(dt),
                wallClock: wallClock,
                timeOfDay: frame.camera.time_of_day,
                camPos: SIMD3<Float>(camPosW.x, camPosW.y, camPosW.z),
                birdsVisible: isUnderwater < 0.5,
                entities: frame.entities,
                entityCount: Int(frame.entity_count),
                greyAmt: max(0, 1 - frame.camera.local_sat))   // #: Grey ash density
            if spriteCount > 0 {
                enc.setRenderPipelineState(ambientLifePipeline)
                enc.setDepthStencilState(ambientLifeDepthState)
                enc.setCullMode(.none)
                var alU = AmbientLifeUniforms(
                    viewProj:   viewProj,
                    camPosW:    camPosW,
                    timeOfDay:  frame.camera.time_of_day,
                    wallClock:  wallClock,
                    horizonOn:  1,   // #180 birds/fireflies bend with the terrain
                    aspect:     Float(view.drawableSize.width / max(view.drawableSize.height, 1)))
                enc.setVertexBuffer(ambientLifeBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&alU, length: MemoryLayout<AmbientLifeUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: spriteCount * 6)
            }

            // --- Water translucency pass ---
            // Re-draw chunk meshes with the water pipeline: the fragment shader discards
            // all material IDs except 9 (water) and outputs alpha 0.55 so the lake
            // bottom (already in the colour buffer from the opaque terrain pass) shows
            // through. Depth write is OFF; depth test is lessEqual so only actual water
            // surface fragments are drawn (terrain below is already at lesser depth).
            enc.setRenderPipelineState(waterPipeline)
            enc.setDepthStencilState(waterDepthState)
            enc.setCullMode(.none)   // water seen from below should also be translucent
            enc.setFrontFacing(.counterClockwise)
            // Reuse the same WaterUniforms / occupancy / wind bindings already set above
            enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
            if let occ = shadowVolTex { enc.setFragmentTexture(occ, index: 0) }  // world occupancy grid (fine)
            if let occc = shadowVolCoarseTex { enc.setFragmentTexture(occc, index: 1) }  // coarse mip (empty-space skip)
            enc.setFragmentBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 3)
            enc.setVertexBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 3)
            for i in 0..<Int(frame.draw_count) {
                let d = frame.draws[i]
                guard (d.material_id & 2) != 0,
                      d.index_count > 0,
                      let vbuf = bufs[d.vertex_buffer],
                      let ibuf = bufs[d.index_buffer] else { continue }
                var u = Uniforms(
                    viewProj:      viewProjRel,
                    chunkOrigin:   SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                    sunDirTime:    SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                    lightViewProj: matrix_identity_float4x4,
                    dimSatN:       SIMD4<Float>(d.dim_sat_px, d.dim_sat_pz, d.dim_sat_pxz, Float(d.material_id & 1)))
                enc.setVertexBuffer(vbuf, offset: Int(d.vertex_offset), index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                          indexType: .uint32, indexBuffer: ibuf,
                                          indexBufferOffset: Int(d.index_offset))
            }

            // --- First-person viewmodel (#70): the arm + equipped item, over the scene ---
            if viewModelArmCount > 0 {
                enc.setRenderPipelineState(viewModelPipeline)
                enc.setDepthStencilState(viewModelDepthState)
                enc.setCullMode(.none)
                let dayB = 0.30 + 0.70 * Renderer.dayLight(frame.camera.time_of_day)
                // #: tool swing — repeated goofy chops while mining (mine_progress > 0),
                // one chop per discrete mine/place/attack. -1 = idle (no swing).
                let swingPhase: Float
                if frame.hud.mine_progress > 0.0 {
                    swingPhase = Float(fmod(now * 2.4, 1.0))
                } else if (now - swingPulse) < 0.35 {
                    swingPhase = Float((now - swingPulse) / 0.35)
                } else {
                    swingPhase = -1.0
                }
                var vmU = ViewModelUniforms(proj: proj, params: SIMD4<Float>(
                    sin(wallClock * 1.6) * 0.006, sin(wallClock * 3.1) * 0.006, dayB, swingPhase))
                enc.setVertexBytes(&vmU, length: MemoryLayout<ViewModelUniforms>.stride, index: 1)
                enc.setVertexBuffer(viewModelArmBuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: viewModelArmCount * 36)

                // #70 v2: the equipped item in the fist (from the HUD in the frame).
                let sel = Int(frame.hud.selected_slot)
                var heldId = 0
                withUnsafePointer(to: frame.hud.hotbar) { p in
                    p.withMemoryRebound(to: bf_hud_slot.self, capacity: 9) { slots in
                        if sel >= 0 && sel < 9 { heldId = Int(slots[sel].item) }
                    }
                }
                if heldId != lastHeldItem {
                    lastHeldItem = heldId
                    let model = makeHeldItem(heldId)
                    heldItemCount = model.count
                    heldItemBuf = model.isEmpty ? nil : device.makeBuffer(
                        bytes: model, length: model.count * MemoryLayout<PropCuboidGPU>.stride, options: .storageModeShared)
                }
                if let hb = heldItemBuf, heldItemCount > 0 {
                    enc.setVertexBuffer(hb, offset: 0, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: heldItemCount * 36)
                }
            }

            // --- World-space precipitation (rain / snow) ---
            // Environmental falling particles in a volume around the camera. Driven
            // by engine weather (0=clear, 1=rain, 2=snow). Drawn after terrain+water
            // so it layers over the scene; depth-tested (lessEqual, no write) so
            // particles behind solid terrain are correctly hidden. Skipped entirely
            // when clear or when underwater (no rain underwater).
            if engineWeather != 0 && isUnderwater <= 0.5 {
                enc.setRenderPipelineState(precipPipeline)
                enc.setDepthStencilState(precipDepthState)
                enc.setCullMode(.none)
                var prU = PrecipUniforms(
                    viewProj:  viewProj,
                    camPosW:   camPosW,
                    wallClock: wallClock,
                    mode:      Float(engineWeather),   // 1=rain, 2=snow
                    boxSize:   kPrecipBox,
                    pad0:      0)
                enc.setVertexBuffer(precipBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&prU, length: MemoryLayout<PrecipUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: kPrecipCount * 6)
            }

            // --- Underwater post-pass ---
            if isUnderwater > 0.01 {
                enc.setRenderPipelineState(underwaterPipeline)
                enc.setDepthStencilState(skyDepthState)
                enc.setCullMode(.none)
                var wuPost = WaterUniforms(wallClockSecs: wallClock, underwater: isUnderwater,
                                           cameraPosW: camPosW)
                enc.setVertexBytes(&wuPost, length: MemoryLayout<WaterUniforms>.stride, index: 0)
                enc.setFragmentBytes(&wuPost, length: MemoryLayout<WaterUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

            enc.endEncoding()
        }

        // =====================================================================
        // PASS 3: Bloom — bright-pass (HDR → half-res bloomBright)
        // =====================================================================
        encodeFullscreenPass(cmd: cmd, pipeline: bloomBrightPipeline,
                             inTexture: hdrColor, outTexture: bloomBright,
                             uniforms: nil, uniformsSize: 0)

        // Separable Gaussian blur, one H+V sweep (matches the perf harness).
        // Final result lands back in bloomBright for the composite pass.
        encodeFullscreenPass(cmd: cmd, pipeline: bloomBlurHPipeline,
                             inTexture: bloomBright, outTexture: bloomBlurA,
                             uniforms: nil, uniformsSize: 0)
        encodeFullscreenPass(cmd: cmd, pipeline: bloomBlurVPipeline,
                             inTexture: bloomBlurA, outTexture: bloomBright,
                             uniforms: nil, uniformsSize: 0)

        // Precipitation driven entirely by engine weather field (0=clear, 1=rain, 2=snow).
        // Pack: >0 = rain (strength), <0 = snow (abs = strength), 0 = clear.
        let precipPacked: Float
        switch engineWeather {
        case 1:  precipPacked =  1.0   // rain
        case 2:  precipPacked = -1.0   // snow
        default: precipPacked =  0.0   // clear
        }
        // God rays (#119): stylized shafts from a radial screen-depth visibility march.
        // The single strength
        // knob folds the toggle (gfxGodRays) AND daylight (dayLight) so it is zero at
        // night and zero when the player turns it off. THE TUNING KNOB is kGodRayStrength.
        let dayT  = Renderer.dayLight(frame.camera.time_of_day)
        var grStrength: Float = 0
        if gfxGodRays {                                   // #: god-ray toggle
            // #136 fold in the intensity slider (0..1) so the rays scale from off to the
            // kGodRayStrength ceiling; defaults to 0.5 = half the old full-strength look.
            grStrength = dayT * (1 - frame.camera.underground) * Renderer.kGodRayStrength * gfxGodRayStr
        }
        // #132 LENS FLARE gate. Project the sun to screen + derive the look-at-sun strength
        // on the CPU; fold in the toggle and underground (no flare in a cave). The shader does
        // the occlusion depth test + the per-element draw. Zero here => the flare block is
        // skipped entirely (free when toggled off, off-screen, or at night via dayT).
        var flareStr: Float = 0
        var sunUVx: Float = 0, sunUVy: Float = 0
        if gfxLensFlare || grStrength > 0 {
            let g = Renderer.sunFlareGate(viewProj: viewProj,
                                          camPos: SIMD3<Float>(camPosW.x, camPosW.y, camPosW.z),
                                          sunDir: SIMD3<Float>(sun.x, sun.y, sun.z), dayT: dayT)
            sunUVx = g.uv.x; sunUVy = g.uv.y
            grStrength *= g.rayVisibility
            if gfxLensFlare {                              // #132 lens-flare toggle
                flareStr = g.strength * (1 - frame.camera.underground)
            }
        }
        // #136 bloom intensity slider (0..1). Maps the default 0.5 to the prior fixed
        // look (0.08 add) and 1.0 to double it: bloomAdd = 0.16 * gfxBloomStr.
        var pu = PostUniforms(bloomStrength: gfxBloom ? 0.16 * gfxBloomStr : 0, vignetteStr: 0.22, satBoost: 1.18,
                              rainStrength: precipPacked, wallClockSecs: wallClock,
                              godrayStrength: 0, sunScreenX: sunUVx, sunScreenY: sunUVy,
                              sunColorR: 1.0, sunColorG: 0.6 + 0.35 * dayT, sunColorB: 0.3 + 0.5 * dayT,
                              greyHaze: max(0, 1 - frame.camera.local_sat),   // #: The Grey wash
                              celShade: gfxCelShade ? 1 : 0)   // #130 ink outlines + cel grade
        pu.lensFlareStr = flareStr
        // #136 cel ink-outline intensity slider (0..1) scales CEL_OUTLINE_DARK in the
        // composite. Only meaningful when cel-shade is on; 0 = no outline, 1 = current look.
        pu.celOutlineStr = gfxCelShade ? gfxCelOutlineStr : 0
        // #119 radial-depth uniforms shared by every composite call site this frame.
        var rayVoxDims = voxDimsU
        rayVoxDims.w = sunUVy
        var vu = VolUniforms(
            invViewProj:    viewProj.inverse,
            voxOrigin:      voxOriginU,
            voxDims:        rayVoxDims,
            camPosW:        SIMD4<Float>(camPosW.x, camPosW.y, camPosW.z, sunUVx),
            sunDir:         SIMD4<Float>(sun.x, sun.y, sun.z, 0),
            sunColor:       SIMD4<Float>(1.0, 0.6 + 0.35 * dayT, 0.3 + 0.5 * dayT, grStrength))

        // =====================================================================
        // PASS 3b (#167): God-ray pre-pass. The GR_STEPS radial depth march runs at
        // scene/kGodRayDownscale resolution (quarter res = 16x fewer marched
        // pixels); the composite then upsamples it depth-aware so shaft edges
        // stay crisp. sunDir.w carries the downscale factor and tells
        // compositeFrag to take the upsample path. Skipped entirely when the
        // toggle / night / underground gate zeroes grStrength, so god rays OFF
        // costs nothing, exactly as before.
        // =====================================================================
        if grStrength > 0, let grTex = godrayTex, godrayPipeline != nil {
            vu.sunDir.w = Renderer.kGodRayDownscale
            let grRP = MTLRenderPassDescriptor()
            grRP.colorAttachments[0].texture     = grTex
            grRP.colorAttachments[0].loadAction  = .dontCare
            grRP.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: grRP) {
                enc.setRenderPipelineState(godrayPipeline)
                enc.setDepthStencilState(noDepthState)
                enc.setCullMode(.none)
                enc.setFragmentBytes(&vu, length: MemoryLayout<VolUniforms>.stride, index: 1)
                enc.setFragmentTexture(hdrDepth, index: 2)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        // =====================================================================
        // PASS 4a: Composite (ACES + colour grade + vignette)
        //   MetalFX path:  composite → compositeLowRes (bgra8Unorm at sceneSize)
        //   Fallback path: composite → drawable directly (bilinear upscale via sampler)
        // =====================================================================
#if canImport(MetalFX)
        let useMetalFX: Bool
        if #available(macOS 13.0, iOS 16.0, *) {
            useMetalFX = metalFXEnabled
                && _spatialScaler != nil
                && compositeLowRes != nil
                && spatialOutput?.width == drawable.texture.width
                && spatialOutput?.height == drawable.texture.height
        } else {
            useMetalFX = false
        }
#else
        let useMetalFX = false
#endif

        if useMetalFX,
           let lowResTarget = compositeLowRes,
           let upscaledTarget = spatialOutput {
            // --- Composite to the low-res intermediate ---
            let lowResRP = MTLRenderPassDescriptor()
            lowResRP.colorAttachments[0].texture    = lowResTarget
            lowResRP.colorAttachments[0].loadAction  = .dontCare
            lowResRP.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: lowResRP) {
                enc.setRenderPipelineState(compositePipeline)
                enc.setDepthStencilState(noDepthState)
                enc.setCullMode(.none)
                enc.setFragmentTexture(hdrColor,    index: 0)
                enc.setFragmentTexture(bloomBright, index: 1)
                enc.setFragmentTexture(hdrDepth,    index: 2)   // #119 scene depth for the raymarch
                if let grTex = godrayTex { enc.setFragmentTexture(grTex, index: 5) }  // #167 half-res god-ray in-scatter
                enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
                enc.setFragmentBytes(&vu, length: MemoryLayout<VolUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
#if canImport(MetalFX)
            // --- PASS 4b: MetalFX spatial upscale → drawable ---
            if #available(macOS 13.0, iOS 16.0, *), let scaler = _spatialScaler {
                scaler.colorTexture  = lowResTarget
                scaler.inputContentWidth = lowResTarget.width
                scaler.inputContentHeight = lowResTarget.height
                scaler.outputTexture = upscaledTarget
                scaler.encode(commandBuffer: cmd)

                if let blit = cmd.makeBlitCommandEncoder() {
                    blit.copy(
                        from: upscaledTarget,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(
                            width: upscaledTarget.width,
                            height: upscaledTarget.height,
                            depth: 1),
                        to: drawable.texture,
                        destinationSlice: 0,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                }
            }
#endif
        } else {
            // --- Fallback: composite straight to drawable (bilinear, original behaviour) ---
            if let passDesc = view.currentRenderPassDescriptor {
                passDesc.colorAttachments[0].loadAction  = .clear
                passDesc.colorAttachments[0].clearColor  = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                if let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc) {
                    enc.setRenderPipelineState(compositePipeline)
                    enc.setDepthStencilState(noDepthState)
                    enc.setCullMode(.none)
                    enc.setFragmentTexture(hdrColor,    index: 0)
                    enc.setFragmentTexture(bloomBright, index: 1)
                    enc.setFragmentTexture(hdrDepth,    index: 2)   // #119 scene depth for the raymarch
                    if let grTex = godrayTex { enc.setFragmentTexture(grTex, index: 5) }  // #167 half-res god-ray in-scatter
                    enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
                    enc.setFragmentBytes(&vu, length: MemoryLayout<VolUniforms>.stride, index: 1)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    enc.endEncoding()
                }
            }
        }

        // In-game screenshot (backslash): if requested, composite the final scene
        // into a CPU-readable texture in THIS command buffer (the drawable itself is
        // framebufferOnly and cannot be read back). The same compositePipeline + post
        // uniforms as the on-screen frame are reused, so the captured image is the
        // real frame, not an approximation. The HUD overlay is added on the CPU after
        // the GPU finishes (see captureScreenshot). Needs no Screen Recording
        // permission and uses no deprecated API.
        #if os(macOS)
        let wantShot = gameView?.consumeScreenshotRequest() ?? false
        if wantShot {
            let rb = screenshotTexture(width: drawable.texture.width, height: drawable.texture.height)
            if let rb = rb {
                let srp = MTLRenderPassDescriptor()
                srp.colorAttachments[0].texture     = rb
                srp.colorAttachments[0].loadAction  = .dontCare
                srp.colorAttachments[0].storeAction = .store
                if let enc = cmd.makeRenderCommandEncoder(descriptor: srp) {
                    enc.setRenderPipelineState(compositePipeline)
                    enc.setDepthStencilState(noDepthState)
                    enc.setCullMode(.none)
                    enc.setFragmentTexture(hdrColor,    index: 0)
                    enc.setFragmentTexture(bloomBright, index: 1)
                    enc.setFragmentTexture(hdrDepth,    index: 2)   // #119 scene depth for the raymarch
                    if let grTex = godrayTex { enc.setFragmentTexture(grTex, index: 5) }  // #167 half-res god-ray in-scatter
                    enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
                    enc.setFragmentBytes(&vu, length: MemoryLayout<VolUniforms>.stride, index: 1)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    enc.endEncoding()
                }
            }
        }
        #else
        let wantShot = false
        #endif

        // Present inside the Core Animation transaction so the AppKit HUD overlay
        // (hotbar, hearts, inventory) composites ON TOP of the Metal layer. With
        // the default async present the metal content draws over the overlay and
        // the HUD is invisible. Requires view.presentsWithTransaction = true.
        // This path is unchanged regardless of whether MetalFX is active.
        let encodedFrame = frameCounter
        cmd.addCompletedHandler { [registry, inFlightSemaphore] _ in
            registry.markFrameCompleted(encodedFrame)
            inFlightSemaphore.signal()
        }
        if view.presentsWithTransaction {
            cmd.commit()
            cmd.waitUntilScheduled()
            drawable.present()
        } else {
            cmd.present(drawable)
            cmd.commit()
        }

        // Finish the screenshot once the GPU has produced the readback texture. We
        // only block on completion for the (rare) screenshot frame, so normal frames
        // keep their async-present timing.
        #if os(macOS)
        if wantShot, let rb = screenshotReadback {
            cmd.waitUntilCompleted()
            captureScreenshot(gameTexture: rb, meta: shotMetaString(frame.camera, frame.hud))
        }
        #endif

        // Audio: drive day/evening music + splash when entering water.
        audio?.setTimeOfDay(Renderer.clockPhase(frame.camera.time_of_day))
        audio?.tickGrey(inGrey: frame.hud.in_dim != 0, dt: Float(dt))   // #88 darker music in the grey
        let nowUnder = frame.camera.underwater > 0.5
        if nowUnder && !lastUnderwater { audio?.play(.splash) }
        lastUnderwater = nowUnder

        hud?.update(from: frame.hud)
        lastHudState = frame.hud   // #203 trade panel reads coin balance from here
        // #239: dialogue walk-away check rides the frame loop (the sim keeps
        // running behind the chat overlay).
        onPlayerPos?(frame.camera.position.x, frame.camera.position.z)

        // #109 chests: poll the engine for an open chest (set by a right-click on a
        // chest block) and push its live contents to the HUD so the chest panel shows
        // and stays current after every take/deposit. When no chest is open the panel
        // is hidden. One cheap poll per frame; no struct-layout change.
        if let hudView = hud {
            var cpos = bf_ivec3()
            var nowOpen = false
            if bf_chest_open_pos(e, &cpos) != 0 {
                var view = bf_chest_view()
                if bf_chest_query(e, cpos, &view) == BF_OK && view.present != 0 {
                    openChestPos = cpos
                    hudView.setChestOpen(pos: cpos, view: view)
                    nowOpen = true
                } else {
                    openChestPos = nil
                    hudView.setChestClosed()
                }
            } else {
                openChestPos = nil
                hudView.setChestClosed()
            }
            // Release/recapture the pointer so the panel is clickable while open.
            gameView?.setChestPanel(open: nowOpen)

            // #95 living villages: poll the nearest village's tier/donation status and
            // push it to the HUD donation panel. One cheap read per frame; the engine
            // returns present=0 when none is near, which hides the panel.
            var vview = bf_village_view()
            if bf_village_query(e, &vview) == BF_OK && vview.present != 0 {
                hudView.setVillage(vview)
            } else {
                hudView.setVillage(nil)
            }
        }

        bf_frame_end(e)
        registry.collect()
        if perfLogEnabled && now - perfLogLastTime >= 1.0 {
            let s = registry.stats()
            let fps = perfLogLastTime > 0 ? Double(perfLogFrames) / (now - perfLogLastTime) : 0
            NSLog("[Blockfall perf] fps=%.1f draws=%u props=%u buffers live=%d retired=%d reusable=%d %.1fMB new=%llu reused=%llu",
                  fps, frame.draw_count, frame.prop_instance_count,
                  s.liveBuffers, s.retiredBuffers, s.reusableBuffers,
                  Double(s.reusableBytes) / 1048576.0, s.newBuffers, s.reusedBuffers)
            perfLogLastTime = now
            perfLogFrames = 0
        }
    }

    #if os(macOS)
    // ---- In-game screenshot (backslash key) ---------------------------------
    // Directory every screenshot is written to. A stable absolute path under the
    // user's home directory (~/blockfall-shots) so it is the same no matter how the
    // .app was launched (Finder, `open`, play.sh) — the running bundle has no
    // reliable notion of the source repo root, and the save-game dir is per-world.
    // Created on first use. Documented and .gitignore'd.
    private static let screenshotDir: String =
        (NSHomeDirectory() as NSString).appendingPathComponent("blockfall-shots")

    // Lazily create / resize the CPU-readable bgra8 texture the screenshot composite
    // renders into. Shared storage so getBytes works; .renderTarget so the composite
    // pass can write it.
    private func screenshotTexture(width: Int, height: Int) -> MTLTexture? {
        if let t = screenshotReadback, t.width == width, t.height == height { return t }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                          width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        screenshotReadback = device.makeTexture(descriptor: td)
        return screenshotReadback
    }

    // Compose the captured game texture with the live AppKit HUD overlay and write a
    // timestamped PNG. The game image comes from the readback texture (the same
    // PNG-readback path PerfHarness.cgImageFromTexture uses); the HUD is rendered
    // into an NSBitmapImageRep via the standard AppKit cacheDisplay path (no Screen
    // Recording permission, no deprecated CGWindowList call). Both are drawn into one
    // CGContext at the drawable's pixel size and encoded with writeCGImagePNG.
    // Build a filename-safe metadata tag (coords, compass facing, day/night phase,
    // biome) so the screenshot filename alone carries the context, no need to read the
    // HUD text off the image. Mirrors HUDView.cardinal()/timePhase() so it matches the
    // on-screen readout.
    private func shotMetaString(_ cam: bf_camera, _ hud: bf_hud_state) -> String {
        let x = Int(cam.position.x.rounded()), y = Int(cam.position.y.rounded()), z = Int(cam.position.z.rounded())
        let names = ["S", "SW", "W", "NW", "N", "NE", "E", "SE"]
        var deg = Double(atan2(cam.forward.x, cam.forward.z)) * 180.0 / .pi
        deg = deg.truncatingRemainder(dividingBy: 360); if deg < 0 { deg += 360 }
        let face = names[Int((deg / 45.0).rounded()) % 8]
        let phase: String
        switch Renderer.clockPhase(cam.time_of_day) {
        case 0.23..<0.30: phase = "dawn"
        case 0.30..<0.70: phase = "day"
        case 0.70..<0.77: phase = "dusk"
        default:          phase = "night"
        }
        let biome = withUnsafeBytes(of: hud.biome_name) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let bsafe = String(biome.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        var parts = ["x\(x)y\(y)z\(z)", face, phase]
        if !bsafe.isEmpty { parts.append(bsafe) }
        return parts.joined(separator: "_")
    }

    private func captureScreenshot(gameTexture: MTLTexture, meta: String) {
        let w = gameTexture.width, h = gameTexture.height
        guard let gameImg = cgImageFromTexture(gameTexture) else {
            NSLog("Blockfall: screenshot failed (could not read game texture)"); return
        }

        // Render the HUD NSView into a bitmap. bitmapImageRepForCachingDisplay sizes
        // the backing store in PIXELS for the view's bounds at the current backing
        // scale, so a Retina HUD comes back at the same pixel size as the drawable.
        var hudImg: CGImage? = nil
        if let hudView = hud, hudView.bounds.width > 0, hudView.bounds.height > 0,
           let rep = hudView.bitmapImageRepForCachingDisplay(in: hudView.bounds) {
            hudView.cacheDisplay(in: hudView.bounds, to: rep)
            hudImg = rep.cgImage
        }

        // Composite game first, HUD on top, at the drawable pixel size. Both the
        // Metal readback CGImage and the AppKit-cached HUD CGImage are drawn with the
        // default CTM: CGContext.draw + makeImage apply Core Graphics' bottom-left
        // origin symmetrically, so an image drawn straight is reproduced in the same
        // memory order (this is why the headless writeTexturePNG path is upright with
        // no flip). Drawing the HUD second layers it on top, matching the on-screen
        // z-order (Metal layer below, AppKit HUD above).
        let cs = CGColorSpaceCreateDeviceRGB()
        let bi = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: bi) else {
            NSLog("Blockfall: screenshot failed (could not allocate composite context)"); return
        }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(gameImg, in: full)             // game scene (Metal readback)
        if let hudImg = hudImg {
            ctx.draw(hudImg, in: full)          // HUD overlay on top (matches on-screen z-order)
        }
        guard let composite = ctx.makeImage() else {
            NSLog("Blockfall: screenshot failed (could not build composite image)"); return
        }

        // Write to <screenshotDir>/shot_<timestamp>.png, creating the dir if needed.
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Renderer.screenshotDir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let name = "shot_\(fmt.string(from: Date()))_\(meta).png"
        let path = (Renderer.screenshotDir as NSString).appendingPathComponent(name)
        if writeCGImagePNG(composite, to: path) {
            NSLog("Blockfall: screenshot saved -> %@", path)
            hud?.flashScreenshot()   // brief on-screen confirmation (does not pause)
        } else {
            NSLog("Blockfall: screenshot failed to encode PNG at %@", path)
        }
    }
    #endif

    // ---- #13: Multiplayer compass builder -----------------------------------
    // Scans frame.entities for remote players (kind == 100). For each it decides
    // whether the peer is on-screen-and-in-front (project through view*proj and
    // test clip.w > 0 with |ndc| < 1) → a screen point; otherwise it computes a
    // stable off-screen arrow direction from the peer's offset projected onto the
    // camera right/up axes. The behind-camera case (forwardDot <= 0) keeps the
    // arrow from flipping: we point it outward along the (right,up) components.
    // Results are pushed to the HUD which draws the markers/arrows.
    //
    // The HUD draws in the GameView's point coordinate space (origin bottom-left,
    // y-up, same as the non-flipped NSView). NDC is x∈[-1,1] right, y∈[-1,1] up,
    // so the point conversion is a straightforward remap with no y-flip needed.
    private func buildPeerCompass(hud: HUDView,
                                  frame: bf_render_frame,
                                  viewProj: simd_float4x4,
                                  camPos: SIMD3<Float>,
                                  camFwd: SIMD3<Float>,
                                  camRight: SIMD3<Float>,
                                  camUp: SIMD3<Float>) {
        let n = Int(frame.entity_count)
        guard n > 0, let ents = frame.entities else {
            hud.setPeers([])
            return
        }

        // View size in POINTS (HUD overlay shares this frame). Fall back to the
        // capped scene size only if the view isn't available yet.
        let vb = gameView?.bounds.size ?? sceneSize
        let vw = CGFloat(max(1, vb.width))
        let vh = CGFloat(max(1, vb.height))

        // Turn a world position into a HUD marker: an on-screen point if it projects
        // inside the viewport, else an off-screen edge-arrow direction. Edge direction
        // uses raw right/up dot products (not w-divided clip) so it stays stable when
        // the target is behind the camera.
        func marker(at worldPos: SIMD3<Float>, color: BlockfallColor, label: String) -> HUDView.PeerMarker {
            let to = worldPos - camPos
            let distM = Int(simd_length(to).rounded())
            let clip = viewProj * SIMD4<Float>(worldPos.x, worldPos.y, worldPos.z, 1)
            var onScreen = false
            var screenPt = CGPoint.zero
            if clip.w > 0.0001 {
                let ndcX = clip.x / clip.w, ndcY = clip.y / clip.w
                if abs(ndcX) <= 1 && abs(ndcY) <= 1 {
                    onScreen = true
                    screenPt = CGPoint(x: (CGFloat(ndcX) * 0.5 + 0.5) * vw,
                                       y: (CGFloat(ndcY) * 0.5 + 0.5) * vh)
                }
            }
            var edgeDir = CGVector(dx: 0, dy: 1)
            if !onScreen {
                var dx = CGFloat(simd_dot(to, camRight))
                var dy = CGFloat(simd_dot(to, camUp))
                let len = (dx * dx + dy * dy).squareRoot()
                if len < 1e-5 { dx = 0; dy = 1 } else { dx /= len; dy /= len }
                edgeDir = CGVector(dx: dx, dy: dy)
            }
            return HUDView.PeerMarker(onScreen: onScreen, screenPt: screenPt,
                                      edgeDir: edgeDir, distM: distM,
                                      color: color, label: label)
        }

        var markers: [HUDView.PeerMarker] = []

        // Remote players (#13): one marker each, in the peer's tint.
        for i in 0..<n {
            let e = ents[i]
            guard e.kind == 100 else { continue }
            let head = SIMD3<Float>(e.position.x, e.position.y + e.scale * 0.9, e.position.z)
            let color = BlockfallColor(red: CGFloat(max(0, min(1, e.color.x))),
                                       green: CGFloat(max(0, min(1, e.color.y))),
                                       blue: CGFloat(max(0, min(1, e.color.z))), alpha: 1)
            markers.append(marker(at: head, color: color, label: "Player"))
        }

        // Objective target (#41/#318): one active creature-quest target, otherwise
        // the next local settlement artisan. Red for a boss; gold for find/help.
        if let e = engine {
            var qt = bf_quest_target()
            if bf_quest_target_get(e, &qt) == 1 && qt.active == 1 {
                let pos = SIMD3<Float>(qt.position.x, qt.position.y + 1.0, qt.position.z)
                let color = qt.is_boss == 1
                    ? BlockfallColor(red: 0.95, green: 0.25, blue: 0.20, alpha: 1)   // fight
                    : BlockfallColor(red: 1.0,  green: 0.80, blue: 0.20, alpha: 1)   // befriend
                let label = withUnsafeBytes(of: qt.label) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                markers.append(marker(at: pos, color: color, label: label))
            }
        }

        hud.setPeers(markers)

        // #202 villager chatter: project every on-screen villager head so the HUD
        // can float comic speech bubbles over talking pairs. The stable per-villager
        // key is the bit pattern of the per-individual clothing colour (#201), which
        // never changes as the villager wanders, so a conversation can follow its
        // two speakers frame to frame. Cheap: only kind 20, only within 24 blocks.
        var chatter: [HUDView.VillagerMarker] = []
        for i in 0..<n {
            let e = ents[i]
            guard e.kind == 20 else { continue }
            let wp = SIMD3<Float>(e.position.x, e.position.y, e.position.z)
            let to = wp - camPos
            let d = simd_length(to)
            guard d < 24 else { continue }
            let head = SIMD3<Float>(wp.x, wp.y + e.scale * 1.55, wp.z)
            let clip = viewProj * SIMD4<Float>(head.x, head.y, head.z, 1)
            guard clip.w > 0.0001 else { continue }
            let ndcX = clip.x / clip.w, ndcY = clip.y / clip.w
            guard abs(ndcX) <= 1.1 && abs(ndcY) <= 1.1 else { continue }
            let pt = CGPoint(x: (CGFloat(ndcX) * 0.5 + 0.5) * vw,
                             y: (CGFloat(ndcY) * 0.5 + 0.5) * vh)
            var key: UInt32 = 2166136261
            for comp in [e.color.x, e.color.y, e.color.z] {
                key = (key ^ comp.bitPattern) &* 16777619
            }
            chatter.append(HUDView.VillagerMarker(key: key, screenPt: pt,
                                                  worldPos: wp, dist: d))
        }
        // #260 chatter is cosmetic world state too: drive it from the same
        // pause-aware clock as every other animation, never wall time.
        hud.setVillagers(chatter, now: animClock)
    }

    // Helper: fullscreen triangle pass with one input + one output texture.
    private func encodeFullscreenPass(cmd: MTLCommandBuffer,
                                      pipeline: MTLRenderPipelineState,
                                      inTexture: MTLTexture,
                                      outTexture: MTLTexture,
                                      uniforms: UnsafeRawPointer?,
                                      uniformsSize: Int) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture     = outTexture
        rp.colorAttachments[0].loadAction  = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(noDepthState)
        enc.setCullMode(.none)
        enc.setFragmentTexture(inTexture, index: 0)
        if let u = uniforms, uniformsSize > 0 {
            enc.setFragmentBytes(u, length: uniformsSize, index: 0)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // MARK: Ambient life sprite update (CPU procedural, ~80 sprites max)

    /// Fills ambientLifeBuffer with this frame's bird/firefly sprites.
    /// Returns the sprite count written (may be 0 when completely faded).
    @discardableResult
    private func updateAmbientSprites(deltaTime: Float, wallClock: Float, timeOfDay: Float,
                                      camPos: SIMD3<Float>, birdsVisible: Bool,
                                      entities: UnsafePointer<bf_entity_draw>?, entityCount: Int,
                                      greyAmt: Float = 0) -> Int {
        // dayT: 0=night, 1=day (sun-elevation based so birds/fireflies swap when the
        // sun actually sets, not a quarter-cycle off — see Renderer.dayLight).
        let dayT  = Renderer.dayLight(timeOfDay)
        // nightT: inverse
        let nightT = max(0, 1.0 - dayT * 2.0)   // 0 during day, >0 during dusk/night

        // Spawn budget
        // Keep the three cheap slots while any daylight remains; each one fades on
        // its own threshold below, avoiding count-rounding pops at dusk.
        let birdCount: Int     = dayT > 0 && birdsVisible ? ambientBirdSystem.count : 0
        let fireflyCount: Int  = Int((nightT * nightT * 40).rounded()) // 0..40 fireflies by night
        let pollenCount: Int   = gfxPollen ? Int((dayT * 16).rounded()) : 0   // 0..16 motes by day (#45, toggle)
        // Grey ash motes: density scales with how drained the player's region is, so
        // walking into The Grey is viscerally obvious (dust/ash thickening in the air).
        let g = max(0, min(1, greyAmt))
        let ashCount: Int      = Int((g * g * 42).rounded())          // 0..42 motes, ramps in the Grey
        let totalSprites = min(birdCount + fireflyCount + pollenCount + ashCount, kMaxAmbientSprites)
        guard totalSprites > 0 else { return 0 }

        let ptr = ambientLifeBuffer.contents().bindMemory(to: AmbientSpritePod.self, capacity: kMaxAmbientSprites)

        var birdThreats = [camPos]
        if let entities {
            birdThreats.reserveCapacity(entityCount + 1)
            for i in 0..<entityCount {
                let p = entities[i].position
                birdThreats.append(SIMD3<Float>(p.x, p.y, p.z))
            }
        }
        let birdPoses = birdCount > 0
            ? ambientBirdSystem.update(dt: deltaTime, clock: wallClock, camera: camPos,
                                       threats: birdThreats,
                                       surface: { [unowned self] x, z in self.ambientPerchSurface(x: x, z: z) })
            : []

        // --- Birds (daytime flight, world perches, local flee reactions) ---
        for i in 0..<birdCount {
            let pose = birdPoses[i]
            // Staggered continuous fade: later birds disappear earlier, while the
            // final one approaches zero before dayLight itself reaches zero.
            let fadeStart = Float(i) * 0.018
            let birdAlpha = max(0, min(1, (dayT - fadeStart) * 4.0))
            let body: SIMD3<Float>
            switch i % 4 {
            case 0: body = SIMD3(0.12, 0.57, 0.67)   // teal jay
            case 1: body = SIMD3(0.88, 0.31, 0.25)   // tomato cardinal
            case 2: body = SIMD3(0.55, 0.32, 0.78)   // purple oddball
            default: body = SIMD3(0.88, 0.60, 0.13)  // golden goof
            }
            ptr[i] = AmbientSpritePod(
                posW:  SIMD4<Float>(pose.position.x, pose.position.y, pose.position.z, 1.25),
                color: SIMD4<Float>(body.x, body.y, body.z, birdAlpha * 0.96),
                motion: SIMD4<Float>(pose.heading.x, pose.heading.y, pose.heading.z,
                                     Float(pose.mode)))
        }

        // --- Fireflies (nighttime, near-ground, small emissive) ---
        for i in 0..<fireflyCount {
            let fi = Float(i)
            // Bob around the player at low altitude in a rough disc
            let angle = wallClock * 0.03 + fi * 2.399 + sin(fi * 1.1 + wallClock * 0.15) * 0.8
            let radius = 5.0 + fmod(fi * 3.14159, 18.0)
            let bobY = sin(fi * 0.87 + wallClock * (0.4 + fi * 0.003)) * 1.8
            let fx = camPos.x + cos(angle) * radius
            let fz = camPos.z + sin(angle) * radius
            let fy = camPos.y + 1.5 + bobY   // hover near ground level
            // Blink: each firefly has its own blink phase
            let blink = max(0.0, sin(wallClock * (1.0 + fi * 0.37) + fi * 2.1))
            let blink2 = blink * blink
            let ffAlpha = min(1.0, nightT * 2.0) * (0.4 + blink2 * 0.6)
            // Warm yellow-green, HDR overbright so they bloom
            let r = 1.2 + blink2 * 0.6
            let g = 1.8 + blink2 * 0.3
            let b = 0.3 + blink2 * 0.1
            let idx = birdCount + i
            ptr[idx] = AmbientSpritePod(
                posW:  SIMD4<Float>(fx, fy, fz, 0.22),              // w=size (tiny)
                color: SIMD4<Float>(r, g, b, ffAlpha),
                motion: .zero)
        }

        // --- Pollen / dust motes (daytime, near-ground, slow drift) (#45) ---
        // Faint pale-gold specks that drift around the player by day, so the world
        // feels alive in sunlight the way fireflies do at night.
        for i in 0..<pollenCount {
            let idx = birdCount + fireflyCount + i
            if idx >= kMaxAmbientSprites { break }              // defensive cap
            let fi = Float(i)
            let angle  = wallClock * 0.02 + fi * 2.399
            let radius = 8.0 + Float(fmod(Double(fi) * 2.71, 12.0))   // 8-20: kept well away from the eye (#76)
            let px = camPos.x + cos(angle) * radius + sin(wallClock * 0.30 + fi) * 1.4
            let pz = camPos.z + sin(angle) * radius + cos(wallClock * 0.27 + fi) * 1.4
            let py = camPos.y + 0.8 + sin(fi * 0.6 + wallClock * 0.25) * 1.3
            let twinkle = 0.5 + 0.5 * sin(wallClock * 0.8 + fi * 1.7)
            // Fade motes that drift near the eye so they never flash across the HUD.
            let pdx = px - camPos.x, pdy = py - camPos.y, pdz = pz - camPos.z
            // Hard fade anything within 5 blocks of the eye so no mote ever flashes
            // across the HUD; full strength only past ~8 blocks. (#76)
            let pNear = max(0, min(1, ((pdx*pdx + pdy*pdy + pdz*pdz).squareRoot() - 5.0) / 3.0))
            let pAlpha  = dayT * (0.08 + twinkle * 0.10) * pNear   // faint, never busy, never up-close
            ptr[idx] = AmbientSpritePod(
                posW:  SIMD4<Float>(px, py, pz, 0.09),          // w=size (very tiny)
                color: SIMD4<Float>(1.0, 0.97, 0.80, pAlpha),  // pale warm gold
                motion: .zero)
        }

        // --- Grey ash / dust motes (The Grey ambience) ---
        // Cold grey flecks that drift and slowly sink around the player, thickening
        // the more drained the region is — so being in The Grey feels like ash in the
        // air, not just desaturated terrain. Cover a wider/taller volume than pollen.
        for i in 0..<ashCount {
            let idx = birdCount + fireflyCount + pollenCount + i
            if idx >= kMaxAmbientSprites { break }              // defensive cap
            let fi = Float(i)
            let angle  = wallClock * 0.015 + fi * 2.399
            let radius = 4.0 + Float(fmod(Double(fi) * 3.37, 20.0))      // 4-24 blocks (kept off the eye)
            // Slow downward drift that wraps, plus lateral sway → ash settling.
            let fall   = Float(fmod(Double(wallClock * 0.6 + fi * 1.3), 9.0))   // 0..9 wrap
            let px = camPos.x + cos(angle) * radius + sin(wallClock * 0.2 + fi) * 1.2
            let pz = camPos.z + sin(angle) * radius + cos(wallClock * 0.18 + fi) * 1.2
            let py = camPos.y + 4.5 - fall + sin(fi * 0.5 + wallClock * 0.3) * 0.6
            let twinkle = 0.6 + 0.4 * sin(wallClock * 0.5 + fi * 2.1)
            let adx = px - camPos.x, ady = py - camPos.y, adz = pz - camPos.z
            let aNear = max(0, min(1, ((adx*adx + ady*ady + adz*adz).squareRoot() - 2.5) / 2.5))
            let aAlpha  = g * (0.12 + twinkle * 0.14) * aNear  // fade in with greyness, never up-close
            // Cold ashen grey, faintly blue, slight value variation per mote.
            let v = 0.40 + 0.18 * Float(fmod(Double(fi) * 0.61, 1.0))
            ptr[idx] = AmbientSpritePod(
                posW:  SIMD4<Float>(px, py, pz, 0.11),          // w=size (small)
                color: SIMD4<Float>(v, v * 1.02, v * 1.08, aAlpha),   // ashen grey
                motion: .zero)
        }

        return totalSprites
    }

    /// Highest loaded solid in a column, borrowed from the existing shadow occupancy
    /// copy. Requiring two clear cells prevents perches inside roofs or tree crowns.
    private func ambientPerchSurface(x: Int, z: Int) -> SIMD3<Float>? {
        let (dx, dy, dz) = shadowVolTexDims
        guard dx > 0, dy > 3, dz > 0, shadowVolBuf.count >= dx * dy * dz else { return nil }
        let ox = Int(shadowVolOrigin.x), oz = Int(shadowVolOrigin.z)
        guard x >= ox, x < ox + dx, z >= oz, z < oz + dz else { return nil }
        let oy = Int(shadowVolOrigin.y)
        func wrap(_ value: Int, _ size: Int) -> Int {
            let m = value % size
            return m < 0 ? m + size : m
        }
        let gx = wrap(x, dx), gz = wrap(z, dz)
        func occupied(_ y: Int) -> Bool {
            let gy = y - oy
            guard gy >= 0, gy < dy else { return false }
            return shadowVolBuf[(gz * dy + gy) * dx + gx] != 0
        }
        for y in stride(from: oy + dy - 3, through: oy, by: -1) {
            if occupied(y), !occupied(y + 1), !occupied(y + 2) {
                // The procedural feet sit ~0.62 world units below a 1.25 bird's
                // centre. Put those feet on the solid top instead of through it.
                return SIMD3<Float>(Float(x) + 0.5, Float(y) + 1.62, Float(z) + 0.5)
            }
        }
        return nil
    }

    // MARK: Sub-voxel props (#51/#52 GPU-instanced)
    // Prop model = a few coloured cuboids (centre, half-extent, colour) in 0..1
    // block space. Bold flat toy colours.
    private static func propModel(_ type: UInt32) -> [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] {
        let green = SIMD3<Float>(0.27, 0.62, 0.20)
        switch type {
        case 36, 37:   // flowers (red / yellow)
            let bloom: SIMD3<Float> = (type == 36) ? SIMD3(0.90, 0.20, 0.22) : SIMD3(0.97, 0.82, 0.16)
            return [
                (SIMD3(0.50, 0.22, 0.50), SIMD3(0.025, 0.22, 0.025), green),
                (SIMD3(0.42, 0.47, 0.50), SIMD3(0.09, 0.07, 0.08), bloom),
                (SIMD3(0.58, 0.47, 0.50), SIMD3(0.09, 0.07, 0.08), bloom),
                (SIMD3(0.50, 0.47, 0.57), SIMD3(0.08, 0.07, 0.09), bloom),
                (SIMD3(0.50, 0.49, 0.49), SIMD3(0.05, 0.055, 0.045), SIMD3(0.98,0.80,0.22)),
            ]
        case 39:       // mushroom
            return [
                (SIMD3(0.5, 0.14, 0.5), SIMD3(0.055, 0.14, 0.055), SIMD3(0.92,0.88,0.78)),
                (SIMD3(0.5, 0.33, 0.5), SIMD3(0.16, 0.075, 0.16), SIMD3(0.85,0.16,0.14)),
            ]
        case 40:       // color crystal (pink, matches its light)
            return [
                (SIMD3(0.5,  0.40, 0.5),  SIMD3(0.11, 0.40, 0.11), SIMD3(0.96,0.42,0.86)),
                (SIMD3(0.33, 0.22, 0.52), SIMD3(0.07, 0.22, 0.07), SIMD3(0.82,0.52,0.96)),
                (SIMD3(0.66, 0.26, 0.43), SIMD3(0.06, 0.26, 0.06), SIMD3(0.92,0.46,0.92)),
            ]
        case 38:       // grass tuft — a few thin blades of varying height + green
            let g1 = SIMD3<Float>(0.32, 0.68, 0.22)
            let g2 = SIMD3<Float>(0.25, 0.58, 0.18)
            let g3 = SIMD3<Float>(0.38, 0.74, 0.27)
            return [
                (SIMD3(0.50, 0.34, 0.50), SIMD3(0.045, 0.34, 0.045), g1),  // tall centre blade
                (SIMD3(0.36, 0.24, 0.57), SIMD3(0.038, 0.24, 0.038), g2),  // shorter left-back
                (SIMD3(0.64, 0.27, 0.44), SIMD3(0.038, 0.27, 0.038), g3),  // medium right
                (SIMD3(0.49, 0.19, 0.37), SIMD3(0.034, 0.19, 0.034), g2),  // short front
            ]
        case 41:       // pebble / small rock — a couple of low grey stones
            let s1 = SIMD3<Float>(0.56, 0.56, 0.59)
            let s2 = SIMD3<Float>(0.46, 0.46, 0.49)
            return [
                (SIMD3(0.48, 0.11, 0.50), SIMD3(0.22, 0.11, 0.19), s1),    // main stone
                (SIMD3(0.68, 0.07, 0.40), SIMD3(0.10, 0.07, 0.10), s2),    // small side stone
            ]
        case 42:       // berry bush — leafy green clump with red berries
            let leaf  = SIMD3<Float>(0.20, 0.50, 0.22)
            let leaf2 = SIMD3<Float>(0.16, 0.42, 0.18)
            let berry = SIMD3<Float>(0.84, 0.14, 0.18)
            return [
                (SIMD3(0.50, 0.28, 0.50), SIMD3(0.28, 0.26, 0.28), leaf),   // bush body
                (SIMD3(0.50, 0.50, 0.50), SIMD3(0.19, 0.13, 0.19), leaf2),  // rounded top
                // Three berries sit outside different sides of the clump. A
                // slight camera turn no longer hides the whole berry set inside
                // the two overlapping leaf spheres (#265).
                (SIMD3(0.34, 0.36, 0.76), SIMD3(0.055, 0.055, 0.055), berry),
                (SIMD3(0.78, 0.28, 0.42), SIMD3(0.060, 0.060, 0.060), berry),
                (SIMD3(0.48, 0.49, 0.29), SIMD3(0.055, 0.055, 0.055), berry),
            ]
        case 43:       // reed / cattail — TWO blocks tall, fuller clump, taller brown poof
            let stalk = SIMD3<Float>(0.28, 0.55, 0.30)
            let tip   = SIMD3<Float>(0.42, 0.26, 0.12)
            return [
                (SIMD3(0.44, 0.95, 0.50), SIMD3(0.055, 0.92, 0.055), stalk),  // tall stalk (~2 tall)
                (SIMD3(0.58, 0.86, 0.46), SIMD3(0.050, 0.84, 0.050), stalk),  // second stalk
                (SIMD3(0.50, 0.78, 0.57), SIMD3(0.048, 0.76, 0.048), stalk),  // third stalk (more fill)
                (SIMD3(0.46, 1.70, 0.50), SIMD3(0.10, 0.30, 0.10), tip),      // taller, fuller brown poof
            ]
        case 44:       // cactus — tall varied desert silhouette; shader scales per seed
            let cac = SIMD3<Float>(0.27, 0.52, 0.26)
            let cac2 = SIMD3<Float>(0.22, 0.45, 0.22)
            return [
                (SIMD3(0.50, 0.48, 0.50), SIMD3(0.16, 0.48, 0.16), cac),    // trunk
                (SIMD3(0.74, 0.44, 0.50), SIMD3(0.10, 0.09, 0.09), cac),    // right arm out
                (SIMD3(0.82, 0.58, 0.50), SIMD3(0.07, 0.18, 0.07), cac),    // right arm up
                (SIMD3(0.28, 0.62, 0.50), SIMD3(0.10, 0.09, 0.09), cac2),   // left arm out
                (SIMD3(0.20, 0.78, 0.50), SIMD3(0.07, 0.20, 0.07), cac2),   // left arm up
            ]
        case 45:       // seashell — small pale shell on the sand
            let sh  = SIMD3<Float>(0.94, 0.86, 0.80)
            let sh2 = SIMD3<Float>(0.90, 0.72, 0.70)
            return [
                (SIMD3(0.50, 0.08, 0.50), SIMD3(0.13, 0.07, 0.16), sh),     // shell body (low)
                (SIMD3(0.50, 0.15, 0.42), SIMD3(0.08, 0.06, 0.07), sh2),    // ridge
            ]
        case 46:       // lily pad — flat green disc floating on the water
            let pad  = SIMD3<Float>(0.30, 0.58, 0.30)
            let pad2 = SIMD3<Float>(0.24, 0.50, 0.26)
            return [
                (SIMD3(0.50, 0.04, 0.50), SIMD3(0.40, 0.03, 0.40), pad),    // wide flat pad
                (SIMD3(0.62, 0.05, 0.40), SIMD3(0.14, 0.03, 0.14), pad2),   // second leaf
            ]
        case 47:       // fallen stick — a low brown twig on the ground
            let bark  = SIMD3<Float>(0.42, 0.28, 0.16)
            let bark2 = SIMD3<Float>(0.36, 0.24, 0.14)
            return [
                (SIMD3(0.50, 0.06, 0.46), SIMD3(0.34, 0.05, 0.06), bark),   // main twig
                (SIMD3(0.40, 0.06, 0.60), SIMD3(0.16, 0.045, 0.05), bark2), // little branch
            ]
        case 5:        // #62 OAK foliage — one broad sphere per exposed leaf voxel.
                       // Neighbouring spheres overlap into a continuous lumpy canopy.
                       // Extra intersecting shells made the frontmost colour swap on yaw.
            let g1 = SIMD3<Float>(0.20, 0.44, 0.16)
            return [
                (SIMD3(0.50, 0.50, 0.50), SIMD3(0.88, 0.82, 0.88), g1),  // big main ball
            ]
        case 27:       // #62 BIRCH foliage — lighter, same stable one-sphere silhouette
            let b1 = SIMD3<Float>(0.31, 0.50, 0.20)
            return [
                (SIMD3(0.50, 0.50, 0.50), SIMD3(0.86, 0.80, 0.86), b1),
            ]
        case 21:       // #62 OAK trunk — a rounded brown column, thinner than a full
                       // block so the trunk reads as round, not a stack of cubes
            let woak = SIMD3<Float>(0.40, 0.27, 0.16)
            return [
                (SIMD3(0.50, 0.50, 0.50), SIMD3(0.40, 0.50, 0.40), woak),
            ]
        case 22:       // #62 BIRCH trunk — pale, slightly thinner column
            let wbirch = SIMD3<Float>(0.82, 0.80, 0.74)
            return [
                (SIMD3(0.50, 0.50, 0.50), SIMD3(0.36, 0.50, 0.36), wbirch),
            ]
        case 49:       // #62 PINE trunk — dark reddish-brown conifer wood
            let wpine = SIMD3<Float>(0.34, 0.22, 0.14)
            return [
                (SIMD3(0.50, 0.50, 0.50), SIMD3(0.40, 0.50, 0.40), wpine),
            ]
        case 48:       // #62 PINE needles — dark green cones. Tall, slim silhouette, but a
                       // fuller lower skirt so the canopy reads dense, not see-through.
            let p1 = SIMD3<Float>(0.16, 0.34, 0.20)
            let p2 = SIMD3<Float>(0.13, 0.29, 0.17)
            return [
                (SIMD3(0.50, 0.44, 0.50), SIMD3(0.52, 0.96, 0.52), p1),  // tall slim main cone
                (SIMD3(0.50, 0.26, 0.50), SIMD3(0.74, 0.56, 0.74), p2),  // fuller lower skirt (density)
                (SIMD3(0.49, 0.72, 0.50), SIMD3(0.32, 0.60, 0.32), p1),  // upper spike
            ]
        default: return []
        }
    }

    // Build all visible props' world-space geometry into `out` (shared by the live
    // renderer). The GPU expands these per instance (#52) — no CPU geometry build.
    // #62: which primitive each prop type's parts use. 0=box, 1=sphere, 2=cone,
    // 3=cylinder. Tree foliage becomes round spheres, trunks become round (octagonal)
    // cylinders. Everything else stays a box.
    private static func propPartShape(_ type: UInt32) -> Float {
        switch type {
        case 5, 27, 42: return 1   // oak/birch foliage and berry bushes → sphere
        case 48:    return 2   // pine needles → cone (conifer look)
        case 21, 22, 49: return 3  // oak/birch/pine trunk → cylinder
        default:     return 0  // box
        }
    }

    private static let propMaxCuboids = 5
    static let propTypeRows: [UInt32] = [36, 37, 39, 40, 38, 41, 42, 43, 44, 45, 46, 47,
                                         5, 27, 21, 22, 48, 49]
    static let propRowCount = propTypeRows.count

    static func propInstanceBufferSlot(for frame: Int) -> Int {
        frame % propInstanceBufferRingSize
    }

    static func propRow(for type: UInt32) -> Int {
        switch type {
        case 36: return 0
        case 37: return 1
        case 39: return 2
        case 40: return 3
        case 38: return 4
        case 41: return 5
        case 42: return 6
        case 43: return 7
        case 44: return 8
        case 45: return 9
        case 46: return 10
        case 47: return 11
        case 5:  return 12
        case 27: return 13
        case 21: return 14
        case 22: return 15
        case 48: return 16
        case 49: return 17
        default: return -1
        }
    }

    private static func propVertsPerShape(_ shape: Float, type: UInt32) -> Int {
        switch Int(shape + 0.5) {
        // Trees and berry bushes are large, frequently overlapping silhouettes.
        // Give only those spheres a smoother 8x3 surface so visible facets do
        // not pop as the camera yaws; tiny flowers/rocks retain the cheap mesh.
        case 1: return (type == 5 || type == 27 || type == 42) ? 144 : 72
        case 2: return 54      // cone: sides + base cap
        case 3: return 72      // cylinder: sides + two caps
        default: return 36     // box
        }
    }

    static let propRowVertsPerShape: [Int] = propTypeRows.map { type in
        propVertsPerShape(propPartShape(type), type: type)
    }

    static let propRowVertexCounts: [Int] = propTypeRows.enumerated().map { row, type in
        min(propModel(type).count, propMaxCuboids) * propRowVertsPerShape[row]
    }

    // Build the static model table: type rows × cuboid slots of PropCuboidGPU.
    // Unused slots are left zero (zero half-extent → the vertex shader skips them).
    static func makePropModelTable(device: MTLDevice) -> MTLBuffer {
        let rows = propRowCount, slots = propMaxCuboids
        var table = [PropCuboidGPU](repeating: PropCuboidGPU(cx:0,cy:0,cz:0, hx:0,hy:0,hz:0, r:0,g:0,b:0),
                                    count: rows * slots)
        for row in 0..<rows {
            let model = propModel(propTypeRows[row])
            let shape = propPartShape(propTypeRows[row])   // #62 box/sphere/cone/cylinder
            for (s, cu) in model.prefix(slots).enumerated() {
                table[row * slots + s] = PropCuboidGPU(cx: cu.0.x, cy: cu.0.y, cz: cu.0.z,
                                                       hx: cu.1.x, hy: cu.1.y, hz: cu.1.z,
                                                       r: cu.2.x, g: cu.2.y, b: cu.2.z,
                                                       shape: shape)
            }
        }
        return device.makeBuffer(bytes: table, length: table.count * MemoryLayout<PropCuboidGPU>.stride,
                                 options: .storageModeShared)!
    }

    // MARK: Sky colour (clear colour tint — sky pass renders on top)

    // #237: the ENGINE day phase puts noon at 0.25 and midnight at 0.75 (the
    // render_frame sun model); the HUD clock, audio schedule, sky tint and shot
    // filenames were all written midnight-at-zero (0.5 = noon), so the labels
    // said Night at 8am and crickets sang at breakfast. Convert ONCE here for
    // every clock-convention consumer. Sun-elevation consumers (dayLight,
    // updateAmbientSprites) take the raw engine phase and must NOT use this.
    static func clockPhase(_ t: Float) -> Float {
        var s = (t + 0.25).truncatingRemainder(dividingBy: 1)
        if s < 0 { s += 1 }
        return s
    }

    private func skyColor(_ t: Float) -> (Double, Double, Double) {
        let dayT  = Double(max(0.0, sin(t * .pi)))
        let dawnT = Double(max(0.0, 1.0 - abs(t - 0.25) * 8.0))
        let duskT = Double(max(0.0, 1.0 - abs(t - 0.75) * 8.0))
        let sunsetT = min(dawnT + duskT, 1.0)
        let nr = 0.08; let ng = 0.10; let nb = 0.22
        let dr = 0.68; let dg = 0.84; let db = 1.00
        let sr = 1.00; let sg = 0.52; let sb = 0.18
        var r = nr + (dr - nr) * dayT
        var g = ng + (dg - ng) * dayT
        var b = nb + (db - nb) * dayT
        r = r + (sr - r) * sunsetT * 0.85
        g = g + (sg - g) * sunsetT * 0.85
        b = b + (sb - b) * sunsetT * 0.85
        return (min(r, 1.0), min(g, 1.0), min(b, 1.0))
    }

    // MARK: Matrix helpers

    // Builds a view-projection that accepts camera-relative positions without ever
    // multiplying/cancelling the absolute view translation. Shader callers subtract
    // the camera from the large object origin BEFORE adding fine local geometry;
    // subtracting after assembly has already lost the precision (#192/#286).
    static func cameraRelativeViewProj(projection: simd_float4x4,
                                       view: simd_float4x4) -> simd_float4x4 {
        var rotationOnlyView = view
        rotationOnlyView.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        return projection * rotationOnlyView
    }

    // bf_mat4 (column-major float[16]) -> simd_float4x4
    static func mat(_ m: bf_mat4) -> simd_float4x4 {
        let c = m.m
        return simd_float4x4(columns: (
            SIMD4<Float>(c.0,  c.1,  c.2,  c.3),
            SIMD4<Float>(c.4,  c.5,  c.6,  c.7),
            SIMD4<Float>(c.8,  c.9,  c.10, c.11),
            SIMD4<Float>(c.12, c.13, c.14, c.15)))
    }

    // Day/night light level (0 = full night, 1 = full day), driven by the sun's
    // actual elevation rather than sin(t*pi).
    //
    // FIX (night washout): the old terrain/prop/sky brightness used
    // 0.15 + 0.85*max(0, sin(t*pi)), which peaks at t=0.5 and only reaches its
    // night floor at the single instant t=0 / t=1. But the sun arc is
    // sun_dir = {cos(ang)*0.6, -sin(ang)-0.25, 0.90} with ang = t*2*pi, so the
    // sun is BELOW the horizon for t in ~(0.54, 0.96) and lowest at t=0.75 — a
    // quarter-cycle out of phase with sin(t*pi). The result: the world stayed lit
    // at 65-99% of noon through the whole night (no sun, so no shadows = a flat,
    // low-contrast, washed-out bright scene that is hard to read), and only went
    // dark at t~0/1 when the sun was actually back up. The shadow toggle never
    // touched this ambient term, so disabling lighting did not help — matching the
    // report ("washed out even with lighting off").
    //
    // Now we derive brightness from the real (normalized) sun elevation, so the
    // world is bright while the sun is up, falls through dusk, and holds a low
    // night floor across the entire night window. Noon stays at full brightness so
    // the daytime look is unchanged.
    static func dayLight(_ t: Float) -> Float {
        let ang = t * 2.0 * Float.pi
        // Sun direction (matches world.hpp). Elevation = -normalize(dir).y, positive
        // when the sun is above the horizon.
        let dx = cos(ang) * 0.6, dy = -sin(ang) - 0.25, dz: Float = 0.90
        let elev = -dy / (dx * dx + dy * dy + dz * dz).squareRoot()
        // smoothstep(-0.12, 0.25): full day when the sun is comfortably up, fading
        // to the night floor through dusk/dawn as it crosses the horizon.
        let x = max(0.0, min(1.0, (elev + 0.12) / 0.37))
        return x * x * (3.0 - 2.0 * x)
    }

    // #132 LENS-FLARE GATE (CPU side).
    // Project the (directional) sun onto the screen and derive the master flare strength
    // BEFORE it reaches the shader. The directional sun has no world position, so we place
    // it a long way down the toSun ray from the camera and project that point. Returns:
    //   onScreenUV : the sun's screen-space uv (matches compositeFrag's top-left uv), or
    //                (-1,-1) when the sun is behind the camera.
    //   strength   : the master flare strength, 0..1, folding:
    //                  - daylight  (0 at night so the flare is impossible after dark)
    //                  - in-front-of-camera (flare needs the sun roughly ahead)
    //                  - look-at-sun: peaks when the sun sits near screen centre, fades
    //                    to 0 toward the screen edge (looking away -> no flare).
    //   rayVisibility: continuous 1..0 fade through the small edge margin used by the
    //                  radial shaft pass. This is separate from centred flare strength.
    // The shader still does the occlusion (scene-depth) test and the per-element draw; these
    // gates kill the whole pass cheaply when it cannot possibly contribute.
    static func sunFlareGate(viewProj: simd_float4x4, camPos: SIMD3<Float>,
                             sunDir: SIMD3<Float>, dayT: Float)
        -> (uv: SIMD2<Float>, strength: Float, rayVisibility: Float) {
        // toSun points from the scene toward the sun (sunDir points downward from the sun).
        let toSun = simd_normalize(-sunDir)
        // A far point along the sun ray; projecting it gives the sun's screen position.
        let sunWorld = camPos + toSun * 1.0e6
        let clip = viewProj * SIMD4<Float>(sunWorld.x, sunWorld.y, sunWorld.z, 1.0)
        // Behind the camera (w <= 0): the sun is not in front, no flare.
        if clip.w <= 1e-4 { return (SIMD2<Float>(-1, -1), 0, 0) }
        let ndc = SIMD2<Float>(clip.x / clip.w, clip.y / clip.w)
        // Metal top-left uv: x maps [-1,1]->[0,1]; y is flipped.
        let uv = SIMD2<Float>(ndc.x * 0.5 + 0.5, 1.0 - (ndc.y * 0.5 + 0.5))
        // Fade shafts continuously through a small off-screen margin. A hard Boolean
        // cutoff here made a slow camera turn pop the entire effect in one frame.
        let m: Float = 0.15
        let outside = max(0, max(max(-uv.x, uv.x - 1), max(-uv.y, uv.y - 1)))
        let rayVisibility = max(0, min(1, 1 - outside / m))
        // Look-at-sun: how close the sun is to the screen centre (0..1). Strongest when you
        // look straight at the sun, fading smoothly to the edges so a sun in the corner only
        // gives a faint flare and one off-screen gives none.
        let off = simd_length(SIMD2<Float>(uv.x - 0.5, uv.y - 0.5)) * 2.0   // 0 centre .. ~1.4 corner
        let centred = max(0.0, 1.0 - off / kFlareEdgeFade)
        let look = centred * centred * (3.0 - 2.0 * centred)   // smoothstep-ish ease
        return (uv, dayT * look, rayVisibility)
    }

    static func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let t = tan(fovy * 0.5)
        var m = simd_float4x4(0)
        m.columns.0.x = 1 / (aspect * t)
        m.columns.1.y = 1 / t
        m.columns.2.z = far / (near - far)
        m.columns.2.w = -1
        m.columns.3.z = (far * near) / (near - far)
        return m
    }

    // The sun light-space matrix builders (buildLightMatrix / buildLightMatrixD) and the
    // LightFrustumDebug struct were retired with the shadow map. World-space voxel shadows
    // need no light-space projection: fmain marches the world occupancy grid toward the sun.


}

// (ShadowVertUniforms removed: the shadow-map render pass is retired in favour of
//  world-space voxel sun shadows.)
