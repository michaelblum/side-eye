# side-eye

Agent-first macOS screenshot CLI. Zero dependencies. Single Swift binary.

`side-eye` is built for **LLM/agent consumption** -- every output is structured JSON, every coordinate is local to the captured target, and overlays (grids, bounding boxes) are baked directly into images so agents can reason about spatial layout without external tooling.

## Install

```bash
git clone https://github.com/michaelblum/side-eye.git
cd side-eye
./build.sh          # compiles to ./side-eye (requires Xcode CLI tools)
cp side-eye /usr/local/bin/   # optional: add to PATH
```

Requirements: macOS 14+, Xcode Command Line Tools (`xcode-select --install`).

First run will prompt for **Screen Recording** permission (System Settings > Privacy & Security > Screen Recording).

## Architecture

```
Agent (Claude, Gemini, etc.)
  |
  |-- side-eye list              --> JSON topology of all displays
  |-- side-eye capture main      --> JSON { status, files }
  |-- side-eye mouse --radius 200 --grid 8x8 --base64
  |       --> JSON { status, base64: ["iVBOR..."], cursor: {x,y} }
  |
  v
All coordinates are LOCAL to the captured target (0,0 = top-left).
Overlays are baked into the image before encoding.
Errors go to stderr as JSON with machine-readable codes.
```

**Design principles:**
- **JSON-first**: All output is parseable JSON. Success on stdout, errors on stderr.
- **Local Coordinate System (LCS)**: `(0,0)` is always the top-left of whatever you captured. Agents never do global screen math.
- **Baked overlays**: Grids, bounding boxes, and cursor highlights are drawn into the image via CoreGraphics before encoding -- no post-processing needed.
- **Zero dependencies**: Pure Swift, Apple frameworks only.

## Quick Start

```bash
# See your display topology
side-eye list

# Screenshot the main display
side-eye main --out /tmp/screen.png

# Screenshot as base64 JSON (no disk I/O)
side-eye main --base64 --format jpg --quality low

# Interactive: drag to select a region
side-eye main --interactive --out /tmp/selection.png
```

## The Cookbook

### Display Discovery

```bash
# Full topology with active app, resolution, scale factor, arrangement
side-eye list
# => {"active_app":"Cursor","displays":[{"id":1,"type":"Main display",...}]}
```

### Targeted Capture

```bash
# Primary display
side-eye main

# External monitor (first one found)
side-eye external

# Whichever display has the focused app
side-eye user_active

# Display under the mouse cursor
side-eye mouse

# The display running this terminal
side-eye selfie

# Every connected display (one file each)
side-eye all --out /tmp/screen.png
# => screenshot_1.png, screenshot_2.png, ...
```

### Window Capture

```bash
# Capture just the frontmost window (transparent background)
side-eye user_active --window --out /tmp/window.png
```

### Format & Compression

```bash
# Low-quality JPEG for fast base64 transfer to an LLM
side-eye main --base64 --format jpg --quality low

# HEIC for archival
side-eye main --format heic --quality high --out ~/captures/today.heic
```

### Cropping

```bash
# Named regions
side-eye main --crop top-half
side-eye main --crop bottom-right

# Exact pixel region (LCS coordinates)
side-eye main --crop 100,200,800,600
```

### Mouse Targeting

```bash
# Capture the display where the cursor is
side-eye mouse

# Capture a 200px-radius box centered on cursor
side-eye mouse --radius 200

# Highlight the cursor position with a colored circle
side-eye mouse --highlight-cursor '#FF000080'
```

### Grid Overlay (LLM Spatial Reasoning)

```bash
# Overlay a 10x10 coordinate grid onto the capture
side-eye main --grid 10x10 --out /tmp/gridded.png

# Grid on a cropped region
side-eye main --crop top-half --grid 4x3

# Custom thickness for Retina displays
side-eye main --grid 8x8 --thickness 4
```

### Bounding Box Annotations

```bash
# Draw a red stroke rectangle
side-eye main --draw-rect 100,50,300,200 '#FF0000'

# Draw a translucent filled box
side-eye main --draw-rect-fill 100,50,300,200 '#0000FF40'

# Multiple boxes with drop shadow
side-eye main \
  --draw-rect 10,10,200,100 '#FF0000' \
  --draw-rect 220,10,200,100 '#00FF00' \
  --shadow 2,2,4,#00000080 \
  --thickness 3
```

### Highlight a Button for an LLM

```bash
# 1. Capture with grid so agent can identify coordinates
side-eye user_active --window --grid 10x10 --base64 --format jpg --quality med

# 2. Agent identifies button at roughly (450,320,120,40)
# 3. Re-capture with bounding box baked in
side-eye user_active --window \
  --draw-rect 450,320,120,40 '#FF000080' \
  --thickness 3 \
  --shadow 2,2,6,#00000080 \
  --base64 --format jpg --quality med
```

### Interactive Selection

```bash
# Native macOS crosshair -- drag to select region
side-eye main --interactive --out /tmp/region.png
# => {"status":"success","files":[...],"bounds":{"x":0,"y":0,"width":800,"height":600}}

# Interactive with grid overlay on result
side-eye main --interactive --grid 5x5
```

### Zone Memory (Spatial Variables)

```bash
# Save a named region
side-eye zone save "navbar" --target main --bounds 0,0,1512,50

# List all saved zones
side-eye zone list

# Capture a saved zone
side-eye navbar --out /tmp/navbar.png

# Capture zone with overlay
side-eye navbar --grid 4x1 --draw-rect 10,5,80,40 '#FF0000'

# Delete a zone
side-eye zone delete "navbar"

# Interactive zone definition (requires direct terminal access)
side-eye zone define "sidebar" --target main
```

Zones are stored in `~/.config/side-eye/zones.json`.

### Clipboard & Delay

```bash
# Copy to clipboard instead of (or in addition to) file
side-eye main --clipboard

# Wait 3 seconds before capturing (e.g., to open a menu)
side-eye main --delay 3 --out /tmp/menu.png
```

### Agent Workflow: Analyze & Annotate Loop

```bash
# Step 1: Agent captures with grid for spatial orientation
side-eye user_active --window --grid 10x10 --base64 --format jpg --quality low
# Agent receives base64 image + analyzes it

# Step 2: Agent identifies UI elements and annotates
side-eye user_active --window \
  --draw-rect 45,120,200,35 '#FF000080' \
  --draw-rect-fill 300,400,150,50 '#00FF0030' \
  --base64

# Step 3: Agent saves interesting region as a zone for later
side-eye zone save "login-form" --target user_active --bounds 45,100,400,300

# Step 4: Quick re-check of just that zone
side-eye login-form --base64 --format jpg --quality low
```

## JSON Output Reference

### Success (stdout, exit 0)

```json
{
  "status": "success",
  "files": ["./screenshot.png"],
  "cursor": { "x": 150, "y": 150 },
  "bounds": { "x": 0, "y": 0, "width": 800, "height": 600 },
  "click_x": 423,
  "click_y": 267,
  "warning": "Window appears minimized. Falling back to display capture."
}
```

All fields except `status` are optional (present only when relevant).

### Failure (stderr, exit 1)

```json
{
  "error": "Screen recording permission denied.",
  "code": "PERMISSION_DENIED"
}
```

Error codes: `PERMISSION_DENIED`, `ACCESSIBILITY_DENIED`, `NO_DISPLAY`, `NO_EXTERNAL_DISPLAY`, `NO_WINDOW`, `NO_ACTIVE_APP`, `SELFIE_NOT_FOUND`, `UNKNOWN_TARGET`, `UNKNOWN_COMMAND`, `UNKNOWN_OPTION`, `INVALID_COLOR`, `INVALID_CROP`, `INVALID_ARG`, `INVALID_FORMAT`, `INVALID_QUALITY`, `MISSING_ARG`, `MISSING_SUBCOMMAND`, `CAPTURE_FAILED`, `ENCODE_FAILED`, `WRITE_FAILED`, `SELECTION_CANCELLED`, `TIMEOUT`, `ZONE_NOT_FOUND`, `ZONE_WRITE_FAILED`, `INTERACTIVE_UNAVAILABLE`.

## Permissions

| Feature | Permission | Check |
|---------|-----------|-------|
| All captures | Screen Recording | `CGPreflightScreenCaptureAccess()` |
| `--wait-for-click` | Accessibility | `AXIsProcessTrustedWithOptions()` |

Both are checked proactively with clear JSON error messages. No silent black images.

## License

MIT
