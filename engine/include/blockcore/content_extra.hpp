// ============================================================================
// Blockfall — creature + quest content loader (M5, Track J content volume)
// A small companion to ContentRegistry (blocks/items/recipes) that loads the
// creature roster and the quest list from /content using the same JSON parser.
// Kept separate so the proven block/item/recipe loader is untouched.
// ============================================================================
#pragma once
#include "blockcore/json.hpp"

#include <string>
#include <vector>
#include <utility>
#include <fstream>
#include <filesystem>
#include <iterator>
#include <algorithm>
#include <cstdint>

namespace bf {

struct CreatureDefX {
    std::uint16_t id{0};
    std::string   name;
    std::string   disposition;     // passive|skittish|night_gentle|boss
    std::uint8_t  max_health{4};
    int           spawn_light_max{15};
    float         move_speed{2.0f};
    std::string   boss_pattern;    // none|stomp|shieldwall|summon_helpers
};

struct QuestObjX { std::string trigger, target, text; std::uint32_t count{1}; };
struct QuestDefX {
    std::uint32_t id{0};
    std::string   title, arc;
    std::vector<QuestObjX> objectives;
    std::vector<std::pair<std::string, std::uint32_t>> rewards;
};

class ContentExtra {
public:
    bool load(const std::string& dir) {
        load_creatures(dir + "/creatures");
        load_quests(dir + "/quests");
        std::sort(quests_.begin(), quests_.end(),
                  [](const QuestDefX& a, const QuestDefX& b) { return a.id < b.id; });
        return !creatures_.empty();
    }
    const std::vector<CreatureDefX>& creatures() const { return creatures_; }
    const std::vector<QuestDefX>&    quests()    const { return quests_; }

private:
    static std::vector<json::Value> records(const std::string& path) {
        std::vector<json::Value> out;
        namespace fs = std::filesystem;
        std::error_code ec;
        if (!fs::exists(path, ec)) return out;
        for (auto& e : fs::directory_iterator(path, ec)) {
            if (e.path().extension() != ".json") continue;
            std::ifstream f(e.path());
            std::string s((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
            auto r = json::parse(s);
            if (!r.ok) continue;
            if (r.value.is_array()) for (auto& v : r.value.as_array()) out.push_back(v);
            else out.push_back(r.value);
        }
        return out;
    }
    static std::string str(const json::Value& v, const char* k) {
        auto* p = v.get(k); return p && p->is_string() ? p->as_string() : std::string();
    }
    static long num(const json::Value& v, const char* k, long def = 0) {
        auto* p = v.get(k); return p && p->is_number() ? long(p->as_int()) : def;
    }
    static double dnum(const json::Value& v, const char* k, double def = 0) {
        auto* p = v.get(k); return p && p->is_number() ? p->as_double() : def;
    }

    void load_creatures(const std::string& path) {
        for (auto& v : records(path)) {
            CreatureDefX c;
            c.id = std::uint16_t(num(v, "id"));
            c.name = str(v, "name");
            c.disposition = str(v, "disposition");
            c.max_health = std::uint8_t(num(v, "max_health", 4));
            c.spawn_light_max = int(num(v, "spawn_light_max", 15));
            c.move_speed = float(dnum(v, "move_speed", 2.0));
            c.boss_pattern = str(v, "boss_pattern");
            if (c.id != 0) creatures_.push_back(std::move(c));
        }
    }
    void load_quests(const std::string& path) {
        for (auto& v : records(path)) {
            QuestDefX q;
            q.id = std::uint32_t(num(v, "id"));
            q.title = str(v, "title");
            q.arc = str(v, "arc");
            if (auto* objs = v.get("objectives"); objs && objs->is_array())
                for (auto& o : objs->as_array()) {
                    QuestObjX ob;
                    ob.trigger = str(o, "trigger");
                    ob.target = str(o, "target");
                    ob.count = std::uint32_t(num(o, "count", 1));
                    ob.text = str(o, "objective_text");
                    q.objectives.push_back(std::move(ob));
                }
            if (auto* rws = v.get("rewards"); rws && rws->is_array())
                for (auto& rw : rws->as_array())
                    q.rewards.emplace_back(str(rw, "item"), std::uint32_t(num(rw, "count", 1)));
            if (q.id != 0 && !q.objectives.empty()) quests_.push_back(std::move(q));
        }
    }

    std::vector<CreatureDefX> creatures_;
    std::vector<QuestDefX>    quests_;
};

} // namespace bf
