// ============================================================================
// Blockfall — ContentRegistry implementation
// engine/src/content.cpp
// C++23, no external dependencies.
// ============================================================================
#include "blockcore/content.hpp"
#include "blockcore/json.hpp"

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <vector>

namespace bf {

// ============================================================================
// File utilities
// ============================================================================
static std::optional<std::string> read_file(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return std::nullopt;
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// Returns all *.json files in a directory (non-recursive), sorted.
static std::vector<std::string> json_files_in(const std::string& dir) {
    std::vector<std::string> out;
    std::error_code ec;
    for (const auto& entry : std::filesystem::directory_iterator(dir, ec)) {
        if (ec) break;
        std::error_code ec2;
        if (entry.is_regular_file(ec2) && !ec2 &&
            entry.path().extension() == ".json") {
            out.push_back(entry.path().string());
        }
    }
    std::sort(out.begin(), out.end());
    return out;
}

// ============================================================================
// Block flag helpers
// ============================================================================
// flags: bit0=gravity, bit1=transparent, bit2=functional(non-"none")
static std::uint8_t make_block_flags(const json::Value& obj) {
    std::uint8_t flags = 0;
    if (const auto* v = obj.get("gravity");     v && v->as_bool()) flags |= std::uint8_t{0x01u};
    if (const auto* v = obj.get("transparent"); v && v->as_bool()) flags |= std::uint8_t{0x02u};
    if (const auto* v = obj.get("functional")) {
        const auto& f = v->as_string();
        if (!f.empty() && f != "none") flags |= std::uint8_t{0x04u};
    }
    return flags;
}

// ============================================================================
// Tool-kind encoding
// ============================================================================
static std::uint8_t tool_kind_encode(const std::string& kind) {
    if (kind == "pickaxe") return 1u;
    if (kind == "axe")     return 2u;
    if (kind == "shovel")  return 3u;
    if (kind == "sword")   return 4u;
    return 0u;
}

// ============================================================================
// Pending cross-reference data collected during pass 1
// ============================================================================
struct PendingXRef {
    // block index -> explicit drop_item name (absent = use default logic)
    std::unordered_map<std::size_t, std::string> block_drop_item;
    // item index -> places_block name
    std::unordered_map<std::size_t, std::string> item_places_block;
    // Track which block indices had an EXPLICIT drop_item in JSON.
    // (blocks without explicit drop_item default to same-name item.)
};

// ============================================================================
// ContentRegistry::load
// ============================================================================

bool ContentRegistry::load(const std::string& content_dir) {
    // Clear prior state.
    string_pool_.clear();
    blocks_.clear(); block_id_map_.clear(); block_name_map_.clear();
    items_.clear();  item_id_map_.clear();  item_name_map_.clear();
    recipes_.clear();

    PendingXRef pending;

    // ------------------------------------------------------------------
    // Pass 1a: Blocks
    // ------------------------------------------------------------------
    {
        auto files = json_files_in(content_dir + "/blocks");
        for (const auto& path : files) {
            auto text = read_file(path);
            if (!text) {
                std::fprintf(stderr, "content: cannot read %s\n", path.c_str());
                continue;
            }
            auto pr = json::parse(*text);
            if (!pr.ok) {
                std::fprintf(stderr, "content: JSON error in %s: %s\n",
                             path.c_str(), pr.error.c_str());
                continue;
            }

            auto process = [&](const json::Value& obj) {
                if (!obj.is_object()) return;
                const auto* id_v   = obj.get("id");
                const auto* name_v = obj.get("name");
                if (!id_v || !name_v) return;

                BlockDef def{};
                def.id            = static_cast<BlockId>(id_v->as_int());
                def.name          = intern(name_v->as_string());
                def.hardness      = static_cast<std::uint8_t>(
                    obj.contains("hardness") ? obj.get("hardness")->as_int() : 0);
                def.required_tier = static_cast<std::uint8_t>(
                    obj.contains("required_tier") ? obj.get("required_tier")->as_int() : 0);
                def.light_emit    = static_cast<std::uint8_t>(
                    obj.contains("light_emit") ? obj.get("light_emit")->as_int() : 0);
                def.flags         = make_block_flags(obj);
                def.drop_item     = 0; // resolved in cross-ref pass

                std::size_t idx = blocks_.size();
                blocks_.push_back(def);
                block_id_map_[def.id] = idx;
                block_name_map_[std::string(def.name)] = idx;

                // Record explicit drop_item name.
                if (const auto* di = obj.get("drop_item");
                    di && di->is_string() && !di->as_string().empty()) {
                    pending.block_drop_item[idx] = di->as_string();
                }
            };

            const auto& root = pr.value;
            if (root.is_array()) {
                for (const auto& el : root.as_array()) process(el);
            } else {
                process(root);
            }
        }
    }

    // ------------------------------------------------------------------
    // Pass 1b: Items
    // ------------------------------------------------------------------
    {
        auto files = json_files_in(content_dir + "/items");
        for (const auto& path : files) {
            auto text = read_file(path);
            if (!text) {
                std::fprintf(stderr, "content: cannot read %s\n", path.c_str());
                continue;
            }
            auto pr = json::parse(*text);
            if (!pr.ok) {
                std::fprintf(stderr, "content: JSON error in %s: %s\n",
                             path.c_str(), pr.error.c_str());
                continue;
            }

            auto process = [&](const json::Value& obj) {
                if (!obj.is_object()) return;
                const auto* id_v   = obj.get("id");
                const auto* name_v = obj.get("name");
                if (!id_v || !name_v) return;

                ItemDef def{};
                def.id        = static_cast<ItemId>(id_v->as_int());
                def.name      = intern(name_v->as_string());
                def.max_stack = static_cast<std::uint16_t>(
                    obj.contains("max_stack") ? obj.get("max_stack")->as_int() : 64);
                def.tool_tier  = 0;
                def.tool_kind  = 0;
                def.tool_durability = 0;
                if (const auto* tool = obj.get("tool"); tool && tool->is_object()) {
                    if (const auto* tier = tool->get("tier"))
                        def.tool_tier = static_cast<std::uint8_t>(tier->as_int());
                    if (const auto* kind = tool->get("kind"))
                        def.tool_kind = tool_kind_encode(kind->as_string());
                    if (const auto* dur = tool->get("durability"))
                        def.tool_durability = static_cast<std::uint16_t>(dur->as_int());
                }
                def.places_block = 0; // resolved in cross-ref pass

                std::size_t idx = items_.size();
                items_.push_back(def);
                item_id_map_[def.id] = idx;
                item_name_map_[std::string(def.name)] = idx;

                if (const auto* pb = obj.get("places_block");
                    pb && pb->is_string() && !pb->as_string().empty()) {
                    pending.item_places_block[idx] = pb->as_string();
                }
            };

            const auto& root = pr.value;
            if (root.is_array()) {
                for (const auto& el : root.as_array()) process(el);
            } else {
                process(root);
            }
        }
    }

    // ------------------------------------------------------------------
    // Cross-reference resolution
    // ------------------------------------------------------------------

    // Block drop_item: explicit override.
    for (const auto& [idx, name] : pending.block_drop_item) {
        auto it = item_name_map_.find(name);
        if (it != item_name_map_.end())
            blocks_[idx].drop_item = items_[it->second].id;
        // else: referenced item doesn't exist — leave 0.
    }
    // Block drop_item: default to same-name item (only if no explicit override).
    for (std::size_t idx = 0; idx < blocks_.size(); ++idx) {
        if (blocks_[idx].drop_item == 0 &&
            pending.block_drop_item.find(idx) == pending.block_drop_item.end()) {
            auto it = item_name_map_.find(std::string(blocks_[idx].name));
            if (it != item_name_map_.end())
                blocks_[idx].drop_item = items_[it->second].id;
        }
    }
    // Item places_block.
    for (const auto& [idx, name] : pending.item_places_block) {
        auto it = block_name_map_.find(name);
        if (it != block_name_map_.end())
            items_[idx].places_block = blocks_[it->second].id;
    }

    // ------------------------------------------------------------------
    // Pass 2: Recipes (items/blocks already resolved)
    // ------------------------------------------------------------------
    {
        auto files = json_files_in(content_dir + "/recipes");
        for (const auto& path : files) {
            auto text = read_file(path);
            if (!text) {
                std::fprintf(stderr, "content: cannot read %s\n", path.c_str());
                continue;
            }
            auto pr = json::parse(*text);
            if (!pr.ok) {
                std::fprintf(stderr, "content: JSON error in %s: %s\n",
                             path.c_str(), pr.error.c_str());
                continue;
            }

            auto process = [&](const json::Value& obj) {
                if (!obj.is_object()) return;
                const auto* result_v = obj.get("result");
                const auto* grid_v   = obj.get("grid");
                if (!result_v || !grid_v || !grid_v->is_array()) return;

                const auto* res_item_v = result_v->get("item");
                if (!res_item_v) return;

                ItemId result_id = 0;
                {
                    auto it = item_name_map_.find(res_item_v->as_string());
                    if (it != item_name_map_.end())
                        result_id = items_[it->second].id;
                    if (result_id == 0) return; // unknown result item — skip
                }
                std::uint16_t result_count = 1;
                if (const auto* cnt = result_v->get("count"))
                    result_count = static_cast<std::uint16_t>(cnt->as_int());

                int grid_size = 2;
                if (const auto* gs = obj.get("grid_size"))
                    grid_size = static_cast<int>(gs->as_int());

                bool shapeless = false;
                if (const auto* sl = obj.get("shapeless"))
                    shapeless = sl->as_bool();

                const auto& arr = grid_v->as_array();
                RecipeEntry entry;
                entry.shapeless    = shapeless;
                entry.grid_size    = grid_size;
                entry.result_item  = result_id;
                entry.result_count = result_count;
                entry.pattern.resize(static_cast<std::size_t>(grid_size * grid_size), ItemId{0});

                for (std::size_t i = 0;
                     i < arr.size() && i < entry.pattern.size(); ++i) {
                    const auto& cell = arr[i];
                    if (cell.is_null() ||
                        (cell.is_string() && cell.as_string().empty())) {
                        entry.pattern[i] = 0;
                    } else if (cell.is_string()) {
                        auto it = item_name_map_.find(cell.as_string());
                        entry.pattern[i] =
                            (it != item_name_map_.end()) ? items_[it->second].id : ItemId{0};
                    }
                }

                recipes_.push_back(std::move(entry));
            };

            const auto& root = pr.value;
            if (root.is_array()) {
                for (const auto& el : root.as_array()) process(el);
            } else {
                process(root);
            }
        }
    }

    return true;
}

// ============================================================================
// Direct typed accessors
// ============================================================================

const BlockDef* ContentRegistry::block_by_id(BlockId id) const {
    auto it = block_id_map_.find(id);
    return it != block_id_map_.end() ? &blocks_[it->second] : nullptr;
}

const BlockDef* ContentRegistry::block_by_name(std::string_view name) const {
    auto it = block_name_map_.find(std::string(name));
    return it != block_name_map_.end() ? &blocks_[it->second] : nullptr;
}

std::uint32_t ContentRegistry::block_count() const {
    return static_cast<std::uint32_t>(blocks_.size());
}

const ItemDef* ContentRegistry::item_by_id(ItemId id) const {
    auto it = item_id_map_.find(id);
    return it != item_id_map_.end() ? &items_[it->second] : nullptr;
}

const ItemDef* ContentRegistry::item_by_name(std::string_view name) const {
    auto it = item_name_map_.find(std::string(name));
    return it != item_name_map_.end() ? &items_[it->second] : nullptr;
}

std::uint32_t ContentRegistry::item_count() const {
    return static_cast<std::uint32_t>(items_.size());
}

std::uint32_t ContentRegistry::recipe_count() const {
    return static_cast<std::uint32_t>(recipes_.size());
}

// ============================================================================
// Recipe matching helpers
// ============================================================================

struct TrimResult {
    std::vector<ItemId> cells;
    int rows{0};
    int cols{0};
};

static TrimResult trim_grid(const ItemId* grid, int dim) {
    int first_row = dim, last_row = -1, first_col = dim, last_col = -1;
    for (int r = 0; r < dim; ++r) {
        for (int c = 0; c < dim; ++c) {
            if (grid[r * dim + c] != 0) {
                if (r < first_row) first_row = r;
                if (r > last_row)  last_row  = r;
                if (c < first_col) first_col = c;
                if (c > last_col)  last_col  = c;
            }
        }
    }
    if (last_row < 0) return TrimResult{{}, 0, 0};

    int rows = last_row - first_row + 1;
    int cols = last_col - first_col + 1;
    std::vector<ItemId> cells;
    cells.reserve(static_cast<std::size_t>(rows * cols));
    for (int r = first_row; r <= last_row; ++r)
        for (int c = first_col; c <= last_col; ++c)
            cells.push_back(grid[r * dim + c]);
    return TrimResult{std::move(cells), rows, cols};
}

bool ContentRegistry::shaped_match(const RecipeEntry& recipe,
                                   const ItemId* input, int input_dim) {
    TrimResult rpat = trim_grid(recipe.pattern.data(), recipe.grid_size);
    TrimResult ipat = trim_grid(input, input_dim);

    if (rpat.rows == 0 && ipat.rows == 0) return true;
    if (rpat.rows != ipat.rows || rpat.cols != ipat.cols) return false;

    std::size_t n = static_cast<std::size_t>(rpat.rows * rpat.cols);
    for (std::size_t i = 0; i < n; ++i) {
        if (rpat.cells[i] != ipat.cells[i]) return false;
    }
    return true;
}

bool ContentRegistry::shapeless_match(const RecipeEntry& recipe,
                                      const ItemId* input, int input_dim) {
    int total = input_dim * input_dim;
    std::vector<ItemId> in_items;
    in_items.reserve(static_cast<std::size_t>(total));
    for (int i = 0; i < total; ++i)
        if (input[i] != 0) in_items.push_back(input[i]);

    std::vector<ItemId> pat_items;
    pat_items.reserve(recipe.pattern.size());
    for (ItemId id : recipe.pattern)
        if (id != 0) pat_items.push_back(id);

    if (in_items.size() != pat_items.size()) return false;
    std::sort(in_items.begin(), in_items.end());
    std::sort(pat_items.begin(), pat_items.end());
    return in_items == pat_items;
}

std::optional<RecipeMatch>
ContentRegistry::recipe_match(std::span<const ItemId> grid, int dim) const {
    if (static_cast<int>(grid.size()) != dim * dim) return std::nullopt;

    for (const auto& recipe : recipes_) {
        bool ok = recipe.shapeless
            ? shapeless_match(recipe, grid.data(), dim)
            : shaped_match   (recipe, grid.data(), dim);
        if (ok) return RecipeMatch{recipe.result_item, recipe.result_count};
    }
    return std::nullopt;
}

// ============================================================================
// Interface adapter implementations
// ============================================================================

// BlockRegistryImpl
const BlockDef* BlockRegistryImpl::by_id(BlockId id) const {
    return reg_->block_by_id(id);
}
const BlockDef* BlockRegistryImpl::by_name(std::string_view name) const {
    return reg_->block_by_name(name);
}
std::uint32_t BlockRegistryImpl::count() const {
    return reg_->block_count();
}

// ItemRegistryImpl
const ItemDef* ItemRegistryImpl::by_id(ItemId id) const {
    return reg_->item_by_id(id);
}
const ItemDef* ItemRegistryImpl::by_name(std::string_view name) const {
    return reg_->item_by_name(name);
}
std::uint32_t ItemRegistryImpl::count() const {
    return reg_->item_count();
}

// RecipeBookImpl
std::optional<RecipeMatch>
RecipeBookImpl::match(std::span<const ItemId> grid, int dim) const {
    return reg_->recipe_match(grid, dim);
}
std::uint32_t RecipeBookImpl::count() const {
    return reg_->recipe_count();
}

} // namespace bf
