# #25 — Async/threaded chunk meshing (perf for big render distance)

- **Area:** perf
- **Priority:** P1
- **Status:** open
- **Source:** playtest feedback (baseline round)

## Description
Worldgen + meshing run on the frame thread; at large render distance this caps FPS. Move generation/meshing/lighting to the existing job system so streaming doesn't stall frames. Prereq/companion to #5.

## Acceptance
Chunk gen+mesh off the frame thread; large render distance holds 60 FPS; no visible holes.

## Notes
_(updates / PR refs go here)_
