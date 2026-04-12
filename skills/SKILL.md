---
name: simpilot — Simulator & Device UI Automation
description: >
  Use this skill when the user mentions "simpilot", "simpilotで", "simpilotを使って",
  or wants to control iOS Simulator / physical device UI programmatically.
  Also trigger when the user says "シミュレータを操作", "シミュレータのアプリを操作",
  "Simulatorのアプリ", "Simulator上で", "Vision Proのシミュレータ", "visionOSシミュレータ",
  "実機を操作", "実機で", "実機のアプリ", "iPhoneを操作", "iPadを操作",
  "シミュレータでアプリを動かして", "シミュレータで検索して",
  "automate the simulator", "control the iOS app", "interact with the device",
  "run UI automation", "test the app on simulator", "tap on the simulator",
  "take a screenshot of the simulator", "navigate the app", or similar phrases
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

## Critical Rules

1. **ALWAYS use bare label queries** — `simpilot tap 'General'` not `simpilot tap '#com.apple.settings.general'`. Bare labels resolve in <1s; identifier queries can take 24+ seconds on complex apps.
2. **Start with `--level 0`** to understand the screen (~50 tokens), then `--level 1` for actionable elements (~500 tokens). Never start with full tree.
3. **Never guess queries — always verify with `elements --level 1` first.** Common labels like "Search", "Settings", "Done" often match multiple elements (e.g., a "Search" settings row vs a search text field). The bare query matches the first one found, which may not be the intended target. Always check the `type` field to confirm you're targeting the right element. Use typed queries (`textField:Search` vs `button:Search`) to disambiguate.
4. **Use `batch` for multi-step flows** — one HTTP round-trip instead of many.
5. **Use `action` for tap→screenshot→elements** — the most common workflow in one command.
6. **`tap` and `tapcoord` are different commands** — `tap` takes a label/query string; `tapcoord` takes x y coordinates. Never pass `--x`/`--y` flags to `tap`.
7. **Use `scroll-to` instead of manual swipe loops** — `scroll-to 'Privacy' --direction down` replaces the swipe→elements→check pattern in a single command.
8. **For WebView elements, always use `source` to get coordinates** — never estimate coordinates from screenshots. Visual position and actual frame coordinates can differ by hundreds of points. See `references/webview.md` for details.
9. **WebView elements require `tapcoord`, not `tap`** — label queries (`tap 'Show more'`) do not work on WebView content. Use `source` to find coordinates, then `tapcoord <x> <y>`.
10. **Never retry a failed approach more than once** — if an action fails, stop and analyze why. Switch to an alternative approach (different query, different command, different UI path). Repeating the same failing action wastes time and tokens.
11. **Clearing search fields** — if the ⊗ clear button doesn't respond to tap/tapcoord, switch approach: exit the search mode entirely (tap Cancel or navigate away) and re-enter it, or select all text first (`longpress` on the field → tap 'Select All') then type the new text to overwrite.
12. **Safari toolbar hides on scroll** — scrolling down in Safari hides the toolbar (back button, URL bar). Swipe up slightly to reveal it. Don't waste time searching for the back button in `elements` when the toolbar is hidden.

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

# 6. Element not found? Scroll to find it first
simpilot scroll-to 'Show more' --direction down
simpilot tap 'Show more'
```

**If `element_not_found`**: the element is likely off-screen. Use `scroll-to` before retrying the tap — don't give up or try a different query immediately.

## Observation Strategy

Choosing the right observation tool reduces token cost and speeds up automation.

| Situation | Tool | Cost |
|---|---|---|
| Native app — find what to tap | `elements --level 1` | ~500 tokens |
| Native app — find specific elements | `elements --level 1 --type button --contains Login` | ~50-100 tokens |
| Native app — screen overview | `elements --level 0` | ~50 tokens |
| WebView — find text/links/coordinates | `source` + grep | ~varies |
| Visual layout, carousel, unfamiliar screen | `screenshot --format jpeg --file` + Read | ~image tokens (3-5x fewer than PNG) |
| Evidence capture for testing | `screenshot --file` (save only, don't read) | ~0 tokens |
| Element-specific capture | `screenshot --element 'query' --file` | ~0 tokens (save) |

**Key principles:**
- **Native apps** → `elements` is almost always sufficient. Skip screenshots.
- **WebView apps** → `source` is the primary tool. It gives you both content and coordinates, like a DOM inspector. See `references/webview.md` for the full workflow.
- **Browser navigation (Safari, Chrome, etc.)** → Read the address bar via `elements` to confirm which page you're on — don't take a screenshot just to check the current URL. Only screenshot when you need to see the visual content. **Navigate through the UI naturally** (back button, links, swipe back) — never type URLs directly into the address bar.
- **Screenshots** → useful for horizontal scroll / carousel UIs (source can't tell what's currently visible), visual layout understanding (grids, maps, overlapping elements), and showing results to the user.
- **Token-conscious capture**: `screenshot --file /tmp/s.png` saves to disk cheaply. Reading the image into context is what costs tokens. Capture liberally for evidence, but only read when visual analysis is actually needed for the next decision.
- **Screenshot resolution**: Default `--scale 1` returns a 1x point-sized PNG (~1/3 long edge of native, ~70% smaller than full resolution) — ideal for AI analysis. Use `--scale 2` for @2x, or `--scale native` for design work needing the device's full pixel resolution.
- **JPEG for smaller screenshots**: `--format jpeg --quality 80` produces files 3-5x smaller than PNG, significantly reducing base64 token cost when sending screenshots to AI models. Use for general observation; keep PNG for pixel-precise comparison.
- **Filter elements to reduce tokens**: `--type button,switch` and `--contains Settings` narrow `--level 1` output to only relevant elements, cutting token consumption on busy screens.

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

### Scroll to find off-screen elements

Instead of manually looping swipe + elements, use `scroll-to` which searches in a single command:

```bash
# Slow: manual scroll loop
simpilot swipe down
simpilot elements --level 1 --contains Privacy   # not found...
simpilot swipe down
simpilot elements --level 1 --contains Privacy   # found!

# Fast: scroll-to does it in one call
simpilot scroll-to 'Privacy' --direction down --max-swipes 10
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

simpilot longpress '<query>' [--duration <s>]     # Long-press (default 0.8s)
simpilot doubletap '<query>'                     # Double-tap

simpilot type '<text>' [--into '<query>']         # Type text (keyboard input)
simpilot type '<text>' --method paste             # Paste via clipboard (use only when keyboard is unavailable)
simpilot swipe <up|down|left|right> [--on '<query>']  # Swipe
simpilot scroll-to '<query>' [--direction down] [--max-swipes 10]  # Scroll until element found

# Drag (element-to-element, element-to-coordinate, or coordinate-to-coordinate)
simpilot drag '<query>' --to '<target>'            # Element to element (list reorder, drag-and-drop)
simpilot drag '<query>' --to-x <x> --to-y <y>     # Element to coordinate (slider adjustment)
simpilot drag --from-x <x> --from-y <y> --to-x <x> --to-y <y>  # Coordinate to coordinate
# --duration <s> (default 0.5) controls press-and-hold time before dragging

# Pinch to zoom
simpilot pinch '<query>' --scale 2.0               # Zoom in (scale > 1)
simpilot pinch '<query>' --scale 0.5               # Zoom out (scale < 1)
simpilot pinch --scale 2.0                         # Pinch on entire app
# --velocity slow|default|fast
simpilot wait '<query>' [--timeout 10] [--gone]  # Wait for element
simpilot slider [<query>] --value <0.0-1.0>      # Adjust slider (0=min, 1=max)
simpilot slider 'slider:Volume' --value 0.5      # Named slider to 50%
simpilot slider --value 0                        # First slider to min
simpilot clipboard get                           # Read clipboard contents
simpilot clipboard set '<text>'                  # Write text to clipboard
```

### Observation

```bash
# Screenshot
simpilot screenshot [--file /tmp/s.png] [--scale <N|native>]  # PNG (default scale=1 for AI)
simpilot screenshot --format jpeg --quality 80 --file /tmp/s.jpg  # JPEG (3-5x smaller)
simpilot screenshot --element 'button:Login' --file /tmp/btn.png  # Element-only screenshot
simpilot screenshot --element '#myView' --format jpeg --file /tmp/view.jpg  # Element + JPEG

# Elements
simpilot elements [--level 0|1|2|3]                           # UI elements (see levels below)
simpilot elements --level 1 --type button,switch              # Filter by type (comma-separated)
simpilot elements --level 1 --contains Settings               # Filter by label (case-insensitive)
simpilot elements --level 1 --type button --contains Login    # Combined (AND condition)

simpilot source                           # Raw Xcode UI hierarchy (essential for WebView)
simpilot info                             # Device and agent info
```

### Compound Commands

Note: `--settle` is `action`-only — `screenshot` does not accept it. Use `action` if you need settle + screenshot in one call.

```bash
# Execute action + wait + screenshot + elements in one call
simpilot action tap '<query>' --screenshot /tmp/s.png --level 1 --settle 1
# Add --scale native if you need full-resolution output instead of the 1x default
simpilot action tap '<query>' --screenshot /tmp/s.png --scale native
# JPEG screenshot of a specific element after action
simpilot action tap 'About' --screenshot /tmp/s.jpg --element 'nav:Settings' --format jpeg --quality 80

# Execute multiple commands in one HTTP round-trip
simpilot batch '{"commands":[
  {"method":"POST","path":"/tap","body":{"query":"General"}},
  {"method":"GET","path":"/screenshot","params":{"file":"/tmp/s.png"}},
  {"method":"GET","path":"/elements","params":{"level":"0"}}
]}'
```

### Device & System

```bash
simpilot rotate landscape-left                   # portrait|landscape-left|landscape-right|portrait-upside-down
simpilot openurl 'myapp://deep/link'             # Open URL/deep link (simulator only)
simpilot alert accept [--timeout 5]              # Accept system permission alert
simpilot alert dismiss                           # Dismiss system permission alert
```

### Agent Lifecycle

```bash
simpilot start [--device '<name>' | --udid <UDID>]  # Build & start agent on simulator or device
simpilot stop --port 8223                           # Stop a specific agent by port
simpilot stop --udid <UDID>                         # Stop a specific agent by device UDID
simpilot stop --all                                 # Stop all agents + delete cloned/created devices
simpilot health                                     # Check if agent is running
simpilot list                                       # Show all running agents with status
```

**Default device resolution**: `simpilot start` picks in order, reported via
`data.resolved_via`: (1) `--udid <UDID>` — `explicit_udid`, simulator-only;
(2) `--device '<name>'` — `explicit_device`; (3) `SIMPILOT_DEFAULT_DEVICE`
env var — `env`; (4) first booted simulator — `booted`; (5) hardcoded
`iPhone 17 Pro` — `fallback`. Whenever the chain produces a concrete UDID,
xcodebuild is launched with `-destination id=<UDID>` so duplicate-named
simulators can't be confused.

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

### Scenario Runner

```bash
# Run YAML scenario files with assertions and reporting
simpilot run <file.yml> [--json] [--var <key=val,...>] [--timeout <s>] [--screenshot-dir <path>]
simpilot run test.yml                              # Terminal output with pass/fail
simpilot run test.yml --json                       # JSON output for automation
simpilot run test.yml --var "app=com.example.App"  # Override YAML variables
```

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
| `secureTextField:Pass` | Search secure text fields | Medium (~2s) |
| `switch:Dark Mode` | Search switches | Medium (~2s) |
| `link:Learn more` | Search links | Medium (~2s) |
| `icon:Logo` | Search icons | Fast (~1-2s) |
| `toggle:Dark Mode` | Search toggles (alias for switch:) | Fast (~1-2s) |
| `slider:Volume` | Search sliders | Fast (~1-2s) |
| `stepper:Quantity` | Search steppers | Fast (~1-2s) |
| `picker:Country` | Search pickers | Fast (~1-2s) |
| `segmentedControl:Tab` | Search segmented controls | Fast (~1-2s) |
| `menu:File` | Search menus | Fast (~1-2s) |
| `menuItem:Copy` | Search menu items | Fast (~1-2s) |
| `scrollView:Content` | Search scroll views | Fast (~1-2s) |
| `webView:Browser` | Search web views | Fast (~1-2s) |
| `datePicker:Birthday` | Search date pickers | Fast (~1-2s) |
| `textView:Notes` | Search text views | Fast (~1-2s) |
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
| tap / longpress / doubletap | OK (~1s) | OK (~20s) | NG |
| type | OK | OK | NG |
| clipboard | OK | OK | NG |
| swipe | OK | NG | tvOS only (remote) |
| scroll-to | OK | NG | NG |
| drag | OK | OK (spatial exceptions possible) | NG |
| pinch | OK | OK (spatial exceptions possible) | NG |
| slider | OK | OK | NG |
| run (scenario) | OK | OK | NG |
| rotate | OK | NG | NG |
| openurl | OK (simulator only) | NG | NG |
| alert | OK | OK | NG |
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
- **simpilot not found**: The CLI is not installed. Ask the user to run `make install` in the simpilot repo.
