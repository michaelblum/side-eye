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
- **Local Coordinate System (LCS)**: `(0,0)` is always the top-left of whatever you captured. Agents never do global screen math. The LCS is also a strict **visibility filter** -- `--xray` only returns elements that physically intersect the captured region.
- **Baked overlays**: Grids, bounding boxes, and cursor highlights are drawn into the image via CoreGraphics before encoding -- no post-processing needed.
- **Semantic perception**: `--xray` emits a flat array of interactive UI elements with accessibility metadata, spatially aligned to the same LCS as the image. The agent gets pixels *and* meaning in one call.
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

## Semantic Perception (`--xray`)

Most screenshot tools give an agent pixels and wish it luck. `--xray` gives the agent **meaning** -- a flat JSON array of every interactive UI element in the capture area, with accessibility metadata, structural context, and bounding boxes in the same Local Coordinate System as the image.

```bash
side-eye user_active --window --xray --base64 --format jpg --quality low
```

```json
{
  "status": "success",
  "base64": ["..."],
  "elements": [
    {
      "role": "AXButton",
      "title": "Submit",
      "label": "Submit form",
      "value": null,
      "enabled": true,
      "context_path": ["MyApp", "Main Window", "Form Section", "AXToolbar"],
      "bounds": {"x": 450, "y": 320, "width": 120, "height": 40}
    }
  ]
}
```

The agent receives a base64 image **and** a structured manifest of what's clickable, editable, and toggleable -- spatially registered to the same coordinate grid. No vision model needed to find the "Submit" button. It's at `(450, 320)`.

### Foveated Vision for AI

The LCS isn't just a coordinate system -- it's a **spatial attention filter**. When an agent crops to a region, `--xray` only returns elements that physically intersect that crop. Everything else is discarded before it reaches the context window.

```bash
# Full window: 182 elements
side-eye user_active --xray

# Agent zooms in on just the toolbar
side-eye user_active --xray --crop 0,0,3024,120

# Now: only 6 elements — just the toolbar buttons
```

This is foveated vision for AI. The agent decides what to look at, and side-eye delivers *only* the pixels and semantics within that gaze. No off-screen noise. No wasted tokens on elements the agent can't see.

### Semantic Breadcrumbs, Not Nested Trees

Standard accessibility dumps produce deeply nested trees -- hundreds of layout wrappers, scroll containers, and invisible groups that consume tokens and confuse reasoning. side-eye takes a different approach:

- **Flat array**: No nesting. Every element is a top-level entry.
- **Whitelisted roles**: Only actionable elements (buttons, text fields, checkboxes, links, menu items) and standalone text. Layout wrappers are traversed but never emitted.
- **`context_path`**: Structural hierarchy preserved as an array of ancestor names. The agent gets `["Main Window", "Sidebar", "Toolbar"]` -- enough for spatial reasoning without the token cost of deeply nested JSON.

A typical window produces 6-20 actionable elements instead of 500+ tree nodes. That's the difference between filling the context window with noise and giving the agent a clean action space.

### Window-Aware Traversal

`--xray` is smart about *which* app to traverse. It doesn't blindly scan the globally active application -- it reads the accessibility tree of the app that **owns the captured target**.

```bash
# Captures the terminal window, traverses the terminal's AX tree
# (even if the terminal is in the background)
side-eye selfie --window --xray

# Captures the active app's window, traverses that app's AX tree
side-eye user_active --window --xray

# Display capture: traverses the frontmost app (what's on top)
side-eye main --xray
```

This means an agent can `--xray` its own terminal window to read its own output, or inspect a background app's UI without bringing it to the foreground.

### The Perception Loop

Combine `--xray` with cropping, overlays, and zones for a tight agent workflow:

```bash
# Step 1: Wide capture with xray — agent sees everything
side-eye user_active --window --xray --base64 --format jpg --quality low
# Agent receives image + 14 interactive elements

# Step 2: Agent identifies a form region at (100,400,800,300)
# Zooms in with crop — xray auto-filters to just that region
side-eye user_active --window --xray --crop 100,400,800,300 \
  --grid 4x3 --base64 --format jpg --quality med
# Agent receives cropped image + grid + only the 4 form elements

# Step 3: Agent knows "Email" field is at (50,20,300,30) in the cropped LCS
# It can now draw a highlight or save the region as a zone
side-eye user_active --window --crop 100,400,800,300 \
  --draw-rect 50,20,300,30 '#FF000080' --base64

# Step 4: Agent saves the form as a named zone for re-inspection
side-eye zone save "signup-form" --target user_active --bounds 100,400,800,300
side-eye signup-form --xray --base64 --format jpg --quality low
```

Each step narrows the spatial scope. Each `--xray` call returns fewer, more relevant elements. The agent's context window stays lean, and every token of UI metadata maps directly to pixels in the image it's analyzing.

### Xray Cookbook

```bash
# Basic: get all interactive elements on the active window
side-eye user_active --window --xray --base64

# Crop to a specific region — only elements in that region
side-eye main --xray --crop 0,0,1512,100

# Combine with grid overlay for visual + semantic understanding
side-eye user_active --window --xray --grid 8x8 --base64 --format jpg --quality med

# Save a zone, then xray just that zone later
side-eye zone save "nav" --target main --bounds 0,0,1512,50
side-eye nav --xray --base64

# Xray your own terminal (agent self-inspection)
side-eye selfie --window --xray --base64 --format jpg --quality low
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
  "warning": "Window appears minimized. Falling back to display capture.",
  "elements": [
    {
      "role": "AXButton",
      "title": "Submit",
      "label": "Submit form",
      "value": null,
      "enabled": true,
      "context_path": ["MyApp", "Main Window", "Toolbar"],
      "bounds": { "x": 450, "y": 320, "width": 120, "height": 40 }
    }
  ]
}
```

All fields except `status` are optional (present only when relevant). `elements` is only present when `--xray` is used.

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
| `--xray` | Accessibility | `AXIsProcessTrustedWithOptions()` |
| `--wait-for-click` | Accessibility | `AXIsProcessTrustedWithOptions()` |

Both are checked proactively with clear JSON error messages. No silent black images.

## License

MIT
