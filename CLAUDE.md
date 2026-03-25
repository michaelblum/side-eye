# side-eye

Agent-first macOS screenshot CLI. Pure Swift, zero dependencies.

## Build

```bash
./build.sh
# or manually:
swiftc -parse-as-library -O -o side-eye main.swift
```

Requires macOS 14+ and Screen Recording permission for the calling terminal.

## Usage

```bash
# Display topology
./side-eye list

# Screenshot main display
./side-eye main --out /tmp/main.png

# Screenshot with base64 output (no file written)
./side-eye selfie --base64 --format jpg --quality low

# Window capture
./side-eye user_active --window --out /tmp/window.png

# Crop
./side-eye main --crop top-half --out /tmp/top.png
```

## Architecture

Single file: `main.swift`. No SPM, no Xcode project, no external deps.

Key frameworks: ScreenCaptureKit (capture), AppKit/CoreGraphics (display enumeration), UniformTypeIdentifiers (format handling).

## Targets

| Target | Resolves to |
|---|---|
| `main`, `center`, `middle` | Primary display (origin 0,0) |
| `external` | First non-main, non-mirrored display |
| `external 1` | Leftmost external (lowest X) |
| `external 2` | Next external by X coordinate |
| `user_active` | Display containing frontmost app window |
| `selfie` | Display hosting the calling process (walks PID tree) |
| `all` | Every connected display |

## JSON Output

All output is JSON. Success to stdout, errors to stderr with exit code 1.

```json
{"status": "success", "files": ["./screenshot.png"]}
{"status": "success", "base64": ["iVBORw0KG..."]}
{"error": "...", "code": "PERMISSION_DENIED"}
```
