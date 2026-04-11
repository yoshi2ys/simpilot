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
  -quiet
```

## Run Agent

```bash
# Simulator (iOS)
simpilot start                                    # default: iPhone 17 Pro
simpilot start --device 'iPhone Air'              # specify device

# Simulator (visionOS)
simpilot start --device 'Apple Vision Pro'        # auto-detects visionOS platform

# Physical device (auto-detected if not found in simulators)
simpilot start --device 'My iPhone'               # auto-detects via devicectl

# Parallel testing (simulator only)
simpilot start --device 'iPhone Air' --clone 2    # clone device state (source must be Shutdown)
simpilot start --create 2                         # create fresh clean devices
simpilot list                                     # show all running agents
simpilot stop --port 8223                         # stop specific agent
simpilot stop --all                               # stop all + delete cloned/created devices
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
- **IPv6 URL bracketing**: Physical devices often return IPv6 addresses (e.g. `fd4d:85e2:eeb::1`). `HTTPClient.init(host:port:)` wraps IPv6 addresses in brackets per RFC 3986 (`http://[addr]:port`). Without this, `URL(string:)` fails because the port suffix is ambiguous with the IPv6 colon notation.
- **Screenshot downscaling** (ScreenshotScaler in ScreenshotHandler.swift): `XCUIScreen.main.screenshot()` always returns native-resolution pixels (1206×2622 on iPhone @3x). Default `--scale 1` downsamples via ImageIO `CGImageSourceCreateThumbnailAtIndex` so the long edge matches 1x points (~1/3 size, ~72% byte reduction), cutting LLM token budgets. `--scale native` skips the scaler entirely for design use. `--scale N` where the target long edge is ≥ source pixel long edge short-circuits and returns the original data.

## Project Structure

```
agent/
  AgentApp/               # Minimal host app (required by XCUITest)
  AgentUITests/
    AgentUITests.swift    # Test entry point (runs HTTP server forever)
    Server/               # NWListener HTTP server + router
    Handlers/             # One file per endpoint (tap, elements, etc.)
    Core/                 # DebugDescriptionParser, ElementResolver, AppManager
cli/
  Sources/simpilot/
    main.swift            # Entry point + arg parsing
    HTTPClient.swift      # URLSession wrapper
    AgentRegistry.swift   # ~/.simpilot/agents.json state management
    SimctlHelper.swift    # xcrun simctl wrapper (clone/create/boot/delete)
    DeviceHelper.swift    # xcrun devicectl wrapper (physical device discovery)
    Commands/             # One file per CLI command
```
