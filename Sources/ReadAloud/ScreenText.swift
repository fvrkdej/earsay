// ScreenText: take a picture of part of the screen so Vision can read it.
//
// Uses ScreenCaptureKit, macOS's screen capture system. Needs the Screen Recording
// permission (asked once). Earsay's own windows (the pill) are left out of the
// picture. The picture lives in memory only and is thrown away after reading.
import AppKit
import ScreenCaptureKit

enum ScreenText {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    static func askPermission() { _ = CGRequestScreenCaptureAccess() }

    /// The normal app window under this point (not ours): its frame (screen points,
    /// top-left origin), its id and the app that owns it.
    static func window(at p: CGPoint) -> (frame: CGRect, id: CGWindowID, pid: pid_t)? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for w in info {                                   // front-most first
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.contains(p),
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            return (r, id, pid)
        }
        return nil
    }

    /// The front window of an app: id, frame and title (the title needs Screen Recording).
    static func frontWindow(of pid: pid_t) -> (id: CGWindowID, frame: CGRect, title: String)? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in info where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.width > 200, r.height > 200 else { continue }
            return (id, r, w[kCGWindowName as String] as? String ?? "")
        }
        return nil
    }

    /// Capture this area (screen points, top-left origin). Returns the picture, the area
    /// actually captured (clipped to one display) and pixels per point.
    static func capture(_ area: CGRect, includeOurs: Bool = false) async throws -> (CGImage, CGRect, CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // The display holding most of the area.
        guard let display = content.displays.max(by: {
            area.intersection($0.frame).width * area.intersection($0.frame).height
                < area.intersection($1.frame).width * area.intersection($1.frame).height
        }) else { throw CocoaError(.featureUnsupported) }
        let ours = includeOurs ? [] : content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
        let r = area.intersection(display.frame)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.sourceRect = r.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int(r.width * scale)
        config.height = Int(r.height * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, r, scale)
    }

    /// Capture one window by id, even if other windows cover it. Returns the picture,
    /// the window's frame (screen points, top-left origin) and pixels per point.
    static func capture(window id: CGWindowID) async throws -> (CGImage, CGRect, CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let w = content.windows.first(where: { $0.windowID == id }) else { throw CocoaError(.fileNoSuchFile) }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(w.frame.width * scale)
        config.height = Int(w.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, w.frame, scale)
    }
}
