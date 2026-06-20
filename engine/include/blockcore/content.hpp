// ============================================================================
// Blockfall — Content registry: blocks, items, recipes
// engine/include/blockcore/content.hpp
// C++23, no external dependencies.
// ============================================================================
#pragma once
#include "blockcore_interfaces.hpp"
#include <deque>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace bf {

// ---------------------------------------------------------------------------
// Internal recipe storage
// ---------------------------------------------------------------------------
struct RecipeEntry {
    bool shapeless{false};
    int  grid_size{2};          // 2 or 3
    // Resolved item ids; 0 = empty cell. Length = grid_size^2.
    std::vector<ItemId> pattern;
    ItemId            result_item{0};
    std::uint16_t     result_count{1};
};

// ---------------------------------------------------------------------------
// Forward declaration of the main registry.
// The three interface implementations are inner classes that hold a reference
// back to the registry's data.  This is needed because IBlockRegistry and
// IItemRegistry both declare by_id / by_name with different return types,
// which C++ cannot implement on the same concrete class.
// ---------------------------------------------------------------------------
class ContentRegistry;

// ---- Inner registries (thin adapters; ContentRegistry owns the data) -------
class BlockRegistryImpl final : public IBlockRegistry {
    const ContentRegistry* reg_{nullptr};
public:
    explicit BlockRegistryImpl(const ContentRegistry* r) noexcept : reg_(r) {}
    const BlockDef* by_id(BlockId id)              const override;
    const BlockDef* by_name(std::string_view name) const override;
    std::uint32_t   count()                        const override;
};

class ItemRegistryImpl final : public IItemRegistry {
    const ContentRegistry* reg_{nullptr};
public:
    explicit ItemRegistryImpl(const ContentRegistry* r) noexcept : reg_(r) {}
    const ItemDef* by_id(ItemId id)               const override;
    const ItemDef* by_name(std::string_view name) const override;
    std::uint32_t  count()                        const override;
};

class RecipeBookImpl final : public IRecipeBook {
    const ContentRegistry* reg_{nullptr};
public:
    explicit RecipeBookImpl(const ContentRegistry* r) noexcept : reg_(r) {}
    std::optional<RecipeMatch>
        match(std::span<const ItemId> grid, int dim) const override;
    std::uint32_t count() const override;
};

// ---------------------------------------------------------------------------
// ContentRegistry — loads all three data sets; exposes typed accessors and
// returns polymorphic interface references for code that only knows the
// abstract interfaces.
// ---------------------------------------------------------------------------
class ContentRegistry {
public:
    ContentRegistry()
        : blocks_iface_(this), items_iface_(this), recipes_iface_(this) {}
    ~ContentRegistry() = default;

    ContentRegistry(const ContentRegistry&)            = delete;
    ContentRegistry& operator=(const ContentRegistry&) = delete;

    // ---- Loading -----------------------------------------------------------
    bool load(const std::string& content_dir);

    // ---- Polymorphic interface accessors -----------------------------------
    IBlockRegistry& block_registry() { return blocks_iface_; }
    IItemRegistry&  item_registry()  { return items_iface_;  }
    IRecipeBook&    recipe_book()    { return recipes_iface_; }

    const IBlockRegistry& block_registry() const { return blocks_iface_; }
    const IItemRegistry&  item_registry()  const { return items_iface_;  }
    const IRecipeBook&    recipe_book()    const { return recipes_iface_; }

    // ---- Direct typed accessors (convenience for tests / engine code) ------
    const BlockDef* block_by_id(BlockId id)              const;
    const BlockDef* block_by_name(std::string_view name) const;
    std::uint32_t   block_count()                        const;

    const ItemDef* item_by_id(ItemId id)               const;
    const ItemDef* item_by_name(std::string_view name) const;
    std::uint32_t  item_count()                        const;

    std::optional<RecipeMatch>
        recipe_match(std::span<const ItemId> grid, int dim) const;
    std::uint32_t recipe_count() const;
    // Enumerate recipes (engine crafting UX). Index < recipe_count().
    const RecipeEntry& recipe(std::uint32_t i) const { return recipes_.at(i); }

private:
    friend class BlockRegistryImpl;
    friend class ItemRegistryImpl;
    friend class RecipeBookImpl;

    // ---- String pool (stable: std::deque never invalidates existing nodes) -
    std::deque<std::string> string_pool_;
    std::string_view intern(std::string s) {
        string_pool_.push_back(std::move(s));
        return string_pool_.back();
    }

    // ---- Block storage -----------------------------------------------------
    std::vector<BlockDef>                          blocks_;
    std::unordered_map<std::uint32_t, std::size_t> block_id_map_;
    std::unordered_map<std::string,   std::size_t> block_name_map_;

    // ---- Item storage ------------------------------------------------------
    std::vector<ItemDef>                           items_;
    std::unordered_map<std::uint32_t, std::size_t> item_id_map_;
    std::unordered_map<std::string,   std::size_t> item_name_map_;

    // ---- Recipe storage ----------------------------------------------------
    std::vector<RecipeEntry> recipes_;

    // ---- Interface adapter members -----------------------------------------
    BlockRegistryImpl blocks_iface_;
    ItemRegistryImpl  items_iface_;
    RecipeBookImpl    recipes_iface_;

    // ---- Internal helpers --------------------------------------------------
    static bool shaped_match(const RecipeEntry& recipe,
                             const ItemId* input, int input_dim);
    static bool shapeless_match(const RecipeEntry& recipe,
                                const ItemId* input, int input_dim);
};

} // namespace bf
