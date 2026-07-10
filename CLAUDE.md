# simpilot

AI agent CLI tool for controlling iOS Simulator and physical device apps via XCUITest.

## Architecture

```
CLI (cli/)  --HTTP:8222-->  XCUITest Agent (agent/)  --XCUIApplication-->  Simulator / Device
```

- **Agent**: Xcode UI test target hosting an HTTP server (Network.framework NWListener). Runs as `xcodebuild test`.
- **CLI**: Swift Package executable. Sends HTTP requests, outputs JSON.
- **Simulator**: agent binds `127.0.0.1:<port>`; CLI connects there. Port/token passed via `TEST_RUNNER_*` env vars.
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
  -only-testing:AgentUITests/BatchHandlerTests \
  -only-testing:AgentUITests/HTTPParserTests \
  -only-testing:AgentUITests/TapHandlerTests \
  -only-testing:AgentUITests/ButtonHandlerTests \
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

# Hardware buttons
simpilot button home                               # iOS: home | volume-up | volume-down (volume = physical device only)
simpilot button menu                               # tvOS remote: menu | play-pause | select | up | down | left | right | home

# Run YAML scenario
simpilot run examples/settings_about.yaml          # terminal output
simpilot run test.yaml --json                      # JSON output
simpilot run test.yaml --var "app=com.example.App" # override variables
```

## Key Design Decisions

- **debugDescription parser** (DebugDescriptionParser.swift): Elements are read by parsing `XCUIApplication.debugDescription` text (1 IPC call, ~0.2s) instead of walking the tree with `children(matching:)` (N IPC calls, 5-16s).
- **Coordinate-based tapping**: TapHandler resolves elements via debugDescription then taps by coordinate, bypassing XCUITest's slow element resolution.
- **ObjC exception catching**: XCUITest APIs throw NSException (not Swift errors). Caught via ObjC bridging at two levels: Router.safeExecute (per-handler) and RunLoop protection (async exceptions).
- **Bare label queries**: `simpilot tap 'General'` is ~30x faster than `simpilot tap '#identifier'` because XCUITest optimizes label-based predicate matching.
- **`TEST_RUNNER_*` env for agent config** (StartCommand.launchXcodebuild → AgentConfig): a plain env var set on the `xcodebuild` process does not reach the XCUITest runner, but `xcodebuild` forwards any `TEST_RUNNER_<NAME>` variable to the runner as `<NAME>` — on simulators and physical devices alike. `simpilot start` passes `TEST_RUNNER_SIMPILOT_{PORT,BIND,TOKEN}`. This replaced the old `/tmp/simpilot-port-<UDID>` file, which only worked because the simulator shares the host's `/tmp` and sat on a predictable, squattable path.
- **Loopback bind + shared token** (AgentConfig / HTTPServer): the agent binds `127.0.0.1` by default (`SIMPILOT_BIND=loopback`), pinned via `NWParameters.requiredLocalEndpoint` so the restriction holds in the kernel — `requiredInterfaceType = .loopback` leaves a wildcard bind and only filters at accept time. Physical devices need `SIMPILOT_BIND=all`, and `AgentConfig.resolve` **refuses to start** an `all`-bound agent without `SIMPILOT_TOKEN` (its memberwise init is private, so no other code can construct that combination). When a token is set, `HTTPServer.isAuthorized` requires it in `X-Simpilot-Token` (constant-time compare) and returns 401 `unauthorized` otherwise. Auth lives at the **socket boundary**, beside the parser's own `.reject` responses — not in `Router`, which would then need `handleDirect` (the `/batch` sub-dispatch path) to be a documented unauthenticated exception. `Router` holds the config only so `/info` can report the resolved port/bind instead of re-reading the environment.
- **PID identity over bare liveness** (ProcessIdentity): `kill(pid, 0) == 0` is unsound because PIDs are recycled. Records store the kernel's process start time (`sysctl KERN_PROC_PID`) and a record is "alive" only when PID *and* start time still match. Records written before this field fall back to an existence check.
- **Registry file lock** (AgentRegistry.withLock): `flock` on `~/.simpilot/registry.lock` (a sidecar, never the atomically-replaced `agents.json`) makes each load→mutate→save cycle exclusive across concurrent `simpilot` processes. `agents.json` is chmod 0600 on every save because it holds agent tokens. Save failures throw rather than being swallowed — a command that reports `success: true` after failing to record its agent leaves it unstoppable. **Reads never write**: `load()` is an unlocked decode + `filter(\.isAlive)`; persisting the prune there would mean swallowing a lock/write failure and printing "no agents" while one is running. The lock cannot span the ~60s `xcodebuild` launch, so two concurrent cold `start`s can still pick the same port — the loser fails loudly when its agent cannot bind.
- **`start` rolls back all three pieces** (StartCommand.rollback): an agent is the `xcodebuild` process, the simulator-side runner it spawned, and (for `--clone`/`--create`) the device. Every failure path — health-check timeout, or a throwing `AgentRegistry.add` on an already-healthy agent — tears down all three. Terminating only the process leaves the runner holding the port with no registry record, and the next `start` silently shifts to port+1.
- **Runner teardown by bundle ID** (SimctlHelper.teardownRunner): the simulator-side `AgentUITests-Runner` owns the listening socket and is parented by `launchd_sim`, so SIGTERMing `xcodebuild` alone leaves the port bound. Terminating it is only half the job: an installed-but-idle runner gets relaunched by `launchd_sim`, and outside `xcodebuild test` there is no `XCTest.framework` on its search path, so each relaunch aborts in dyld (`Library not loaded: @rpath/XCTest.framework/XCTest`) and macOS raises a "quit unexpectedly" dialog. Teardown is therefore `simctl terminate` **then** `simctl uninstall` of `dev.yoshi.simpilot.AgentUITests.xctrunner` — except for `--clone`/`--create` devices, which are deleted outright, taking the runner with them. `start` re-installs the runner every time (it runs plain `xcodebuild test`, not `test-without-building`), so the uninstall is not a cost. `StopCommand.teardownAgent`, `StartCommand.rollback`, and the `stop --all` orphan sweep all route through the one primitive so they cannot drift apart. Scoping by bundle ID is exact where a `pgrep -f` pattern would have to guess.
- **Orphan sweep selects on installed, not running** (SimctlHelper.sweepOrphanRunners): `stop --all` sweeps booted simulators absent from the registry. It picks them with `simctl get_app_container` (exit 0 ⇔ installed) rather than by whether `simctl terminate` found something to kill. A crash-looping runner is dead almost all the time — it aborts in dyld within milliseconds of each relaunch — so selecting on "was running" would skip the exact state the sweep exists to clean. `simctl uninstall` cannot be used as the probe: it exits 0 whether or not the app was there, so it can never report what it removed.
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
- **Hardware buttons** (ButtonHandler.swift): `POST /button` with `{"name": ...}` (camelCase wire name). iOS/iPadOS route to `XCUIDevice.shared.press(_:)` (`home`, plus `volumeUp`/`volumeDown` on physical devices only — the volume cases are `@available`-unavailable in the Simulator SDK and gated with `#if !targetEnvironment(simulator)`); tvOS routes to `XCUIRemote.shared.press(_:)` (`menu`/`playPause`/`select`/arrows/`home`). Platform-specific bits live only in `invocation(for:)`; the error/success envelope is shared. The CLI (`ButtonCommand`) takes kebab-case (`volume-up`) like `rotate`, normalizes to the camelCase wire name, and forwards it — the agent owns per-platform validation, returning `invalid_args` for an unknown name on a button-capable platform and `unsupported_platform` where no buttons exist (visionOS/watchOS). Buttons with no public XCUITest API (lock/power, shake, Digital Crown) are never silent no-ops.
- **One element schema** (ElementResolver.elementDict): every response that embeds an element goes through one builder. Keys `type/label/identifier/value/frame/enabled/selected/hittable` are **always present**; a field the resolution path cannot know is `null` rather than a fabricated default. Two consequences: `value` is always string-or-null (`XCUIElement.value` is `Any?` — `NSNumber` for sliders — so it is stringified; the wire type must not depend on the element kind), and the debugDescription fast path reports `selected: null` while `ElementResolver.describe` reports `hittable: null` (computing it costs a ~50–750ms accessibility snapshot).
- **Ambiguous queries are reported, never re-ranked** (DebugDescriptionParser.findElement): a bare label routinely matches twice — in Settings the "General" row is a `Button` whose inner `StaticText` repeats the label. The first match in parse order (the parent, i.e. the actionable row) still wins, and `match_count` is added to the element dict when >1 so the caller can narrow. Do **not** "prefer the enabled match": `ElementPoller` observes through this same function, so preferring an enabled sibling would let `assert enabled 'X'` pass against a disabled control by reading its enabled inner label.
- **Typed query type filtering** (DebugDescriptionParser.matchesQuery): typed queries (`searchField:`, `button:`, etc.) now verify element type, not just label/identifier. Previously `searchField:Search` could match a button labeled "Search". Unknown prefixes return no match (fall through to ElementResolver).
- **SwiftUI Toggle tap offset** (TapHandler.swift): SwiftUI Toggle exposes the entire row (label + toggle) as one accessibility element. Coordinate taps offset to the trailing edge where the actual switch control sits, since center-tapping hits the label area which doesn't toggle.
- **YAML scenario runner** (cli/Sources/simpilot/Scenario/): `simpilot run <file.yaml>` executes YAML scenarios with step-by-step assertions, auto-wait, screenshot-on-failure, and variable substitution. Steps map 1:1 to existing HTTP endpoints. Custom minimal YAML parser (no external dependencies). Terminal and JSON (`--json`) output modes.
- **One envelope on stdout** (`AlreadyReported` / `decodeAndPrint`): simpilot's first consumer is an AI agent running `json.loads(stdout)`, so a command writes **exactly one** JSON object. `decodeAndPrint` prints the agent's envelope and then throws `AlreadyReported(status:)` — carrying a status and no message — which `Simpilot.run` turns into a bare `exit`. Throwing a `CLIError` there instead would make `main` print a *second* envelope: `json.loads` fails on the pair, and the agent's specific code (`element_not_found`) is buried under a generic `command_failed`. `AlreadyReported` is deliberately **not** a `CLIError` case, because Swift's exhaustiveness check is per-type: a new case would force `Simpilot.envelope` and `ScenarioRunner` to invent a `(code, message)` for a value whose point is having none. `run` throws it too, which is why it no longer needs its own `exit()`. Never throw it from a scenario step — `ScenarioRunner`'s generic `catch` would drop the status.
- **`batch` fails when any sub-command fails** (`BatchHandler.summarize`): the outer envelope's `success` is `failed == 0`, mirroring `RunReporter`'s report — a batch that tapped nothing must not exit 0 for a script gating on `$?`. The results ride along on failure (`HTTPResponseBuilder.error` takes a `data:` for exactly this), because a caller who cannot see *which* sub-command failed is no better off than one who saw nothing. HTTP status stays **200**, not `error`'s default 400: the batch request itself was well-formed and ran. `error.code` is the aggregate `batch_failed` rather than the first sub-error's code — surfacing `invalid_regex` there would flip the CLI's exit to 3; each sub-result keeps its own code in `data.results`. A sub-command counts as completed only on an explicit `success: true`, so a sub-envelope with a missing or non-boolean `success` fails the batch rather than passing it (the agent-side mirror of `classify`). `stop_on_error` skips carry `success: false` too, so `data` reports `skipped` alongside `completed`/`failed` — `completed + failed + skipped == total_commands`, and a caller filtering `results` on `success == false` would otherwise disagree with `failed`.
- **A non-envelope response is a loud failure** (`decodeAgentEnvelope` → `CLIError.invalidResponse`): a body that is not JSON, is not a JSON object, or carries no boolean `success` used to be echoed verbatim with **exit 0** — `json.loads(stdout)` raised while the exit code claimed success. It is now rejected *before* anything is printed, so `main`'s `invalid_response` envelope is still the only object on stdout. Exit **2**, not 1: something answered on that port, so `agent_unreachable` would send the caller hunting for an agent that is in fact there. `decodeAgentEnvelope` is the **single owner** of "is this an envelope at all" — `decodeAndPrint` (direct commands) and `StepExecutor.parseResponse` (scenario steps) both route through it, so `{"data":{}}` cannot be an `invalid_response` under `tap` and an anonymous failed step under `run`. `success: false` is *not* rejected: a failing step is a normal outcome that `isSuccess` reports. The error is typed rather than an `NSError` because `ScenarioRunner` switches over `CLIError` to build the step's message; anything else falls to its generic `catch` and surfaces as a default `localizedDescription`. `responsePreview` bounds the body's **bytes before decoding** — a wrong `--port` can land on a file server answering with megabytes.

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
