---
name: simpilot — Simulator & Device UI Automation
description: >
  Use this skill when the user mentions "simpilot", "simpilotで", "simpilotを使って",
  or wants to control iOS Simulator / physical device UI programmatically.
  Also trigger when the user says "シミュレータを操作", "シミュレータのアプリを操作",
  "Simulatorのアプリ", "Simulator上で", "Vision Proのシミュレータ", "visionOSシミュレータ",
  "実機を操作", "実機で", "実機のアプリ", "iPhoneを操作", "iPadを操作",
  "シミュレータでアプリを動かして", "シミュレータで検索して", or similar phrases
  about controlling apps on Simulator or physical iOS/visionOS devices.
  Do NOT trigger for generic phrases like "設定アプリを見て", "tap a button",
  "take a screenshot" — these could refer to macOS or non-device contexts.
  Always invoke this skill before attempting any simpilot commands — it contains
  critical command syntax and anti-patterns that prevent common mistakes.
  Supports iOS, iPadOS, and visionOS.
---

# simpilot — Simulator & Device UI Automation

Control Simulator and physical device apps programmatically from the command line. Built on XCUITest, simpilot lets you tap, type, swipe, take screenshots, and read UI element trees — all via JSON output optimized for AI agents. Supports iOS, iPadOS, and visionOS.

## Before You Start

**Always use the installed binary `simpilot`, never `swift run simpilot`.**
The CLI is installed at `/usr/local/bin/simpilot`. Using `swift run` adds unnecessary build-cache checks on every invocation and is significantly slower.

```bash
# WRONG — slow, unnecessary build check
swift run simpilot tap 'General'

# RIGHT — direct execution
simpilot tap 'General'
```

## Setup

```bash
# Build & install (one-time)
cd /Users/yoshi/Developer/simpilot
make install   # builds CLI and installs to /usr/local/bin

# Start the agent — Simulator
simpilot start                                 # default: iPhone 17 Pro
simpilot start --device 'iPhone Air'           # specify iOS device
simpilot start --device 'iPad Pro 13-inch (M5)' # iPad
simpilot start --device 'Apple Vision Pro'     # visionOS

# Start the agent — Physical device
simpilot start --device 'My iPhone'            # auto-detects physical device via devicectl

# Start parallel agents (see "Parallel Testing" section)
simpilot start --device 'iPhone Air' --clone 2   # 2 clones for parallel testing
```

For physical devices, the device must be connected via USB or Wi-Fi, and the XCUITest agent must be signed with a valid team in Xcode.

## Critical Rules

1. **ALWAYS use bare label queries** — `simpilot tap 'General'` not `simpilot tap '#com.apple.settings.general'`. Bare labels resolve in <1s; identifier queries can take 24+ seconds on complex apps.
2. **Start with `--level 0`** to understand the screen (~50 tokens), then `--level 1` for actionable elements (~500 tokens). Never start with full tree.
3. **Never guess queries — always verify with `elements --level 1` first.** Common labels like "Search", "Settings", "Done" often match multiple elements (e.g., a "Search" settings row vs a search text field). The bare query matches the first one found, which may not be the intended target. Always check the `type` field to confirm you're targeting the right element. Use typed queries (`searchField:Search` vs `button:Search`) to disambiguate.
4. **Use `batch` for multi-step flows** — one HTTP round-trip instead of many.
5. **Use `action` for tap→screenshot→elements** — the most common workflow in one command.
6. **`tap` and `tapcoord` are different commands** — `tap` takes a label/query string; `tapcoord` takes x y coordinates. Never pass `--x`/`--y` flags to `tap`.
7. **For WebView elements, always use `source` to get coordinates** — never estimate coordinates from screenshots. Visual position and actual frame coordinates can differ by hundreds of points. See `references/webview.md` for details.

## Recommended Workflow

```bash
# 1. Launch app
simpilot launch com.apple.Preferences

# 2. Get screen overview (tiny output)
simpilot elements --level 0
# → {"counts": {"button": 12, "cell": 11, ...}, "total": 62}

# 3. Get actionable elements (query field tells you what to tap)
simpilot elements --level 1
# → [{"query": "General", "type": "button", "label": "General"}, ...]

# 4. Use the query field value directly
simpilot tap 'General'

# 5. Or do tap + screenshot + elements in one call
simpilot action tap 'About' --screenshot /tmp/about.png --level 0 --settle 1
```

## Observation Strategy

Choosing the right observation tool reduces token cost and speeds up automation.

| Situation | Tool | Cost |
|---|---|---|
| Native app — find what to tap | `elements --level 1` | ~500 tokens |
| Native app — screen overview | `elements --level 0` | ~50 tokens |
| WebView — find text/links/coordinates | `source` + grep | ~varies |
| Visual layout, carousel, unfamiliar screen | `screenshot --file` + Read | ~image tokens |
| Evidence capture for testing | `screenshot --file` (save only, don't read) | ~0 tokens |

**Key principles:**
- **Native apps** → `elements` is almost always sufficient. Skip screenshots.
- **WebView apps** → `source` is the primary tool. It gives you both content and coordinates, like a DOM inspector. See `references/webview.md` for the full workflow.
- **Screenshots** → useful for horizontal scroll / carousel UIs (source can't tell what's currently visible), visual layout understanding (grids, maps, overlapping elements), and showing results to the user.
- **Token-conscious capture**: `screenshot --file /tmp/s.png` saves to disk cheaply. Reading the image into context is what costs tokens. Capture liberally for evidence, but only read when visual analysis is actually needed for the next decision.
- **Screenshot resolution**: Default `--scale 1` returns a 1x point-sized PNG (~1/3 long edge of native, ~70% smaller than full resolution) — ideal for AI analysis. Use `--scale 2` for @2x, or `--scale native` for design work needing the device's full pixel resolution.

## Fast Operation Patterns

### Batch multiple actions

When the UI flow is predictable (e.g., navigating Settings → General → About), chain actions in a single `batch` call instead of observing after each step:

```bash
# Slow: observe after every tap
simpilot action tap 'General' --screenshot /tmp/s.png --level 1  # → analyze...
simpilot action tap 'About' --screenshot /tmp/s.png --level 1   # → analyze...

# Fast: batch actions, observe only at the end
simpilot batch '{"commands":[
  {"method":"POST","path":"/tap","body":{"query":"General"}},
  {"method":"POST","path":"/tap","body":{"query":"About"}},
  {"method":"GET","path":"/screenshot","params":{"file":"/tmp/s.png"}},
  {"method":"GET","path":"/elements","params":{"level":"0"}}
]}'
```

### Skip observation on known flows

If you already know what elements are on the next screen (e.g., from a previous visit or standard OS screens), skip the observation step entirely and tap directly.

## Commands Reference

### App Lifecycle

```bash
simpilot launch <bundleId>        # Launch an app
simpilot activate <bundleId>      # Bring to foreground (no relaunch)
simpilot terminate <bundleId>     # Terminate an app
```

### Element Interaction

```bash
# Tap by label/query (for native elements and elements visible in `elements --level 1`)
simpilot tap '<query>'

# Tap by screen coordinates (for WebView elements — get coordinates from `source`)
simpilot tapcoord <x> <y>

simpilot type '<text>' [--into '<query>']         # Type text (keyboard input)
simpilot type '<text>' --method paste             # Paste via clipboard (use only when keyboard is unavailable)
simpilot swipe <up|down|left|right> [--on '<query>']  # Swipe
simpilot wait '<query>' [--timeout 10] [--gone]  # Wait for element
simpilot clipboard get                           # Read clipboard contents
simpilot clipboard set '<text>'                  # Write text to clipboard
```

### Observation

```bash
simpilot screenshot [--file /tmp/s.png] [--scale <N|native>]  # Screenshot (default scale=1 for AI; scale=native for full resolution)
simpilot elements [--level 0|1|2|3]       # UI elements (see levels below)
simpilot source                           # Raw Xcode UI hierarchy (essential for WebView)
simpilot info                             # Device and agent info
```

### Compound Commands

```bash
# Execute action + wait + screenshot + elements in one call
simpilot action tap '<query>' --screenshot /tmp/s.png --level 1 --settle 1
# Add --scale native if you need full-resolution output instead of the 1x default
simpilot action tap '<query>' --screenshot /tmp/s.png --scale native

# Execute multiple commands in one HTTP round-trip
simpilot batch '{"commands":[
  {"method":"POST","path":"/tap","body":{"query":"General"}},
  {"method":"GET","path":"/screenshot","params":{"file":"/tmp/s.png"}},
  {"method":"GET","path":"/elements","params":{"level":"0"}}
]}'
```

### Agent Lifecycle

```bash
simpilot start [--device '<name>']  # Build & start agent on simulator or device
simpilot stop                       # Stop the agent on default port
simpilot stop --port 8223           # Stop a specific agent
simpilot stop --all                 # Stop all agents + delete cloned/created devices
simpilot health                     # Check if agent is running
simpilot list                       # Show all running agents with status
```

### Parallel Testing

Run multiple agents simultaneously on cloned or new simulator devices.

```bash
# Clone: copy device state (source must be Shutdown)
simpilot start --device 'iPhone Air' --clone       # 1 clone
simpilot start --device 'iPhone Air' --clone 3     # 3 clones

# Create: fresh clean device (works regardless of source state)
simpilot start --create                            # 1 new device
simpilot start --device 'iPhone Air' --create 2    # 2 new devices
```

Each clone/create gets an auto-assigned port (8222, 8223, ...). Use `--port` to target a specific agent:

```bash
simpilot tap 'General' --port 8223    # operate on clone 1
simpilot tap 'General' --port 8224    # operate on clone 2
```

Device naming:
- Clone: `Clone of iPhone Air (8223)` — preserves source device state
- Create: `New iPhone Air (8223)` — clean device, no prior state

Cloned/created devices are automatically deleted when stopped.

For AI agent parallel execution, launch subagents that each target a different `--port`.

### Utility

```bash
simpilot help      # Full command catalog (JSON)
```

## Element Query Syntax

Used by `tap`, `type`, `wait`, and `action` commands:

| Format | Description | Speed |
|---|---|---|
| `General` | Search by label (bare query) | **Fast** (<1s) |
| `button:Login` | Search buttons by label | Medium (~2s) |
| `text:Hello` | Search static text by label | Medium (~2s) |
| `textField:Email` | Search text fields | Medium (~2s) |
| `link:Learn more` | Search links | Medium (~2s) |
| `#identifier` | Search by accessibility ID | **Slow** (10-24s) |

**Always prefer bare label queries.** The `query` field in `elements --level 1` output already returns the optimal query string.

## Elements Levels

| Level | Output | Tokens | Use Case |
|---|---|---|---|
| `--level 0` | Type counts only | ~50 | Screen overview |
| `--level 1` | Flat actionable list | ~500 | Find what to tap |
| `--level 2` | Compact tree | ~2000 | Understand layout |
| `--level 3` | Full tree | ~5000+ | Debug |

## Output Format

All output is JSON with a consistent envelope:

```json
{"success": true, "data": {...}, "error": null, "duration_ms": 42}
```

Errors:

```json
{"success": false, "data": null, "error": {"code": "element_not_found", "message": "..."}}
```

## Common Bundle IDs

| App | Bundle ID |
|---|---|
| Settings | `com.apple.Preferences` |
| Safari | `com.apple.mobilesafari` |
| Messages | `com.apple.MobileSMS` |
| Photos | `com.apple.Photos` |
| Maps | `com.apple.Maps` |
| Calendar | `com.apple.mobilecal` |
| Notes | `com.apple.mobilenotes` |

## Platform Support

| Command | iOS / iPadOS | visionOS | tvOS / watchOS |
|---|---|---|---|
| launch / terminate / activate | OK | OK | NG |
| tap | OK (~1s) | OK (~20s) | NG |
| type | OK | OK | NG |
| clipboard | OK | OK | NG |
| swipe | OK | NG | tvOS only (remote) |
| screenshot | OK | OK | OK |
| elements / source | OK | OK | NG |
| start / stop / health | OK | OK | OK |

- **visionOS**: Coordinate taps fall back to native element resolution (slower). `swipe` and `tapcoord` not supported.
- **tvOS / watchOS**: External app launch not supported (XCUITest limitation). Agent starts and screenshot works, but app control is not possible.

## WebView Apps

WebView-based apps (Safari, Chrome, hybrid apps) need `source` instead of `elements` for interacting with page content. Read **`references/webview.md`** for the full guide, including:

- Decision tree: when to use `tap` vs `tapcoord`
- Reading `source` as a DOM inspector (layout reconstruction from frames)
- Finding and tapping WebView element coordinates
- Overlay dialogs (sign-in prompts, cookie banners) — why visual coordinates are wrong
- Floating UI interference zones (toolbar, tab bar, sticky headers)
- Duplicate labels, swipe targeting, ads and modals

## Physical Device Limitations

- **System dialogs are untappable**: OS-level permission dialogs (location, notifications, tracking, etc.) are owned by SpringBoard, not the app. `simpilot tap` and `simpilot tapcoord` cannot reach them. The user must dismiss these manually.
- **`type '\n'` does not press Enter**: It types the literal characters `\n`. To submit a search, tap the search suggestion from `elements --level 1` or tap the keyboard's submit button by coordinate.

## Troubleshooting

- **Agent not running**: Run `simpilot health`. If unreachable, run `simpilot start`.
- **Slow taps (>10s)**: You're using `#identifier` queries. Switch to bare label queries.
- **Element not found**: Use `simpilot elements --level 1` to see available elements and their query strings.
- **App not responding**: Try `simpilot terminate <bundleId>` then `simpilot launch <bundleId>`.
- **Want to open an app?**: Use `simpilot launch <bundleId>`, not home screen icon tapping.
- **visionOS tap slow (~20s)**: Expected. Coordinate tap falls back to XCUITest native resolution on visionOS.
- **Physical device unreachable after USB reconnect**: Run `simpilot stop --all` then `simpilot start --device '<name>'` to re-register with the correct hostname.
- **WebView tap hits wrong element**: See `references/webview.md` — use `source` for coordinates, never estimate from screenshots.
