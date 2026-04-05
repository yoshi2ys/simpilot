---
name: simpilot — Simulator UI Automation
description: >
  Use this skill ONLY when the user explicitly mentions "simpilot", "iOS Simulator UI",
  "simulator tap", "simulator swipe", "simulator screenshot",
  or uses the phrase "use simpilot" / "simpilotで" / "simpilotを使って".
  Also trigger when the user says "シミュレータを操作", "シミュレータのアプリを操作",
  "Simulatorのアプリ", "Simulator上で", "Vision Proのシミュレータ", or "visionOSシミュレータ".
  Do NOT trigger for generic phrases like "設定アプリを見て", "tap a button",
  "take a screenshot" — these could refer to macOS, real devices, or non-simulator contexts.
  This skill provides programmatic UI control over Simulator apps via XCUITest.
  Supports iOS, iPadOS, and visionOS. tvOS/watchOS have limited support (no external app launch).
---

# simpilot — Simulator UI Automation

Control Simulator apps programmatically from the command line. Built on XCUITest, simpilot lets you tap, type, swipe, take screenshots, and read UI element trees — all via JSON output optimized for AI agents. Supports iOS, iPadOS, and visionOS.

## Setup

```bash
# Build & install (one-time)
cd /Users/yoshi/Developer/simpilot
make install   # builds CLI and installs to /usr/local/bin

# Start the agent
simpilot start                                 # default: iPhone 17 Pro
simpilot start --device 'iPhone Air'           # specify iOS device
simpilot start --device 'iPad Pro 13-inch (M5)' # iPad
simpilot start --device 'Apple Vision Pro'     # visionOS
```

The CLI binary is installed at: `/usr/local/bin/simpilot`

## Critical Performance Rules

1. **ALWAYS use bare label queries** — `simpilot tap 'General'` not `simpilot tap '#com.apple.settings.general'`. Bare labels resolve in <1s; identifier queries can take 24+ seconds on complex apps.
2. **Start with `--level 0`** to understand the screen (~50 tokens), then `--level 1` for actionable elements (~500 tokens). Never start with full tree.
3. **Use `batch` for multi-step flows** — one HTTP round-trip instead of many.
4. **Use `action` for tap→screenshot→elements** — the most common workflow in one command.

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

## Commands Reference

### App Lifecycle

```bash
simpilot launch <bundleId>        # Launch an app
simpilot activate <bundleId>      # Bring to foreground (no relaunch)
simpilot terminate <bundleId>     # Terminate an app
```

### Element Interaction

```bash
simpilot tap '<query>'                           # Tap an element
simpilot type '<text>' [--into '<query>']         # Type text
simpilot swipe <up|down|left|right> [--on '<query>']  # Swipe
simpilot tapcoord <x> <y>                        # Tap coordinates
simpilot wait '<query>' [--timeout 10] [--gone]  # Wait for element
```

### Observation

```bash
simpilot screenshot [--file /tmp/s.png]   # Screenshot (file or base64)
simpilot elements [--level 0|1|2|3]       # UI elements (see levels below)
simpilot source                           # Raw Xcode UI hierarchy
simpilot info                             # Device and agent info
```

### Compound Commands

```bash
# Execute action + wait + screenshot + elements in one call
simpilot action tap '<query>' --screenshot /tmp/s.png --level 1 --settle 1

# Execute multiple commands in one HTTP round-trip
simpilot batch '{"commands":[
  {"method":"POST","path":"/tap","body":{"query":"General"}},
  {"method":"GET","path":"/screenshot","params":{"file":"/tmp/s.png"}},
  {"method":"GET","path":"/elements","params":{"level":"0"}}
]}'
```

### Agent Lifecycle

```bash
simpilot start [--device '<name>']  # Build & start agent on simulator
simpilot stop                       # Stop the running agent
simpilot health                     # Check if agent is running
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
| swipe | OK | NG | tvOS only (remote) |
| screenshot | OK | OK | OK |
| elements / source | OK | OK | NG |
| start / stop / health | OK | OK | OK |

- **visionOS**: Coordinate taps fall back to native element resolution (slower). `swipe` and `tapcoord` not supported.
- **tvOS / watchOS**: External app launch not supported (XCUITest limitation). Agent starts and screenshot works, but app control is not possible.

## Troubleshooting

- **Agent not running**: Run `simpilot health`. If unreachable, run `simpilot start`.
- **Slow taps (>10s)**: You're using `#identifier` queries. Switch to bare label queries.
- **Element not found**: Use `simpilot elements --level 1` to see available elements and their query strings.
- **App not responding**: Try `simpilot terminate <bundleId>` then `simpilot launch <bundleId>`.
- **Want to open an app?**: Use `simpilot launch <bundleId>`, not home screen icon tapping.
- **visionOS tap slow (~20s)**: Expected. Coordinate tap falls back to XCUITest native resolution on visionOS.
