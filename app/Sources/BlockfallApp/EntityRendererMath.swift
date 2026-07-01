import simd

extension EntityRenderer {
    // -----------------------------------------------------------------------
    // Matrix helpers
    static func trans(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }
    static func scaleM(_ s: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.0.x = s.x
        m.columns.1.y = s.y
        m.columns.2.z = s.z
        return m
    }
    static func rotY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4( c, 0, -s, 0)
        m.columns.2 = SIMD4( s, 0,  c, 0)
        return m
    }
    static func rotX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        var m = matrix_identity_float4x4
        m.columns.1 = SIMD4(0,  c, s, 0)
        m.columns.2 = SIMD4(0, -s, c, 0)
        return m
    }
    static func rotZ(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4( c, s, 0, 0)
        m.columns.1 = SIMD4(-s, c, 0, 0)
        return m
    }
}
