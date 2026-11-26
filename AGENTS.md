# NBA Score Tracker (macOS menu bar)

A native SwiftUI menu-bar app (macOS 13+) for live NBA scores and box-score player
leaders. The legacy Electron/npm implementation has been removed — the repo contains
only the Xcode project and docs.

## Project layout

- `NBAScoreTracker/NBAScoreTracker.xcodeproj` — the Xcode project (macOS 13+, `SWIFT_STRICT_CONCURRENCY = complete`).
- `NBAScoreTracker/NBAScoreTracker/` — app source:
  - `NBAScoreTrackerApp.swift`, `ContentView.swift` — app entry and menu-bar UI.
  - `Models/Game.swift` — scoreboard/box-score models and cached `ScoreDate` timezone formatters.
  - `Services/` — `NBAClient` (HTTP, decoding, CDN date validation, CDN `304` conditional cache, dated stats
    fallback, broadcaster negative cache), `NBAService` (published UI state, decoupled foreground/future lanes,
    visibility-gated polling, dynamic leader enrichment priority), `BoxScoreCache` (final-score cache),
    `LogoCache` (L1/L2 downsampled team logos), `NetworkMonitor` (`NWPathMonitor` reachability),
    `ScoreboardSnapshotCache` (cold-start snapshot), `LaunchAtLoginManager` (login item), `UpdateManager` (Sparkle).
  - `Views/` — `GameListView`, `GameRowView`, `LeadersView`, `SettingsView`.
- `NBAScoreTracker/Verification/ReviewRegressions.swift` — standalone regression
  executable, not an app test target.
- `scripts/release.sh`, `scripts/verify_release.py` — signed release preparation and verification.
- `docs/releases.md` — GitHub Releases, notarization, and Sparkle signing instructions.

## Commands

Build the app:

```sh
xcodebuild -project NBAScoreTracker/NBAScoreTracker.xcodeproj \
  -scheme NBAScoreTracker -configuration Debug build
```

(or open the project in Xcode and run the `NBAScoreTracker` scheme.)

Focused check — build and run the standalone regression executable:

```sh
xcrun swiftc -parse-as-library -module-cache-path /tmp/nba-swift-module-cache \
  NBAScoreTracker/NBAScoreTracker/Models/Game.swift \
  NBAScoreTracker/NBAScoreTracker/Services/{NBAClient,NBAService,BoxScoreCache,LogoCache,NetworkMonitor,ScoreboardSnapshotCache}.swift \
  NBAScoreTracker/Verification/ReviewRegressions.swift \
  -o /tmp/nba-review-regressions
/tmp/nba-review-regressions
```

These checks cover box-score progress overriding a lagging scoreboard without moving
backward, Today's broadcaster fill and negative caching, wake/day rollover during an in-flight request,
refresh coalescing, visibility-gated polling, decoupled foreground/future lanes, `NWPathMonitor` offline/reconnect
handling, settled final skipping, dynamic enrichment priority, `LogoCache` downsampling/L1/L2/cooldown,
CDN `304 Not Modified` caching, `ScoreboardSnapshotCache` cold-start hydration,
player identity through ranking and cache reloads, duplicate/missing IDs, legacy
cache decoding, and tolerant scoreboard decoding that drops malformed game rows
while keeping their siblings.
They also cover network payload and field limits, disk cache expiry cleanup, entry and byte budgets, and invalid cache paths.

There is no test suite and no lint script configured. Don't invent either speculatively.

## Refresh, polling, and caching

`NBAClient` owns HTTP and decoding; failures throw and are never converted to empty
schedules. Its requested dates are local Gregorian calendar days. It fetches the
overlapping Eastern NBA schedules, validates the CDN against the league date, uses
bounded in-memory `If-None-Match` / `If-Modified-Since` → `304` validation on CDN JSON
endpoints (never `stats.nba.com`), and groups games by UTC tipoff within the local day's
midnight boundaries. Adjacent local days share in-flight league requests; a local day
updates only when all its overlapping schedules succeed. Rows without a usable UTC tipoff
are malformed. `NBAService` coalesces overlapping refreshes, runs foreground dates
(**Today**, **Yesterday**, and loaded live days) separately from on-demand future days (+1..+3),
publishes dates independently, and on failure retains the last successful games.
The scoreboard decides which games exist and when they tip off; for score, status, period
and clock, whichever of the scoreboard and the box score is further into the game wins
(the scoreboard feeds can lag the box score by minutes, even staying live after the final
buzzer). The accepted box-score state is reapplied while the scoreboard lags, so scores
never move backward; a box score behind the displayed state (such as live details after
final) is never applied; once both are final, the scoreboard's result wins. The CDN live
scoreboard omits national TV, so `NBAClient` fills it in the background from the stats
feed for that league date (at most every 30 minutes, with a 6-hour negative cache for
confirmed local-only games, never blocking scores). Polling and the footer `TimelineView`
pause completely when the popover is hidden or offline (`NWPathMonitor`); reconnect resets
backoff and immediately refreshes visible windows. While visible and online, polling waits
15 seconds between completed refreshes with live games (live takes precedence over the
error-state interval), 60 seconds with no live games or errors, or 30 seconds while any
date is in the error state and none are live — the loop's cadence, not the failing date's
retry rate, which stays on its own backoff (30 seconds to 5 minutes). Settled unselected
**Yesterday** raises its TTL to 30 minutes once > 3 hours past local midnight; future days
(+1..+3) load purely on-demand when selected. Manual refresh bypasses freshness/backoff
for active lanes and joins any request already running. `BoxScoreCache` accepts only
confirmed final results whose totals match the scoreboard and expires entries after six
hours. `LogoCache` provides synchronous L1 memory and L2 downsampled (≤ 66 px) disk logo
caching. `ScoreboardSnapshotCache` provides debounced 6-hour cold-start hydration.
See docs/behavior.md for the full behavior contract.

## Debug league override

Launching a **debug** build with `NBA_LEAGUE=10` points the whole live pipeline at the WNBA:
scoreboard and box scores come from `cdn.wnba.com` (`todaysScoreboard_10.json`,
`boxscore_<id>.json`) and the dated stats fallback uses `LeagueID=10`. WNBA live data only
exists there — `cdn.nba.com`'s `_10` object is stale, frozen at a 2020 Finals game.

## Gotchas and boundaries

- The schedule uses five single-day chips (Yesterday, Today, and three dated days),
  not a combined Upcoming tab. Keep expansion state above rows so it survives section changes.
- **NBA's endpoints are unofficial and undocumented.** They can change shape or what
  they accept (headers, date handling) without notice — verify against live data when
  touching `NBAClient`.
- **No test or lint suite exists.** The regression executable above is the focused
  check; don't invent a test or lint setup speculatively.
- For refresh changes, run the regression executable and manually verify concurrent
  refreshes, offline recovery, midnight rollover, and live-to-final cache transitions
  (docs/build.md has the full checklist).
- Sparkle is pinned to 2.10.0. Keep the sandbox and its two Sparkle Mach lookup exceptions.
  Archive and export through Xcode to sign nested helpers. Never ship `get-task-allow`
  or disable library validation. The Sparkle private key stays in the login keychain;
  only its public key belongs in `Updates.xcconfig`. Follow `docs/releases.md`.
