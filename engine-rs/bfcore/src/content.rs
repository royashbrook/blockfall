// ============================================================================
// Blockfall content registry, ported from C++ (engine/src/content.cpp +
// engine/include/blockcore/content.hpp + content_extra.hpp).
//
// Loads the JSON under content/ (blocks, items, recipes, creatures, quests)
// and exposes typed accessors. Faithful port: defaults, type tolerance, file
// ordering, and cross reference resolution all match the C++ behavior.
//
// JSON is parsed with serde_json into a generic Value tree, then read with the
// same accessor semantics the C++ json::Value used (default on type mismatch,
// no throw). This mirrors the original loader which also walked a generic tree.
// ============================================================================

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use serde_json::Value;

// Shared value types come from the crate's types module (BlockId/ItemId = u16).
use crate::types::{BlockId, ItemId, ItemRegistry};

// ---------------------------------------------------------------------------
// BlockDef. Mirrors bf::BlockDef (contract/blockcore_interfaces.hpp).
// In C++ `name` is a string_view borrowed from a string pool. Here we own the
// String. flags: bit0 gravity, bit1 transparent, bit2 functional.
// ---------------------------------------------------------------------------
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlockDef {
    pub id: BlockId,
    pub name: String,
    pub hardness: u8,
    pub required_tier: u8,
    pub light_emit: u8,
    pub flags: u8,
    pub drop_item: ItemId,
}

// ---------------------------------------------------------------------------
// ItemDef. Mirrors bf::ItemDef.
// ---------------------------------------------------------------------------
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ItemDef {
    pub id: ItemId,
    pub name: String,
    pub max_stack: u16,
    pub tool_tier: u8,
    pub tool_kind: u8,
    pub tool_durability: u16,
    pub places_block: BlockId,
}

// ---------------------------------------------------------------------------
// RecipeEntry. Mirrors bf::RecipeEntry (content.hpp). pattern length is
// grid_size^2; 0 = empty cell.
// ---------------------------------------------------------------------------
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecipeEntry {
    pub shapeless: bool,
    pub grid_size: i32, // 2 or 3
    pub pattern: Vec<ItemId>,
    pub result_item: ItemId,
    pub result_count: u16,
}

// ---------------------------------------------------------------------------
// RecipeMatch. Mirrors bf::RecipeMatch (interface return type).
// ---------------------------------------------------------------------------
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RecipeMatch {
    pub result: ItemId,
    pub count: u16,
}

// ============================================================================
// JSON accessor helpers matching the C++ json::Value semantics.
// ============================================================================

// as_int(): int -> value; double -> truncated toward zero; else 0.
// serde_json keeps numbers as i64/u64/f64. Match strtoll/strtod behavior of the
// C++ parser which produced i64 for integers and f64 for anything with . or e.
fn as_int(v: &Value) -> i64 {
    match v {
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                i
            } else if let Some(u) = n.as_u64() {
                // The C++ parser used strtoll (signed); large unsigned wraps the
                // same way a static_cast would. Values here are small so this is
                // never exercised, but keep it total.
                u as i64
            } else if let Some(f) = n.as_f64() {
                f as i64 // truncation toward zero, like static_cast<Int>(double)
            } else {
                0
            }
        }
        _ => 0,
    }
}

// as_double(): double -> value; int -> as double; else 0.0
fn as_double(v: &Value) -> f64 {
    match v {
        Value::Number(n) => n.as_f64().unwrap_or(0.0),
        _ => 0.0,
    }
}

// as_bool(): bool -> value; else false
fn as_bool(v: &Value) -> bool {
    matches!(v, Value::Bool(true))
}

// as_string(): string -> value; else "" (empty)
fn as_str(v: &Value) -> &str {
    match v {
        Value::String(s) => s.as_str(),
        _ => "",
    }
}

// Object member access: returns None if not an object or key absent.
fn get<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    v.as_object().and_then(|o| o.get(key))
}

fn is_object(v: &Value) -> bool {
    v.is_object()
}
fn is_string(v: &Value) -> bool {
    v.is_string()
}
fn is_array(v: &Value) -> bool {
    v.is_array()
}
fn is_null(v: &Value) -> bool {
    v.is_null()
}
fn is_number(v: &Value) -> bool {
    v.is_number()
}

// content_extra helpers (str/num/dnum with default on missing or wrong type).
fn x_str(v: &Value, k: &str) -> String {
    match get(v, k) {
        Some(p) if is_string(p) => as_str(p).to_string(),
        _ => String::new(),
    }
}
fn x_num(v: &Value, k: &str, def: i64) -> i64 {
    match get(v, k) {
        Some(p) if is_number(p) => as_int(p),
        _ => def,
    }
}
fn x_dnum(v: &Value, k: &str, def: f64) -> f64 {
    match get(v, k) {
        Some(p) if is_number(p) => as_double(p),
        _ => def,
    }
}

// ============================================================================
// File utilities (mirror content.cpp).
// ============================================================================

// Returns all *.json files in a directory (non-recursive), sorted by full path
// string. Matches json_files_in() which sorts entry.path().string().
fn json_files_in(dir: &Path) -> Vec<std::path::PathBuf> {
    let mut out: Vec<std::path::PathBuf> = Vec::new();
    let rd = match fs::read_dir(dir) {
        Ok(rd) => rd,
        Err(_) => return out, // directory_iterator with error_code: empty
    };
    for entry in rd.flatten() {
        let path = entry.path();
        let is_file = entry.file_type().map(|t| t.is_file()).unwrap_or(false);
        if is_file && path.extension().and_then(|e| e.to_str()) == Some("json") {
            out.push(path);
        }
    }
    out.sort();
    out
}

// content_extra used fs::directory_iterator WITHOUT sorting (records()).
// We reproduce that exactly: OS directory order, not sorted. Rust's read_dir and
// C++'s directory_iterator both wrap the same OS readdir, so the iteration order
// matches the C++ loader on a given filesystem. Creatures are never sorted by
// the C++ loader, so the creature vector order is whatever the directory yields;
// quests ARE sorted by id afterward (see ContentExtra::load). NOTE: this carries
// over the C++ loader's reliance on directory order for creatures; it is a latent
// nondeterminism in the original, preserved here for faithful parity.
fn dir_json_files_unsorted(dir: &Path) -> Vec<std::path::PathBuf> {
    let mut out: Vec<std::path::PathBuf> = Vec::new();
    let rd = match fs::read_dir(dir) {
        Ok(rd) => rd,
        Err(_) => return out,
    };
    for entry in rd.flatten() {
        let path = entry.path();
        // C++ records() filters only on extension == ".json" (no is_regular_file
        // check), so match that.
        if path.extension().and_then(|e| e.to_str()) == Some("json") {
            out.push(path);
        }
    }
    out
}

// ============================================================================
// Block flag + tool-kind encoders (mirror content.cpp).
// ============================================================================

// flags: bit0=gravity, bit1=transparent, bit2=functional(non-"none")
fn make_block_flags(obj: &Value) -> u8 {
    let mut flags: u8 = 0;
    if let Some(v) = get(obj, "gravity") {
        if as_bool(v) {
            flags |= 0x01;
        }
    }
    if let Some(v) = get(obj, "transparent") {
        if as_bool(v) {
            flags |= 0x02;
        }
    }
    if let Some(v) = get(obj, "functional") {
        let f = as_str(v);
        if !f.is_empty() && f != "none" {
            flags |= 0x04;
        }
    }
    flags
}

fn tool_kind_encode(kind: &str) -> u8 {
    match kind {
        "pickaxe" => 1,
        "axe" => 2,
        "shovel" => 3,
        "sword" => 4,
        _ => 0,
    }
}

// ============================================================================
// ContentRegistry: blocks, items, recipes.
// ============================================================================

pub struct ContentRegistry {
    blocks: Vec<BlockDef>,
    block_id_map: HashMap<u32, usize>,
    block_name_map: HashMap<String, usize>,

    items: Vec<ItemDef>,
    item_id_map: HashMap<u32, usize>,
    item_name_map: HashMap<String, usize>,

    recipes: Vec<RecipeEntry>,
}

impl Default for ContentRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl ContentRegistry {
    pub fn new() -> Self {
        ContentRegistry {
            blocks: Vec::new(),
            block_id_map: HashMap::new(),
            block_name_map: HashMap::new(),
            items: Vec::new(),
            item_id_map: HashMap::new(),
            item_name_map: HashMap::new(),
            recipes: Vec::new(),
        }
    }

    // ---- Loading ----------------------------------------------------------
    // Returns true always (matching the C++ which returns true unconditionally).
    pub fn load<P: AsRef<Path>>(&mut self, content_dir: P) -> bool {
        let dir = content_dir.as_ref();

        // Clear prior state.
        self.blocks.clear();
        self.block_id_map.clear();
        self.block_name_map.clear();
        self.items.clear();
        self.item_id_map.clear();
        self.item_name_map.clear();
        self.recipes.clear();

        // block index -> explicit drop_item name; item index -> places_block name
        let mut pending_block_drop_item: HashMap<usize, String> = HashMap::new();
        let mut pending_item_places_block: HashMap<usize, String> = HashMap::new();

        // ---- Pass 1a: Blocks ----------------------------------------------
        for path in json_files_in(&dir.join("blocks")) {
            let text = match fs::read(&path) {
                Ok(t) => t,
                Err(_) => {
                    eprintln!("content: cannot read {}", path.display());
                    continue;
                }
            };
            let root: Value = match parse_bytes(&text) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("content: JSON error in {}: {}", path.display(), e);
                    continue;
                }
            };
            let process = |reg: &mut ContentRegistry,
                           pend: &mut HashMap<usize, String>,
                           obj: &Value| {
                if !is_object(obj) {
                    return;
                }
                let id_v = get(obj, "id");
                let name_v = get(obj, "name");
                if id_v.is_none() || name_v.is_none() {
                    return;
                }
                let id_v = id_v.unwrap();
                let name_v = name_v.unwrap();

                let def = BlockDef {
                    id: as_int(id_v) as u16,
                    name: as_str(name_v).to_string(),
                    hardness: if get(obj, "hardness").is_some() {
                        as_int(get(obj, "hardness").unwrap()) as u8
                    } else {
                        0
                    },
                    required_tier: if get(obj, "required_tier").is_some() {
                        as_int(get(obj, "required_tier").unwrap()) as u8
                    } else {
                        0
                    },
                    light_emit: if get(obj, "light_emit").is_some() {
                        as_int(get(obj, "light_emit").unwrap()) as u8
                    } else {
                        0
                    },
                    flags: make_block_flags(obj),
                    drop_item: 0, // resolved in cross-ref pass
                };

                let idx = reg.blocks.len();
                let id = def.id;
                let name = def.name.clone();
                reg.blocks.push(def);
                reg.block_id_map.insert(id as u32, idx);
                reg.block_name_map.insert(name, idx);

                // Record explicit drop_item name.
                if let Some(di) = get(obj, "drop_item") {
                    if is_string(di) && !as_str(di).is_empty() {
                        pend.insert(idx, as_str(di).to_string());
                    }
                }
            };

            if is_array(&root) {
                for el in root.as_array().unwrap() {
                    process(self, &mut pending_block_drop_item, el);
                }
            } else {
                process(self, &mut pending_block_drop_item, &root);
            }
        }

        // ---- Pass 1b: Items -----------------------------------------------
        for path in json_files_in(&dir.join("items")) {
            let text = match fs::read(&path) {
                Ok(t) => t,
                Err(_) => {
                    eprintln!("content: cannot read {}", path.display());
                    continue;
                }
            };
            let root: Value = match parse_bytes(&text) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("content: JSON error in {}: {}", path.display(), e);
                    continue;
                }
            };
            let process = |reg: &mut ContentRegistry,
                           pend: &mut HashMap<usize, String>,
                           obj: &Value| {
                if !is_object(obj) {
                    return;
                }
                let id_v = get(obj, "id");
                let name_v = get(obj, "name");
                if id_v.is_none() || name_v.is_none() {
                    return;
                }
                let id_v = id_v.unwrap();
                let name_v = name_v.unwrap();

                let mut def = ItemDef {
                    id: as_int(id_v) as u16,
                    name: as_str(name_v).to_string(),
                    max_stack: if get(obj, "max_stack").is_some() {
                        as_int(get(obj, "max_stack").unwrap()) as u16
                    } else {
                        64
                    },
                    tool_tier: 0,
                    tool_kind: 0,
                    tool_durability: 0,
                    places_block: 0, // resolved in cross-ref pass
                };
                if let Some(tool) = get(obj, "tool") {
                    if is_object(tool) {
                        if let Some(tier) = get(tool, "tier") {
                            def.tool_tier = as_int(tier) as u8;
                        }
                        if let Some(kind) = get(tool, "kind") {
                            def.tool_kind = tool_kind_encode(as_str(kind));
                        }
                        if let Some(dur) = get(tool, "durability") {
                            def.tool_durability = as_int(dur) as u16;
                        }
                    }
                }

                let idx = reg.items.len();
                let id = def.id;
                let name = def.name.clone();
                reg.items.push(def);
                reg.item_id_map.insert(id as u32, idx);
                reg.item_name_map.insert(name, idx);

                if let Some(pb) = get(obj, "places_block") {
                    if is_string(pb) && !as_str(pb).is_empty() {
                        pend.insert(idx, as_str(pb).to_string());
                    }
                }
            };

            if is_array(&root) {
                for el in root.as_array().unwrap() {
                    process(self, &mut pending_item_places_block, el);
                }
            } else {
                process(self, &mut pending_item_places_block, &root);
            }
        }

        // ---- Cross-reference resolution -----------------------------------

        // Block drop_item: explicit override.
        for (idx, name) in &pending_block_drop_item {
            if let Some(&it) = self.item_name_map.get(name) {
                self.blocks[*idx].drop_item = self.items[it].id;
            }
            // else: referenced item doesn't exist, leave 0.
        }
        // Block drop_item: default to same-name item (only if no explicit override).
        for idx in 0..self.blocks.len() {
            if self.blocks[idx].drop_item == 0 && !pending_block_drop_item.contains_key(&idx) {
                let name = self.blocks[idx].name.clone();
                if let Some(&it) = self.item_name_map.get(&name) {
                    self.blocks[idx].drop_item = self.items[it].id;
                }
            }
        }
        // Item places_block.
        for (idx, name) in &pending_item_places_block {
            if let Some(&it) = self.block_name_map.get(name) {
                self.items[*idx].places_block = self.blocks[it].id;
            }
        }

        // ---- Pass 2: Recipes (items/blocks already resolved) --------------
        for path in json_files_in(&dir.join("recipes")) {
            let text = match fs::read(&path) {
                Ok(t) => t,
                Err(_) => {
                    eprintln!("content: cannot read {}", path.display());
                    continue;
                }
            };
            let root: Value = match parse_bytes(&text) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("content: JSON error in {}: {}", path.display(), e);
                    continue;
                }
            };
            let process = |reg: &mut ContentRegistry, obj: &Value| {
                if !is_object(obj) {
                    return;
                }
                let result_v = get(obj, "result");
                let grid_v = get(obj, "grid");
                if result_v.is_none() {
                    return;
                }
                let grid_v = match grid_v {
                    Some(g) if is_array(g) => g,
                    _ => return,
                };
                let result_v = result_v.unwrap();

                let res_item_v = match get(result_v, "item") {
                    Some(r) => r,
                    None => return,
                };

                let mut result_id: ItemId = 0;
                if let Some(&it) = reg.item_name_map.get(as_str(res_item_v)) {
                    result_id = reg.items[it].id;
                }
                if result_id == 0 {
                    return; // unknown result item, skip
                }

                let mut result_count: u16 = 1;
                if let Some(cnt) = get(result_v, "count") {
                    result_count = as_int(cnt) as u16;
                }

                let mut grid_size: i32 = 2;
                if let Some(gs) = get(obj, "grid_size") {
                    grid_size = as_int(gs) as i32;
                }

                let mut shapeless = false;
                if let Some(sl) = get(obj, "shapeless") {
                    shapeless = as_bool(sl);
                }

                let arr = grid_v.as_array().unwrap();
                let pat_len = (grid_size * grid_size) as usize;
                let mut pattern: Vec<ItemId> = vec![0; pat_len];

                let mut i = 0;
                while i < arr.len() && i < pattern.len() {
                    let cell = &arr[i];
                    if is_null(cell) || (is_string(cell) && as_str(cell).is_empty()) {
                        pattern[i] = 0;
                    } else if is_string(cell) {
                        pattern[i] = match reg.item_name_map.get(as_str(cell)) {
                            Some(&it) => reg.items[it].id,
                            None => 0,
                        };
                    }
                    i += 1;
                }

                reg.recipes.push(RecipeEntry {
                    shapeless,
                    grid_size,
                    pattern,
                    result_item: result_id,
                    result_count,
                });
            };

            if is_array(&root) {
                for el in root.as_array().unwrap() {
                    process(self, el);
                }
            } else {
                process(self, &root);
            }
        }

        true
    }

    // ---- Direct typed accessors -------------------------------------------
    /// Max stack for an item id, or 64 when unknown (matches the C++ default the
    /// Inventory uses when the registry has no override). World wires its Inventory
    /// to this so per-item stack limits come straight from content.
    pub fn item_max_stack(&self, item: ItemId) -> u16 {
        match self.item_by_id(item) {
            Some(d) if d.max_stack > 0 => d.max_stack,
            _ => 64,
        }
    }
    pub fn block_by_id(&self, id: BlockId) -> Option<&BlockDef> {
        self.block_id_map.get(&(id as u32)).map(|&i| &self.blocks[i])
    }
    pub fn block_by_name(&self, name: &str) -> Option<&BlockDef> {
        self.block_name_map.get(name).map(|&i| &self.blocks[i])
    }
    pub fn block_count(&self) -> u32 {
        self.blocks.len() as u32
    }

    pub fn item_by_id(&self, id: ItemId) -> Option<&ItemDef> {
        self.item_id_map.get(&(id as u32)).map(|&i| &self.items[i])
    }
    pub fn item_by_name(&self, name: &str) -> Option<&ItemDef> {
        self.item_name_map.get(name).map(|&i| &self.items[i])
    }
    pub fn item_count(&self) -> u32 {
        self.items.len() as u32
    }

    pub fn recipe_count(&self) -> u32 {
        self.recipes.len() as u32
    }
    // Enumerate recipes. Index < recipe_count().
    pub fn recipe(&self, i: u32) -> &RecipeEntry {
        &self.recipes[i as usize]
    }

    // ---- Recipe matching --------------------------------------------------
    pub fn recipe_match(&self, grid: &[ItemId], dim: i32) -> Option<RecipeMatch> {
        if grid.len() as i32 != dim * dim {
            return None;
        }
        for recipe in &self.recipes {
            let ok = if recipe.shapeless {
                shapeless_match(recipe, grid, dim)
            } else {
                shaped_match(recipe, grid, dim)
            };
            if ok {
                return Some(RecipeMatch {
                    result: recipe.result_item,
                    count: recipe.result_count,
                });
            }
        }
        None
    }
}

/// So an Inventory can borrow content for its per-item stack limits (the C++
/// Inventory holds an IItemRegistry* for exactly this).
impl ItemRegistry for ContentRegistry {
    fn max_stack(&self, item: ItemId) -> u16 {
        self.item_max_stack(item)
    }
}

// ---- Recipe matching helpers (mirror content.cpp) -------------------------

struct TrimResult {
    cells: Vec<ItemId>,
    rows: i32,
    cols: i32,
}

fn trim_grid(grid: &[ItemId], dim: i32) -> TrimResult {
    let mut first_row = dim;
    let mut last_row = -1;
    let mut first_col = dim;
    let mut last_col = -1;
    for r in 0..dim {
        for c in 0..dim {
            if grid[(r * dim + c) as usize] != 0 {
                if r < first_row {
                    first_row = r;
                }
                if r > last_row {
                    last_row = r;
                }
                if c < first_col {
                    first_col = c;
                }
                if c > last_col {
                    last_col = c;
                }
            }
        }
    }
    if last_row < 0 {
        return TrimResult {
            cells: Vec::new(),
            rows: 0,
            cols: 0,
        };
    }
    let rows = last_row - first_row + 1;
    let cols = last_col - first_col + 1;
    let mut cells: Vec<ItemId> = Vec::with_capacity((rows * cols) as usize);
    for r in first_row..=last_row {
        for c in first_col..=last_col {
            cells.push(grid[(r * dim + c) as usize]);
        }
    }
    TrimResult { cells, rows, cols }
}

fn shaped_match(recipe: &RecipeEntry, input: &[ItemId], input_dim: i32) -> bool {
    let rpat = trim_grid(&recipe.pattern, recipe.grid_size);
    let ipat = trim_grid(input, input_dim);

    if rpat.rows == 0 && ipat.rows == 0 {
        return true;
    }
    if rpat.rows != ipat.rows || rpat.cols != ipat.cols {
        return false;
    }
    let n = (rpat.rows * rpat.cols) as usize;
    for i in 0..n {
        if rpat.cells[i] != ipat.cells[i] {
            return false;
        }
    }
    true
}

fn shapeless_match(recipe: &RecipeEntry, input: &[ItemId], input_dim: i32) -> bool {
    let total = (input_dim * input_dim) as usize;
    let mut in_items: Vec<ItemId> = Vec::with_capacity(total);
    for i in 0..total {
        if input[i] != 0 {
            in_items.push(input[i]);
        }
    }
    let mut pat_items: Vec<ItemId> = Vec::with_capacity(recipe.pattern.len());
    for &id in &recipe.pattern {
        if id != 0 {
            pat_items.push(id);
        }
    }
    if in_items.len() != pat_items.len() {
        return false;
    }
    in_items.sort_unstable();
    pat_items.sort_unstable();
    in_items == pat_items
}

// ============================================================================
// ContentExtra: creatures + quests (port of content_extra.hpp).
// ============================================================================

#[derive(Debug, Clone, PartialEq)]
pub struct CreatureDefX {
    pub id: u16,
    pub name: String,
    pub disposition: String, // passive|skittish|night_gentle|boss
    pub max_health: u8,
    pub spawn_light_max: i32,
    pub move_speed: f32,
    pub boss_pattern: String, // none|stomp|shieldwall|summon_helpers
    pub biome: String,
    pub model: i32, // renderer kind override (-1 = legacy shape mapping)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuestObjX {
    pub trigger: String,
    pub target: String,
    pub text: String,
    pub count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuestDefX {
    pub id: u32,
    pub title: String,
    pub arc: String,
    pub objectives: Vec<QuestObjX>,
    pub rewards: Vec<(String, u32)>,
}

pub struct ContentExtra {
    creatures: Vec<CreatureDefX>,
    quests: Vec<QuestDefX>,
}

impl Default for ContentExtra {
    fn default() -> Self {
        Self::new()
    }
}

impl ContentExtra {
    pub fn new() -> Self {
        ContentExtra {
            creatures: Vec::new(),
            quests: Vec::new(),
        }
    }

    // Returns true if any creatures loaded (matches C++ !creatures_.empty()).
    pub fn load<P: AsRef<Path>>(&mut self, dir: P) -> bool {
        let dir = dir.as_ref();
        self.load_creatures(&dir.join("creatures"));
        self.load_quests(&dir.join("quests"));
        // Stable sort by id (C++ used std::sort; ids are unique so the choice of
        // stability does not change the result here).
        self.quests.sort_by(|a, b| a.id.cmp(&b.id));
        !self.creatures.is_empty()
    }

    pub fn creatures(&self) -> &[CreatureDefX] {
        &self.creatures
    }
    pub fn quests(&self) -> &[QuestDefX] {
        &self.quests
    }

    // Collect all records (each array element, or the bare object) across the
    // *.json files in a directory. Mirrors content_extra.hpp records().
    fn records(path: &Path) -> Vec<Value> {
        let mut out: Vec<Value> = Vec::new();
        if !path.exists() {
            return out;
        }
        for p in dir_json_files_unsorted(path) {
            let text = match fs::read(&p) {
                Ok(t) => t,
                Err(_) => continue,
            };
            let v = match parse_bytes(&text) {
                Ok(v) => v,
                Err(_) => continue,
            };
            if is_array(&v) {
                for el in v.as_array().unwrap() {
                    out.push(el.clone());
                }
            } else {
                out.push(v);
            }
        }
        out
    }

    fn load_creatures(&mut self, path: &Path) {
        for v in Self::records(path) {
            let c = CreatureDefX {
                id: x_num(&v, "id", 0) as u16,
                name: x_str(&v, "name"),
                disposition: x_str(&v, "disposition"),
                max_health: x_num(&v, "max_health", 4) as u8,
                spawn_light_max: x_num(&v, "spawn_light_max", 15) as i32,
                move_speed: x_dnum(&v, "move_speed", 2.0) as f32,
                boss_pattern: x_str(&v, "boss_pattern"),
                biome: x_str(&v, "biome"),
                model: x_num(&v, "model", -1) as i32,
            };
            if c.id != 0 {
                self.creatures.push(c);
            }
        }
    }

    fn load_quests(&mut self, path: &Path) {
        for v in Self::records(path) {
            let mut q = QuestDefX {
                id: x_num(&v, "id", 0) as u32,
                title: x_str(&v, "title"),
                arc: x_str(&v, "arc"),
                objectives: Vec::new(),
                rewards: Vec::new(),
            };
            if let Some(objs) = get(&v, "objectives") {
                if is_array(objs) {
                    for o in objs.as_array().unwrap() {
                        q.objectives.push(QuestObjX {
                            trigger: x_str(o, "trigger"),
                            target: x_str(o, "target"),
                            count: x_num(o, "count", 1) as u32,
                            text: x_str(o, "objective_text"),
                        });
                    }
                }
            }
            if let Some(rws) = get(&v, "rewards") {
                if is_array(rws) {
                    for rw in rws.as_array().unwrap() {
                        q.rewards
                            .push((x_str(rw, "item"), x_num(rw, "count", 1) as u32));
                    }
                }
            }
            if q.id != 0 && !q.objectives.is_empty() {
                self.quests.push(q);
            }
        }
    }
}

// ============================================================================
// JSON parse helper. The C++ parser accepts trailing content after the root
// value and reads bytes; serde_json::from_slice gives equivalent results for
// the well formed content files. Errors are reported (loader skips the file).
// ============================================================================
fn parse_bytes(bytes: &[u8]) -> Result<Value, serde_json::Error> {
    serde_json::from_slice(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    const CONTENT: &str = "/Users/roy/gh/blockfall/content";

    // Golden counts + records from the verified C++ dump (full record diff was IDENTICAL).
    #[test]
    fn loads_with_cpp_parity_counts() {
        let mut reg = ContentRegistry::new();
        assert!(reg.load(CONTENT));
        assert_eq!(reg.block_count(), 51);
        assert_eq!(reg.item_count(), 60);
        assert_eq!(reg.recipe_count(), 34);
        let oak = reg.block_by_name("oak_log").expect("oak_log");
        assert_eq!((oak.id, oak.drop_item), (21, 12));
        let dirt_item = reg.item_by_name("dirt").expect("dirt item");
        assert_eq!(dirt_item.places_block, 2);
        let pick = reg.item_by_name("wood_pickaxe").expect("wood_pickaxe");
        assert_eq!((pick.tool_tier, pick.tool_kind, pick.tool_durability), (1, 1, 300));
        let r0 = reg.recipe(0);
        assert!(!r0.shapeless && r0.grid_size == 2 && r0.result_count == 4 && r0.pattern == vec![12, 0, 0, 0]);
    }

    #[test]
    fn extra_loads_creatures_quests() {
        let mut x = ContentExtra::new();
        assert!(x.load(CONTENT));
        assert_eq!(x.creatures().len(), 29);
        assert_eq!(x.quests().len(), 15);
        assert_eq!(x.quests()[0].id, 1);
        assert_eq!(x.quests()[0].title, "First Light");
    }

    #[test]
    fn recipe_match_works() {
        let mut reg = ContentRegistry::new();
        reg.load(CONTENT);
        let m = reg.recipe_match(&[12, 0, 0, 0], 2).expect("match recipe 0");
        assert_eq!((m.result, m.count), (13, 4));
    }
}
