# simpilot

CLI tool for controlling apps on Simulator and physical devices via XCUITest. Supports iOS, iPadOS, and visionOS. JSON output optimized for AI agents.

```
CLI (simpilot)  --HTTP-->  XCUITest Agent  --XCUIApplication-->  Simulator / Device
```

## Quick Start

```bash
# Build & install
make install        # requires sudo for /usr/local/bin

# Start the agent — picks: --udid > --device > SIMPILOT_DEFAULT_DEVICE env > first booted sim > iPhone 17 Pro
simpilot start                                # chain default
simpilot start --device 'Apple Vision Pro'    # visionOS
simpilot start --udid <UDID>                  # reconnect to a specific simulator (from `simpilot list`)
SIMPILOT_DEFAULT_DEVICE='iPhone Air' simpilot start  # env default

# Use it
simpilot launch com.apple.Preferences
simpilot elements --level 1
simpilot tap 'General'
simpilot tap 'About'
simpilot screenshot --file /tmp/screen.png

# Stop (requires an explicit target — no default)
simpilot stop --all
```

## Requirements

- macOS with Xcode 26+
- Simulator runtime (iOS or visionOS) or a connected physical device

### Physical Device Setup

1. Connect your device via USB or enable Wi-Fi connectivity in Xcode
2. Open `agent/AgentApp.xcodeproj` in Xcode
3. Select the `AgentUITests` scheme → set your Team in Signing & Capabilities
4. Trust the developer certificate on the device (Settings → General → Device Management)

```bash
simpilot start --device 'My iPhone'     # auto-detects physical device
```

The agent is discovered via `devicectl` hostname — no additional network configuration needed.

## Commands

### Agent Lifecycle

```bash
simpilot start [--device '<name>' | --udid <UDID>]  # Build & start agent on simulator or device
simpilot stop --port 8223                           # Stop a specific agent by port
simpilot stop --udid <UDID>                         # Stop a specific agent by device UDID
simpilot stop --all                                 # Stop all agents + delete cloned/created devices
simpilot health                                     # Check if agent is running
simpilot list                                       # Show all running agents with status
```

#### Default device resolution

`simpilot start` resolves the target device in this order, and reports which
slot fired via `data.resolved_via` in the JSON envelope:

1. `--udid <UDID>` (`resolved_via: "explicit_udid"`) — simulator-only;
   physical-device UDIDs are rejected (use `--device '<name>'` for those)
2. `--device '<name>'` (`resolved_via: "explicit_device"`)
3. `SIMPILOT_DEFAULT_DEVICE` env var (`resolved_via: "env"`)
4. First `Booted` simulator in `simctl list` (`resolved_via: "booted"`)
5. Hardcoded `iPhone 17 Pro` fallback (`resolved_via: "fallback"`)

Combining `--udid` with `--clone`/`--create` is allowed — simpilot
reverse-looks up the source name internally. When the chain produces a
concrete UDID (`--udid` or `booted` slots), xcodebuild is launched with
`-destination id=<UDID>` so duplicate-named simulators can't be confused.

### Parallel Testing

```bash
# Clone device state (source must be Shutdown)
simpilot start --device 'iPhone Air' --clone       # 1 clone
simpilot start --device 'iPhone Air' --clone 3     # 3 clones

# Create fresh clean device (works regardless of source state)
simpilot start --create                            # 1 new device
simpilot start --device 'iPhone Air' --create 2    # 2 new devices

# Target specific agents by port
simpilot tap 'General' --port 8223
simpilot tap 'General' --port 8224

# See all running agents
simpilot list
```

Each agent gets an auto-assigned port (8222, 8223, ...). Cloned/created devices are automatically deleted when stopped.

### App Lifecycle

```bash
simpilot launch <bundleId>            # Launch an app
simpilot activate <bundleId>          # Bring to foreground (no relaunch)
simpilot terminate <bundleId>         # Terminate an app
```

### Interaction

```bash
simpilot tap '<query>'                              # Tap an element
simpilot type '<text>' [--into '<query>']            # Type text
simpilot type '<text>' --method paste                # Paste text (no keyboard needed)
simpilot swipe <up|down|left|right> [--on '<query>'] # Swipe
simpilot tapcoord <x> <y>                           # Tap at coordinates
simpilot wait '<query>' [--timeout 10] [--gone]     # Wait for element
simpilot slider [<query>] --value <0.0-1.0>         # Adjust slider position
simpilot clipboard get                              # Read clipboard contents
simpilot clipboard set '<text>'                     # Write text to clipboard
```

### Observation

```bash
simpilot screenshot [--file /tmp/s.png]   # Screenshot (file or base64)
simpilot elements [--level 0|1|2|3]       # UI element tree
simpilot source                           # Raw Xcode UI hierarchy
simpilot info                             # Device and agent info
simpilot help                             # Full command catalog (JSON)
```

### Scenario Runner

```bash
simpilot run <file.yml> [--json] [--var <key=val,...>] [--timeout <s>]
simpilot run examples/settings_about.yml             # terminal output
simpilot run test.yml --json                         # JSON output
simpilot run test.yml --var "app=com.example.App"    # override variables
```

YAML scenarios define steps (tap, type, assert, screenshot, etc.) with assertions, auto-wait, and screenshot-on-failure. See `examples/` for sample scenarios.

### Compound

```bash
# Tap + screenshot + elements in one call
simpilot action tap '<query>' --screenshot /tmp/s.png --level 1 --settle 1

# Multiple commands in one HTTP round-trip
simpilot batch '{"commands":[
  {"method":"POST","path":"/tap","body":{"query":"General"}},
  {"method":"GET","path":"/screenshot","params":{"file":"/tmp/s.png"}}
]}'
```

## Element Query Syntax

| Format | Example | Speed |
|---|---|---|
| Bare label | `General` | **Fast** (<1s) |
| Typed | `button:Login`, `textField:Email` | Medium (~2s) |
| Identifier | `#accessibilityId` | Slow (10-24s) |

Always prefer bare label queries. `simpilot elements --level 1` returns the optimal `query` field for each element.

## Elements Levels

| Level | Output | Tokens | Use Case |
|---|---|---|---|
| 0 | Type counts | ~50 | Screen overview |
| 1 | Actionable list | ~500 | Find what to tap |
| 2 | Compact tree | ~2000 | Understand layout |
| 3 | Full tree | ~5000+ | Debug |

## Output Format

```json
{"success": true, "data": {...}, "error": null, "duration_ms": 42}
```

## Architecture

- **Agent** (`agent/`): Xcode UI test target that hosts an HTTP server via `Network.framework`. Runs indefinitely as `xcodebuild test`.
- **CLI** (`cli/`): Swift Package executable. Sends HTTP requests to the agent, outputs JSON.
- No external dependencies. Pure Swift + system frameworks.

### Performance

The agent parses `XCUIApplication.debugDescription` (1 IPC call, ~0.2s) instead of walking the element tree via `children(matching:)` (N IPC calls, 5-16s). Taps use coordinates from the parsed tree, bypassing XCUITest's slow element resolution.

## Platform Support

| Command | iOS | visionOS | tvOS | watchOS |
|---|---|---|---|---|
| start / stop | OK | OK | OK | OK |
| health / info | OK | OK | OK | OK |
| launch / terminate / activate | OK | OK | NG | NG |
| tap | OK (~1s) | OK (~20s) | -- | -- |
| type | OK | OK | -- | -- |
| clipboard | OK | OK | NG | NG |
| swipe | OK | NG | OK (remote) | -- |
| tapcoord | OK | NG | NG (no API) | -- |
| screenshot | OK | OK | OK | OK |
| elements / source | OK | OK | -- | -- |
| slider | OK | OK | -- | -- |
| wait | OK | OK | -- | -- |
| run (scenario) | OK | OK | -- | -- |
| action / batch | OK | OK | -- | -- |

- **visionOS**: Coordinate taps fall back to XCUITest's native element resolution (slower). `swipe` and `tapcoord` not supported.
- **tvOS / watchOS**: External app launch is not supported (XCUITest limitation). `launch` returns an error. Agent can start and take screenshots, but app control is not possible.

## License

MIT
