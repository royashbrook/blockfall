# Blockfall — Binary & Wire Formats (FROZEN, Phase 0)

All multi-byte integers little-endian (arm64 native). Every persisted blob
starts with a 4-byte magic + `uint16 version` + `uint16 flags`; loaders reject
mismatched magic/version (`BF_ERR_CORRUPT_SAVE`). Round-trip tests
(serialize→deserialize byte-identical) are an exit-gate for Tracks B/C.

## 1. On-disk chunk  (magic `BFCK`, version 1)

Palette-compressed bit-packing (spec §4.3). Air / single-block chunks are
~free.

```
struct ChunkBlobHeader {
  char     magic[4];      // 'B','F','C','K'
  uint16   version;       // 1
  uint16   flags;         // bit0 uniform (single block, no block data follows)
  int32    cx, cy, cz;    // chunk coord
  uint32   revision;      // edit counter (matches IChunk::revision())
  uint16   palette_count; // N distinct block ids in this chunk
  uint8    bits_per_index;// ceil(log2(palette_count)), 0 if uniform
  uint8    _pad;
}
// then: BlockId palette[palette_count]          (uint16 each)
// then: if !uniform: packed indices, kChunkVol * bits_per_index bits,
//       row-major y,z,x, padded to 8 bytes
// then: uint32 crc32  (over everything above)
```
Uniform chunk = header + palette[0] + crc only (≈14 bytes).

## 2. Region / save file  (magic `BFRG`, version 1)

One region = 8×8×(full Y column) of chunks (spec: `kRegionChunks=8`). A save
directory holds region files + one `player.dat` + `world.meta`.

`world.meta` (magic `BFWM`): seed, ABI version, game mode, day/time,
total play-time, and the **per-region restoration progress** table
(`region_coord → saturation 0..1`) so Dim/colour state persists.

`player.dat` (magic `BFPL`): position, look, **inventory (all 36 slots)**,
selected hotbar slot, **game mode**, **health/hunger**, and **active +
completed quest state**. This satisfies the spec's "persists world edits,
player inventory, position, mode, health, quest + region-restoration progress."

Region file body: directory of present chunk coords → file offsets, then the
chunk blobs (§1). Only edited/generated-then-touched chunks are stored; pure
procedural chunks regenerate from seed (saves space, verified by determinism
hash, Track C).

## 3. Wire protocol  (UDP, magic per-datagram `BFNW`, version 1)

Server-authoritative, custom reliability over UDP (spec §4.7). Bonjour
discovery (`_blockfall._udp`). Three channels (`NetChannel`):

| Channel | Reliability | Carries |
|---|---|---|
| 0 ReliableOrdered | ack+resend, in-order | **block edits**, inventory ops, quest state, mode |
| 1 ReliableUnordered | ack+resend | chunk stream blobs (§1), structure spawns |
| 2 Unreliable | newest-wins, seq-gated | movement/creature position snapshots (20 Hz) |

Datagram header:
```
char magic[4]='BFNW'; uint16 version; uint8 channel; uint8 flags;
uint32 seq; uint32 ack; uint32 ack_bits;  // sliding-window reliability
uint16 peer_id; uint16 payload_len;       // then payload
```

Packet types (payload `uint16 type` first): `HELLO`, `WELCOME`,
`SNAPSHOT`(full), `DELTA`(since seq), `BLOCK_EDIT`, `INV_OP`, `QUEST_OP`,
`CREATURE_STATE`, `CHUNK_DATA`, `PING/PONG`. Client prediction +
reconciliation: client applies BLOCK_EDIT locally with a provisional tag,
server echoes authoritative edit; client rolls back/forward on mismatch.

**Co-op consistency:** all authoritative edits serialize on the host Sim
thread, so two clients editing the same block converge to the host's order.
Convergence under 5% loss / 100 ms is a Track H exit-gate.

## 4. Render vertex layout  (FROZEN — Tracks D mesher ↔ E renderer)

Greedy-meshed quads. Mesher writes this exact layout into the
`storageModeShared` buffer from `bf_gpu_allocator.alloc`; the renderer's
vertex descriptor must match byte-for-byte.

```
struct BFVertex {            // 16 bytes, tightly packed
  uint32 pos_packed;   // x:6 y:6 z:6 (0..16 incl. seam), within-chunk
  uint32 normal_uv;    // normal:3, ao:2, u:8, v:8 (atlas tile coords)
  uint16 material_id;  // -> atlas slot
  uint8  sky_light;    // 0..15
  uint8  block_light;  // 0..15 (packed colour resolved in shader)
  uint32 _reserved;    // future (e.g. animated-block phase)
}
```
Indices: `uint32`, two triangles per quad. `material_id` indexes the texture
atlas table loaded from `/content`. The Dim post-effect uses
`bf_draw_item.dim_saturation` + per-region state — it is a screen-space pass,
not per-vertex, so grey regions cost no extra geometry (and use the simplified
LOD mesh, `simplified=true`).
