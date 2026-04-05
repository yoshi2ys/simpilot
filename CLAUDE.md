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
```

## Key Design Decisions

- **debugDescription parser** (DebugDescriptionParser.swift): Elements are read by parsing `XCUIApplication.debugDescription` text (1 IPC call, ~0.2s) instead of walking the tree with `children(matching:)` (N IPC calls, 5-16s).
- **Coordinate-based tapping**: TapHandler resolves elements via debugDescription then taps by coordinate, bypassing XCUITest's slow element resolution.
- **ObjC exception catching**: XCUITest APIs throw NSException (not Swift errors). Caught via ObjC bridging at two levels: Router.safeExecute (per-handler) and RunLoop protection (async exceptions).
- **Bare label queries**: `simpilot tap 'General'` is ~30x faster than `simpilot tap '#identifier'` because XCUITest optimizes label-based predicate matching.

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
    Commands/             # One file per CLI command
```
