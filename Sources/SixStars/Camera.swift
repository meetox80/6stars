import simd

struct Camera {
    var position = SIMD3<Float>(0, 0, 500)
    var yaw: Float = .pi / 2
    var pitch: Float = -0.6
    var fovY: Float = 65 * .pi / 180
    var near: Float = 0.3

    static let up = SIMD3<Float>(0, 0, 1)

    var forward: SIMD3<Float> {
        SIMD3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch))
    }

    var right: SIMD3<Float> {
        simd_normalize(simd_cross(forward, Camera.up))
    }

    mutating func look(dx: Float, dy: Float) {
        yaw -= dx * 0.0025
        pitch = max(-1.55, min(1.55, pitch - dy * 0.0025))
    }

    func viewMatrix() -> simd_float4x4 {
        let f = forward
        let s = simd_normalize(simd_cross(f, Camera.up))
        let u = simd_cross(s, f)
        let e = position
        return simd_float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, e), -simd_dot(u, e), simd_dot(f, e), 1)))
    }

    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY / 2)
        let x = y / aspect
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, 0, -1),
            SIMD4(0, 0, near, 0)))
    }
}
