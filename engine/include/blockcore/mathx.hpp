// ============================================================================
// Blockfall — minimal column-major 4x4 math for camera/view (engine side).
// Column-major so a bf_mat4 (float[16]) drops straight into a Metal uniform.
// Kept tiny and dependency-free; not a general linear-algebra library.
// ============================================================================
#pragma once
#include <cmath>
#include <cstdint>

namespace bf {

struct V3 { float x{}, y{}, z{}; };
struct M4 { float m[16]{}; };   // column-major

inline V3 operator+(V3 a, V3 b) { return {a.x+b.x, a.y+b.y, a.z+b.z}; }
inline V3 operator-(V3 a, V3 b) { return {a.x-b.x, a.y-b.y, a.z-b.z}; }
inline V3 operator*(V3 a, float s) { return {a.x*s, a.y*s, a.z*s}; }
inline float dot(V3 a, V3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
inline V3 cross(V3 a, V3 b) {
    return { a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x };
}
inline V3 normalize(V3 v) {
    float l = std::sqrt(dot(v, v));
    return l > 1e-6f ? v * (1.0f / l) : V3{0,0,0};
}

inline M4 identity() {
    M4 r; r.m[0] = r.m[5] = r.m[10] = r.m[15] = 1.0f; return r;
}

// Right-handed look-at, column-major.
inline M4 look_at(V3 eye, V3 center, V3 up) {
    V3 f = normalize(center - eye);
    V3 s = normalize(cross(f, up));
    V3 u = cross(s, f);
    M4 r{};
    r.m[0] = s.x;  r.m[4] = s.y;  r.m[8]  = s.z;  r.m[12] = -dot(s, eye);
    r.m[1] = u.x;  r.m[5] = u.y;  r.m[9]  = u.z;  r.m[13] = -dot(u, eye);
    r.m[2] = -f.x; r.m[6] = -f.y; r.m[10] = -f.z; r.m[14] =  dot(f, eye);
    r.m[15] = 1.0f;
    return r;
}

// Perspective, Metal NDC depth [0,1], column-major.
inline M4 perspective(float fovy_rad, float aspect, float znear, float zfar) {
    float t = std::tan(fovy_rad * 0.5f);
    M4 r{};
    r.m[0]  = 1.0f / (aspect * t);
    r.m[5]  = 1.0f / t;
    r.m[10] = zfar / (znear - zfar);
    r.m[11] = -1.0f;
    r.m[14] = (zfar * znear) / (znear - zfar);
    return r;
}

// Forward direction from yaw (around +Y) and pitch.
inline V3 forward_from(float yaw, float pitch) {
    return normalize(V3{
        std::cos(pitch) * std::sin(yaw),
        std::sin(pitch),
        std::cos(pitch) * std::cos(yaw)   // note: -Z forward handled in look_at
    });
}

} // namespace bf
