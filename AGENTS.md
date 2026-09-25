# NBA Score Tracker (macOS menu bar)

A native SwiftUI menu-bar app (macOS 13+) for live NBA scores and box-score player
leaders. The legacy Electron/npm implementation has been removed — the repo contains
only the Xcode project and docs.

## Project layout

- `NBAScoreTracker/NBAScoreTracker.xcodeproj` — the Xcode project (macOS 13+).
- `NBAScoreTracker/NBAScoreTracker/` — app source:
  - `NBAScoreTrackerApp.swift`, `ContentView.swift` — app entry and menu-bar UI.
  - `Models/Game.swift` — scoreboard/box-score models.
  - `Services/` — `NBAClient` (HTTP, decoding, CDN date validation, dated stats
    fallback), `NBAService` (published UI state, refresh coalescing), `BoxScoreCache`
    (final-score cache), `LaunchAtLoginManager` (login item).
  - `Views/` — `GameListView`, `GameRowView`, `LeadersView`, `SettingsView`.
- `NBAScoreTracker/Verification/ReviewRegressions.swift` — standalone regression
  executable, not an app test target.

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
  NBAScoreTracker/NBAScoreTracker/Services/{NBAClient,NBAService,BoxScoreCache}.swift \
  NBAScoreTracker/Verification/ReviewRegressions.swift \
  -o /tmp/nba-review-regressions
/tmp/nba-review-regressions
```

These checks cover wake/day rollover during an in-flight request, refresh coalescing,
player identity through ranking and cache reloads, duplicate/missing IDs, legacy
cache decoding, and tolerant scoreboard decoding that drops malformed game rows
while keeping their siblings.

There is no test suite and no lint script configured. Don't invent either speculatively.

## Refresh, polling, and caching

`NBAClient` owns HTTP and decoding; failures throw and are never converted to empty
schedules. `NBAService` coalesces overlapping refreshes, publishes dates independently,
and on failure retains the last successful games; box-score enrichment cannot overwrite
scoreboard scores or apply live details after a game becomes final. While visible,
polling waits 15 seconds between completed refreshes with live games, 60 seconds
otherwise, or 30 seconds while any date is in the error state (a failing feed is
worth re-checking sooner); hidden windows use 5/15-minute intervals; unselected
non-live dates refresh
at most every five minutes; each failed date backs off independently from 30 seconds
to five minutes. Manual refresh bypasses freshness/backoff and joins any request
already running. `BoxScoreCache` accepts only confirmed final results whose totals
match the scoreboard and expires entries after six hours. See README for the full
behavior contract.

## Debug league override

Launching a **debug** build with `NBA_LEAGUE=10` points the whole live pipeline at the WNBA:
scoreboard and box scores come from `cdn.wnba.com` (`todaysScoreboard_10.json`,
`boxscore_<id>.json`) and the dated stats fallback uses `LeagueID=10`. WNBA live data only
exists there — `cdn.nba.com`'s `_10` object is stale, frozen at a 2020 Finals game.

## Gotchas and boundaries

- **NBA's endpoints are unofficial and undocumented.** They can change shape or what
  they accept (headers, date handling) without notice — verify against live data when
  touching `NBAClient`.
- **No test or lint suite exists.** The regression executable above is the focused
  check; don't invent a test or lint setup speculatively.
- For refresh changes, run the regression executable and manually verify concurrent
  refreshes, offline recovery, midnight rollover, and live-to-final cache transitions
  (README's Verification section has the full checklist).
