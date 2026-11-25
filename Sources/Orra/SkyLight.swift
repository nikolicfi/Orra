import AppKit

/// Thin wrapper over the private SkyLight framework.
/// A window added to a custom compositor space with a high absolute level is
/// drawn above the login window, i.e. on the lock screen.
/// Private API: can break with any macOS update.
/// Diagnostics are compiled in for Debug builds only, so Release builds never log
/// track titles or write any log file.
func lpLog(_ s: String) {
    #if DEBUG
    NSLog("Orra: %@", s)
    let line = "\(Date()) \(s)\n"
    let url = URL(fileURLWithPath: "/tmp/orra.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
    #endif
}

struct LockSpace {
    private typealias ConnFn   = @convention(c) () -> Int32
    private typealias CreateFn = @convention(c) (Int32, Int32, Int) -> Int32
    private typealias LevelFn  = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddFn    = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func load<T>(_ name: String) -> T? {
        guard let h = handle, let p = dlsym(h, name) else {
            lpLog("symbol missing: \(name)")
            return nil
        }
        return unsafeBitCast(p, to: T.self)
    }

    private let cid: Int32
    private let sid: Int32
    private let showFn: SpacesFn
    private let hideFn: SpacesFn

    init?(windows: [NSWindow], level: Int32) {
        lpLog("SkyLight handle: \(Self.handle != nil)")
        guard
            let conn: ConnFn = Self.load("SLSMainConnectionID"),
            let create: CreateFn = Self.load("SLSSpaceCreate"),
            let setLevel: LevelFn = Self.load("SLSSpaceSetAbsoluteLevel"),
            let show: SpacesFn = Self.load("SLSShowSpaces"),
            let hide: SpacesFn = Self.load("SLSHideSpaces"),
            let add: AddFn = Self.load("SLSAddWindowsToSpaces")
        else { return nil }

        let c = conn()
        let s = create(c, 1, 0)
        let r1 = setLevel(c, s, level)
        let ids = windows.map { NSNumber(value: $0.windowNumber) } as CFArray
        let r2 = add(c, ids, [NSNumber(value: s)] as CFArray)
        lpLog("cid=\(c) space=\(s) level=\(level) setLevel=\(r1) add=\(r2) windows=\(windows.map { $0.windowNumber })")
        cid = c; sid = s; showFn = show; hideFn = hide
    }

    func show() { let r = showFn(cid, [NSNumber(value: sid)] as CFArray); lpLog("show -> \(r)") }
    func hide() { let r = hideFn(cid, [NSNumber(value: sid)] as CFArray); lpLog("hide -> \(r)") }
}
