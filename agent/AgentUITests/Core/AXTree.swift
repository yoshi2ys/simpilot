import Foundation
import XCTest

/// The one place the agent reads `app.debugDescription`, and the only place that
/// may hand out the same read twice (SU5).
///
/// The tree fetch is a single ~0.2s IPC and is the most expensive thing the agent
/// does; a `batch` that lists a screen and then acts on it pays for it once per
/// sub-command. `ax_cache=perBatch` makes those sub-commands share one fetch until
/// something changes the screen.
///
/// Reuse is **opt-in and off by default** because it is a bet: a cached tree is
/// only current for as long as the UI stands still, and simpilot cannot observe an
/// animation finishing or a background update landing. What `perBatch` does
/// guarantee is that the bet is dropped the moment a sub-command *can* have
/// changed the screen. Which sub-commands those are is `Router`'s answer, not this
/// type's — `mutates:` sits on the route registration, so a new endpoint does not
/// compile until someone classifies it.
///
/// State is a static because the readers are `DebugDescriptionParser`'s static
/// parse functions, which no handler threads a cache through. That is sound here
/// and nowhere else: `Router.handle` runs every handler inside
/// `DispatchQueue.main.sync`, and a batch's sub-commands run nested in that same
/// call, so exactly one handler is ever in flight.
enum AXTree {

    /// How long one fetched tree may be reused.
    enum Mode: String {
        /// Every read fetches. The default, and what simpilot did before SU5.
        /// Spelled `off` rather than `none` so it never has to be disambiguated
        /// from `Optional.none` — `parse` returns a `Mode?`, where the two would
        /// otherwise read alike and mean opposite things.
        case off = "none"
        /// One fetch is shared across a batch's sub-commands, dropped after any of
        /// them that can change the screen.
        case perBatch

        /// The decoded `ax_cache` field of a `/batch` body.
        ///
        /// Absent — or an explicit JSON `null`, which clients emit for an unset
        /// optional — is `none`. Anything else that is not a mode name returns nil
        /// so the caller can reject it: silently falling back to `none` would let
        /// `"ax_cache": "perStep"` (sim-use has that mode; simpilot does not) read
        /// as accepted and do nothing.
        static func parse(_ raw: Any?) -> Mode? {
            guard let raw, !(raw is NSNull) else { return .off }
            guard let name = raw as? String else { return nil }
            return Mode(rawValue: name)
        }

        /// For the rejection message, so the wire names have one owner.
        static let names = "'\(Mode.off.rawValue)' or '\(Mode.perBatch.rawValue)'"
    }

    private(set) static var mode: Mode = .off
    private static var cached: String?

    /// Tree reads requested, and fetches actually performed, since `begin`.
    /// Their difference is the IPC the cache saved, which is what makes the
    /// speed-up something a caller can check rather than take on trust.
    private(set) static var reads = 0
    private(set) static var fetches = 0

    /// The app's element tree — cached when a batch asked for it, fetched otherwise.
    static func description(of app: XCUIApplication) -> String {
        read { app.debugDescription }
    }

    /// The caching rule on its own, so it is testable without a live app.
    static func read(_ fetch: () -> String) -> String {
        reads += 1
        if mode == .perBatch, let cached { return cached }
        let raw = fetch()
        fetches += 1
        if mode == .perBatch { cached = raw }
        return raw
    }

    /// Drop the cached tree: the next read looks at the screen again.
    ///
    /// A no-op when caching is off, so a call site that needs a fresh look states
    /// that need unconditionally rather than repeating the mode check.
    static func invalidate() {
        cached = nil
    }

    /// Wait for the UI to settle, then drop the tree that described it beforehand.
    ///
    /// Every place in the agent that waits for the screen and then reads it again
    /// within a single command goes through here — whether the command moved the
    /// screen itself (`ActionHandler` after its gesture, `ScrollToHandler` after a
    /// swipe) or is watching for a change someone else will make (`ElementPoller`
    /// between polls). The sleep and the drop are one act with one ordering:
    /// invalidate *after* the wait, so a repaint that lands during it is caught
    /// too. Between sub-commands `BatchHandler` handles this from the route;
    /// inside one, that is too late.
    static func settle(_ interval: TimeInterval) {
        Thread.sleep(forTimeInterval: interval)
        invalidate()
    }

    /// Start a batch. Clears any tree left by a previous one — batch B must never
    /// resolve against batch A's screen — and resets the counters so the report
    /// describes this batch only.
    static func begin(mode: Mode) {
        self.mode = mode
        cached = nil
        reads = 0
        fetches = 0
    }

    /// Leave caching off, which is the state every non-batch command runs in.
    /// Called from a `defer` so an NSException unwinding out of a sub-command
    /// cannot leave the agent caching the tree forever.
    static func end() {
        mode = .off
        cached = nil
    }

    /// What the batch envelope reports. Read before `end` fires.
    static var report: [String: Any] {
        ["mode": mode.rawValue, "tree_reads": reads, "tree_fetches": fetches]
    }
}
