import Cocoa
import ScreenCaptureKit
import UniformTypeIdentifiers
import CoreText

// MARK: - JSON Output Models

struct DisplayJSON: Encodable {
    let id: Int
    let type: String
    let resolution: String
    let scale_factor: Double
    let rotation: Double
    let arrangement: String
}

struct TopologyJSON: Encodable {
    let active_app: String
    let displays: [DisplayJSON]
}

struct CursorJSON: Encodable {
    let x: Int
    let y: Int
}

struct BoundsJSON: Encodable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct SuccessResponse: Encodable {
    let status = "success"
    var files: [String]?
    var base64: [String]?
    var cursor: CursorJSON?
    var bounds: BoundsJSON?
    var click_x: Int?
    var click_y: Int?
    var warning: String?

    enum CodingKeys: String, CodingKey { case status, files, base64, cursor, bounds, click_x, click_y, warning }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        if let f = files { try c.encode(f, forKey: .files) }
        if let b = base64 { try c.encode(b, forKey: .base64) }
        if let cur = cursor { try c.encode(cur, forKey: .cursor) }
        if let bnd = bounds { try c.encode(bnd, forKey: .bounds) }
        if let cx = click_x { try c.encode(cx, forKey: .click_x) }
        if let cy = click_y { try c.encode(cy, forKey: .click_y) }
        if let w = warning { try c.encode(w, forKey: .warning) }
    }
}

// MARK: - Overlay Types

struct RectOverlay {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let color: CGColor
    let fill: Bool
}

struct ShadowSpec {
    let offsetX: CGFloat
    let offsetY: CGFloat
    let blur: CGFloat
    let color: CGColor
}

struct GridSpec {
    let cols: Int
    let rows: Int
}

struct ZoneEntry: Codable {
    let target: String
    let crop: String
}

// MARK: - Internal Display Model

struct DisplayEntry {
    let ordinal: Int
    let cgID: CGDirectDisplayID
    let bounds: CGRect
    let scaleFactor: Double
    let rotation: Double
    let isMain: Bool
    let isMirrored: Bool
    let type: String
    let arrangement: String
    let resolution: String
}

// MARK: - JSON Helpers

func jsonString<T: Encodable>(_ value: T) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) else { return "{}" }
    return s
}

func exitError(_ message: String, code: String) -> Never {
    let obj: [String: String] = ["error": message, "code": code]
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
    exit(1)
}

// MARK: - Color Parsing

func parseHexColor(_ hex: String) -> CGColor {
    var h = hex
    if h.hasPrefix("#") { h = String(h.dropFirst()) }
    guard h.count == 6 || h.count == 8 else {
        exitError("Invalid color '\(hex)'. Use #RRGGBB or #RRGGBBAA.", code: "INVALID_COLOR")
    }
    // Validate all characters are hex digits
    guard h.allSatisfy({ $0.isHexDigit }) else {
        exitError("Invalid color '\(hex)'. Contains non-hex characters.", code: "INVALID_COLOR")
    }
    let scanner = Scanner(string: h)
    var value: UInt64 = 0
    scanner.scanHexInt64(&value)

    let r, g, b, a: CGFloat
    if h.count == 8 {
        r = CGFloat((value >> 24) & 0xFF) / 255.0
        g = CGFloat((value >> 16) & 0xFF) / 255.0
        b = CGFloat((value >> 8) & 0xFF) / 255.0
        a = CGFloat(value & 0xFF) / 255.0
    } else {
        r = CGFloat((value >> 16) & 0xFF) / 255.0
        g = CGFloat((value >> 8) & 0xFF) / 255.0
        b = CGFloat(value & 0xFF) / 255.0
        a = 1.0
    }
    return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// MARK: - Permission Checks

func checkScreenRecordingPermission() {
    if !CGPreflightScreenCaptureAccess() {
        CGRequestScreenCaptureAccess()
        exitError(
            "Screen recording permission required. A system prompt should appear. Grant access in System Settings > Privacy & Security > Screen Recording, then retry.",
            code: "PERMISSION_DENIED"
        )
    }
}

func checkAccessibilityPermission() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(opts) {
        exitError(
            "Accessibility permission required for --wait-for-click. Grant in System Settings > Privacy & Security > Accessibility.",
            code: "ACCESSIBILITY_DENIED"
        )
    }
}

// MARK: - Display Enumeration

func getDisplays() -> [DisplayEntry] {
    let maxD: UInt32 = 16
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(maxD))
    var count: UInt32 = 0
    CGGetActiveDisplayList(maxD, &ids, &count)

    let mainID = CGMainDisplayID()
    let mainBounds = CGDisplayBounds(mainID)
    let mainCX = mainBounds.origin.x + mainBounds.width / 2

    var scaleMap: [CGDirectDisplayID: Double] = [:]
    for screen in NSScreen.screens {
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            scaleMap[n] = screen.backingScaleFactor
        }
    }

    let sorted = ids.prefix(Int(count)).sorted { a, b in
        if a == mainID { return true }
        if b == mainID { return false }
        return CGDisplayBounds(a).origin.x < CGDisplayBounds(b).origin.x
    }

    return sorted.enumerated().map { i, did in
        let b = CGDisplayBounds(did)
        let isMain = did == mainID
        let mirror = CGDisplayMirrorsDisplay(did)
        let isMirror = mirror != kCGNullDirectDisplay
        let type = isMirror ? "Mirror for Built-in Display" : (isMain ? "Main display" : "Extended")
        let cx = b.origin.x + b.width / 2
        let arr = isMain ? "main" : (cx < mainCX ? "left" : (cx > mainCX ? "right" : "center"))

        return DisplayEntry(
            ordinal: i + 1, cgID: did, bounds: b,
            scaleFactor: scaleMap[did] ?? 1.0,
            rotation: Double(CGDisplayRotation(did)),
            isMain: isMain, isMirrored: isMirror,
            type: type, arrangement: arr,
            resolution: "\(Int(b.width))x\(Int(b.height))"
        )
    }
}

func displayForWindow(_ window: SCWindow, displays: [DisplayEntry]) -> DisplayEntry {
    let pt = CGPoint(x: window.frame.midX, y: window.frame.midY)
    return displays.first(where: { $0.bounds.contains(pt) }) ?? displays.first(where: { $0.isMain })!
}

/// Resolve a target string to a display entry.
func resolveDisplayTarget(_ target: String, displays: [DisplayEntry]) -> DisplayEntry? {
    switch target {
    case "main", "center", "middle":
        return displays.first(where: { $0.isMain })
    case "external":
        return displays.first(where: { !$0.isMain && !$0.isMirrored })
    case "external 1":
        return displays.filter({ !$0.isMain && !$0.isMirrored }).first
    case "external 2":
        let exts = displays.filter({ !$0.isMain && !$0.isMirrored })
        return exts.count >= 2 ? exts[1] : exts.first
    default:
        return displays.first(where: { $0.isMain })
    }
}

/// Find the display containing the current mouse cursor.
func displayForMouse(displays: [DisplayEntry]) -> DisplayEntry? {
    let mouse = NSEvent.mouseLocation
    let mainH = CGDisplayBounds(CGMainDisplayID()).height
    let pt = CGPoint(x: mouse.x, y: mainH - mouse.y)
    return displays.first(where: { $0.bounds.contains(pt) }) ?? displays.first(where: { $0.isMain })
}

/// Get mouse position in CG screen coordinates (top-left origin).
func mouseInCGCoords() -> CGPoint {
    let mouse = NSEvent.mouseLocation
    let mainH = CGDisplayBounds(CGMainDisplayID()).height
    return CGPoint(x: mouse.x, y: mainH - mouse.y)
}

func largestWindow(for pid: pid_t, in windows: [SCWindow]) -> SCWindow? {
    windows
        .filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 0 }
        .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
}

func largestWindowOnDisplay(_ entry: DisplayEntry, in windows: [SCWindow], preferPID: pid_t? = nil) -> SCWindow? {
    let onDisplay = windows.filter { w in
        w.windowLayer == 0 && w.frame.width > 100
            && entry.bounds.contains(CGPoint(x: w.frame.midX, y: w.frame.midY))
    }
    if let pid = preferPID,
       let w = onDisplay.filter({ $0.owningApplication?.processID == pid })
           .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
        return w
    }
    return onDisplay.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
}

// MARK: - Process Tree Walking (selfie)

func parentPID(of pid: pid_t) -> pid_t {
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/ps")
    proc.arguments = ["-o", "ppid=", "-p", "\(pid)"]
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return -1 }
    proc.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          let v = Int32(s) else { return -1 }
    return v
}

func selfieWindow(content: SCShareableContent) -> SCWindow? {
    var pid = getpid()
    var visited = Set<pid_t>()
    while pid > 1 && !visited.contains(pid) {
        visited.insert(pid)
        if let w = largestWindow(for: pid, in: content.windows) { return w }
        pid = parentPID(of: pid)
    }
    if let termProgram = ProcessInfo.processInfo.environment["TERM_PROGRAM"] {
        let needle = termProgram.lowercased()
        let candidates = content.windows.filter {
            guard let app = $0.owningApplication else { return false }
            return $0.windowLayer == 0 && $0.frame.width > 100
                && (app.applicationName.lowercased().contains(needle)
                    || app.bundleIdentifier.lowercased().contains(needle))
        }
        if let w = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            return w
        }
    }
    if let frontApp = NSWorkspace.shared.frontmostApplication {
        return largestWindow(for: frontApp.processIdentifier, in: content.windows)
    }
    return nil
}

// MARK: - Image Drawing Infrastructure

func drawOnImage(_ image: CGImage, _ draw: (CGContext, Int, Int) -> Void) -> CGImage {
    let w = image.width
    let h = image.height
    guard let ctx = CGContext(
        data: nil, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return image }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    draw(ctx, w, h)
    return ctx.makeImage() ?? image
}

func drawLabel(ctx: CGContext, text: String, at point: CGPoint, font: CTFont) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9)
    ]
    let attrStr = NSAttributedString(string: text, attributes: attrs)
    let line = CTLineCreateWithAttributedString(attrStr)
    let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    let padding: CGFloat = 3

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 0)
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6))
    ctx.fill(CGRect(
        x: point.x - padding, y: point.y - padding,
        width: lineBounds.width + padding * 2, height: lineBounds.height + padding * 2
    ))
    ctx.textPosition = point
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// MARK: - Image Encoding

func encodeImage(_ image: CGImage, format: UTType, quality: Double) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, format.identifier as CFString, 1, nil)
    else { return nil }
    var props: [CFString: Any] = [:]
    if format != .png { props[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

func writeImage(_ image: CGImage, to path: String, format: UTType, quality: Double) -> Bool {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.identifier as CFString, 1, nil)
    else { return false }
    var props: [CFString: Any] = [:]
    if format != .png { props[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    return CGImageDestinationFinalize(dest)
}

// MARK: - Crop

func applyCrop(_ image: CGImage, style: String) -> (image: CGImage, rect: CGRect) {
    let w = CGFloat(image.width)
    let h = CGFloat(image.height)

    let rect: CGRect
    switch style {
    case "top-half":        rect = CGRect(x: 0, y: 0, width: w, height: h / 2)
    case "bottom-half":     rect = CGRect(x: 0, y: h / 2, width: w, height: h / 2)
    case "left-half":       rect = CGRect(x: 0, y: 0, width: w / 2, height: h)
    case "right-half":      rect = CGRect(x: w / 2, y: 0, width: w / 2, height: h)
    case "top-left":        rect = CGRect(x: 0, y: 0, width: w / 2, height: h / 2)
    case "top-right":       rect = CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2)
    case "bottom-left":     rect = CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2)
    case "bottom-right":    rect = CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2)
    case "center":          rect = CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2)
    default:
        let parts = style.split(separator: ",").compactMap { Int($0) }
        if parts.count == 4 {
            rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        } else {
            exitError("Invalid crop style: '\(style)'. Use a named style or x,y,w,h.", code: "INVALID_CROP")
        }
    }
    guard let cropped = image.cropping(to: rect) else {
        exitError("Crop region is outside image bounds", code: "CROP_FAILED")
    }
    return (cropped, rect)
}

// MARK: - Cursor Position

func cursorPositionInImageSpace(display: DisplayEntry) -> (x: Int, y: Int)? {
    let pt = mouseInCGCoords()
    guard display.bounds.contains(pt) else { return nil }
    let relX = pt.x - display.bounds.origin.x
    let relY = pt.y - display.bounds.origin.y
    return (Int(relX * display.scaleFactor), Int(relY * display.scaleFactor))
}

// MARK: - Grid Drawing

func drawGrid(on image: CGImage, spec: GridSpec, thickness: CGFloat, shadow: ShadowSpec?) -> CGImage {
    drawOnImage(image) { ctx, w, h in
        if let s = shadow {
            ctx.setShadow(offset: CGSize(width: s.offsetX, height: s.offsetY), blur: s.blur, color: s.color)
        }
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.6))
        ctx.setLineWidth(thickness)

        let colW = CGFloat(w) / CGFloat(spec.cols)
        let rowH = CGFloat(h) / CGFloat(spec.rows)

        for c in 1..<spec.cols {
            let x = CGFloat(c) * colW
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: CGFloat(h)))
        }
        for r in 1..<spec.rows {
            let y = CGFloat(r) * rowH
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: CGFloat(w), y: y))
        }
        ctx.strokePath()

        ctx.setShadow(offset: .zero, blur: 0)
        let fontSize = max(12.0, min(24.0, CGFloat(min(w, h)) / 80.0))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)

        for c in 0...spec.cols {
            let px = Int(CGFloat(c) * colW)
            drawLabel(ctx: ctx, text: "\(px)",
                     at: CGPoint(x: CGFloat(px) + 2, y: CGFloat(h) - fontSize - 4), font: font)
        }
        for r in 0...spec.rows {
            let py = Int(CGFloat(r) * rowH)
            drawLabel(ctx: ctx, text: "\(py)",
                     at: CGPoint(x: 2, y: CGFloat(h) - CGFloat(py) - fontSize - 4), font: font)
        }
    }
}

// MARK: - Rect Drawing

func drawRects(on image: CGImage, rects: [RectOverlay], thickness: CGFloat, shadow: ShadowSpec?) -> CGImage {
    drawOnImage(image) { ctx, w, h in
        if let s = shadow {
            ctx.setShadow(offset: CGSize(width: s.offsetX, height: s.offsetY), blur: s.blur, color: s.color)
        }
        ctx.setLineWidth(thickness)
        for r in rects {
            let rect = CGRect(
                x: CGFloat(r.x),
                y: CGFloat(h - r.y - r.height),
                width: CGFloat(r.width),
                height: CGFloat(r.height)
            )
            if r.fill {
                ctx.setFillColor(r.color)
                ctx.fill(rect)
            } else {
                ctx.setStrokeColor(r.color)
                ctx.stroke(rect)
            }
        }
    }
}

// MARK: - ScreenCaptureKit Capture

@available(macOS 14.0, *)
func captureDisplay(_ scDisplay: SCDisplay, scaleFactor: Double, showCursor: Bool) async throws -> CGImage {
    let filter = SCContentFilter(display: scDisplay, excludingApplications: [], exceptingWindows: [])
    let config = SCStreamConfiguration()
    config.width = Int(Double(scDisplay.width) * scaleFactor)
    config.height = Int(Double(scDisplay.height) * scaleFactor)
    config.showsCursor = showCursor
    config.captureResolution = .best
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
}

@available(macOS 14.0, *)
func captureWindow(_ window: SCWindow, scaleFactor: Double, showCursor: Bool) async throws -> CGImage {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    config.width = Int(window.frame.width * scaleFactor)
    config.height = Int(window.frame.height * scaleFactor)
    config.showsCursor = showCursor
    config.captureResolution = .best
    config.ignoreShadowsSingleWindow = true
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
}

// MARK: - Argument Parsing

struct CaptureOptions {
    var target: String = "main"
    var windowOnly: Bool = false
    var outputPath: String? = nil
    var useBase64: Bool = false
    var crop: String? = nil
    var format: String = "png"
    var quality: String = "high"

    // Cursor
    var showCursor: Bool = false
    var highlightCursorColor: String? = nil  // nil = no highlight; string = hex color

    // Mouse target
    var radius: Int? = nil

    // Interactive
    var interactive: Bool = false

    // Wait for click
    var waitForClick: Bool = false

    // Timeout for interactive flags (seconds)
    var timeout: Double = 60.0

    // Utilities
    var delay: Double? = nil
    var clipboard: Bool = false

    // Overlays (all in LCS — post-crop local coordinates)
    var grid: GridSpec? = nil
    var drawRects: [RectOverlay] = []
    var thickness: CGFloat = 2.0
    var shadow: ShadowSpec? = nil

    var resolvedOutputPath: String {
        if let p = outputPath { return p }
        let ext = (format == "jpeg") ? "jpg" : format
        return "./screenshot.\(ext)"
    }
}

func parseCaptureArgs(_ args: [String]) -> CaptureOptions {
    var opts = CaptureOptions()
    var i = 0

    if i < args.count && !args[i].hasPrefix("--") {
        opts.target = args[i]
        i += 1
        if opts.target == "external" && i < args.count && !args[i].hasPrefix("--") {
            if let _ = Int(args[i]) {
                opts.target += " \(args[i])"
                i += 1
            }
        }
    }

    while i < args.count {
        switch args[i] {
        case "--window":
            opts.windowOnly = true
        case "--out":
            i += 1
            guard i < args.count else { exitError("--out requires a path", code: "MISSING_ARG") }
            opts.outputPath = args[i]
        case "--base64":
            opts.useBase64 = true
        case "--crop":
            i += 1
            guard i < args.count else { exitError("--crop requires a value", code: "MISSING_ARG") }
            opts.crop = args[i]
        case "--format":
            i += 1
            guard i < args.count else { exitError("--format requires a value", code: "MISSING_ARG") }
            opts.format = args[i].lowercased()
        case "--quality":
            i += 1
            guard i < args.count else { exitError("--quality requires a value", code: "MISSING_ARG") }
            opts.quality = args[i].lowercased()

        // Cursor
        case "--show-cursor":
            opts.showCursor = true
        case "--highlight-cursor":
            // Optional color argument: --highlight-cursor or --highlight-cursor #FF000080
            if i + 1 < args.count && args[i + 1].hasPrefix("#") {
                i += 1
                opts.highlightCursorColor = args[i]
            } else {
                opts.highlightCursorColor = "#FFFF0066"  // default: yellow 40% opacity
            }

        // Mouse radius
        case "--radius":
            i += 1
            guard i < args.count else { exitError("--radius requires a pixel value", code: "MISSING_ARG") }
            guard let r = Int(args[i]), r > 0 else {
                exitError("--radius must be a positive integer", code: "INVALID_ARG")
            }
            opts.radius = r

        // Interactive
        case "--interactive":
            opts.interactive = true

        // Wait for click
        case "--wait-for-click":
            opts.waitForClick = true

        // Timeout
        case "--timeout":
            i += 1
            guard i < args.count else { exitError("--timeout requires seconds", code: "MISSING_ARG") }
            guard let t = Double(args[i]), t > 0 else {
                exitError("--timeout must be a positive number", code: "INVALID_ARG")
            }
            opts.timeout = t

        // Utilities
        case "--delay":
            i += 1
            guard i < args.count else { exitError("--delay requires seconds", code: "MISSING_ARG") }
            guard let d = Double(args[i]), d >= 0 else {
                exitError("--delay must be a non-negative number", code: "INVALID_ARG")
            }
            opts.delay = d
        case "--clipboard":
            opts.clipboard = true

        // Grid
        case "--grid":
            i += 1
            guard i < args.count else { exitError("--grid requires COLSxROWS", code: "MISSING_ARG") }
            let parts = args[i].lowercased().split(separator: "x")
            guard parts.count == 2, let c = Int(parts[0]), let r = Int(parts[1]), c > 0, r > 0 else {
                exitError("--grid format: COLSxROWS (e.g., 4x3)", code: "INVALID_ARG")
            }
            opts.grid = GridSpec(cols: c, rows: r)

        // Draw rects
        case "--draw-rect", "--draw-rect-fill":
            let fill = args[i] == "--draw-rect-fill"
            let flag = args[i]
            i += 1
            guard i < args.count else { exitError("\(flag) requires x,y,w,h and #color", code: "MISSING_ARG") }
            let coords = args[i]
            i += 1
            guard i < args.count else { exitError("\(flag) requires a color after coordinates", code: "MISSING_ARG") }
            let color = args[i]
            let p = coords.split(separator: ",").compactMap { Int($0) }
            guard p.count == 4 else { exitError("Rect coords must be x,y,w,h", code: "INVALID_ARG") }
            opts.drawRects.append(RectOverlay(
                x: p[0], y: p[1], width: p[2], height: p[3],
                color: parseHexColor(color), fill: fill
            ))

        // Overlay properties
        case "--thickness":
            i += 1
            guard i < args.count else { exitError("--thickness requires a value", code: "MISSING_ARG") }
            guard let t = Double(args[i]), t > 0 else {
                exitError("--thickness must be a positive number", code: "INVALID_ARG")
            }
            opts.thickness = CGFloat(t)

        case "--shadow":
            i += 1
            guard i < args.count else { exitError("--shadow requires \"offsetX,offsetY,blur,#color\"", code: "MISSING_ARG") }
            let parts = args[i].split(separator: ",", maxSplits: 3)
            guard parts.count == 4,
                  let ox = Double(parts[0]), let oy = Double(parts[1]), let bl = Double(parts[2]) else {
                exitError("--shadow format: offsetX,offsetY,blur,#color", code: "INVALID_ARG")
            }
            opts.shadow = ShadowSpec(
                offsetX: CGFloat(ox), offsetY: CGFloat(-oy),
                blur: CGFloat(bl), color: parseHexColor(String(parts[3]))
            )

        default:
            exitError("Unknown option: \(args[i])", code: "UNKNOWN_OPTION")
        }
        i += 1
    }
    return opts
}

func resolveUTType(for format: String) -> UTType {
    switch format {
    case "png":          return .png
    case "jpg", "jpeg":  return .jpeg
    case "heic":         return .heic
    default: exitError("Unknown format: '\(format)'. Use png, jpg, or heic.", code: "INVALID_FORMAT")
    }
}

func resolveQuality(for level: String) -> Double {
    switch level {
    case "high": return 1.0
    case "med":  return 0.6
    case "low":  return 0.3
    default: exitError("Unknown quality: '\(level)'. Use high, med, or low.", code: "INVALID_QUALITY")
    }
}

// MARK: - Known Targets

let knownTargets: Set<String> = ["main", "center", "middle", "external", "user_active", "all", "selfie", "mouse"]

// MARK: - Named Zones

let zonesFilePath = NSString("~/.config/side-eye/zones.json").expandingTildeInPath

func loadZones() -> [String: ZoneEntry] {
    guard let data = FileManager.default.contents(atPath: zonesFilePath),
          let zones = try? JSONDecoder().decode([String: ZoneEntry].self, from: data)
    else { return [:] }
    return zones
}

func saveZones(_ zones: [String: ZoneEntry]) {
    let url = URL(fileURLWithPath: zonesFilePath)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(zones) else { exitError("Failed to encode zones", code: "ZONE_WRITE_FAILED") }
    try? data.write(to: url)
}

func zoneCommand(args: [String]) {
    guard !args.isEmpty else {
        exitError("Usage: side-eye zone <save|define|list|delete> [args]", code: "MISSING_SUBCOMMAND")
    }
    switch args[0] {
    case "list":
        let zones = loadZones()
        print(jsonString(zones))

    case "save":
        guard args.count >= 3 else {
            exitError("Usage: side-eye zone save <name> [--target <display>] [--bounds] <x,y,w,h>", code: "MISSING_ARG")
        }
        let name = args[1]
        var target = "main"
        var cropStr: String? = nil
        var j = 2
        while j < args.count {
            if args[j] == "--target" && j + 1 < args.count {
                target = args[j + 1]; j += 2
            } else if args[j] == "--bounds" && j + 1 < args.count {
                cropStr = args[j + 1]; j += 2
            } else {
                cropStr = args[j]; j += 1
            }
        }
        guard let crop = cropStr else { exitError("Missing bounds. Provide x,y,w,h.", code: "MISSING_ARG") }
        let parts = crop.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 4 else { exitError("Bounds must be x,y,w,h", code: "INVALID_ARG") }
        var zones = loadZones()
        zones[name] = ZoneEntry(target: target, crop: crop)
        saveZones(zones)
        print(jsonString(["status": "saved", "zone": name]))

    case "define":
        guard args.count >= 2 else {
            exitError("Usage: side-eye zone define <name> [--target <display>]", code: "MISSING_ARG")
        }
        let name = args[1]
        var target = "main"
        if args.count >= 4 && args[2] == "--target" { target = args[3] }

        let displays = getDisplays()
        guard let targetDisplay = resolveDisplayTarget(target, displays: displays) else {
            exitError("Cannot resolve display '\(target)'", code: "NO_DISPLAY")
        }

        // Try native overlay first (works from real terminals like iTerm/Terminal.app).
        // Falls back to error with guidance if overlay can't acquire focus (e.g. sandboxed contexts).
        if let rect = showInteractiveSelection(on: targetDisplay, timeout: 120) {
            let scale = targetDisplay.scaleFactor
            let cropStr = "\(Int(rect.origin.x * scale)),\(Int(rect.origin.y * scale)),\(Int(rect.width * scale)),\(Int(rect.height * scale))"
            var zones = loadZones()
            zones[name] = ZoneEntry(target: target, crop: cropStr)
            saveZones(zones)
            print(jsonString(["status": "saved", "zone": name, "bounds": cropStr]))
        } else {
            exitError(
                "Interactive overlay timed out (window could not acquire focus). "
                + "Use 'side-eye zone save \(name) --target \(target) --bounds x,y,w,h' instead, "
                + "or run 'side-eye capture \(target) --interactive --grid 10x10' to identify coordinates visually.",
                code: "INTERACTIVE_UNAVAILABLE"
            )
        }

    case "delete":
        guard args.count >= 2 else { exitError("Usage: side-eye zone delete <name>", code: "MISSING_ARG") }
        var zones = loadZones()
        guard zones.removeValue(forKey: args[1]) != nil else {
            exitError("Zone '\(args[1])' not found", code: "ZONE_NOT_FOUND")
        }
        saveZones(zones)
        print(jsonString(["status": "deleted", "zone": args[1]]))

    default:
        exitError("Unknown zone command: '\(args[0])'. Use save, define, list, or delete.", code: "UNKNOWN_SUBCOMMAND")
    }
}

// MARK: - Wait For Click

/// Block until a global left-click occurs. Returns click position in CG screen coords (top-left origin).
func waitForGlobalClick(timeout: Double) -> CGPoint {
    // Must run on main thread for NSEvent global monitor.
    if !Thread.isMainThread {
        var result: CGPoint = .zero
        DispatchQueue.main.sync { result = waitForGlobalClick(timeout: timeout) }
        return result
    }
    checkAccessibilityPermission()

    var clickPoint: CGPoint? = nil
    var done = false
    let deadline = Date(timeIntervalSinceNow: timeout)

    let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
        clickPoint = mouseInCGCoords()
        done = true
    }

    while !done && Date() < deadline {
        autoreleasepool {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    if let m = monitor { NSEvent.removeMonitor(m) }

    guard done, let pt = clickPoint else {
        exitError("Timed out waiting for click (\(Int(timeout))s)", code: "TIMEOUT")
    }
    return pt
}

// MARK: - Interactive Selection

/// Borderless windows can't become key by default. Override to allow event delivery.
class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class SelectionOverlayView: NSView {
    var startPoint: NSPoint = .zero
    var currentPoint: NSPoint = .zero
    var isDragging = false
    var onComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var selectionRect: NSRect {
        let x = min(startPoint.x, currentPoint.x)
        let y = min(startPoint.y, currentPoint.y)
        return NSRect(x: x, y: y,
                      width: abs(currentPoint.x - startPoint.x),
                      height: abs(currentPoint.y - startPoint.y))
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        isDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        isDragging = false
        let sel = selectionRect
        if sel.width > 5 && sel.height > 5 { onComplete?(sel) }
        else { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let sel = selectionRect
        let dark = NSColor(calibratedWhite: 0, alpha: 0.3)

        if (isDragging || sel.width > 5) && sel.width > 0 && sel.height > 0 {
            dark.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: sel.minY).fill()
            NSRect(x: 0, y: sel.maxY, width: bounds.width, height: bounds.height - sel.maxY).fill()
            NSRect(x: 0, y: sel.minY, width: sel.minX, height: sel.height).fill()
            NSRect(x: sel.maxX, y: sel.minY, width: bounds.width - sel.maxX, height: sel.height).fill()

            NSColor.white.setStroke()
            let path = NSBezierPath(rect: sel)
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.stroke()

            let label = "\(Int(sel.width))x\(Int(sel.height))"
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 14, weight: .medium)
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            let labelPt = NSPoint(x: sel.midX - size.width / 2, y: sel.maxY + 6)

            NSColor(calibratedWhite: 0, alpha: 0.7).setFill()
            NSRect(x: labelPt.x - 4, y: labelPt.y - 2, width: size.width + 8, height: size.height + 4).fill()
            (label as NSString).draw(at: labelPt, withAttributes: attrs)
        } else {
            dark.setFill()
            bounds.fill()
        }
    }
}

func showInteractiveSelection(on display: DisplayEntry, timeout: Double = 60) -> NSRect? {
    // Must run on main thread for NSWindow. If called from background (async context),
    // dispatch synchronously to main queue.
    if !Thread.isMainThread {
        var result: NSRect? = nil
        DispatchQueue.main.sync { result = showInteractiveSelection(on: display, timeout: timeout) }
        return result
    }
    NSApp.setActivationPolicy(.regular)

    let nsScreen = NSScreen.screens.first { screen in
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.cgID
    }
    let windowRect = nsScreen?.frame ?? NSRect(
        x: Double(display.bounds.origin.x), y: 0,
        width: Double(display.bounds.width), height: Double(display.bounds.height)
    )

    var result: NSRect? = nil
    var done = false
    let deadline = Date(timeIntervalSinceNow: timeout)

    let window = KeyableWindow(contentRect: windowRect, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = .screenSaver
    window.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.3)  // Visible immediately
    window.isOpaque = false
    window.hasShadow = false
    window.ignoresMouseEvents = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let overlay = SelectionOverlayView(frame: window.contentView!.bounds)
    overlay.autoresizingMask = [.width, .height]
    overlay.wantsLayer = true  // Ensure layer-backed for reliable drawing
    window.contentView?.addSubview(overlay)

    overlay.onComplete = { rect in result = rect; done = true }
    overlay.onCancel = { done = true }

    window.orderFrontRegardless()
    window.makeKey()
    window.makeFirstResponder(overlay)
    NSRunningApplication.current.activate(options: [.activateAllWindows])

    // Force initial draw + process activation events
    overlay.needsDisplay = true
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
    NSCursor.crosshair.push()

    while !done && Date() < deadline {
        autoreleasepool {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    NSCursor.pop()
    window.orderOut(nil)
    NSApp.setActivationPolicy(.prohibited)
    return done ? result : nil
}

// MARK: - Usage

func printUsage() {
    print("""
    side-eye — Agent-first macOS screenshot CLI  (v3)

    USAGE
      side-eye list                              Display topology as JSON
      side-eye [capture] <target> [options]      Take a screenshot
      side-eye zone <save|define|list|delete>    Manage named zones
      side-eye <zone-name> [options]             Capture a saved zone

    TARGETS
      main, center, middle    Primary display (Retina MacBook)
      external                First external monitor
      external 1              Leftmost external (by X coordinate)
      external 2              Next external moving right
      user_active             Display with the focused application
      selfie                  Display hosting this CLI process
      mouse                   Display containing the cursor
      all                     Every connected display (one file each)

    OUTPUT
      --out <path>            File path (default: ./screenshot.<format>)
      --base64                Skip disk I/O; emit base64 string in JSON
      --format <ext>          png (default), jpg/jpeg, heic
      --quality <level>       high (1.0, default), med (0.6), low (0.3)
      --clipboard             Also copy final image to system clipboard

    CAPTURE MODIFIERS
      --window                Capture the targeted window, not the full display
      --crop <style>          Crop: named style or exact x,y,w,h
      --show-cursor           Include the system cursor in the capture
      --delay <secs>          Sleep N seconds before capturing

    INTERACTIVE & MOUSE
      --interactive           Native macOS crosshair; drag to select region
      --wait-for-click        Block until left-click; returns click_x/y in JSON
      --timeout <secs>        Timeout for interactive flags (default: 60)
      mouse                   Target: resolves to display under cursor
      --radius <px>           With 'mouse': capture <px>-radius box around cursor
      --highlight-cursor [#color]   Draw 50px circle at cursor (default: #FFFF0066)

    OVERLAYS (baked into the image via CoreGraphics)
      --grid <CxR>            Coordinate grid, e.g. 10x10 — aids LLM spatial reasoning
      --draw-rect <x,y,w,h> <#color>       Stroke bounding box
      --draw-rect-fill <x,y,w,h> <#color>  Filled/translucent bounding box
      --thickness <px>        Stroke width for grid/rects (default: 2)
      --shadow <ox,oy,blur,#color>  Drop shadow on all drawn elements

    ZONE MEMORY (~/.config/side-eye/zones.json)
      zone save <name> [--target <t>] [--bounds] <x,y,w,h>
      zone define <name> [--target <t>]    Interactive zone selection
      zone list                             Dump all zones as JSON
      zone delete <name>                    Remove a zone

    COORDINATE SYSTEM (Local Coordinate System / LCS)
      All coordinates are LOCAL to the captured target image.
      (0,0) = top-left of whatever you're capturing.
      Overlays (--draw-rect, --grid, --crop) use post-crop pixel coordinates.
      This means an AI agent never needs global screen arithmetic.

    COLORS
      #RRGGBB or #RRGGBBAA (hex). Example: #FF000080 = red at 50% alpha.

    JSON OUTPUT
      Success:  {"status":"success", "files":[...], "base64":[...], ...}
      Failure:  exit 1, stderr: {"error":"...", "code":"PERMISSION_DENIED"}
      Optional keys: cursor{x,y}, bounds{x,y,w,h}, click_x, click_y, warning
    """)
}

// MARK: - Command: list

@available(macOS 14.0, *)
func listCommand() {
    let displays = getDisplays()
    let activeApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
    let topology = TopologyJSON(
        active_app: activeApp,
        displays: displays.map {
            DisplayJSON(id: $0.ordinal, type: $0.type, resolution: $0.resolution,
                       scale_factor: $0.scaleFactor, rotation: $0.rotation, arrangement: $0.arrangement)
        }
    )
    print(jsonString(topology))
}

// MARK: - Command: capture

@available(macOS 14.0, *)
func captureCommand(args: [String]) async {
    var opts = parseCaptureArgs(args)
    let fmt = resolveUTType(for: opts.format)
    let quality = resolveQuality(for: opts.quality)

    // ── Zone resolution ──
    if !knownTargets.contains(opts.target) && !opts.target.hasPrefix("external") {
        let zones = loadZones()
        if let zone = zones[opts.target] {
            opts.target = zone.target
            if opts.crop == nil { opts.crop = zone.crop }
        }
    }

    // ── Delay ──
    if let delay = opts.delay {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    // ── Wait for click (blocks until click or timeout) ──
    var clickCGPos: CGPoint? = nil
    if opts.waitForClick {
        clickCGPos = waitForGlobalClick(timeout: opts.timeout)
    }

    // ── Permission pre-check ──
    checkScreenRecordingPermission()

    // ── Get ScreenCaptureKit content ──
    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    } catch {
        exitError(
            "Screen recording permission denied. Grant in System Settings > Privacy & Security > Screen Recording.",
            code: "PERMISSION_DENIED"
        )
    }

    let displays = getDisplays()

    // ── Resolve target ──
    var targetDisplayIDs: [CGDirectDisplayID] = []
    var specificWindow: SCWindow? = nil
    var responseWarning: String? = nil

    switch opts.target {
    case "main", "center", "middle":
        guard let d = displays.first(where: { $0.isMain }) else { exitError("No main display", code: "NO_DISPLAY") }
        targetDisplayIDs = [d.cgID]

    case "external":
        guard let d = displays.first(where: { !$0.isMain && !$0.isMirrored }) else {
            exitError("No external display connected", code: "NO_EXTERNAL_DISPLAY")
        }
        targetDisplayIDs = [d.cgID]

    case "external 1":
        let exts = displays.filter { !$0.isMain && !$0.isMirrored }
        guard let d = exts.first else { exitError("No external display connected", code: "NO_EXTERNAL_DISPLAY") }
        targetDisplayIDs = [d.cgID]

    case "external 2":
        let exts = displays.filter { !$0.isMain && !$0.isMirrored }
        if exts.count >= 2 { targetDisplayIDs = [exts[1].cgID] }
        else if let d = exts.first { targetDisplayIDs = [d.cgID] }
        else { exitError("No external display connected", code: "NO_EXTERNAL_DISPLAY") }

    case "user_active":
        guard let app = NSWorkspace.shared.frontmostApplication else {
            exitError("No frontmost application", code: "NO_ACTIVE_APP")
        }
        guard let w = largestWindow(for: app.processIdentifier, in: content.windows) else {
            exitError("No window for active app '\(app.localizedName ?? "?")'", code: "NO_WINDOW")
        }
        specificWindow = w
        targetDisplayIDs = [displayForWindow(w, displays: displays).cgID]

    case "selfie":
        guard let w = selfieWindow(content: content) else {
            exitError("Cannot find hosting app window", code: "SELFIE_NOT_FOUND")
        }
        specificWindow = w
        targetDisplayIDs = [displayForWindow(w, displays: displays).cgID]

    case "mouse":
        guard let d = displayForMouse(displays: displays) else {
            exitError("Cannot determine display for cursor", code: "NO_DISPLAY")
        }
        targetDisplayIDs = [d.cgID]
        // Auto-crop to radius box centered on cursor
        if let r = opts.radius {
            let pt = mouseInCGCoords()
            let relX = pt.x - d.bounds.origin.x
            let relY = pt.y - d.bounds.origin.y
            let scale = d.scaleFactor
            let px = Int(relX * scale)
            let py = Int(relY * scale)
            let pr = Int(Double(r) * scale)
            opts.crop = "\(max(0, px - pr)),\(max(0, py - pr)),\(pr * 2),\(pr * 2)"
        }

    case "all":
        targetDisplayIDs = displays.filter { !$0.isMirrored }.map { $0.cgID }

    default:
        exitError("Unknown target: '\(opts.target)'", code: "UNKNOWN_TARGET")
    }

    // ── Interactive selection (via native screencapture -i) ──
    var interactiveBounds: BoundsJSON? = nil
    var interactiveImage: CGImage? = nil
    if opts.interactive {
        let tmpPath = NSTemporaryDirectory() + "side-eye-interactive-\(ProcessInfo.processInfo.processIdentifier).png"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-i", "-x", tmpPath]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch {
            exitError("Failed to launch screencapture: \(error.localizedDescription)", code: "INTERACTIVE_FAILED")
        }
        proc.waitUntilExit()

        guard proc.terminationStatus == 0,
              let dataProvider = CGDataProvider(url: URL(fileURLWithPath: tmpPath) as CFURL),
              let img = CGImage(pngDataProviderSource: dataProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else {
            try? FileManager.default.removeItem(atPath: tmpPath)
            exitError("Interactive selection cancelled", code: "SELECTION_CANCELLED")
        }
        try? FileManager.default.removeItem(atPath: tmpPath)

        interactiveImage = img
        interactiveBounds = BoundsJSON(x: 0, y: 0, width: img.width, height: img.height)
    }

    // ── Capture loop ──
    var results: [(CGImage, String)] = []
    var responseCursor: CursorJSON? = nil
    var responseClickX: Int? = nil
    var responseClickY: Int? = nil

    // If interactive captured an image, use it directly (skip display/window capture)
    if let iImg = interactiveImage {
        var finalImage = iImg
        // Apply overlays to interactive image
        if let grid = opts.grid {
            finalImage = drawGrid(on: finalImage, spec: grid, thickness: opts.thickness, shadow: opts.shadow)
        }
        if !opts.drawRects.isEmpty {
            finalImage = drawRects(on: finalImage, rects: opts.drawRects, thickness: opts.thickness, shadow: opts.shadow)
        }
        results.append((finalImage, opts.resolvedOutputPath))
    }

    for (idx, cgID) in targetDisplayIDs.enumerated() {
        if interactiveImage != nil { break }  // Already handled above
        guard let entry = displays.first(where: { $0.cgID == cgID }) else { continue }
        var image: CGImage

        // 1. Capture
        if opts.windowOnly {
            let window: SCWindow
            if let sw = specificWindow, idx == 0 {
                window = sw
            } else {
                let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard let w = largestWindowOnDisplay(entry, in: content.windows, preferPID: frontPID) else {
                    exitError("No window on display \(entry.ordinal)", code: "NO_WINDOW")
                }
                window = w
            }

            // Hidden window fallback: check for suspiciously small window
            if window.frame.width < 10 || window.frame.height < 10 {
                responseWarning = "Window appears minimized or hidden (frame: \(Int(window.frame.width))x\(Int(window.frame.height))). Falling back to display capture."
                guard let scDisplay = content.displays.first(where: { $0.displayID == cgID }) else {
                    exitError("Display \(entry.ordinal) not available", code: "DISPLAY_NOT_FOUND")
                }
                do { image = try await captureDisplay(scDisplay, scaleFactor: entry.scaleFactor, showCursor: opts.showCursor) }
                catch { exitError("Display capture failed: \(error.localizedDescription)", code: "CAPTURE_FAILED") }
            } else {
                do { image = try await captureWindow(window, scaleFactor: entry.scaleFactor, showCursor: opts.showCursor) }
                catch {
                    // Window capture failed — fall back to display
                    responseWarning = "Window capture failed (\(error.localizedDescription)). Falling back to display capture."
                    guard let scDisplay = content.displays.first(where: { $0.displayID == cgID }) else {
                        exitError("Display \(entry.ordinal) not available", code: "DISPLAY_NOT_FOUND")
                    }
                    do { image = try await captureDisplay(scDisplay, scaleFactor: entry.scaleFactor, showCursor: opts.showCursor) }
                    catch { exitError("Display capture also failed: \(error.localizedDescription)", code: "CAPTURE_FAILED") }
                }
            }
        } else {
            guard let scDisplay = content.displays.first(where: { $0.displayID == cgID }) else {
                exitError("Display \(entry.ordinal) not available", code: "DISPLAY_NOT_FOUND")
            }
            do { image = try await captureDisplay(scDisplay, scaleFactor: entry.scaleFactor, showCursor: opts.showCursor) }
            catch { exitError("Display capture failed: \(error.localizedDescription)", code: "CAPTURE_FAILED") }
        }

        // 2. Cursor highlight (capture-space, before crop)
        var cursorCapPos: (x: Int, y: Int)? = nil
        if let hlColor = opts.highlightCursorColor, let pos = cursorPositionInImageSpace(display: entry) {
            cursorCapPos = pos
            let radius = 25.0 * entry.scaleFactor
            let color = parseHexColor(hlColor)
            image = drawOnImage(image) { ctx, w, h in
                ctx.setFillColor(color)
                let ctxY = CGFloat(h) - CGFloat(pos.y)
                ctx.fillEllipse(in: CGRect(
                    x: CGFloat(pos.x) - radius, y: ctxY - radius,
                    width: radius * 2, height: radius * 2
                ))
            }
        }

        // 3. Crop (LCS boundary)
        var cropRect: CGRect? = nil
        if let crop = opts.crop {
            let result = applyCrop(image, style: crop)
            image = result.image
            cropRect = result.rect
        }

        // 4. Cursor position in LCS
        if let capPos = cursorCapPos {
            if let cr = cropRect {
                let localX = capPos.x - Int(cr.origin.x)
                let localY = capPos.y - Int(cr.origin.y)
                if localX >= 0 && localY >= 0 && localX < Int(cr.width) && localY < Int(cr.height) {
                    responseCursor = CursorJSON(x: localX, y: localY)
                }
            } else {
                responseCursor = CursorJSON(x: capPos.x, y: capPos.y)
            }
        }

        // 5. Click position in LCS
        if let clickPt = clickCGPos {
            let relX = clickPt.x - entry.bounds.origin.x
            let relY = clickPt.y - entry.bounds.origin.y
            var px = Int(relX * entry.scaleFactor)
            var py = Int(relY * entry.scaleFactor)
            if let cr = cropRect {
                px -= Int(cr.origin.x)
                py -= Int(cr.origin.y)
            }
            responseClickX = px
            responseClickY = py
        }

        // 6. Overlays (LCS — post-crop coordinates)
        if let grid = opts.grid {
            image = drawGrid(on: image, spec: grid, thickness: opts.thickness, shadow: opts.shadow)
        }
        if !opts.drawRects.isEmpty {
            image = drawRects(on: image, rects: opts.drawRects, thickness: opts.thickness, shadow: opts.shadow)
        }

        // 7. Output path
        let basePath = opts.resolvedOutputPath
        let path: String
        if targetDisplayIDs.count > 1 {
            let ext = (basePath as NSString).pathExtension
            let stem = (basePath as NSString).deletingPathExtension
            path = "\(stem)_\(idx + 1).\(ext)"
        } else {
            path = basePath
        }

        results.append((image, path))
    }

    // ── Clipboard ──
    if opts.clipboard, let (lastImage, _) = results.last {
        let pb = NSPasteboard.general
        pb.clearContents()
        let bitmapRep = NSBitmapImageRep(cgImage: lastImage)
        if let tiff = bitmapRep.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    // ── Output ──
    func buildResponse() -> SuccessResponse {
        var resp = SuccessResponse()
        resp.cursor = responseCursor
        resp.bounds = interactiveBounds
        resp.click_x = responseClickX
        resp.click_y = responseClickY
        resp.warning = responseWarning
        return resp
    }

    if opts.useBase64 {
        var b64s: [String] = []
        for (img, _) in results {
            guard let data = encodeImage(img, format: fmt, quality: quality) else {
                exitError("Failed to encode image to \(opts.format)", code: "ENCODE_FAILED")
            }
            b64s.append(data.base64EncodedString())
        }
        var resp = buildResponse()
        resp.base64 = b64s
        print(jsonString(resp))
    } else {
        var files: [String] = []
        for (img, path) in results {
            guard writeImage(img, to: path, format: fmt, quality: quality) else {
                exitError("Failed to write image to \(path)", code: "WRITE_FAILED")
            }
            files.append(path)
        }
        var resp = buildResponse()
        resp.files = files
        print(jsonString(resp))
    }
}

// MARK: - Entry Point
//
// The main thread must stay free for AppKit (NSWindow, NSEvent monitors, RunLoop pumping).
// Async work (ScreenCaptureKit) runs on a detached Task. The main thread pumps the RunLoop
// while waiting, so DispatchQueue.main.sync calls from background threads can execute.

@available(macOS 14.0, *)
@main
struct SideEye {
    static func main() {
        _ = NSApplication.shared

        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else { printUsage(); exit(0) }

        // Synchronous commands — run directly on main thread
        switch args[0] {
        case "list":
            listCommand(); exit(0)
        case "zone":
            zoneCommand(args: Array(args.dropFirst())); exit(0)
        case "help", "--help", "-h":
            printUsage(); exit(0)
        default:
            break
        }

        // Async commands — run on detached task, pump main RunLoop while waiting
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            switch args[0] {
            case "capture":
                await captureCommand(args: Array(args.dropFirst()))
            default:
                if knownTargets.contains(args[0]) {
                    await captureCommand(args: args)
                } else {
                    let zones = loadZones()
                    if zones[args[0]] != nil {
                        await captureCommand(args: args)
                    } else {
                        exitError("Unknown command or target: '\(args[0])'", code: "UNKNOWN_COMMAND")
                    }
                }
            }
            done.signal()
        }

        // Keep main thread alive for AppKit work while async task runs
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
    }
}
