// ============================================================================
// Blockfall — Minimal recursive-descent JSON parser (header-only)
// engine/include/blockcore/json.hpp
// C++23, no external dependencies.
// ============================================================================
#pragma once
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <unordered_map>
#include <variant>
#include <vector>

namespace bf::json {

// Forward declaration so Value can reference itself.
struct Value;

using Null   = std::monostate;
using Bool   = bool;
using Int    = std::int64_t;
using Double = double;
using String = std::string;
using Array  = std::vector<Value>;
using Object = std::unordered_map<std::string, Value>;

// ---- Value type ----------------------------------------------------------
struct Value {
    std::variant<Null, Bool, Int, Double, String, Array, Object> data;

    Value()                        : data(Null{}) {}
    explicit Value(bool v)         : data(v) {}
    explicit Value(Int v)          : data(v) {}
    explicit Value(Double v)       : data(v) {}
    explicit Value(std::string v)  : data(std::move(v)) {}
    explicit Value(Array v)        : data(std::move(v)) {}
    explicit Value(Object v)       : data(std::move(v)) {}

    bool is_null()   const { return std::holds_alternative<Null>(data);   }
    bool is_bool()   const { return std::holds_alternative<Bool>(data);   }
    bool is_int()    const { return std::holds_alternative<Int>(data);    }
    bool is_double() const { return std::holds_alternative<Double>(data); }
    bool is_number() const { return is_int() || is_double(); }
    bool is_string() const { return std::holds_alternative<String>(data); }
    bool is_array()  const { return std::holds_alternative<Array>(data);  }
    bool is_object() const { return std::holds_alternative<Object>(data); }

    // Accessors — return default on type mismatch (no throw).
    bool               as_bool()   const { return is_bool()   ? std::get<Bool>(data)   : false; }
    Int                as_int()    const {
        if (is_int())    return std::get<Int>(data);
        if (is_double()) return static_cast<Int>(std::get<Double>(data));
        return 0;
    }
    double             as_double() const {
        if (is_double()) return std::get<Double>(data);
        if (is_int())    return static_cast<double>(std::get<Int>(data));
        return 0.0;
    }
    const std::string& as_string() const {
        static const std::string empty;
        return is_string() ? std::get<String>(data) : empty;
    }
    const Array&  as_array()  const {
        static const Array empty;
        return is_array() ? std::get<Array>(data) : empty;
    }
    const Object& as_object() const {
        static const Object empty;
        return is_object() ? std::get<Object>(data) : empty;
    }

    // Object member access — returns nullptr if not an object or key absent.
    const Value* get(const std::string& key) const {
        if (!is_object()) return nullptr;
        const auto& obj = std::get<Object>(data);
        auto it = obj.find(key);
        return it != obj.end() ? &it->second : nullptr;
    }
    bool contains(const std::string& key) const { return get(key) != nullptr; }

    // Array element access — returns nullptr on out-of-bounds.
    const Value* at(std::size_t idx) const {
        if (!is_array()) return nullptr;
        const auto& arr = std::get<Array>(data);
        return idx < arr.size() ? &arr[idx] : nullptr;
    }
    std::size_t size() const {
        if (is_array())  return std::get<Array>(data).size();
        if (is_object()) return std::get<Object>(data).size();
        return 0;
    }
};

// ---- Parse result --------------------------------------------------------
struct ParseResult {
    Value value;
    bool  ok{false};
    std::string error;
};

// ---- Parser (internal) ---------------------------------------------------
namespace detail {

struct Parser {
    const char* src{nullptr};
    std::size_t pos{0};
    std::size_t len{0};

    char peek() const { return pos < len ? src[pos] : '\0'; }
    char advance() { return pos < len ? src[pos++] : '\0'; }
    bool eof() const { return pos >= len; }

    void skip_ws() {
        while (!eof() && (src[pos] == ' ' || src[pos] == '\t' ||
                          src[pos] == '\r' || src[pos] == '\n'))
            ++pos;
    }

    bool expect(char c) {
        skip_ws();
        if (peek() == c) { ++pos; return true; }
        return false;
    }

    // Parse a JSON string literal (assumes opening " already not consumed).
    std::optional<std::string> parse_string() {
        skip_ws();
        if (peek() != '"') return std::nullopt;
        ++pos; // consume opening "
        std::string result;
        result.reserve(32);
        while (!eof()) {
            char c = advance();
            if (c == '"') return result;
            if (c == '\\') {
                if (eof()) return std::nullopt;
                char esc = advance();
                switch (esc) {
                    case '"':  result += '"';  break;
                    case '\\': result += '\\'; break;
                    case '/':  result += '/';  break;
                    case 'n':  result += '\n'; break;
                    case 'r':  result += '\r'; break;
                    case 't':  result += '\t'; break;
                    case 'b':  result += '\b'; break;
                    case 'f':  result += '\f'; break;
                    case 'u': {
                        // Consume 4 hex digits, basic Latin-1 approximation.
                        if (pos + 4 > len) return std::nullopt;
                        char hex[5] = {src[pos], src[pos+1], src[pos+2], src[pos+3], '\0'};
                        pos += 4;
                        unsigned long cp = std::strtoul(hex, nullptr, 16);
                        if (cp < 0x80) {
                            result += static_cast<char>(cp);
                        } else if (cp < 0x800) {
                            result += static_cast<char>(0xC0 | (cp >> 6));
                            result += static_cast<char>(0x80 | (cp & 0x3F));
                        } else {
                            result += static_cast<char>(0xE0 | (cp >> 12));
                            result += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                            result += static_cast<char>(0x80 | (cp & 0x3F));
                        }
                        break;
                    }
                    default: return std::nullopt;
                }
            } else {
                result += c;
            }
        }
        return std::nullopt; // unterminated string
    }

    // Parse a number (int or double).
    std::optional<Value> parse_number() {
        skip_ws();
        std::size_t start = pos;
        if (peek() == '-') { ++pos; }
        if (eof() || (src[pos] < '0' || src[pos] > '9')) { pos = start; return std::nullopt; }

        while (!eof() && src[pos] >= '0' && src[pos] <= '9') ++pos;
        bool is_fp = false;
        if (!eof() && src[pos] == '.') { is_fp = true; ++pos;
            while (!eof() && src[pos] >= '0' && src[pos] <= '9') ++pos; }
        if (!eof() && (src[pos] == 'e' || src[pos] == 'E')) {
            is_fp = true; ++pos;
            if (!eof() && (src[pos] == '+' || src[pos] == '-')) ++pos;
            while (!eof() && src[pos] >= '0' && src[pos] <= '9') ++pos;
        }
        const char* num_start = src + start;
        if (is_fp) {
            char* end;
            double d = std::strtod(num_start, &end);
            return Value{d};
        } else {
            char* end;
            long long i = std::strtoll(num_start, &end, 10);
            return Value{static_cast<Int>(i)};
        }
    }

    std::optional<Value> parse_array() {
        // Opening '[' already consumed by caller.
        Array arr;
        skip_ws();
        if (peek() == ']') { ++pos; return Value{std::move(arr)}; }
        while (true) {
            skip_ws();
            auto v = parse_value();
            if (!v) return std::nullopt;
            arr.push_back(std::move(*v));
            skip_ws();
            if (peek() == ',') { ++pos; continue; }
            if (peek() == ']') { ++pos; break; }
            return std::nullopt;
        }
        return Value{std::move(arr)};
    }

    std::optional<Value> parse_object() {
        // Opening '{' already consumed by caller.
        Object obj;
        skip_ws();
        if (peek() == '}') { ++pos; return Value{std::move(obj)}; }
        while (true) {
            skip_ws();
            auto key = parse_string();
            if (!key) return std::nullopt;
            skip_ws();
            if (peek() != ':') return std::nullopt;
            ++pos;
            skip_ws();
            auto val = parse_value();
            if (!val) return std::nullopt;
            obj[std::move(*key)] = std::move(*val);
            skip_ws();
            if (peek() == ',') { ++pos; continue; }
            if (peek() == '}') { ++pos; break; }
            return std::nullopt;
        }
        return Value{std::move(obj)};
    }

    std::optional<Value> parse_value() {
        skip_ws();
        char c = peek();
        if (c == '"') {
            auto s = parse_string();
            if (!s) return std::nullopt;
            return Value{std::move(*s)};
        }
        if (c == '[') { ++pos; return parse_array();  }
        if (c == '{') { ++pos; return parse_object(); }
        if (c == 't') {
            if (pos + 4 <= len && std::strncmp(src + pos, "true", 4) == 0) {
                pos += 4; return Value{true};
            }
            return std::nullopt;
        }
        if (c == 'f') {
            if (pos + 5 <= len && std::strncmp(src + pos, "false", 5) == 0) {
                pos += 5; return Value{false};
            }
            return std::nullopt;
        }
        if (c == 'n') {
            if (pos + 4 <= len && std::strncmp(src + pos, "null", 4) == 0) {
                pos += 4; return Value{};
            }
            return std::nullopt;
        }
        if (c == '-' || (c >= '0' && c <= '9')) {
            return parse_number();
        }
        return std::nullopt;
    }
};

} // namespace detail

// ---- Public API ----------------------------------------------------------
inline ParseResult parse(const std::string& input) {
    detail::Parser p;
    p.src = input.data();
    p.len = input.size();
    p.pos = 0;

    auto v = p.parse_value();
    if (!v) {
        return ParseResult{Value{}, false, "JSON parse error near offset " + std::to_string(p.pos)};
    }
    p.skip_ws();
    // Extra content after root value → still accept (real files sometimes have trailing newlines).
    return ParseResult{std::move(*v), true, {}};
}

} // namespace bf::json
