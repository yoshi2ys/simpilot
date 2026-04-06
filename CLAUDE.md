# simpilot

AI agent CLI tool for controlling iOS Simulator apps via XCUITest.

## Architecture

```
CLI (cli/)  --HTTP:8222-->  XCUITest Agent (agent/)  --XCUIApplication-->  Simulator
```

- **Agent**: Xcode UI test target hosting an HTTP server (Network.framework NWListener). Runs as `xcodebuild test`.
- **CLI**: Swift Package executable. Sends HTTP requests, outputs JSON.
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

## Run Agent

```bash
# iOS
simpilot start                                    # default: iPhone 17 Pro
simpilot start --device 'iPhone Air'              # specify device

# visionOS
simpilot start --device 'Apple Vision Pro'        # auto-detects visionOS platform

# Parallel testing
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
    Commands/             # One file per CLI command
```
