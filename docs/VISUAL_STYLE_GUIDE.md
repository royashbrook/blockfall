# Blockfall visual style guide

Blockfall should feel like a playable storybook cartoon: warm, tactile, funny,
slightly imperfect, and full of motion. The world is built from voxels, but it
must not read as a pile of uniform toy bricks or untextured classroom shapes.

This document is the art contract for new work. It defines principles rather
than copying another game's assets. Cuphead is a useful motion and personality
reference—rubber-hose flow, anticipation, squash, stretch, and expressive
silhouettes—while Zelda and Final Fantasy are useful references for readable
fantasy roles, landmarks, and adventure scale.

## Primary presentation

- **Cel Shading off is the canonical look.** Review screenshots, trailers, and
  first-run play with the softer render first.
- Cel Shading remains an optional player setting and a secondary regression
  mode. Art must remain readable with it enabled, but should not depend on ink
  outlines to create shape or material definition.
- Shape, colour grouping, surface variation, lighting, and animation must do
  the visual work. A post-process is seasoning, never structure.

## Five rules

1. **Readable from the silhouette.** A child should identify a creature, tool,
   door, loot container, or profession before seeing its small details.
2. **One connected character, not floating primitives.** Overlap and taper body
   parts. Hide mechanical joints inside rounded masses, cuffs, fur, cloth, or
   armour. Reserve disconnected pieces for magic or an intentional monster idea.
3. **Broad shapes first, texture second.** Use a strong big/medium/small rhythm:
   one dominant mass, a supporting mass, then a few high-value accents.
4. **Tactile imperfection.** Slight lean, bulge, uneven spacing, worn edges, and
   colour drift make the world authored. Keep collision and gameplay grids exact;
   put the irregularity in the visible surface.
5. **Motion has intent.** Every action needs anticipation, contact, overshoot,
   and recovery where appropriate. Do not expose raw simulation jitter as style.

## Shape language

Use rounded, tapered, tubular, bowed, and slightly asymmetrical forms. Curves
may be assembled from efficient sub-block geometry, but adjacent pieces must
overlap enough to read as a single solid form from normal play distance.

Prefer:

- soft rectangles, barrels, wedges, arches, bent tubes, scallops, and layered
  clumps;
- exaggerated proportions with one memorable feature;
- chunky load-bearing structure plus sparse fine detail;
- negative space that clarifies a silhouette or entrance.

Avoid:

- equally sized boxes distributed everywhere;
- paper-thin decorative bands, coplanar surfaces, or floating facial features;
- logs used as sealed walls when their round profile opens sightlines;
- detail made from many tiny shapes with no dominant mass;
- identical scale and perfect spacing across natural objects.

## Materials and surfaces

Every common surface needs variation at three scales:

1. **Base family:** a restrained local palette, never one perfectly flat colour.
2. **Block motif:** grain, courses, cracks, knots, turf clumps, sand ripples, or
   another material-specific pattern that continues coherently across a face.
3. **Sparse accents:** a few chips, tufts, stains, caps, braces, flowers, or raised
   pieces. Accents support the material; they do not become visual noise.

Variation must be deterministic from world position or stable entity identity.
It must not change with camera yaw, rebuild every frame, shimmer at distance, or
break at chunk seams.

### Natural ground

- Grass is a family of greens with broad soft patches, short grass marks, and
  occasional small tufts. Tall grass is a distinct, rarer prop.
- Sand uses warm value drift, shallow ripples, pebbles, and wind-shaped patches.
- Snow is broad and quiet, with blue-grey shade, rounded accumulation, and rare
  exposed ground or sparkle accents.
- Mud and Grey ground communicate dampness, disturbance, or corruption through
  shape and surface behavior—not desaturation alone.
- Flowers are small relative to a block, varied in height and head size, clustered
  intentionally, and less frequent than ordinary ground cover.

### Constructed materials

- Stone walls show courses, occasional inset/recessed blocks, caps, buttresses,
  wear, and a few controlled hue/value shifts.
- Wood shows grain direction, joins, braces, pegs, and end grain. Round logs are
  corner posts or decoration unless a deliberately open structure uses them.
- Metal has thickness, rounded edges, fasteners, and readable connections. Bands
  wrap or bite into the object they reinforce; they do not hover over it.
- Roofs need an eave, ridge, thickness, and a tile/thatch/shingle rhythm rather
  than a single flat slab.
- Doors, gates, stations, and loot containers need a clear interaction face and
  a state change legible without text.

### Settlements and ruins

- Villages are modest, irregular, and locally built. Paths must lead to doors.
- Cities are maintained and developed: flat public ground, broad primary roads,
  deliberate gardens, and little accidental overgrowth inside the civic core.
- Fortresses communicate protection through height, layered entrances, heavy
  gates, watch posts, guards, and clear sightlines.
- Ruins are broken versions of believable structures. Show former floors,
  supports, arches, thresholds, or rooflines so rubble tells a story.
- Large structures need a landmark silhouette and a visual hierarchy; adding
  volume everywhere does not create grandeur.

## Characters and creatures

- Faces sit on and wrap the head mass. Eyes, muzzle, beak, nose, and mouth overlap
  their supporting forms instead of floating in front of them.
- Give each species one dominant personality feature and one contrasting detail:
  huge expressive brow plus tiny legs, long flowing neck plus round feet, and so on.
- Limbs are tapered and flexible. Hands, paws, hooves, and tools make convincing
  contact with the world.
- Use colour variation inside a controlled species palette. Important fantasy
  roles also need silhouette or equipment cues; colour alone is insufficient.
- Player customization and villager presentation share the same anatomy and
  animation language so multiplayer characters belong in the same world.

## Animation language

Locomotion should use authored, phase-stable animation driven by actual speed.
Procedural aiming and ground contact may layer on top, but cannot replace the
walk/run cycle.

- Anticipate a step or strike before accelerating.
- Let limbs bow and trail, then extend into the contact.
- Plant feet cleanly; do not switch phase or direction on tiny velocity noise.
- Add controlled torso bob, head lag, secondary cloth/fur/tool follow-through,
  and a small settle after stopping.
- Exaggerate more for large or magical creatures, but preserve mass: a Ramlord
  can poof and troll along without its pieces separating.
- Tools must point through the intended contact arc and meet the target at the
  impact frame.

Idle characters should still breathe, blink, glance, shift weight, and react.
Those loops must be quiet enough that real actions remain obvious.

## Lighting, atmosphere, and effects

- Lighting establishes time, safety, and mood while preserving material colour.
- Bloom, lens flare, god rays, shadows, and cel shading are optional layers. Each
  must respect depth and occlusion and degrade cleanly when disabled.
- Effects may not reveal hidden geometry, draw halos around occluders, or change
  object content as the camera turns.
- Grey territory should have its own particles, edge behavior, growth, damage,
  creatures, and sound—not only a grey colour grade.
- Keep the middle of the screen readable during play. Put spectacle in the sky,
  distance, silhouette, and event timing rather than permanent screen clutter.

## UI and interaction readability

- HUD, menus, prompts, and world labels share a consistent type scale and visual
  weight at every window size.
- Interactable objects use silhouette, pose, light, or motion to advertise their
  purpose. Glow is reserved for meaningful state such as non-empty loot.
- Open/closed, safe/dangerous, available/complete, and friendly/hostile states
  must differ in more than a subtle colour shift.
- Animation may add charm but must not delay or obscure player feedback.

## Performance and stability contract

Art is not complete if it only looks correct from one camera angle.

- No z-fighting, coplanar overlays, camera-angle-dependent random selection, or
  per-frame remeshing for static state.
- LOD transitions preserve silhouette and use hysteresis or a stable distance;
  props must not appear only when the player is almost touching them.
- Decorative geometry has a part budget. Spend it on silhouette and material
  cues before invisible backs, repeated micro-detail, or speculative variants.
- Validate the base M1 performance gates before increasing scene-wide density.

## Review checklist

For each visual feature, capture the same representative scene with:

- Cel Shading **off** (primary) at near, middle, and far distance;
- Cel Shading **on** (secondary regression) at the same camera positions;
- daylight, dusk/night, and Grey lighting where relevant;
- still camera, slow yaw/pitch, strafing, and ordinary walking;
- low and high render distance, plus effects off/on when the feature interacts
  with lighting or post-processing.

For animated subjects, also record idle, start, steady movement, stop, turn,
action contact, and interruption. Check silhouette, feet/tool contact, phase
continuity, secondary motion, and whether any part jitters or separates.

The primary pass succeeds only when the subject reads without cel outlines,
remains stable while the camera moves, and looks intentional beside the older
content around it. Track broad material work in #335, terrain in #336, and
constructed surfaces in #337.
