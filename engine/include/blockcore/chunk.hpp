// ============================================================================
// Blockfall — Track B: palette-compressed chunk storage
// (engine/include/blockcore/chunk.hpp). Implements bf::IChunk / bf::IChunkStore.
//
// Storage (spec §4.3): each 16^3 chunk keeps a palette of distinct block ids +
// a bit-packed index array. bits-per-index is restricted to {1,2,4,8,16} so an
// index never straddles a 64-bit word (since each divides 64) — fast, simple,
// lossless. A uniform chunk (one block, e.g. all-air) stores just the palette
// entry and no index array: air/single-block chunks are ~free.
// ============================================================================
#pragma once
#include "blockcore_interfaces.hpp"

#include <cstdint>
#include <vector>
#include <unordered_map>
#include <memory>
#include <span>
#include <cstring>

namespace bf {

class PaletteChunk final : public IChunk {
public:
    explicit PaletteChunk(ChunkCoord c, BlockId fill = 0)
        : coord_(c) {
        palette_.push_back(fill);   // index 0 == fill (uniform to start)
    }

    BlockId get(int lx, int ly, int lz) const override {
        if (bits_ == 0) return palette_[0];               // uniform fast path
        return palette_[read_index(voxel(lx, ly, lz))];
    }

    void set(int lx, int ly, int lz, BlockId b) override {
        std::uint32_t pi = palette_index_for(b);
        if (bits_ == 0) {
            if (pi == 0) { ++revision_; return; }         // still uniform, no-op value
            grow_bits(1);                                  // leave uniform: allocate indices
        }
        write_index(voxel(lx, ly, lz), pi);
        ++revision_;
    }

    bool is_uniform() const override { return bits_ == 0; }
    std::uint32_t revision() const override { return revision_; }

    // ---- per-voxel light (Track F, ADR 0004) ------------------------------
    std::uint8_t sky_light(int lx, int ly, int lz) const override {
        if (light_.empty()) return 15;
        return std::uint8_t(light_[voxel(lx, ly, lz)] >> 4);
    }
    std::uint8_t block_light(int lx, int ly, int lz) const override {
        if (light_.empty()) return 0;
        return std::uint8_t(light_[voxel(lx, ly, lz)] & 0x0F);
    }
    void set_light(int lx, int ly, int lz, std::uint8_t sky, std::uint8_t block) override {
        if (light_.empty()) light_.assign(kChunkVol, 0);
        light_[voxel(lx, ly, lz)] = std::uint8_t((sky << 4) | (block & 0x0F));
    }
    ChunkCoord coord() const { return coord_; }
    std::uint8_t  bits_per_index() const { return bits_; }

    // Deep copy (for async meshing snapshots — a worker meshes from isolated
    // copies of a chunk + its neighbours so it never races the live store).
    std::unique_ptr<PaletteChunk> clone() const {
        auto c = std::make_unique<PaletteChunk>(coord_);
        c->palette_ = palette_; c->data_ = data_; c->light_ = light_;
        c->bits_ = bits_; c->revision_ = revision_;
        return c;
    }

    // ---- Serialization (lossless round-trip; BFCK-style blob) --------------
    // Layout: magic 'BFCK', u16 ver=1, u16 flags(bit0 uniform), i32 cx,cy,cz,
    // u32 revision, u16 palette_count, u8 bits, u8 pad, palette[u16*count],
    // if !uniform: u32 word_count, words[u64*word_count].
    std::size_t serialize(std::span<std::byte> out) const {
        std::size_t need = header_bytes() + palette_.size() * 2
                         + (bits_ ? 4 + data_.size() * 8 : 0);
        if (out.size() < need) return 0;
        std::byte* p = out.data();
        auto put = [&](const void* src, std::size_t n) { std::memcpy(p, src, n); p += n; };
        const char magic[4] = {'B','F','C','K'};
        std::uint16_t ver = 1, flags = std::uint16_t(bits_ == 0 ? 1 : 0);
        put(magic, 4); put(&ver, 2); put(&flags, 2);
        put(&coord_.x, 4); put(&coord_.y, 4); put(&coord_.z, 4);
        put(&revision_, 4);
        std::uint16_t pc = std::uint16_t(palette_.size());
        std::uint8_t pad = 0;
        put(&pc, 2); put(&bits_, 1); put(&pad, 1);
        put(palette_.data(), palette_.size() * 2);
        if (bits_) {
            std::uint32_t wc = std::uint32_t(data_.size());
            put(&wc, 4); put(data_.data(), data_.size() * 8);
        }
        return need;
    }

    static std::unique_ptr<PaletteChunk> deserialize(std::span<const std::byte> in) {
        if (in.size() < header_bytes()) return nullptr;
        const std::byte* p = in.data();
        const std::byte* end = in.data() + in.size();
        bool ok = true;
        // Bounds-checked reader — a truncated/corrupt file must never read past
        // the input span (these files can come from disk corruption or hand-edits).
        auto take = [&](void* dst, std::size_t n) {
            if (!ok || std::size_t(end - p) < n) { ok = false; return; }
            std::memcpy(dst, p, n); p += n;
        };
        char magic[4]; std::uint16_t ver, flags;
        take(magic, 4); take(&ver, 2); take(&flags, 2);
        if (!ok || std::memcmp(magic, "BFCK", 4) != 0 || ver != 1) return nullptr;
        ChunkCoord c{}; take(&c.x, 4); take(&c.y, 4); take(&c.z, 4);
        std::uint32_t rev; take(&rev, 4);
        std::uint16_t pc; std::uint8_t bits, pad;
        take(&pc, 2); take(&bits, 1); take(&pad, 1);
        (void)flags; (void)pad;   // present in the format; not needed to reconstruct
        if (!ok) return nullptr;
        // Validate width + palette size from disk before trusting them, otherwise
        // a bogus bits_/pc lets indices run off the end of palette_/data_.
        if (bits != 0 && bits != 1 && bits != 2 && bits != 4 && bits != 8 && bits != 16) return nullptr;
        if (pc == 0 || pc > kChunkVol) return nullptr;
        auto ch = std::make_unique<PaletteChunk>(c);
        ch->palette_.resize(pc);
        take(ch->palette_.data(), std::size_t(pc) * 2);
        ch->bits_ = bits;
        if (bits) {
            std::uint32_t wc; take(&wc, 4);
            if (!ok) return nullptr;
            std::size_t per_word = 64u / bits;
            std::size_t required = (kChunkVol + per_word - 1) / per_word;
            if (wc != required) return nullptr;            // wrong word count
            ch->data_.resize(wc);
            take(ch->data_.data(), std::size_t(wc) * 8);
            if (!ok) return nullptr;
            // Every packed index must address a real palette entry.
            for (std::uint32_t n = 0; n < kChunkVol; ++n)
                if (ch->read_index(n) >= pc) return nullptr;
        }
        if (!ok) return nullptr;
        ch->revision_ = rev;
        return ch;
    }

private:
    static constexpr std::size_t header_bytes() { return 4 + 2 + 2 + 12 + 4 + 2 + 1 + 1; }
    static std::uint32_t voxel(int lx, int ly, int lz) {
        return std::uint32_t(lx + kChunkDim * (ly + kChunkDim * lz));
    }

    std::uint32_t palette_index_for(BlockId b) {
        for (std::uint32_t i = 0; i < palette_.size(); ++i)
            if (palette_[i] == b) return i;
        palette_.push_back(b);
        std::uint32_t needed = std::uint32_t(palette_.size());
        // Grow bits if the palette outgrew the current width.
        std::uint8_t want = bits_ ? bits_ : 1;
        while ((std::size_t{1} << want) < needed) want = std::uint8_t(want * 2);
        if (want != bits_ && bits_ != 0) grow_bits(want);
        else if (bits_ == 0 && needed > 1) { /* handled by set() */ }
        return std::uint32_t(palette_.size() - 1);
    }

    void ensure_storage() {
        std::size_t per_word = 64u / bits_;
        std::size_t words = (kChunkVol + per_word - 1) / per_word;
        if (data_.size() < words) data_.assign(words, 0);
    }

    // Move from uniform (or smaller width) to `new_bits`, repacking existing
    // indices. bits in {1,2,4,8,16}.
    void grow_bits(std::uint8_t new_bits) {
        std::vector<std::uint32_t> old(kChunkVol);
        for (std::uint32_t n = 0; n < kChunkVol; ++n) old[n] = bits_ ? read_index(n) : 0;
        bits_ = new_bits;
        data_.clear();
        ensure_storage();
        for (std::uint32_t n = 0; n < kChunkVol; ++n) write_index(n, old[n]);
    }

    std::uint32_t read_index(std::uint32_t n) const {
        std::size_t per_word = 64u / bits_;
        std::size_t w = n / per_word;
        std::size_t off = (n % per_word) * bits_;
        std::uint64_t mask = (bits_ == 64) ? ~0ull : ((std::uint64_t{1} << bits_) - 1);
        return std::uint32_t((data_[w] >> off) & mask);
    }
    void write_index(std::uint32_t n, std::uint32_t value) {
        ensure_storage();
        std::size_t per_word = 64u / bits_;
        std::size_t w = n / per_word;
        std::size_t off = (n % per_word) * bits_;
        std::uint64_t mask = ((std::uint64_t{1} << bits_) - 1) << off;
        data_[w] = (data_[w] & ~mask) | ((std::uint64_t(value) << off) & mask);
    }

    ChunkCoord                 coord_;
    std::vector<BlockId>       palette_;
    std::vector<std::uint64_t> data_;       // empty when uniform
    std::vector<std::uint8_t>  light_;      // empty until lit; sky<<4 | block
    std::uint8_t               bits_{0};
    std::uint32_t              revision_{0};
};

// ---- Chunk store -----------------------------------------------------------
struct ChunkCoordHash {
    std::size_t operator()(const ChunkCoord& c) const noexcept {
        std::uint64_t h = (std::uint64_t(std::uint32_t(c.x)) * 0x9E3779B1u)
                        ^ (std::uint64_t(std::uint32_t(c.y)) * 0x85EBCA77u)
                        ^ (std::uint64_t(std::uint32_t(c.z)) * 0xC2B2AE3Du);
        return std::size_t(h);
    }
};
inline bool operator==(const ChunkCoord& a, const ChunkCoord& b) {
    return a.x == b.x && a.y == b.y && a.z == b.z;
}

class ChunkStore final : public IChunkStore {
public:
    IChunk* get(ChunkCoord c) override {
        auto it = map_.find(c);
        return it == map_.end() ? nullptr : it->second.get();
    }
    IChunk* get_or_create(ChunkCoord c) override {
        auto it = map_.find(c);
        if (it != map_.end()) return it->second.get();
        auto* ch = new PaletteChunk(c, 0);
        map_.emplace(c, std::unique_ptr<PaletteChunk>(ch));
        return ch;
    }
    void evict(ChunkCoord c) override { map_.erase(c); }
    bool is_resident(ChunkCoord c) const override { return map_.count(c) != 0; }

    std::size_t serialize(ChunkCoord c, std::span<std::byte> out) const override {
        auto it = map_.find(c);
        return it == map_.end() ? 0 : it->second->serialize(out);
    }
    bool deserialize(ChunkCoord c, std::span<const std::byte> in) override {
        auto ch = PaletteChunk::deserialize(in);
        if (!ch) return false;
        map_[c] = std::move(ch);
        return true;
    }

    // Direct insert (worldgen/tests).
    PaletteChunk* insert(std::unique_ptr<PaletteChunk> ch) {
        ChunkCoord c = ch->coord();
        auto* raw = ch.get();
        map_[c] = std::move(ch);
        return raw;
    }
    std::size_t resident_count() const { return map_.size(); }

private:
    std::unordered_map<ChunkCoord, std::unique_ptr<PaletteChunk>, ChunkCoordHash> map_;
};

} // namespace bf
