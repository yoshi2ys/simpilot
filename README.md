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
simpilot button <home|volume-up|volume-down>        # Press a hardware button (tvOS: remote menu/select/up/...)
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
simpilot elements --format outline        # Compact text (~1/6 the bytes), prints raw text
simpilot source                           # Raw Xcode UI hierarchy
simpilot info                             # Device and agent info
simpilot help                             # Full command catalog (JSON)
```

### Scenario Runner

```bash
simpilot run <file.yaml> [--json] [--var <key=val,...>] [--timeout <s>]
simpilot run examples/settings_about.yaml            # terminal output
simpilot run test.yaml --json                        # JSON output
simpilot run test.yaml --var "app=com.example.App"   # override variables
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

A batch exits `2` if any sub-command fails; `data.results` still lists every one, so you can see which.

```bash
# Reuse one screen read across the batch's read-only steps
simpilot batch '{"ax_cache":"perBatch","commands":[
  {"method":"GET","path":"/elements","params":{"format":"outline"}},
  {"method":"POST","path":"/tap","body":{"query":"@e11"}}
]}'
```

Reading the screen costs one ~0.2s IPC, and by default every command pays it. `ax_cache: "perBatch"`
makes the batch's commands share one read, dropped as soon as a command runs that can change the
screen — so the `tap` above resolves `@e11` against the tree `elements` just fetched, while a
command *after* the tap reads the screen again. On a four-step read-only batch against Settings this
was 4 reads → 1, and 795ms → 208ms.

It is opt-in, and the default stays `none`, because reuse is a bet: simpilot cannot see an animation
finishing or a background update landing between two steps. Every batch reports
`data.ax_cache: {mode, tree_reads, tree_fetches}` — including a `none` run, so the two are directly
comparable — and `ax_cache` values other than `none` / `perBatch` are rejected rather than ignored.

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

`--format outline` renders the level-1 list as text instead of JSON — one line per
element, no frames — at roughly a sixth of the bytes. It renders level 1 only, so
combining it with another `--level` / `--compact` is rejected rather than silently
overridden:

```
# list @l1: 8 cell rows, first row @e3
- navigationBar "Settings" @e1
- cell @e3
- button "General" @e11
- switch "Wi-Fi" @e14 [value=1]
```

A `# list` line appears for every repeating list simpilot detected on the screen —
same type, same width, evenly spaced, three rows or more. Its rows are addressable
positionally (see below); the element lines themselves are unchanged.

The line shape follows agent-browser / Playwright's aria snapshot so it reads the
same way to a model that has seen those, with a cheaper `@e9` ref. This mode prints
**raw text on success**; a failure still prints one JSON envelope and a non-zero exit.

The `@eN` refs are usable as queries:

```bash
simpilot elements --format outline
simpilot tap '@e11'          # taps the element outline listed as @e11
```

Aliases number the unfiltered list, so `--type`/`--contains` show gaps rather than
renumbering. They are re-validated against the live screen on every use: once you
navigate, the same alias fails with `stale_alias` instead of tapping whatever now
sits in that position. Validation compares the recorded element *and its immediate
neighbours*, so a list that merely shifted by a row is caught too; a run of rows
identical to their neighbours (a grid of nameless cells) is the one case that stays
ambiguous. `tap` / `doubletap` / `longpress` / `type` / `action` accept
them; `pinch`, `slider`, `screenshot --element`, `swipe`, `drag`, `scroll-to`,
`assert` and `wait` return `alias_unsupported` with the reason.

### Row selectors: `@rN` / `@lMrN`

`@r3` is the third row of the screen's list, `@l2r3` the third row of its second
list. Unlike an alias, a row selector is re-derived from the live screen on every
use, so it needs no prior `elements` call and survives the taps and scrolls that
invalidate an alias:

```bash
simpilot tap '@r3'           # third row of the only list on screen
simpilot tap '@l2r3'         # third row of the second list
simpilot assert enabled '@r3'
```

What it gives up is identity: it names *whatever now sits* at that position, so it
is the right tool for "act on the Nth row" and the wrong one for "wait for X to
appear". The rules that follow from that:

- Rows are numbered **top to bottom over the rows currently on screen**. A row
  scrolled out of view is not numbered, so every `@rN` names a row whose centre is on
  screen — swipe first to reach rows further down. "On screen" is geometry, not
  reachability: a row behind a sheet or the keyboard is still numbered, the same
  limitation every coordinate tap has (`assert hittable` is the separate check).
- `--depth` narrows what the outline lists, but lists are always detected at the
  full depth `@rN` resolves at, so a narrowed listing drops the header's
  `first row @eN` cross-reference rather than numbering a list `@lM` will not find.
- A bare `@rN` resolves only when the screen has **one** list. With more, it is
  `ambiguous_list` (which reports each list's row count), not a guess — name the
  list with `@lM`.
- Detection is deliberately conservative: a grid, a two-row run, and rows of
  differing height or unevenly spaced are not lists. A screen with none gives
  `list_not_found` — use a label, `#identifier`, or `@eN` there.
- `tap` / `doubletap` / `longpress` / `type` / `action` / `assert` / `wait` take
  row selectors. The commands that need a real element (`pinch`, `slider`,
  `screenshot --element`, `swipe`, `drag`) and `scroll-to` return
  `row_unsupported`.
- `#2` is still "the element whose identifier is `2`" — a row is never addressed
  with `#`, and a typed prefix always wins (`cell:@r3` means the cell labeled
  `@r3`).

## Output Format

```json
{"success": true, "data": {...}, "error": null, "duration_ms": 42}
```

A failure replaces `error` with `{"code": ..., "message": ..., "hint": ...}`.
`message` says what went wrong; `hint` says what to do next, and is present
whenever the repair is the same for every occurrence of that code:

```json
{"success": false, "data": null, "duration_ms": 12, "error": {
  "code": "stale_alias",
  "message": "@e3 now points at a different element; the screen changed",
  "hint": "Run `elements --format outline` again and use an alias from the fresh list."
}}
```

Codes whose repair depends entirely on the message — `invalid_request` above
all, where the message names the field it rejected — carry no `hint` key at all.

## Surface Honesty

simpilot never presents a surface it cannot actually drive. A command that is
unsupported here, that names something the screen no longer has, or that
contradicts itself, fails with a code. It is never accepted and quietly turned
into nothing, and never quietly turned into a *different* action. Three rules
follow from that, and everything below is existing behavior, not aspiration:

- **No silent no-ops.** Buttons with no public XCUITest API — lock/power, shake,
  the Digital Crown — return `invalid_args`, and platforms with no buttons at all
  return `unsupported_platform`. `@eN` aliases resolve to a coordinate, so every
  command that needs a real `XCUIElement` (`pinch`, `slider`,
  `screenshot --element`, `swipe`, `drag`, `scroll-to`, `assert`, `wait`) returns
  `alias_unsupported` **with the reason**, rather than matching `@e9` as a literal
  label and reporting `element_not_found`. An `@rN` row selector is refused the same
  way by the commands that need a real element, under its own `row_unsupported`;
  `assert` and `wait` do take one, because it is re-derived on every observation. On
  tvOS, where there is no coordinate path at all, `tap` and `type` refuse both up
  front.
- **No silent substitution.** Contradictory parameters are rejected, never
  resolved by picking one: `--format outline` with a non-actionable `--level`, or
  `drag` given both a target element and target coordinates, are
  `invalid_request`. A query that matches twice reports `match_count` and keeps
  parse order — it is never re-ranked into whichever match looks better. A stale
  `@eN` fails as `stale_alias` instead of tapping whatever now sits in that
  position, and a bare `@rN` on a screen with two lists is `ambiguous_list` rather
  than the larger one. `simpilot start` always names the slot its device came from in
  `resolved_via`, so falling back to `iPhone 17 Pro` is visible; `simpilot stop`
  with no target exits `3` rather than guessing which agent you meant.
- **No silent success.** A `batch` in which any sub-command failed exits non-zero,
  carrying every sub-result so you can see which. A reply that is not a simpilot
  envelope — a 401 page, a wrong `--port` landing on some other server — is
  `invalid_response` with exit `2`, not the old echo-with-exit-0. A field the
  resolution path genuinely cannot know is `null`, never a plausible default. And
  an agent that starts but cannot be recorded in the registry tears itself back
  down, rather than reporting success as an agent nobody can stop.

The point is what a caller may then assume: **exit 0 means it happened.** You do
not need a screenshot to confirm a tap landed, and a failure always arrives as a
code you can branch on rather than as silence you have to go looking for.

## Architecture

- **Agent** (`agent/`): Xcode UI test target that hosts an HTTP server via `Network.framework`. Runs indefinitely as `xcodebuild test`.
- **CLI** (`cli/`): Swift Package executable. Sends HTTP requests to the agent, outputs JSON.
- No external dependencies. Pure Swift + system frameworks.

### Performance

The agent parses `XCUIApplication.debugDescription` (1 IPC call, ~0.2s) instead of walking the element tree via `children(matching:)` (N IPC calls, 5-16s). Taps use coordinates from the parsed tree, bypassing XCUITest's slow element resolution.

### Security

The agent drives your simulator or device, so it is not safe to expose. Two rules keep it contained:

- **Simulators bind `127.0.0.1` only.** The simulator shares the Mac's network stack, so the agent is unreachable from the LAN.
- **Every network-reachable agent requires a token.** `simpilot start` generates a per-agent secret, hands it to the runner, and sends it in `X-Simpilot-Token` on every request. Requests without it get `401 unauthorized`. Physical devices must bind all interfaces to be reachable over USB/Wi-Fi, and the agent **refuses to start** in that mode without a token.

Tokens live in `~/.simpilot/agents.json` (mode `0600`). The CLI reads them from there, so you never pass one by hand.

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
| button | OK (home; volume device-only) | NG | OK (remote) | NG |
| tapcoord | OK | NG | NG (no API) | -- |
| screenshot | OK | OK | OK | OK |
| elements / source | OK | OK | -- | -- |
| slider | OK | OK | -- | -- |
| wait | OK | OK | -- | -- |
| run (scenario) | OK | OK | -- | -- |
| action / batch | OK | OK | -- | -- |

- **visionOS**: Coordinate taps fall back to XCUITest's native element resolution (slower). `swipe` and `tapcoord` not supported.
- **tvOS / watchOS**: External app launch is not supported (XCUITest limitation). `launch` returns an error. Agent can start and take screenshots, but app control is not possible.
- **button**: iOS presses `home` (Simulator + device) and `volume-up`/`volume-down` (physical device only — the Simulator SDK has no volume API). tvOS presses remote buttons (`menu`, `play-pause`, `select`, `up`/`down`/`left`/`right`, `home`). Names are kebab-case (like `rotate landscape-left`). Buttons with no public XCUITest API — lock/power, shake, Digital Crown — return an error (`invalid_args`, or `unsupported_platform` on visionOS/watchOS) rather than silently doing nothing.

## License

MIT
