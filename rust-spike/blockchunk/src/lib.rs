//! Rust port spike of blockcore's palette-compressed chunk storage.
//! Faithful port of `engine/include/blockcore/chunk.hpp` (PaletteChunk): a 16^3 voxel
//! chunk kept as a palette of distinct block ids plus a bit-packed index array, with a
//! lossless BFCK serialization. The byte layout matches the C++ engine exactly (same
//! little-endian field order), so a save written by one side loads on the other.
//!
//! This is a ONE-MODULE spike to gauge the economics of porting blockcore to Rust.
//! It is standalone (cargo test) and is not wired into the live build.

pub const CHUNK_DIM: usize = 16;
pub const CHUNK_VOL: usize = CHUNK_DIM * CHUNK_DIM * CHUNK_DIM; // 4096
pub type BlockId = u16;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct ChunkCoord {
    pub x: i32,
    pub y: i32,
    pub z: i32,
}

/// Palette-compressed chunk. A uniform chunk (bits == 0) stores only its single
/// palette entry and no index array, so air/single-block chunks are nearly free.
#[derive(Clone)]
pub struct PaletteChunk {
    coord: ChunkCoord,
    palette: Vec<BlockId>,
    data: Vec<u64>, // empty when uniform
    light: Vec<u8>, // empty until lit; (sky << 4) | block
    bits: u8,       // 0 = uniform, else one of {1,2,4,8,16}
    revision: u32,
}

impl PaletteChunk {
    pub fn new(coord: ChunkCoord, fill: BlockId) -> Self {
        Self {
            coord,
            palette: vec![fill], // index 0 == fill (uniform to start)
            data: Vec::new(),
            light: Vec::new(),
            bits: 0,
            revision: 0,
        }
    }

    fn voxel(lx: usize, ly: usize, lz: usize) -> usize {
        lx + CHUNK_DIM * (ly + CHUNK_DIM * lz)
    }

    pub fn get(&self, lx: usize, ly: usize, lz: usize) -> BlockId {
        if self.bits == 0 {
            return self.palette[0]; // uniform fast path
        }
        self.palette[self.read_index(Self::voxel(lx, ly, lz)) as usize]
    }

    pub fn set(&mut self, lx: usize, ly: usize, lz: usize, b: BlockId) {
        let pi = self.palette_index_for(b);
        if self.bits == 0 {
            if pi == 0 {
                self.revision += 1; // still uniform, no-op value
                return;
            }
            self.grow_bits(1); // leave uniform: allocate indices
        }
        self.write_index(Self::voxel(lx, ly, lz), pi);
        self.revision += 1;
    }

    pub fn is_uniform(&self) -> bool {
        self.bits == 0
    }
    pub fn revision(&self) -> u32 {
        self.revision
    }
    pub fn coord(&self) -> ChunkCoord {
        self.coord
    }
    pub fn bits_per_index(&self) -> u8 {
        self.bits
    }

    // ---- per-voxel light (sky << 4 | block) --------------------------------
    pub fn sky_light(&self, lx: usize, ly: usize, lz: usize) -> u8 {
        if self.light.is_empty() {
            return 15;
        }
        self.light[Self::voxel(lx, ly, lz)] >> 4
    }
    pub fn block_light(&self, lx: usize, ly: usize, lz: usize) -> u8 {
        if self.light.is_empty() {
            return 0;
        }
        self.light[Self::voxel(lx, ly, lz)] & 0x0F
    }
    pub fn set_light(&mut self, lx: usize, ly: usize, lz: usize, sky: u8, block: u8) {
        if self.light.is_empty() {
            self.light = vec![0u8; CHUNK_VOL];
        }
        self.light[Self::voxel(lx, ly, lz)] = (sky << 4) | (block & 0x0F);
    }

    fn palette_index_for(&mut self, b: BlockId) -> u32 {
        if let Some(i) = self.palette.iter().position(|&p| p == b) {
            return i as u32;
        }
        self.palette.push(b);
        let needed = self.palette.len();
        // Grow bits if the palette outgrew the current width. (When still uniform,
        // bits == 0 and set() does the first allocation via grow_bits(1).)
        let mut want = if self.bits != 0 { self.bits } else { 1 };
        while (1usize << want) < needed {
            want *= 2;
        }
        if want != self.bits && self.bits != 0 {
            self.grow_bits(want);
        }
        (self.palette.len() - 1) as u32
    }

    fn ensure_storage(&mut self) {
        let per_word = 64 / self.bits as usize;
        let words = (CHUNK_VOL + per_word - 1) / per_word;
        if self.data.len() < words {
            self.data = vec![0u64; words];
        }
    }

    // Move from uniform (or a smaller width) to `new_bits`, repacking existing indices.
    fn grow_bits(&mut self, new_bits: u8) {
        let mut old = vec![0u32; CHUNK_VOL];
        for n in 0..CHUNK_VOL {
            old[n] = if self.bits != 0 { self.read_index(n) } else { 0 };
        }
        self.bits = new_bits;
        self.data.clear();
        self.ensure_storage();
        for n in 0..CHUNK_VOL {
            self.write_index(n, old[n]);
        }
    }

    fn read_index(&self, n: usize) -> u32 {
        let per_word = 64 / self.bits as usize;
        let w = n / per_word;
        let off = (n % per_word) * self.bits as usize;
        let mask = if self.bits == 64 { u64::MAX } else { (1u64 << self.bits) - 1 };
        ((self.data[w] >> off) & mask) as u32
    }

    fn write_index(&mut self, n: usize, value: u32) {
        self.ensure_storage();
        let per_word = 64 / self.bits as usize;
        let w = n / per_word;
        let off = (n % per_word) * self.bits as usize;
        let mask = ((1u64 << self.bits) - 1) << off;
        self.data[w] = (self.data[w] & !mask) | (((value as u64) << off) & mask);
    }

    // ---- serialization (BFCK; byte-identical to the C++ engine) ------------
    // magic 'BFCK', u16 ver=1, u16 flags(bit0 uniform), i32 cx,cy,cz, u32 revision,
    // u16 palette_count, u8 bits, u8 pad, palette[u16*count],
    // if !uniform: u32 word_count, words[u64*word_count].
    pub fn serialize(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(b"BFCK");
        out.extend_from_slice(&1u16.to_le_bytes()); // ver
        let flags: u16 = if self.bits == 0 { 1 } else { 0 };
        out.extend_from_slice(&flags.to_le_bytes());
        out.extend_from_slice(&self.coord.x.to_le_bytes());
        out.extend_from_slice(&self.coord.y.to_le_bytes());
        out.extend_from_slice(&self.coord.z.to_le_bytes());
        out.extend_from_slice(&self.revision.to_le_bytes());
        out.extend_from_slice(&(self.palette.len() as u16).to_le_bytes());
        out.push(self.bits);
        out.push(0u8); // pad
        for &b in &self.palette {
            out.extend_from_slice(&b.to_le_bytes());
        }
        if self.bits != 0 {
            out.extend_from_slice(&(self.data.len() as u32).to_le_bytes());
            for &w in &self.data {
                out.extend_from_slice(&w.to_le_bytes());
            }
        }
        out
    }

    pub fn deserialize(input: &[u8]) -> Option<PaletteChunk> {
        // The C++ side hand-rolls a bounds-checked reader with an `ok` flag; here the
        // type system does that bookkeeping: every read returns Option and `?` bails on
        // a truncated or corrupt blob, so reading past the end is impossible by construction.
        let mut r = Reader::new(input);
        if r.take(4)? != b"BFCK" {
            return None;
        }
        let ver = r.u16()?;
        let _flags = r.u16()?;
        if ver != 1 {
            return None;
        }
        let coord = ChunkCoord {
            x: r.i32()?,
            y: r.i32()?,
            z: r.i32()?,
        };
        let rev = r.u32()?;
        let pc = r.u16()?;
        let bits = r.u8()?;
        let _pad = r.u8()?;
        // Validate width + palette size from disk before trusting them; a bogus
        // bits/pc must not let indices run off the end of the palette or data.
        if ![0u8, 1, 2, 4, 8, 16].contains(&bits) {
            return None;
        }
        if pc == 0 || pc as usize > CHUNK_VOL {
            return None;
        }
        let mut ch = PaletteChunk::new(coord, 0);
        ch.palette = (0..pc).map(|_| r.u16()).collect::<Option<Vec<_>>>()?;
        ch.bits = bits;
        if bits != 0 {
            let wc = r.u32()? as usize;
            let per_word = 64 / bits as usize;
            let required = (CHUNK_VOL + per_word - 1) / per_word;
            if wc != required {
                return None; // wrong word count
            }
            ch.data = (0..wc).map(|_| r.u64()).collect::<Option<Vec<_>>>()?;
            // Every packed index must address a real palette entry.
            for n in 0..CHUNK_VOL {
                if ch.read_index(n) as usize >= pc as usize {
                    return None;
                }
            }
        }
        ch.revision = rev;
        Some(ch)
    }
}

/// Bounds-checked little-endian cursor over a byte slice.
struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}
impl<'a> Reader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let s = self.buf.get(self.pos..self.pos + n)?;
        self.pos += n;
        Some(s)
    }
    fn u8(&mut self) -> Option<u8> {
        Some(self.take(1)?[0])
    }
    fn u16(&mut self) -> Option<u16> {
        Some(u16::from_le_bytes(self.take(2)?.try_into().ok()?))
    }
    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_le_bytes(self.take(4)?.try_into().ok()?))
    }
    fn i32(&mut self) -> Option<i32> {
        Some(i32::from_le_bytes(self.take(4)?.try_into().ok()?))
    }
    fn u64(&mut self) -> Option<u64> {
        Some(u64::from_le_bytes(self.take(8)?.try_into().ok()?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Mirrors tests/unit/test_chunk.cpp: a chunk starts uniform, a set makes it
    // non-uniform, and reads return what was written.
    #[test]
    fn uniform_then_set() {
        let mut c = PaletteChunk::new(ChunkCoord { x: 0, y: 0, z: 0 }, 0);
        assert!(c.is_uniform());
        assert_eq!(c.get(8, 0, 8), 0);
        c.set(8, 0, 8, 3);
        assert!(!c.is_uniform());
        assert_eq!(c.get(8, 0, 8), 3);
        assert_eq!(c.get(0, 0, 0), 0);
    }

    // Lossless serialize round-trip, including palette growth that bumps the
    // bit width (1 -> 2 -> 4 bits as distinct block ids accumulate).
    #[test]
    fn serialize_round_trip() {
        let mut c = PaletteChunk::new(ChunkCoord { x: 1, y: -2, z: 3 }, 0);
        c.set(8, 0, 8, 3);
        for i in 0..16 {
            c.set(i, 1, 0, (i as BlockId) + 10); // forces several palette/width growths
        }
        assert!(c.bits_per_index() >= 4);
        let bytes = c.serialize();
        let c2 = PaletteChunk::deserialize(&bytes).expect("round trip");
        assert_eq!(c2.coord(), c.coord());
        assert_eq!(c2.revision(), c.revision());
        assert_eq!(c2.bits_per_index(), c.bits_per_index());
        for z in 0..CHUNK_DIM {
            for y in 0..CHUNK_DIM {
                for x in 0..CHUNK_DIM {
                    assert_eq!(c2.get(x, y, z), c.get(x, y, z), "voxel {x},{y},{z}");
                }
            }
        }
    }

    // A uniform chunk is the header (28 bytes) plus one u16 palette entry, no index data.
    #[test]
    fn uniform_byte_layout() {
        let c = PaletteChunk::new(ChunkCoord::default(), 7);
        let b = c.serialize();
        assert_eq!(&b[0..4], b"BFCK");
        assert_eq!(b.len(), 28 + 2);
    }

    // Cross-language parity: the SAME chunk serialized by the C++ engine
    // (engine/include/blockcore/chunk.hpp) produces byte-identical output, so a save
    // written by either side loads on the other. The golden hex was emitted by the C++
    // serialize for: PaletteChunk({1,-2,3}); set(8,0,8,3); for i in 0..16 set(i,1,0,i+10).
    #[test]
    fn byte_identical_to_cpp() {
        let mut c = PaletteChunk::new(ChunkCoord { x: 1, y: -2, z: 3 }, 0);
        c.set(8, 0, 8, 3);
        for i in 0..16 {
            c.set(i, 1, 0, (i as BlockId) + 10);
        }
        let hex: String = c.serialize().iter().map(|b| format!("{:02x}", b)).collect();
        assert_eq!(hex, include_str!("cpp_golden.hex").trim());
    }

    // Truncated or garbage input is rejected, never read out of bounds.
    #[test]
    fn corrupt_input_rejected() {
        let mut c = PaletteChunk::new(ChunkCoord::default(), 0);
        c.set(0, 0, 0, 5);
        let bytes = c.serialize();
        assert!(PaletteChunk::deserialize(&bytes[..bytes.len() / 2]).is_none());
        assert!(PaletteChunk::deserialize(b"XXXX").is_none());
        assert!(PaletteChunk::deserialize(b"").is_none());
    }
}
