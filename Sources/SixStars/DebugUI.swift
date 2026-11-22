import Foundation
import Metal
import simd
import CImGui

final class DebugState {
    var status = "Starting"
    var fps: Double = 0
    var frameMs: Float = 0
    var encodeMs: Float = 0
    var gpuMs: Float = 0
    var speed: Float = 40
    var fast = false
    var startView: (() -> Void)?
    var overview: (() -> Void)?
}

@inline(__always) private func ig<T: RawRepresentable>(_ v: T) -> Int32 where T.RawValue: BinaryInteger {
    Int32(truncatingIfNeeded: v.rawValue)
}

private func text(_ s: String) { igTextUnformatted(s, nil) }

private func dim(_ s: String) {
    igPushStyleColor_Vec4(ig(ImGuiCol_Text), ImVec4_c(x: 0.60, y: 0.57, z: 0.52, w: 1))
    igTextUnformatted(s, nil)
    igPopStyleColor(1)
}

private let zero = ImVec2_c(x: 0, y: 0)

private func grouped(_ n: Int) -> String {
    let digits = Array(String(abs(n)))
    var out = ""
    for (i, ch) in digits.enumerated() {
        if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
        out.append(ch)
    }
    return (n < 0 ? "-" : "") + out
}

final class DebugUI {
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct ImVert { packed_float2 pos; packed_float2 uv; uint col; };
    struct ImOut { float4 position [[position]]; float2 uv; float4 color; };
    static float3 toLinear(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }
    vertex ImOut imguiVertex(uint vid [[vertex_id]], const device ImVert* v [[buffer(0)]], constant float4x4& proj [[buffer(1)]]) {
        ImVert x = v[vid];
        ImOut o;
        o.position = proj * float4(float2(x.pos), 0.0, 1.0);
        o.uv = float2(x.uv);
        float4 c = unpack_unorm4x8_to_float(x.col);
        o.color = float4(toLinear(c.rgb), c.a);
        return o;
    }
    fragment float4 imguiFragment(ImOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        return in.color * t.sample(s, in.uv);
    }
    """
    static let panelWidth: Float = 380

    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    var textures: [UInt64: MTLTexture] = [:]
    var nextTexture: UInt64 = 1
    var vertexBuffers = [MTLBuffer?](repeating: nil, count: 4)
    var indexBuffers = [MTLBuffer?](repeating: nil, count: 4)
    var slot = 0
    var visible = true
    var built = false
    var history = [Float](repeating: 0, count: 240)
    var historyIndex = 0

    init(device: MTLDevice, colorFormat: MTLPixelFormat) throws {
        self.device = device
        let lib = try device.makeLibrary(source: DebugUI.shader, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "imguiVertex")
        d.fragmentFunction = lib.makeFunction(name: "imguiFragment")
        d.colorAttachments[0].pixelFormat = colorFormat
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        d.colorAttachments[0].sourceAlphaBlendFactor = .one
        d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: d)
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let s = device.makeSamplerState(descriptor: sd) else { throw RendererError.setup("no debug ui sampler") }
        sampler = s
        igCreateContext(nil)
        let io = igGetIO_Nil()!
        io.pointee.IniFilename = nil
        io.pointee.LogFilename = nil
        io.pointee.BackendFlags |= ig(ImGuiBackendFlags_RendererHasVtxOffset) | ig(ImGuiBackendFlags_RendererHasTextures)
        ImFontAtlas_AddFontDefaultVector(io.pointee.Fonts, nil)
        DebugUI.applyStyle()
    }

    static func applyStyle() {
        igStyleColorsDark(nil)
        let st = igGetStyle()!
        st.pointee.FontSizeBase = 15
        st.pointee.WindowRounding = 3
        st.pointee.FrameRounding = 2
        st.pointee.GrabRounding = 2
        st.pointee.WindowPadding = ImVec2_c(x: 10, y: 8)
        st.pointee.ItemSpacing = ImVec2_c(x: 8, y: 5)
        func set(_ c: ImGuiCol_, _ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
            withUnsafeMutableBytes(of: &st.pointee.Colors) { raw in
                raw.bindMemory(to: ImVec4_c.self)[Int(ig(c))] = ImVec4_c(x: r, y: g, z: b, w: a)
            }
        }
        set(ImGuiCol_Text, 0.92, 0.89, 0.83)
        set(ImGuiCol_TextDisabled, 0.55, 0.52, 0.48)
        set(ImGuiCol_WindowBg, 0.055, 0.05, 0.045, 0.88)
        set(ImGuiCol_Border, 0.42, 0.10, 0.08, 0.6)
        set(ImGuiCol_TitleBg, 0.20, 0.04, 0.03)
        set(ImGuiCol_TitleBgActive, 0.42, 0.06, 0.04)
        set(ImGuiCol_TitleBgCollapsed, 0.16, 0.03, 0.02, 0.8)
        set(ImGuiCol_Header, 0.36, 0.06, 0.04, 0.75)
        set(ImGuiCol_HeaderHovered, 0.55, 0.09, 0.06, 0.85)
        set(ImGuiCol_HeaderActive, 0.68, 0.11, 0.07)
        set(ImGuiCol_FrameBg, 0.25, 0.22, 0.20, 0.95)
        set(ImGuiCol_FrameBgHovered, 0.40, 0.15, 0.11)
        set(ImGuiCol_FrameBgActive, 0.50, 0.14, 0.10)
        set(ImGuiCol_CheckMark, 0.96, 0.93, 0.87)
        set(ImGuiCol_SliderGrab, 0.72, 0.14, 0.10)
        set(ImGuiCol_SliderGrabActive, 0.92, 0.22, 0.16)
        set(ImGuiCol_Button, 0.36, 0.06, 0.04, 0.8)
        set(ImGuiCol_ButtonHovered, 0.55, 0.09, 0.06)
        set(ImGuiCol_ButtonActive, 0.68, 0.11, 0.07)
        set(ImGuiCol_Separator, 0.42, 0.10, 0.08, 0.6)
        set(ImGuiCol_PlotLines, 0.92, 0.30, 0.22)
        set(ImGuiCol_PlotLinesHovered, 1.0, 0.45, 0.35)
        set(ImGuiCol_ResizeGrip, 0.42, 0.06, 0.04, 0.4)
        set(ImGuiCol_ResizeGripHovered, 0.55, 0.09, 0.06, 0.7)
        set(ImGuiCol_ResizeGripActive, 0.68, 0.11, 0.07, 0.9)
    }

    var wantsMouse: Bool { visible && igGetIO_Nil().pointee.WantCaptureMouse }

    func mouse(x: Float, y: Float) { ImGuiIO_AddMousePosEvent(igGetIO_Nil(), x, y) }

    func mouseLeft() { ImGuiIO_AddMousePosEvent(igGetIO_Nil(), -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude) }

    func button(_ b: Int32, down: Bool) { ImGuiIO_AddMouseButtonEvent(igGetIO_Nil(), b, down) }

    func wheel(x: Float, y: Float) { ImGuiIO_AddMouseWheelEvent(igGetIO_Nil(), x, y) }

    func frame(renderer r: Renderer, state s: DebugState, size: CGSize, scale: Float, dt: Float) {
        let io = igGetIO_Nil()!
        io.pointee.DisplaySize = ImVec2_c(x: Float(size.width), y: Float(size.height))
        io.pointee.DisplayFramebufferScale = ImVec2_c(x: scale, y: scale)
        io.pointee.DeltaTime = max(dt, 1.0 / 1000)
        history[historyIndex] = s.frameMs
        historyIndex = (historyIndex + 1) % history.count
        igNewFrame()
        if visible { panel(r, s) }
        igRender()
        built = true
    }

    private func panel(_ r: Renderer, _ s: DebugState) {
        igSetNextWindowPos(ImVec2_c(x: 12, y: 12), ig(ImGuiCond_FirstUseEver), zero)
        defer { igEnd() }
        guard igBegin("6stars", nil, ig(ImGuiWindowFlags_AlwaysAutoResize)) else { return }
        text(String(format: "%.0f fps   %.2f ms   cpu %.1f ms   gpu %.1f ms", s.fps, s.frameMs, s.encodeMs, s.gpuMs))
        let peak = max(34, (history.max() ?? 0) * 1.15)
        history.withUnsafeBufferPointer { p in
            igPlotLines_FloatPtr("##frame", p.baseAddress, Int32(p.count), Int32(historyIndex), "frame time", 0, peak,
                                 ImVec2_c(x: DebugUI.panelWidth, y: 54), Int32(MemoryLayout<Float>.stride))
        }
        guard let sc = r.scene else {
            dim(s.status)
            return
        }
        let open = ig(ImGuiTreeNodeFlags_DefaultOpen)
        if igCollapsingHeader_TreeNodeFlags("camera", open) {
            let c = r.camera
            text(String(format: "pos  %9.1f %9.1f %7.1f", c.position.x, c.position.y, c.position.z))
            text(String(format: "yaw %4.0f°   pitch %4.0f°%@", c.yaw * 180 / .pi, c.pitch * 180 / .pi, s.fast ? "   fast ×6" : ""))
            var sp = s.speed
            igSetNextItemWidth(220)
            if igSliderFloat("fly speed", &sp, 2, 2000, "%.0f m/s", ig(ImGuiSliderFlags_Logarithmic)) { s.speed = sp }
            if igButton("start view", zero) { s.startView?() }
            igSameLine(0, -1)
            if igButton("overview", zero) { s.overview?() }
        }
        if igCollapsingHeader_TreeNodeFlags("time and weather", open) {
            var h = r.atmosphere.hour
            igSetNextItemWidth(220)
            if igSliderFloat("hour", &h, 0, 23.99, String(format: "%02d:%02d", Int(h), Int((h - floor(h)) * 60)), 0) { r.atmosphere.hour = h }
            let sun = r.atmosphere.sunDirection
            text(String(format: "%@ · sun elevation %.1f°", r.atmosphere.weather, asin(max(-1, min(1, sun.z))) * 180 / .pi))
        }
        if igCollapsingHeader_TreeNodeFlags("world", open) {
            text("\(grouped(sc.entityCount)) map entities, \(grouped(sc.matched)) with models")
            dim("\(grouped(sc.catalog.entries.count)) drawables catalogued")
            var lod = sc.lodDistanceScale * r.lodFactor
            igSetNextItemWidth(220)
            if igSliderFloat("LOD distance", &lod, 1, 6, "×%.1f", 0) {
                r.lodFactor = lod / sc.lodDistanceScale
                r.invalidateVisibility()
            }
            var models = r.showMeshes
            if igCheckbox("models", &models) { r.showMeshes = models }
            for (i, name) in ["HD", "LOD", "SLOD"].enumerated() {
                igSameLine(0, -1)
                var on = r.showClass[i]
                if igCheckbox(name, &on) {
                    r.showClass[i] = on
                    r.invalidateVisibility()
                }
            }
        }
        if igCollapsingHeader_TreeNodeFlags("rendering", open) {
            text("\(grouped(r.visibleInstances)) visible · \(grouped(r.drawnInstances)) drawn · \(grouped(r.drawCalls)) draws")
            text(String(format: "%.1fM triangles", Double(r.mainTris) / 1e6))
            dim("shadow cascades " + r.shadowStats.map { String(format: "%d/%.1fM", $0.0, Double($0.1) / 1e6) }.joined(separator: "  "))
            var shadows = r.shadows.enabled
            if igCheckbox("shadows", &shadows) { r.shadows.enabled = shadows }
            igSameLine(0, -1)
            var occl = r.occlusionEnabled
            if igCheckbox("occlusion", &occl) {
                r.occlusionEnabled = occl
                r.invalidateVisibility()
            }
            igSameLine(0, -1)
            var bloom = r.atmosphere.bloomEnabled
            if igCheckbox("bloom", &bloom) { r.atmosphere.bloomEnabled = bloom }
            var taa = r.taaEnabled
            if igCheckbox("TAA", &taa) { r.taaEnabled = taa }
            igSameLine(0, -1)
            var gi = r.deferred.giEnabled
            if igCheckbox("GI", &gi) { r.deferred.giEnabled = gi }
            igSameLine(0, -1)
            var ssr = r.deferred.reflectionsEnabled
            if igCheckbox("reflections", &ssr) { r.deferred.reflectionsEnabled = ssr }
            var sharp = r.atmosphere.sharpness
            igSetNextItemWidth(220)
            if igSliderFloat("sharpen", &sharp, 0, 1, "%.2f", 0) { r.atmosphere.sharpness = sharp }
            igSameLine(0, -1)
            var grid = r.showGrid
            if igCheckbox("grid", &grid) { r.showGrid = grid }
        }
        if igCollapsingHeader_TreeNodeFlags("grade", 0) {
            let at = r.atmosphere
            var v = at.exposureBias
            igSetNextItemWidth(220)
            if igSliderFloat("exposure bias", &v, -3, 3, "%+.2f EV", 0) { at.exposureBias = v }
            v = at.saturation
            igSetNextItemWidth(220)
            if igSliderFloat("saturation", &v, 0, 2, "%.2f", 0) { at.saturation = v }
            v = at.contrast
            igSetNextItemWidth(220)
            if igSliderFloat("contrast", &v, 0.5, 2, "%.2f", 0) { at.contrast = v }
            v = at.warmth
            igSetNextItemWidth(220)
            if igSliderFloat("warmth", &v, -1, 1, "%.2f", 0) { at.warmth = v }
            if igButton("reset grade", zero) {
                at.exposureBias = Atmosphere.defaultGrade[0]
                at.saturation = Atmosphere.defaultGrade[1]
                at.contrast = Atmosphere.defaultGrade[2]
                at.warmth = Atmosphere.defaultGrade[3]
            }
        }
        if igCollapsingHeader_TreeNodeFlags("streaming", 0) {
            if let st = r.streamer?.stats {
                text(String(format: "meshes %d loaded · %d queued · %d undecodable", st.loaded, st.pending, st.failed))
                dim(String(format: "%.0f MB", Double(st.bytes) / 1e6))
            }
            if let ts = r.textures?.stats {
                text(String(format: "textures %d of %d · %d queued · %d undecodable", ts.loaded, ts.slots - 2, ts.pending, ts.failed))
                dim(String(format: "%.0f MB · %d materials", Double(ts.bytes) / 1e6, r.materials?.count ?? 0))
            }
        }
        if igCollapsingHeader_TreeNodeFlags("controls", 0) {
            dim("click the view to look around, Esc frees the mouse")
            dim("WASD/arrows move · E/Space up · Q/C down · Shift fast")
            dim("scroll: fly speed · [ ] time of day · ` hides this panel")
            dim("M models · 1/2/3 HD/LOD/SLOD · G grid · O overview · R start view")
        }
    }

    private func updateTexture(_ t: UnsafeMutablePointer<ImTextureData>) {
        let status = t.pointee.Status
        if status == ImTextureStatus_WantCreate {
            let w = Int(t.pointee.Width), h = Int(t.pointee.Height)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: d), let px = t.pointee.Pixels else { return }
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
            let id = nextTexture
            nextTexture += 1
            textures[id] = tex
            ImTextureData_SetTexID(t, id)
            ImTextureData_SetStatus(t, ImTextureStatus_OK)
        } else if status == ImTextureStatus_WantUpdates, let tex = textures[t.pointee.TexID] {
            let ups = t.pointee.Updates
            for i in 0..<Int(ups.Size) {
                let u = ups.Data[i]
                guard let px = ImTextureData_GetPixelsAt(t, Int32(u.x), Int32(u.y)) else { continue }
                tex.replace(region: MTLRegionMake2D(Int(u.x), Int(u.y), Int(u.w), Int(u.h)), mipmapLevel: 0, withBytes: px,
                            bytesPerRow: Int(t.pointee.Width) * 4)
            }
            ImTextureData_SetStatus(t, ImTextureStatus_OK)
        } else if status == ImTextureStatus_WantDestroy, t.pointee.UnusedFrames > 0 {
            textures.removeValue(forKey: t.pointee.TexID)
            ImTextureData_SetTexID(t, 0)
            ImTextureData_SetStatus(t, ImTextureStatus_Destroyed)
        }
    }

    func render(_ enc: MTLRenderCommandEncoder, width: Int, height: Int) {
        guard built, let dd = igGetDrawData(), dd.pointee.Valid else { return }
        let d = dd.pointee
        if let texs = d.Textures {
            for i in 0..<Int(texs.pointee.Size) {
                if let t = texs.pointee.Data[i] { updateTexture(t) }
            }
        }
        guard width > 0, height > 0, d.CmdLists.Size > 0, d.TotalVtxCount > 0 else { return }
        let vstride = MemoryLayout<ImDrawVert>.stride, istride = MemoryLayout<ImDrawIdx>.stride
        let vbytes = Int(d.TotalVtxCount) * vstride, ibytes = Int(d.TotalIdxCount) * istride
        slot = (slot + 1) % vertexBuffers.count
        if (vertexBuffers[slot]?.length ?? 0) < vbytes { vertexBuffers[slot] = device.makeBuffer(length: max(vbytes * 2, 1 << 16), options: .storageModeShared) }
        if (indexBuffers[slot]?.length ?? 0) < ibytes { indexBuffers[slot] = device.makeBuffer(length: max(ibytes * 2, 1 << 15), options: .storageModeShared) }
        guard let vb = vertexBuffers[slot], let ib = indexBuffers[slot] else { return }
        let l = d.DisplayPos.x, rr = l + d.DisplaySize.x, t = d.DisplayPos.y, b = t + d.DisplaySize.y
        var proj = simd_float4x4(columns: (SIMD4(2 / (rr - l), 0, 0, 0), SIMD4(0, 2 / (t - b), 0, 0), SIMD4(0, 0, 0.5, 0),
                                           SIMD4((rr + l) / (l - rr), (t + b) / (b - t), 0.5, 1)))
        let sx = d.FramebufferScale.x, sy = d.FramebufferScale.y
        enc.setRenderPipelineState(pipeline)
        enc.setCullMode(.none)
        enc.setVertexBuffer(vb, offset: 0, index: 0)
        enc.setVertexBytes(&proj, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        var vo = 0, io = 0
        let lists = d.CmdLists
        for li in 0..<Int(lists.Size) {
            guard let list = lists.Data[li] else { continue }
            let vcount = Int(list.pointee.VtxBuffer.Size), icount = Int(list.pointee.IdxBuffer.Size)
            memcpy(vb.contents() + vo * vstride, list.pointee.VtxBuffer.Data, vcount * vstride)
            memcpy(ib.contents() + io * istride, list.pointee.IdxBuffer.Data, icount * istride)
            let cmds = list.pointee.CmdBuffer
            for ci in 0..<Int(cmds.Size) {
                let cmd = cmds.Data + ci
                if cmd.pointee.UserCallback != nil { continue }
                let cr = cmd.pointee.ClipRect
                let x0 = max(0, (cr.x - l) * sx), y0 = max(0, (cr.y - t) * sy)
                let x1 = min(Float(width), (cr.z - l) * sx), y1 = min(Float(height), (cr.w - t) * sy)
                guard x1 > x0, y1 > y0, cmd.pointee.ElemCount > 0 else { continue }
                enc.setScissorRect(MTLScissorRect(x: Int(x0), y: Int(y0), width: max(1, Int(x1) - Int(x0)), height: max(1, Int(y1) - Int(y0))))
                if let tex = textures[ImDrawCmd_GetTexID(cmd)] { enc.setFragmentTexture(tex, index: 0) }
                enc.setVertexBufferOffset((vo + Int(cmd.pointee.VtxOffset)) * vstride, index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(cmd.pointee.ElemCount), indexType: .uint16, indexBuffer: ib,
                                          indexBufferOffset: (io + Int(cmd.pointee.IdxOffset)) * istride)
            }
            vo += vcount
            io += icount
        }
        enc.setScissorRect(MTLScissorRect(x: 0, y: 0, width: width, height: height))
    }
}
