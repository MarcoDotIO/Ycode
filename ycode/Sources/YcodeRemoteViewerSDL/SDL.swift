// The SDL 3 functions the Linux viewer uses, resolved at run time with
// dlopen (no SDL headers or library at build time; SDL is zlib-licensed,
// libsdl-org/SDL release 3.4). Signatures and the event layouts below are
// SDL 3's public API (SDL_video.h, SDL_render.h, SDL_events.h; checked
// against the 3.4.18 headers OpenViews vendors in
// frameworks/swiftui/Sources/COVSDL). The library is found as OpenViews
// finds it: $YCODE_SDL3_LIBRARY, $OV_SDL3_LIBRARY, the loader's search path,
// ~/.local/lib.

import Foundation
#if canImport(Glibc)
import Glibc
#endif

public struct SDLRect { public var x, y, w, h: Int32 }
public struct SDLFRect { public var x, y, w, h: Float }
/// SDL_Vertex: position, colour (0…1), texture coordinate.
public struct SDLVertex {
    public var x, y: Float
    public var r, g, b, a: Float
    public var u, v: Float
}

/// SDL_Event (a 128-byte union) and the fields read from it.
public struct SDLEvent {
    public var raw = [UInt8](repeating: 0, count: 128)
    public init() {}
    public var type: UInt32 { u32(0) }
    public var timestamp: UInt64 { raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) } }
    public func u32(_ o: Int) -> UInt32 { raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
    public func i32(_ o: Int) -> Int32 { raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int32.self) } }
    public func u16(_ o: Int) -> UInt16 { raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) } }
    public func u8(_ o: Int) -> UInt8 { raw[o] }
    public func f32(_ o: Int) -> Float { raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Float.self) } }
    public func pointer(_ o: Int) -> UnsafeRawPointer? { raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UnsafeRawPointer?.self) } }

    // SDL_KeyboardEvent
    public var keyScancode: Int32 { i32(24) }
    public var keyMod: UInt16 { u16(32) }
    public var keyDown: Bool { u8(36) != 0 }
    public var keyRepeat: Bool { u8(37) != 0 }
    // SDL_MouseMotionEvent / SDL_MouseButtonEvent
    public var motionX: Float { f32(28) }
    public var motionY: Float { f32(32) }
    public var motionState: UInt32 { u32(24) }
    public var buttonIndex: UInt8 { u8(24) }
    public var buttonX: Float { f32(28) }
    public var buttonY: Float { f32(32) }
    // SDL_MouseWheelEvent
    public var wheelX: Float { f32(24) }
    public var wheelY: Float { f32(28) }
    public var wheelFlipped: Bool { u32(32) == 1 }
    public var wheelMouseX: Float { f32(36) }
    public var wheelMouseY: Float { f32(40) }
    // SDL_WindowEvent
    public var windowData1: Int32 { i32(20) }
    public var windowData2: Int32 { i32(24) }
}

public enum SDLConst {
    public static let initVideo: UInt32 = 0x20
    public static let windowResizable: UInt64 = 0x20
    public static let windowHighPixelDensity: UInt64 = 0x2000
    public static let pixelFormatXRGB8888: UInt32 = 0x1616_1804
    public static let pixelFormatNV12: UInt32 = 0x3231_564E
    public static let textureStreaming: Int32 = 1
    public static let blendModeBlend: UInt32 = 1
    public static let scaleLinear: Int32 = 1

    public static let quit: UInt32 = 0x100
    public static let windowExposed: UInt32 = 0x204
    public static let windowResized: UInt32 = 0x206
    public static let windowPixelSizeChanged: UInt32 = 0x207
    public static let windowMouseLeave: UInt32 = 0x20D
    public static let windowFocusGained: UInt32 = 0x20E
    public static let windowFocusLost: UInt32 = 0x20F
    public static let windowCloseRequested: UInt32 = 0x210
    public static let keyDown: UInt32 = 0x300
    public static let keyUp: UInt32 = 0x301
    public static let mouseMotion: UInt32 = 0x400
    public static let mouseButtonDown: UInt32 = 0x401
    public static let mouseButtonUp: UInt32 = 0x402
    public static let mouseWheel: UInt32 = 0x403
    public static let user: UInt32 = 0x8000

    public static let kmodShift: UInt16 = 0x0003
    public static let kmodCtrl: UInt16 = 0x00C0
    public static let kmodAlt: UInt16 = 0x0300
    public static let kmodGUI: UInt16 = 0x0C00
}

public final class SDL: @unchecked Sendable {
    typealias VP = UnsafeMutableRawPointer
    let handle: UnsafeMutableRawPointer

    let Init: @convention(c) (UInt32) -> Bool
    let QuitFn: @convention(c) () -> Void
    let GetError: @convention(c) () -> UnsafePointer<CChar>?
    let SetHint: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Bool
    let CreateWindow: @convention(c) (UnsafePointer<CChar>, Int32, Int32, UInt64) -> VP?
    let DestroyWindow: @convention(c) (VP) -> Void
    let GetWindowSize: @convention(c) (VP, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Bool
    let SetWindowSize: @convention(c) (VP, Int32, Int32) -> Bool
    let GetWindowSizeInPixels: @convention(c) (VP, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Bool
    let SetWindowTitle: @convention(c) (VP, UnsafePointer<CChar>) -> Bool
    let StartTextInput: @convention(c) (VP) -> Bool
    let PollEvent: @convention(c) (UnsafeMutableRawPointer) -> Bool
    let WaitEventTimeout: @convention(c) (UnsafeMutableRawPointer, Int32) -> Bool
    let PushEvent: @convention(c) (UnsafeMutableRawPointer) -> Bool
    let GetTicksNS: @convention(c) () -> UInt64
    let GetModState: @convention(c) () -> UInt16
    let CreateRenderer: @convention(c) (VP, UnsafePointer<CChar>?) -> VP?
    let DestroyRenderer: @convention(c) (VP) -> Void
    let GetRendererName: @convention(c) (VP) -> UnsafePointer<CChar>?
    let SetRenderVSync: @convention(c) (VP, Int32) -> Bool
    let CreateTexture: @convention(c) (VP, UInt32, Int32, Int32, Int32) -> VP?
    let DestroyTexture: @convention(c) (VP) -> Void
    let UpdateTexture: @convention(c) (VP, UnsafeRawPointer?, UnsafeRawPointer, Int32) -> Bool
    let UpdateNVTexture: @convention(c) (VP, UnsafeRawPointer?, UnsafePointer<UInt8>, Int32, UnsafePointer<UInt8>, Int32) -> Bool
    let SetTextureScaleMode: @convention(c) (VP, Int32) -> Bool
    let SetRenderDrawColor: @convention(c) (VP, UInt8, UInt8, UInt8, UInt8) -> Bool
    let SetRenderDrawBlendMode: @convention(c) (VP, UInt32) -> Bool
    let RenderClear: @convention(c) (VP) -> Bool
    let RenderFillRect: @convention(c) (VP, UnsafeRawPointer?) -> Bool
    let RenderRect: @convention(c) (VP, UnsafeRawPointer?) -> Bool
    let RenderTexture: @convention(c) (VP, VP, UnsafeRawPointer?, UnsafeRawPointer?) -> Bool
    let RenderTextureRotated: @convention(c) (VP, VP, UnsafeRawPointer?, UnsafeRawPointer?, Double, UnsafeRawPointer?, Int32) -> Bool
    let RenderGeometry: @convention(c) (VP, VP?, UnsafeRawPointer, Int32, UnsafePointer<Int32>?, Int32) -> Bool
    let RenderDebugText: @convention(c) (VP, Float, Float, UnsafePointer<CChar>) -> Bool
    let SetRenderScale: @convention(c) (VP, Float, Float) -> Bool
    let RenderPresent: @convention(c) (VP) -> Bool
    let RenderReadPixels: @convention(c) (VP, UnsafeRawPointer?) -> VP?
    let ConvertSurface: @convention(c) (VP, UInt32) -> VP?
    let DestroySurface: @convention(c) (VP) -> Void

    /// The library's path when loaded.
    public let path: String

    public static func candidates() -> [String] {
        let env = ProcessInfo.processInfo.environment
        var out: [String] = []
        for k in ["YCODE_SDL3_LIBRARY", "OV_SDL3_LIBRARY"] { if let v = env[k], !v.isEmpty { out.append(v) } }
        out += ["libSDL3.so.0", "libSDL3.so"]
        out.append(NSHomeDirectory() + "/.local/lib/libSDL3.so.0")
        return out
    }

    public init?() {
        var h: UnsafeMutableRawPointer?
        var found = ""
        for c in Self.candidates() {
            if let x = dlopen(c, RTLD_NOW | RTLD_LOCAL) { h = x; found = c; break }
        }
        guard let h else { return nil }
        handle = h
        path = found
        func f<T>(_ name: String) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let a: @convention(c) (UInt32) -> Bool = f("SDL_Init"), let b: @convention(c) () -> Void = f("SDL_Quit"),
              let c: @convention(c) () -> UnsafePointer<CChar>? = f("SDL_GetError"),
              let d: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Bool = f("SDL_SetHint"),
              let e: @convention(c) (UnsafePointer<CChar>, Int32, Int32, UInt64) -> VP? = f("SDL_CreateWindow"),
              let g: @convention(c) (VP) -> Void = f("SDL_DestroyWindow"),
              let i: @convention(c) (VP, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Bool = f("SDL_GetWindowSize"),
              let j: @convention(c) (VP, Int32, Int32) -> Bool = f("SDL_SetWindowSize"),
              let k: @convention(c) (VP, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Bool = f("SDL_GetWindowSizeInPixels"),
              let l: @convention(c) (VP, UnsafePointer<CChar>) -> Bool = f("SDL_SetWindowTitle"),
              let m: @convention(c) (VP) -> Bool = f("SDL_StartTextInput"),
              let n: @convention(c) (UnsafeMutableRawPointer) -> Bool = f("SDL_PollEvent"),
              let o: @convention(c) (UnsafeMutableRawPointer, Int32) -> Bool = f("SDL_WaitEventTimeout"),
              let p: @convention(c) (UnsafeMutableRawPointer) -> Bool = f("SDL_PushEvent"),
              let q: @convention(c) () -> UInt64 = f("SDL_GetTicksNS"),
              let r: @convention(c) () -> UInt16 = f("SDL_GetModState"),
              let s: @convention(c) (VP, UnsafePointer<CChar>?) -> VP? = f("SDL_CreateRenderer"),
              let t: @convention(c) (VP) -> Void = f("SDL_DestroyRenderer"),
              let t2: @convention(c) (VP) -> UnsafePointer<CChar>? = f("SDL_GetRendererName"),
              let u: @convention(c) (VP, Int32) -> Bool = f("SDL_SetRenderVSync"),
              let v: @convention(c) (VP, UInt32, Int32, Int32, Int32) -> VP? = f("SDL_CreateTexture"),
              let w: @convention(c) (VP) -> Void = f("SDL_DestroyTexture"),
              let x: @convention(c) (VP, UnsafeRawPointer?, UnsafeRawPointer, Int32) -> Bool = f("SDL_UpdateTexture"),
              let x2: @convention(c) (VP, UnsafeRawPointer?, UnsafePointer<UInt8>, Int32, UnsafePointer<UInt8>, Int32) -> Bool = f("SDL_UpdateNVTexture"),
              let y: @convention(c) (VP, Int32) -> Bool = f("SDL_SetTextureScaleMode"),
              let z: @convention(c) (VP, UInt8, UInt8, UInt8, UInt8) -> Bool = f("SDL_SetRenderDrawColor"),
              let aa: @convention(c) (VP, UInt32) -> Bool = f("SDL_SetRenderDrawBlendMode"),
              let ab: @convention(c) (VP) -> Bool = f("SDL_RenderClear"),
              let ac: @convention(c) (VP, UnsafeRawPointer?) -> Bool = f("SDL_RenderFillRect"),
              let ac2: @convention(c) (VP, UnsafeRawPointer?) -> Bool = f("SDL_RenderRect"),
              let ad: @convention(c) (VP, VP, UnsafeRawPointer?, UnsafeRawPointer?) -> Bool = f("SDL_RenderTexture"),
              let ae: @convention(c) (VP, VP, UnsafeRawPointer?, UnsafeRawPointer?, Double, UnsafeRawPointer?, Int32) -> Bool = f("SDL_RenderTextureRotated"),
              let af: @convention(c) (VP, VP?, UnsafeRawPointer, Int32, UnsafePointer<Int32>?, Int32) -> Bool = f("SDL_RenderGeometry"),
              let ag: @convention(c) (VP, Float, Float, UnsafePointer<CChar>) -> Bool = f("SDL_RenderDebugText"),
              let ah: @convention(c) (VP, Float, Float) -> Bool = f("SDL_SetRenderScale"),
              let ai: @convention(c) (VP) -> Bool = f("SDL_RenderPresent"),
              let aj: @convention(c) (VP, UnsafeRawPointer?) -> VP? = f("SDL_RenderReadPixels"),
              let ak: @convention(c) (VP, UInt32) -> VP? = f("SDL_ConvertSurface"),
              let al: @convention(c) (VP) -> Void = f("SDL_DestroySurface")
        else { dlclose(h); return nil }
        (Init, QuitFn, GetError, SetHint, CreateWindow, DestroyWindow) = (a, b, c, d, e, g)
        (GetWindowSize, SetWindowSize, GetWindowSizeInPixels, SetWindowTitle, StartTextInput) = (i, j, k, l, m)
        (PollEvent, WaitEventTimeout, PushEvent, GetTicksNS, GetModState) = (n, o, p, q, r)
        (CreateRenderer, DestroyRenderer, GetRendererName, SetRenderVSync, CreateTexture, DestroyTexture) = (s, t, t2, u, v, w)
        (UpdateTexture, UpdateNVTexture, SetTextureScaleMode, SetRenderDrawColor, SetRenderDrawBlendMode) = (x, x2, y, z, aa)
        (RenderClear, RenderFillRect, RenderRect, RenderTexture, RenderTextureRotated, RenderGeometry) = (ab, ac, ac2, ad, ae, af)
        (RenderDebugText, SetRenderScale, RenderPresent, RenderReadPixels, ConvertSurface, DestroySurface) = (ag, ah, ai, aj, ak, al)
    }

    public var error: String { GetError().map { String(cString: $0) } ?? "" }

    /// SDL_Surface: flags, format, w, h, pitch, pixels (SDL_surface.h).
    public static func surfaceInfo(_ s: UnsafeMutableRawPointer) -> (format: UInt32, w: Int, h: Int, pitch: Int, pixels: UnsafeRawPointer?) {
        let format = s.load(fromByteOffset: 4, as: UInt32.self)
        let w = Int(s.load(fromByteOffset: 8, as: Int32.self))
        let h = Int(s.load(fromByteOffset: 12, as: Int32.self))
        let pitch = Int(s.load(fromByteOffset: 16, as: Int32.self))
        let pixels = s.load(fromByteOffset: 24, as: UnsafeRawPointer?.self)
        return (format, w, h, pitch, pixels)
    }
}
