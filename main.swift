import Cocoa
import ScreenCaptureKit
import UniformTypeIdentifiers

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

struct SuccessResponse: Encodable {
    let status = "success"
    var files: [String]?
    var base64: [String]?

    enum CodingKeys: String, CodingKey { case status, files, base64 }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        if let f = files { try c.encode(f, forKey: .files) }
        if let b = base64 { try c.encode(b, forKey: .base64) }
    }
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

// MARK: - Display Enumeration

func getDisplays() -> [DisplayEntry] {
    let maxD: UInt32 = 16
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(maxD))
    var count: UInt32 = 0
    CGGetActiveDisplayList(maxD, &ids, &count)

    let mainID = CGMainDisplayID()
    let mainBounds = CGDisplayBounds(mainID)
    let mainCX = mainBounds.origin.x + mainBounds.width / 2

    // NSScreen scale factor lookup
    var scaleMap: [CGDirectDisplayID: Double] = [:]
    for screen in NSScreen.screens {
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            scaleMap[n] = screen.backingScaleFactor
        }
    }

    // Sort: main first, then by X coordinate (left to right)
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

/// Which display entry contains a given window's center point?
func displayForWindow(_ window: SCWindow, displays: [DisplayEntry]) -> DisplayEntry {
    let pt = CGPoint(x: window.frame.midX, y: window.frame.midY)
    return displays.first(where: { $0.bounds.contains(pt) }) ?? displays.first(where: { $0.isMain })!
}

/// Find the largest normal window for a given PID (skips tiny utility windows).
func largestWindow(for pid: pid_t, in windows: [SCWindow]) -> SCWindow? {
    windows
        .filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 0 }
        .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
}

/// Find the largest normal window on a given display.
func largestWindowOnDisplay(_ entry: DisplayEntry, in windows: [SCWindow], preferPID: pid_t? = nil) -> SCWindow? {
    let onDisplay = windows.filter { w in
        w.windowLayer == 0 && w.frame.width > 100
            && entry.bounds.contains(CGPoint(x: w.frame.midX, y: w.frame.midY))
    }
    // Prefer a window from the specified app if provided
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

/// Walk up the PID tree from the current process to find the nearest ancestor with a window.
/// Falls back to TERM_PROGRAM env var matching, then to user_active.
func selfieWindow(content: SCShareableContent) -> SCWindow? {
    // Strategy 1: walk PID tree (works for Terminal -> shell -> side-eye)
    var pid = getpid()
    var visited = Set<pid_t>()
    while pid > 1 && !visited.contains(pid) {
        visited.insert(pid)
        if let w = largestWindow(for: pid, in: content.windows) {
            return w
        }
        pid = parentPID(of: pid)
    }

    // Strategy 2: TERM_PROGRAM env var (handles tmux/screen where PID tree is severed)
    if let termProgram = ProcessInfo.processInfo.environment["TERM_PROGRAM"] {
        let needle = termProgram.lowercased()
        let candidates = content.windows.filter {
            guard let app = $0.owningApplication else { return false }
            let name = app.applicationName.lowercased()
            let bundle = app.bundleIdentifier.lowercased()
            return $0.windowLayer == 0 && $0.frame.width > 100
                && (name.contains(needle) || bundle.contains(needle))
        }
        if let w = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            return w
        }
    }

    // Strategy 3: fall back to frontmost app (user_active behavior)
    if let frontApp = NSWorkspace.shared.frontmostApplication {
        return largestWindow(for: frontApp.processIdentifier, in: content.windows)
    }

    return nil
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
    // Create parent directory if needed
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.identifier as CFString, 1, nil)
    else { return false }

    var props: [CFString: Any] = [:]
    if format != .png { props[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    return CGImageDestinationFinalize(dest)
}

// MARK: - Crop

func applyCrop(_ image: CGImage, style: String) -> CGImage {
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
        // Try exact: x,y,w,h
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
    return cropped
}

// MARK: - ScreenCaptureKit Capture

@available(macOS 14.0, *)
func captureDisplay(_ scDisplay: SCDisplay, scaleFactor: Double) async throws -> CGImage {
    let filter = SCContentFilter(display: scDisplay, excludingApplications: [], exceptingWindows: [])
    let config = SCStreamConfiguration()
    config.width = Int(Double(scDisplay.width) * scaleFactor)
    config.height = Int(Double(scDisplay.height) * scaleFactor)
    config.showsCursor = false
    config.captureResolution = .best
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
}

@available(macOS 14.0, *)
func captureWindow(_ window: SCWindow, scaleFactor: Double) async throws -> CGImage {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    config.width = Int(window.frame.width * scaleFactor)
    config.height = Int(window.frame.height * scaleFactor)
    config.showsCursor = false
    config.captureResolution = .best
    config.ignoreShadowsSingleWindow = true
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
}

// MARK: - Argument Parsing

struct CaptureOptions {
    var target: String = "main"
    var windowOnly: Bool = false
    var outputPath: String? = nil  // nil = use default based on format
    var useBase64: Bool = false
    var crop: String? = nil
    var format: String = "png"
    var quality: String = "high"

    var resolvedOutputPath: String {
        if let p = outputPath { return p }
        let ext = (format == "jpeg") ? "jpg" : format
        return "./screenshot.\(ext)"
    }
}

func parseCaptureArgs(_ args: [String]) -> CaptureOptions {
    var opts = CaptureOptions()
    var i = 0

    // Extract target (first non-flag arg)
    if i < args.count && !args[i].hasPrefix("--") {
        opts.target = args[i]
        i += 1
        // Handle "external 1" / "external 2" (two-word target)
        if opts.target == "external" && i < args.count && !args[i].hasPrefix("--") {
            if let _ = Int(args[i]) {
                opts.target += " \(args[i])"
                i += 1
            }
        }
    }

    // Parse flags
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

let knownTargets: Set<String> = ["main", "center", "middle", "external", "user_active", "all", "selfie"]

// MARK: - Usage

func printUsage() {
    print("""
    side-eye — Agent-first macOS screenshot CLI

    USAGE:
      side-eye list                          Display topology as JSON
      side-eye capture <target> [options]    Take a screenshot
      side-eye <target> [options]            Shorthand for capture

    TARGETS:
      main, center, middle    Primary display
      external                First external display
      external 1              Leftmost external display
      external 2              Next external display
      user_active             Display with the focused app
      selfie                  Display hosting this process
      all                     Every connected display

    OPTIONS:
      --window                Capture only the targeted window
      --out <path>            Output path (default: ./screenshot.<format>)
      --base64                Output base64 in JSON instead of writing a file
      --crop <style>          Crop region (fuzzy name or x,y,w,h)
      --format <ext>          png (default), jpg, heic
      --quality <level>       high (default), med, low

    CROP STYLES:
      top-half, bottom-half, left-half, right-half
      top-left, top-right, bottom-left, bottom-right, center
      x,y,w,h (exact pixel coordinates)
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
            DisplayJSON(
                id: $0.ordinal, type: $0.type, resolution: $0.resolution,
                scale_factor: $0.scaleFactor, rotation: $0.rotation, arrangement: $0.arrangement
            )
        }
    )
    print(jsonString(topology))
}

// MARK: - Command: capture

@available(macOS 14.0, *)
func captureCommand(args: [String]) async {
    let opts = parseCaptureArgs(args)
    let fmt = resolveUTType(for: opts.format)
    let quality = resolveQuality(for: opts.quality)

    // Get ScreenCaptureKit content
    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    } catch {
        exitError(
            "Screen recording permission denied or unavailable. Grant permission in System Settings > Privacy & Security > Screen Recording.",
            code: "PERMISSION_DENIED"
        )
    }

    let displays = getDisplays()

    // Resolve target → display ID(s) + optional specific window
    var targetDisplayIDs: [CGDirectDisplayID] = []
    var specificWindow: SCWindow? = nil

    switch opts.target {
    case "main", "center", "middle":
        guard let d = displays.first(where: { $0.isMain }) else {
            exitError("No main display found", code: "NO_DISPLAY")
        }
        targetDisplayIDs = [d.cgID]

    case "external":
        guard let d = displays.first(where: { !$0.isMain && !$0.isMirrored }) else {
            exitError("No external display connected", code: "NO_EXTERNAL_DISPLAY")
        }
        targetDisplayIDs = [d.cgID]

    case "external 1":
        let exts = displays.filter { !$0.isMain && !$0.isMirrored }
        guard let d = exts.first else {
            exitError("No external display connected", code: "NO_EXTERNAL_DISPLAY")
        }
        targetDisplayIDs = [d.cgID]

    case "external 2":
        let exts = displays.filter { !$0.isMain && !$0.isMirrored }
        if exts.count >= 2 {
            targetDisplayIDs = [exts[1].cgID]
        } else if let d = exts.first {
            targetDisplayIDs = [d.cgID]
        } else {
            exitError("No external display connected", code: "NO_EXTERNAL_DISPLAY")
        }

    case "user_active":
        guard let app = NSWorkspace.shared.frontmostApplication else {
            exitError("No frontmost application found", code: "NO_ACTIVE_APP")
        }
        guard let w = largestWindow(for: app.processIdentifier, in: content.windows) else {
            exitError("No window found for active app '\(app.localizedName ?? "?")'", code: "NO_WINDOW")
        }
        specificWindow = w
        targetDisplayIDs = [displayForWindow(w, displays: displays).cgID]

    case "selfie":
        guard let w = selfieWindow(content: content) else {
            exitError("Cannot find hosting application window in process tree", code: "SELFIE_NOT_FOUND")
        }
        specificWindow = w
        targetDisplayIDs = [displayForWindow(w, displays: displays).cgID]

    case "all":
        targetDisplayIDs = displays.filter { !$0.isMirrored }.map { $0.cgID }

    default:
        exitError("Unknown target: '\(opts.target)'", code: "UNKNOWN_TARGET")
    }

    // Capture each target
    var results: [(CGImage, String)] = []

    for (idx, cgID) in targetDisplayIDs.enumerated() {
        guard let entry = displays.first(where: { $0.cgID == cgID }) else { continue }

        var image: CGImage

        if opts.windowOnly {
            // Window capture mode
            let window: SCWindow
            if let sw = specificWindow, idx == 0 {
                // selfie / user_active already identified the window
                window = sw
            } else {
                // Find the largest window on this display, preferring the frontmost app
                let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard let w = largestWindowOnDisplay(entry, in: content.windows, preferPID: frontPID) else {
                    exitError("No window found on display \(entry.ordinal)", code: "NO_WINDOW")
                }
                window = w
            }
            do {
                image = try await captureWindow(window, scaleFactor: entry.scaleFactor)
            } catch {
                exitError("Window capture failed: \(error.localizedDescription)", code: "CAPTURE_FAILED")
            }

        } else {
            // Full display capture
            guard let scDisplay = content.displays.first(where: { $0.displayID == cgID }) else {
                exitError("Display \(entry.ordinal) not available via ScreenCaptureKit", code: "DISPLAY_NOT_FOUND")
            }
            do {
                image = try await captureDisplay(scDisplay, scaleFactor: entry.scaleFactor)
            } catch {
                exitError("Display capture failed: \(error.localizedDescription)", code: "CAPTURE_FAILED")
            }
        }

        // Apply crop
        if let crop = opts.crop {
            image = applyCrop(image, style: crop)
        }

        // Determine output path for this image
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

    // Output results
    if opts.useBase64 {
        var b64s: [String] = []
        for (img, _) in results {
            guard let data = encodeImage(img, format: fmt, quality: quality) else {
                exitError("Failed to encode image to \(opts.format)", code: "ENCODE_FAILED")
            }
            b64s.append(data.base64EncodedString())
        }
        var resp = SuccessResponse()
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
        var resp = SuccessResponse()
        resp.files = files
        print(jsonString(resp))
    }
}

// MARK: - Entry Point

@available(macOS 14.0, *)
@main
struct SideEye {
    static func main() async {
        // Required for ScreenCaptureKit to function in a CLI context
        _ = NSApplication.shared

        let args = Array(CommandLine.arguments.dropFirst())

        guard !args.isEmpty else {
            printUsage()
            exit(0)
        }

        switch args[0] {
        case "list":
            await listCommand()
        case "capture":
            await captureCommand(args: Array(args.dropFirst()))
        case "help", "--help", "-h":
            printUsage()
        default:
            // Implied capture: if the first arg is a known target, treat as `capture <target>`
            if knownTargets.contains(args[0]) {
                await captureCommand(args: args)
            } else {
                exitError("Unknown command or target: '\(args[0])'", code: "UNKNOWN_COMMAND")
            }
        }
    }
}
