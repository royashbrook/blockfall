import Foundation
import simd

struct AmbientBirdPose {
    var position: SIMD3<Float>
    var heading: SIMD3<Float>
    var mode: UInt32
}

/// Client-only ambience. Birds borrow loaded solid surfaces for perches but never
/// become engine entities, so they need no collision, persistence, or replication.
final class AmbientBirdSystem {
    private enum Mode: UInt32 { case cruise, approach, perched, flee, landing }

    private struct Bird {
        var position = SIMD3<Float>.zero
        var target = SIMD3<Float>.zero
        var perch = SIMD3<Float>.zero
        var heading = SIMD3<Float>(1, 0, 0)
        var mode = Mode.cruise
        var timer: Float = 0
        var cycle = 0
        var initialized = false
    }

    private static let worldPeriod: Float = 32_768
    private var birds: [Bird]
    private var disturbance: SIMD3<Float>?
    private var disturbanceTTL: Float = 0

    init(count: Int = 3) {
        birds = Array(repeating: Bird(), count: count)
    }

    var count: Int { birds.count }

    func disturb(at position: SIMD3<Float>) {
        disturbance = position
        disturbanceTTL = 1.5
    }

    func update(dt rawDT: Float, clock: Float, camera: SIMD3<Float>,
                threats baseThreats: [SIMD3<Float>],
                surface: (Int, Int) -> SIMD3<Float>?) -> [AmbientBirdPose] {
        let dt = max(0, min(rawDT, 0.10))
        disturbanceTTL = max(0, disturbanceTTL - dt)
        var threats = baseThreats
        if disturbanceTTL > 0, let disturbance { threats.append(disturbance) }

        var poses: [AmbientBirdPose] = []
        poses.reserveCapacity(birds.count)
        for i in birds.indices {
            if !birds[i].initialized {
                reset(&birds[i], index: i, camera: camera)
            }
            birds[i].position = Self.nearestImage(birds[i].position, around: camera)
            birds[i].target = Self.nearestImage(birds[i].target, around: camera)
            if simd_length(Self.delta(from: camera, to: birds[i].position)) > 120 {
                reset(&birds[i], index: i, camera: camera)
            }

            if dt > 0 {
                let nearest = Self.nearestThreat(to: birds[i].position, threats: threats)
                let fleeRadius: Float = (birds[i].mode == .perched || birds[i].mode == .approach) ? 10 : 5
                if birds[i].mode != .flee, let nearest, nearest.distance < fleeRadius {
                    beginFlee(&birds[i], index: i, from: nearest.position)
                }

                birds[i].timer -= dt
                switch birds[i].mode {
                case .cruise:
                    let left = Self.advance(&birds[i], speed: 7.0 + Float(i % 3),
                                            turnRate: 2.4, dt: dt)
                    if birds[i].timer <= 0,
                       let perch = choosePerch(index: i, cycle: birds[i].cycle,
                                              camera: camera, surface: surface) {
                        birds[i].cycle += 1
                        birds[i].perch = perch
                        var inbound = Self.delta(from: birds[i].position, to: perch)
                        inbound.y = 0
                        if simd_length_squared(inbound) < 0.001 {
                            let a = Self.unit(i, birds[i].cycle, 13) * .pi * 2
                            inbound = SIMD3<Float>(cos(a), 0, sin(a))
                        } else {
                            inbound = simd_normalize(inbound)
                        }
                        // Stage above and before the perch. The final 16x6 glide is
                        // shallow enough to flare instead of diving beak-first.
                        birds[i].target = perch - inbound * 16 + SIMD3<Float>(0, 6, 0)
                        birds[i].mode = .approach
                        birds[i].timer = 14
                    } else if left < 1.5 {
                        birds[i].cycle += 1
                        birds[i].target = flightTarget(index: i, cycle: birds[i].cycle, camera: camera)
                    }

                case .approach:
                    let left = Self.advance(&birds[i], speed: 7.0, turnRate: 3.0, dt: dt)
                    if left < 0.8 {
                        if supported(birds[i].perch, surface: surface) {
                            birds[i].target = birds[i].perch
                            birds[i].mode = .landing
                            birds[i].timer = 7
                        } else {
                            beginFlee(&birds[i], index: i, from: camera)
                        }
                    } else if birds[i].timer <= 0 {
                        beginFlee(&birds[i], index: i, from: camera)
                    }

                case .landing:
                    if !supported(birds[i].perch, surface: surface) {
                        beginFlee(&birds[i], index: i, from: camera)
                    } else {
                        let distance = simd_length(Self.delta(from: birds[i].position,
                                                              to: birds[i].target))
                        let speed = max(2.2, min(5.5, distance * 0.65))
                        let left = Self.advance(&birds[i], speed: speed,
                                                turnRate: 4.8, dt: dt)
                        if left < 0.12 {
                            birds[i].position = birds[i].perch
                            birds[i].heading.y = 0
                            if simd_length_squared(birds[i].heading) > 0.001 {
                                birds[i].heading = simd_normalize(birds[i].heading)
                            }
                            birds[i].mode = .perched
                            birds[i].timer = 6 + 8 * Self.unit(i, birds[i].cycle, 17)
                        } else if birds[i].timer <= 0 {
                            beginFlee(&birds[i], index: i, from: camera)
                        }
                    }

                case .perched:
                    birds[i].position = birds[i].target
                    let x = Int(floor(birds[i].target.x))
                    let z = Int(floor(birds[i].target.z))
                    let supported = surface(x, z).map { abs($0.y - birds[i].target.y) < 0.30 } ?? false
                    if !supported {
                        beginFlee(&birds[i], index: i, from: camera)
                    } else if birds[i].timer <= 0 {
                        birds[i].cycle += 1
                        birds[i].position.y += 0.5
                        birds[i].target = flightTarget(index: i, cycle: birds[i].cycle, camera: camera)
                        birds[i].mode = .cruise
                        birds[i].timer = 3 + 2 * Self.unit(i, birds[i].cycle, 23)
                    }

                case .flee:
                    let left = Self.advance(&birds[i], speed: 13.5, turnRate: 5.0, dt: dt)
                    if birds[i].timer <= 0 || left < 1.5 {
                        birds[i].cycle += 1
                        birds[i].target = flightTarget(index: i, cycle: birds[i].cycle, camera: camera)
                        birds[i].mode = .cruise
                        birds[i].timer = 3 + 3 * Self.unit(i, birds[i].cycle, 29)
                    }
                }

                if birds[i].mode != .perched {
                    keepAboveSurface(&birds[i], surface: surface)
                }
            }

            var position = birds[i].position
            if birds[i].mode == .perched {
                let hop = max(0, sin(clock * 1.7 + Float(i) * 2.3) - 0.92) * 0.35
                position.y += hop
            } else {
                let side = SIMD3<Float>(-birds[i].heading.z, 0, birds[i].heading.x)
                let sway: Float = birds[i].mode == .landing ? 0.08
                    : (birds[i].mode == .approach ? 0.18
                    : (birds[i].mode == .flee ? 0.32 : 0.65))
                let lateral = sin(clock * 0.72 + Float(i) * 1.8) * sway
                let vertical = sin(clock * 1.15 + Float(i) * 0.91) * sway * 0.55
                position += side * lateral
                position.y += vertical
            }
            // A bird banks and flares; it does not rotate its whole cartoon body
            // beak-down along the descent vector.
            var displayHeading = birds[i].heading
            displayHeading.y = 0
            if simd_length_squared(displayHeading) > 0.001 {
                displayHeading = simd_normalize(displayHeading)
            } else {
                displayHeading = SIMD3<Float>(1, 0, 0)
            }
            poses.append(AmbientBirdPose(position: position, heading: displayHeading,
                                         mode: birds[i].mode.rawValue))
        }
        return poses
    }

    private func reset(_ bird: inout Bird, index: Int, camera: SIMD3<Float>) {
        let angle = Self.unit(index, 0, 3) * .pi * 2
        let radius = 48 + 30 * Self.unit(index, 0, 5)
        bird.position = camera + SIMD3<Float>(cos(angle) * radius,
                                              20 + 14 * Self.unit(index, 0, 7),
                                              sin(angle) * radius)
        bird.perch = .zero
        bird.cycle = 1
        bird.target = flightTarget(index: index, cycle: bird.cycle, camera: camera)
        let d = Self.delta(from: bird.position, to: bird.target)
        bird.heading = simd_length_squared(d) > 0.001 ? simd_normalize(d) : SIMD3<Float>(1, 0, 0)
        bird.mode = .cruise
        bird.timer = 1.5 + Float(index) * 0.65
        bird.initialized = true
    }

    private func flightTarget(index: Int, cycle: Int, camera: SIMD3<Float>) -> SIMD3<Float> {
        let angle = Self.unit(index, cycle, 31) * .pi * 2
        let radius = 55 + 40 * Self.unit(index, cycle, 37)
        return camera + SIMD3<Float>(cos(angle) * radius,
                                     22 + 17 * Self.unit(index, cycle, 41),
                                     sin(angle) * radius)
    }

    private func choosePerch(index: Int, cycle: Int, camera: SIMD3<Float>,
                             surface: (Int, Int) -> SIMD3<Float>?) -> SIMD3<Float>? {
        var best: SIMD3<Float>?
        var bestScore = -Float.greatestFiniteMagnitude
        for attempt in 0..<12 {
            let angle = Self.unit(index, cycle, attempt * 3 + 43) * .pi * 2
            let radius = 42 + 43 * Self.unit(index, cycle, attempt * 3 + 47)
            let x = Int(floor(camera.x + cos(angle) * radius))
            let z = Int(floor(camera.z + sin(angle) * radius))
            guard let perch = surface(x, z), perch.y > camera.y - 10,
                  perch.y < camera.y + 40 else { continue }
            let score = perch.y + 1.5 * Self.unit(index, cycle, attempt * 3 + 53)
            if score > bestScore { best = perch; bestScore = score }
        }
        return best
    }

    private func beginFlee(_ bird: inout Bird, index: Int, from threat: SIMD3<Float>) {
        var away = Self.delta(from: threat, to: bird.position)
        away.y = 0
        if simd_length_squared(away) < 0.001 {
            let a = Self.unit(index, bird.cycle, 59) * .pi * 2
            away = SIMD3<Float>(cos(a), 0, sin(a))
        } else {
            away = simd_normalize(away)
        }
        bird.target = bird.position + away * 34 + SIMD3<Float>(0, 15, 0)
        bird.perch = .zero
        bird.heading = simd_normalize(Self.delta(from: bird.position, to: bird.target))
        bird.mode = .flee
        bird.timer = 2.8
    }

    @discardableResult
    private static func advance(_ bird: inout Bird, speed: Float,
                                turnRate: Float, dt: Float) -> Float {
        let d = delta(from: bird.position, to: bird.target)
        let distance = simd_length(d)
        guard distance > 0.0001 else { return 0 }
        let desired = d / distance
        let turn = min(1, dt * turnRate)
        let blended = bird.heading * (1 - turn) + desired * turn
        bird.heading = simd_length_squared(blended) > 0.001 ? simd_normalize(blended) : desired
        let travel = min(distance, speed * dt)
        bird.position += bird.heading * travel
        return simd_length(delta(from: bird.position, to: bird.target))
    }

    private func supported(_ perch: SIMD3<Float>,
                           surface: (Int, Int) -> SIMD3<Float>?) -> Bool {
        let x = Int(floor(perch.x)), z = Int(floor(perch.z))
        return surface(x, z).map { abs($0.y - perch.y) < 0.30 } ?? false
    }

    private func keepAboveSurface(_ bird: inout Bird,
                                  surface: (Int, Int) -> SIMD3<Float>?) {
        let x = Int(floor(bird.position.x)), z = Int(floor(bird.position.z))
        guard let floor = surface(x, z) else { return }
        var horizontal = Self.delta(from: bird.position, to: bird.perch)
        horizontal.y = 0
        let clearance: Float = bird.mode == .landing
            ? min(0.8, simd_length(horizontal) * 0.08)
            : 0.5
        let minY = floor.y + clearance
        if bird.position.y < minY {
            bird.position.y = minY
            bird.heading.y = max(bird.heading.y, 0.12)
            bird.heading = simd_normalize(bird.heading)
        }
    }

    private static func nearestThreat(to p: SIMD3<Float>, threats: [SIMD3<Float>])
        -> (position: SIMD3<Float>, distance: Float)? {
        var best: (SIMD3<Float>, Float)?
        for threat in threats {
            let d = simd_length(delta(from: p, to: threat))
            if best == nil || d < best!.1 { best = (threat, d) }
        }
        return best
    }

    private static func delta(from a: SIMD3<Float>, to b: SIMD3<Float>) -> SIMD3<Float> {
        var d = b - a
        d.x -= round(d.x / worldPeriod) * worldPeriod
        d.z -= round(d.z / worldPeriod) * worldPeriod
        return d
    }

    private static func nearestImage(_ p: SIMD3<Float>, around camera: SIMD3<Float>) -> SIMD3<Float> {
        var out = p
        out.x += round((camera.x - out.x) / worldPeriod) * worldPeriod
        out.z += round((camera.z - out.z) / worldPeriod) * worldPeriod
        return out
    }

    private static func unit(_ a: Int, _ b: Int, _ c: Int) -> Float {
        var x = UInt32(truncatingIfNeeded: a &* 73_856_093 ^ b &* 19_349_663 ^ c &* 83_492_791)
        x ^= x >> 16; x &*= 0x7FEB_352D
        x ^= x >> 15; x &*= 0x846C_A68B
        x ^= x >> 16
        return Float(x) / Float(UInt32.max)
    }

    static func selfTest() -> Bool {
        let system = AmbientBirdSystem(count: 1)
        let surface: (Int, Int) -> SIMD3<Float>? = { x, z in
            SIMD3<Float>(Float(x) + 0.5, 6.6, Float(z) + 0.5)
        }
        let camera = SIMD3<Float>(0, 4, 0)
        var poses: [AmbientBirdPose] = []
        var sawApproach = false, sawLanding = false
        var landingStart: SIMD3<Float>?, previousLanding: SIMD3<Float>?
        var maxLandingDrop: Float = 0
        for frame in 0..<3_200 {
            poses = system.update(dt: 0.05, clock: Float(frame) * 0.05,
                                  camera: camera, threats: [], surface: surface)
            sawApproach = sawApproach || poses.contains { $0.mode == Mode.approach.rawValue }
            if let landing = poses.first(where: { $0.mode == Mode.landing.rawValue }) {
                sawLanding = true
                guard abs(landing.heading.y) < 0.001 else { return false }
                if landingStart == nil { landingStart = landing.position }
                if let previousLanding {
                    maxLandingDrop = max(maxLandingDrop, previousLanding.y - landing.position.y)
                }
                previousLanding = landing.position
            }
            if poses.contains(where: { $0.mode == Mode.perched.rawValue }) { break }
        }
        guard let perched = poses.first(where: { $0.mode == Mode.perched.rawValue }) else { return false }
        guard sawApproach, sawLanding, let landingStart,
              abs(perched.position.y - 6.6) < 0.01 else { return false }
        var landingRun = Self.delta(from: landingStart, to: perched.position)
        let landingDrop = -landingRun.y
        landingRun.y = 0
        guard landingDrop > 0, landingDrop < simd_length(landingRun) * 0.60,
              maxLandingDrop < 0.40 else { return false }
        poses = system.update(dt: 0.05, clock: 61, camera: camera,
                              threats: [perched.position], surface: surface)
        guard poses.contains(where: { $0.mode == Mode.flee.rawValue }) else { return false }

        let sparse = AmbientBirdSystem().update(dt: 0, clock: 0, camera: camera,
                                                threats: [], surface: surface)
        return sparse.count == 3
    }
}
