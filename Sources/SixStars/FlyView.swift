import AppKit
import MetalKit

final class FlyView: MTKView, MTKViewDelegate {
    var renderer: Renderer!
    var world: World?
    let state = DebugState()
    var debugUI: DebugUI?
    var status: String {
        get { state.status }
        set { state.status = newValue }
    }
    var speed: Float {
        get { state.speed }
        set { state.speed = newValue }
    }
    var keys = Set<UInt16>()
    var shift = false
    var captured = false
    var uiDrag = false
    var lastFrame = CACurrentMediaTime()
    var frames = 0
    var fps: Double = 0
    var fpsWindow = CACurrentMediaTime()

    init(frame: CGRect, renderer: Renderer) {
        super.init(frame: frame, device: renderer.device)
        self.renderer = renderer
        colorPixelFormat = renderer.colorFormat
        depthStencilPixelFormat = renderer.depthFormat
        preferredFramesPerSecond = 120
        delegate = self
        speed = 120
        do {
            debugUI = try DebugUI(device: renderer.device, colorFormat: renderer.colorFormat)
        } catch {
            print("debug ui unavailable: \(error)")
        }
        renderer.debugUI = debugUI
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { release(); return }
        if event.keyCode == 50, !event.isARepeat {
            debugUI?.visible.toggle()
            return
        }
        if !event.isARepeat, let w = world {
            switch event.keyCode {
            case 5: renderer.showGrid.toggle(); return
            case 33:
                renderer.atmosphere.hour = (renderer.atmosphere.hour + 23.5).truncatingRemainder(dividingBy: 24)
                return
            case 30:
                renderer.atmosphere.hour = (renderer.atmosphere.hour + 0.5).truncatingRemainder(dividingBy: 24)
                return
            case 46: renderer.showMeshes.toggle(); return
            case 18, 19, 20:
                renderer.showClass[Int(event.keyCode) - 18].toggle()
                renderer.invalidateVisibility()
                return
            case 40:
                w.scene.invertRotation.toggle()
                w.scene.rebuild()
                renderer.invalidateVisibility()
                return
            case 31: renderer.camera = w.overviewCamera(); return
            case 15: renderer.camera = w.startCamera(); return
            default: break
            }
        }
        keys.insert(event.keyCode)
    }

    override func keyUp(with event: NSEvent) { keys.remove(event.keyCode) }

    override func flagsChanged(with event: NSEvent) { shift = event.modifierFlags.contains(.shift) }

    func uiPoint(_ e: NSEvent) -> (x: Float, y: Float) {
        let p = convert(e.locationInWindow, from: nil)
        return (Float(p.x), Float(bounds.height - p.y))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if !captured, let ui = debugUI {
            let p = uiPoint(event)
            ui.mouse(x: p.x, y: p.y)
            if ui.wantsMouse {
                ui.button(0, down: true)
                uiDrag = true
                return
            }
        }
        if !captured {
            captured = true
            debugUI?.mouseLeft()
            NSCursor.hide()
            CGAssociateMouseAndMouseCursorPosition(0)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard uiDrag, let ui = debugUI else { return }
        let p = uiPoint(event)
        ui.mouse(x: p.x, y: p.y)
        ui.button(0, down: false)
        uiDrag = false
    }

    override func rightMouseDragged(with event: NSEvent) { look(event) }

    override func mouseDragged(with event: NSEvent) {
        if uiDrag, let ui = debugUI {
            let p = uiPoint(event)
            ui.mouse(x: p.x, y: p.y)
            return
        }
        look(event)
    }

    override func mouseMoved(with event: NSEvent) {
        if captured {
            look(event)
        } else if let ui = debugUI {
            let p = uiPoint(event)
            ui.mouse(x: p.x, y: p.y)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if !captured, let ui = debugUI, ui.wantsMouse {
            let k: Float = event.hasPreciseScrollingDeltas ? 0.1 : 1
            ui.wheel(x: Float(event.scrollingDeltaX) * k, y: Float(event.scrollingDeltaY) * k)
            return
        }
        let f = Float(pow(1.08, Double(event.scrollingDeltaY > 0 ? 1 : (event.scrollingDeltaY < 0 ? -1 : 0))))
        speed = max(2, min(20000, speed * f))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
    }

    func look(_ e: NSEvent) { renderer.camera.look(dx: Float(e.deltaX), dy: Float(e.deltaY)) }

    func release() {
        if captured {
            captured = false
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
    }

    func setWorld(_ w: World) {
        world = w
        renderer.upload(w)
        renderer.camera = w.startCamera()
        speed = 40
        state.startView = { [weak self] in self?.renderer.camera = w.startCamera() }
        state.overview = { [weak self] in self?.renderer.camera = w.overviewCamera() }
    }

    func step(_ dt: Float) {
        var move = SIMD3<Float>(0, 0, 0)
        let cam = renderer.camera
        if keys.contains(13) || keys.contains(126) { move += cam.forward }
        if keys.contains(1) || keys.contains(125) { move -= cam.forward }
        if keys.contains(2) || keys.contains(124) { move += cam.right }
        if keys.contains(0) || keys.contains(123) { move -= cam.right }
        if keys.contains(14) || keys.contains(49) { move += Camera.up }
        if keys.contains(12) || keys.contains(8) { move -= Camera.up }
        if simd_length(move) > 0 {
            renderer.camera.position += simd_normalize(move) * speed * (shift ? 6 : 1) * dt
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let elapsed = now - lastFrame
        let dt = Float(min(0.1, elapsed))
        lastFrame = now
        step(dt)
        frames += 1
        if now - fpsWindow >= 0.5 {
            fps = Double(frames) / (now - fpsWindow)
            frames = 0
            fpsWindow = now
        }
        state.fps = fps
        state.frameMs = Float(elapsed * 1000)
        state.fast = shift
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let cmd = renderer.queue.makeCommandBuffer() else { return }
        let scale = Float(drawableSize.width / max(bounds.width, 1))
        debugUI?.frame(renderer: renderer, state: state, size: bounds.size, scale: scale, dt: dt)
        let t0 = CACurrentMediaTime()
        renderer.encode(cmd, pass: pass, size: drawableSize)
        state.encodeMs = Float((CACurrentMediaTime() - t0) * 1000)
        cmd.addCompletedHandler { [weak self] c in
            let gpu = Float((c.gpuEndTime - c.gpuStartTime) * 1000)
            DispatchQueue.main.async { self?.state.gpuMs = gpu }
        }
        cmd.present(drawable)
        cmd.commit()
    }
}
