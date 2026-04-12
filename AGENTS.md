# simpilot

AI agent CLI tool for controlling iOS Simulator and physical device apps via XCUITest.

## Architecture

```
CLI (cli/)  --HTTP:8222-->  XCUITest Agent (agent/)  --XCUIApplication-->  Simulator / Device
```

- **Agent**: Xcode UI test target hosting an HTTP server (Network.framework NWListener). Runs as `xcodebuild test`.
- **CLI**: Swift Package executable. Sends HTTP requests, outputs JSON.
- **Simulator**: CLI connects to `localhost:<port>`. Port communicated via port file (`/tmp/simpilot-port-<UDID>`).
- **Physical device**: CLI discovers devices via `xcrun devicectl` and connects using the `.coredevice.local` hostname.
- No external dependencies. Pure Swift + system frameworks.

## Build

```bash
cd cli && swift build                    # CLI
cd agent && xcodebuild build-for-testing \
  -project AgentApp.xcodeproj \
  -scheme AgentUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet       # iOS Agent
cd agent && xcodebuild build-for-testing \
  -project AgentApp.xcodeproj \
  -scheme AgentUITests \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -quiet  # visionOS Agent
```

## Run Unit Tests

```bash
# Core logic tests (no simulator UI driving). Do NOT run the whole
# AgentUITests target — AgentUITests/testAgent is the long-running HTTP
# server entry point used by `simpilot start` and never returns.
cd agent && xcodebuild test \
  -project AgentApp.xcodeproj \
  -scheme AgentUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:AgentUITests/StablePredicateTests \
  -only-testing:AgentUITests/PredicateEvaluatorTests \
  -only-testing:AgentUITests/DebugDescriptionParserTests \
  -only-testing:AgentUITests/ActionHandlerTests \
  -quiet
```

## Run Agent

```bash
# Simulator (iOS)
# Priority: --udid > --device > SIMPILOT_DEFAULT_DEVICE env > first booted sim > iPhone 17 Pro
# Envelope reports via data.resolved_via: explicit_udid | explicit_device | env | booted | fallback
simpilot start                                    # chain default
simpilot start --device 'iPhone Air'              # specify device by name
simpilot start --udid <UDID>                      # specify simulator by UDID (from `simpilot list`)
SIMPILOT_DEFAULT_DEVICE='iPhone Air' simpilot start  # env default

# Simulator (visionOS)
simpilot start --device 'Apple Vision Pro'        # auto-detects visionOS platform

# Physical device (auto-detected if not found in simulators)
simpilot start --device 'My iPhone'               # auto-detects via devicectl

# Parallel testing (simulator only)
simpilot start --device 'iPhone Air' --clone 2    # clone device state (source must be Shutdown)
simpilot start --create 2                         # create fresh clean devices
simpilot list                                     # show all running agents
simpilot stop --port 8223                         # stop specific agent by port
simpilot stop --udid <UDID>                       # stop specific agent by device UDID
simpilot stop --all                               # stop all + delete cloned/created devices
# Note: `simpilot stop` with no target exits 3 — one of --port/--udid/--all is required.

# Element screenshot
simpilot screenshot --element 'button:Login' --scale native --file /tmp/btn.png
simpilot action tap 'About' --screenshot /tmp/s.png --element 'nav:Settings'

# JPEG format (smaller output for AI agents)
simpilot screenshot --format jpeg --quality 80 --file /tmp/s.jpg

# Elements filtering
simpilot elements --level 1 --type button,switch --contains Settings

# Scroll to find
simpilot scroll-to 'Privacy' --direction down --max-swipes 10

# Drag (reorder, slider, drag-and-drop)
simpilot drag 'item-1' --to 'item-3'              # element to element
simpilot drag 'slider:Volume' --to-x 200 --to-y 400  # element to coordinate

# Pinch (zoom)
simpilot pinch 'map' --scale 2.0                   # zoom in
simpilot pinch 'photo' --scale 0.5 --velocity slow # zoom out

# Slider (precise value)
simpilot slider 'slider:Volume' --value 0.5        # set to 50%
simpilot slider --value 0                          # first slider → min

# Run YAML scenario
simpilot run examples/settings_about.yml           # terminal output
simpilot run test.yml --json                       # JSON output
simpilot run test.yml --var "app=com.example.App"  # override variables
```

## Key Design Decisions

- **debugDescription parser** (DebugDescriptionParser.swift): Elements are read by parsing `XCUIApplication.debugDescription` text (1 IPC call, ~0.2s) instead of walking the tree with `children(matching:)` (N IPC calls, 5-16s).
- **Coordinate-based tapping**: TapHandler resolves elements via debugDescription then taps by coordinate, bypassing XCUITest's slow element resolution.
- **ObjC exception catching**: XCUITest APIs throw NSException (not Swift errors). Caught via ObjC bridging at two levels: Router.safeExecute (per-handler) and RunLoop protection (async exceptions).
- **Bare label queries**: `simpilot tap 'General'` is ~30x faster than `simpilot tap '#identifier'` because XCUITest optimizes label-based predicate matching.
- **Port file for multi-agent**: `xcodebuild` does not propagate environment variables to XCUITest runners. Port is passed via `/tmp/simpilot-port-<UDID>`, read by the agent using `SIMULATOR_UDID`.
- **`simctl create` over `simctl clone`**: `--create` uses `simctl create` (works on Booted devices). `--clone` uses `simctl clone` (requires Shutdown source, but preserves device state).
- **devicectl for physical devices**: On physical devices, the XCUITest agent runs on the device (not Mac). CLI discovers devices via `xcrun devicectl list devices` and connects using the `.coredevice.local` hostname. Works over USB and Wi-Fi.
- **Device auto-detection**: `simpilot start --device '<name>'` tries SimctlHelper (simulators) first, then DeviceHelper (physical devices via `xcrun devicectl`). Simulator is prioritized to preserve existing behavior.
- **Default device priority chain** (StartCommand.resolveStart): `--udid` > `--device` > `SIMPILOT_DEFAULT_DEVICE` env > first booted sim > `iPhone 17 Pro`. The envelope's `data.resolved_via` always reports which slot fired (`explicit_udid` / `explicit_device` / `env` / `booted` / `fallback`) — silent fallback is forbidden. `--udid` is simulator-only (physical UDIDs are rejected; use `--device '<name>'`).
- **xcodebuild destination by UDID when known** (StartCommand.launchTarget): whenever a concrete simulator UDID is known (from `--udid`, `booted`, or name lookup), xcodebuild is launched with `-destination id=<UDID>` so duplicate-named simulators stay disambiguated. Only the `.unknown` fallback uses `name=<name>`.
- **IPv6 URL bracketing**: Physical devices often return IPv6 addresses (e.g. `fd4d:85e2:eeb::1`). `HTTPClient.init(host:port:)` wraps IPv6 addresses in brackets per RFC 3986 (`http://[addr]:port`). Without this, `URL(string:)` fails because the port suffix is ambiguous with the IPv6 colon notation.
- **Screenshot downscaling** (ScreenshotScaler in ScreenshotHandler.swift): `XCUIScreen.main.screenshot()` always returns native-resolution pixels (1206×2622 on iPhone @3x). Default `--scale 1` downsamples via ImageIO `CGImageSourceCreateThumbnailAtIndex` so the long edge matches 1x points (~1/3 size, ~72% byte reduction), cutting LLM token budgets. `--scale native` skips the scaler entirely for design use. `--scale N` where the target long edge is ≥ source pixel long edge short-circuits and returns the original data.
- **Element screenshots** (ScreenshotHandler.swift): `GET /screenshot?element=<query>` resolves via `ElementResolver.resolve()` then calls `XCUIElement.screenshot()`. Wrapped in `catchObjCException` for NSException safety (detached/offscreen elements). `ScreenshotScaler` applies to both full-screen and element screenshots unchanged. Error codes: `element_not_found` (resolver fail) vs `screenshot_failed` (ObjC exception).
- **JPEG output** (ScreenshotConverter in ScreenshotHandler.swift): `--format jpeg` converts PNG→JPEG via `CGImageDestinationCreateWithData` + `kCGImageDestinationLossyCompressionQuality`. Default quality 80. Reduces base64 token consumption for AI agents.
- **Elements filtering**: `GET /elements?level=1&type=button,switch&contains=Settings` applies server-side AND filtering on actionable elements. `type` matches element type, `contains` matches label substring (case-insensitive).
- **scroll-to-find** (ScrollToHandler.swift): `POST /scroll-to` loops: `DebugDescriptionParser.findElement` (fast path) → swipe → settle → repeat. `max_swipes` caps iterations (default 10, must be >0). Checks before first swipe so already-visible elements return `swipes: 0`.
- **Extended query prefixes**: 12 additional typed query prefixes (`icon`, `toggle`, `slider`, `stepper`, `picker`, `segmentedControl`, `menu`, `menuItem`, `scrollView`, `webView`, `datePicker`, `textView`) for direct element resolution. `toggle` maps to `app.toggles` (distinct from `switch` which maps to `app.switches`).
- **Drag gesture** (DragHandler.swift): `press(forDuration:thenDragTo:)` supports element-to-element, element-to-coordinate, and coordinate-to-coordinate modes. Mutual exclusivity validation prevents silent misrouting.
- **Pinch gesture** (PinchHandler.swift): `pinch(withScale:velocity:)` for zoom in/out. `scale > 1` = zoom in, `scale < 1` = zoom out.
- **Slider adjustment** (SliderHandler.swift): `adjust(toNormalizedSliderPosition:)` for precise slider control. `--value 0.0` = min, `--value 1.0` = max. No query = first slider in view.
- **Typed query type filtering** (DebugDescriptionParser.matchesQuery): typed queries (`searchField:`, `button:`, etc.) now verify element type, not just label/identifier. Previously `searchField:Search` could match a button labeled "Search". Unknown prefixes return no match (fall through to ElementResolver).
- **SwiftUI Toggle tap offset** (TapHandler.swift): SwiftUI Toggle exposes the entire row (label + toggle) as one accessibility element. Coordinate taps offset to the trailing edge where the actual switch control sits, since center-tapping hits the label area which doesn't toggle.
- **YAML scenario runner** (cli/Sources/simpilot/Scenario/): `simpilot run <file.yml>` executes YAML scenarios with step-by-step assertions, auto-wait, screenshot-on-failure, and variable substitution. Steps map 1:1 to existing HTTP endpoints. Custom minimal YAML parser (no external dependencies). Terminal and JSON (`--json`) output modes.

## Project Structure

```
agent/
  AgentApp/               # Minimal host app (required by XCUITest)
  AgentUITests/
    AgentUITests.swift    # Test entry point (runs HTTP server forever)
    Server/               # NWListener HTTP server + router
    Handlers/             # One file per endpoint (tap, elements, scroll-to, etc.)
    Core/                 # DebugDescriptionParser, ElementResolver, AppManager
cli/
  Sources/simpilot/
    main.swift            # Entry point + arg parsing
    HTTPClient.swift      # URLSession wrapper
    AgentRegistry.swift   # ~/.simpilot/agents.json state management
    SimctlHelper.swift    # xcrun simctl wrapper (clone/create/boot/delete)
    DeviceHelper.swift    # xcrun devicectl wrapper (physical device discovery)
    Commands/             # One file per CLI command (ScrollToCommand, etc.)
    Scenario/             # YAML scenario runner (YAMLParser, ScenarioRunner, etc.)
examples/                 # Sample YAML scenario files for `simpilot run`
```
