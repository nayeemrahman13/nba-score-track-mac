# NBA Score Tracker

A native SwiftUI macOS menu-bar app for NBA scores and player leaders.

## Build the native app

Open `NBAScoreTracker/NBAScoreTracker.xcodeproj` in Xcode and run the `NBAScoreTracker` scheme (macOS 13+). From a terminal:

```sh
xcodebuild -project NBAScoreTracker/NBAScoreTracker.xcodeproj \
  -scheme NBAScoreTracker -configuration Debug build
```

## Refresh architecture

- `NBAClient` owns HTTP, decoding, CDN date validation, and the dated stats fallback. Requests have bounded timeouts and HTTP failures are thrown, never converted to empty schedules. Box scores use a separate connection pool.
- `NBAService` owns published UI state and coalesces overlapping refreshes. Dates publish independently; failures retain the last successful games and timestamp. Box-score enrichment cannot overwrite scoreboard scores, erase another date's changes, or apply live details after a game becomes final.
- While visible, polling waits 15 seconds between completed refreshes with live games, 60 seconds otherwise, or 30 seconds while any date is in the error state — a failing feed is worth re-checking sooner. Hidden windows use 5/15-minute intervals. Unselected non-live dates refresh at most every five minutes. Each failed date backs off independently from 30 seconds to five minutes, without slowing successful live dates. Manual refresh bypasses freshness/backoff and joins any request already running.
- Window visibility, wake, clock, timezone, and calendar-day notifications update polling. Dates use the local Gregorian calendar consistently; the CDN's `gameDate` must match before its response is accepted.
- `BoxScoreCache` accepts only confirmed final results with matching scoreboard totals. Entries expire after six hours to allow official corrections. The v2 directory excludes potentially incomplete data from the previous implementation.

Settings opens in a retained, independent window rather than a sheet on the transient menu-bar panel, so login-item approval and focus changes cannot dismiss it. Login-item status is refreshed when the app becomes active again.

The UI distinguishes initial loading, a successful empty schedule, initial failure, and failure with retained scores. Refresh is available through the toolbar or ⌘R. Game rows are native keyboard-accessible buttons, score updates do not animate, and press feedback respects Reduce Motion. Tipoff times use the local timezone. Missing broadcast information is omitted rather than guessed.

## Verification

There is no configured test or lint suite. Focused PR-review regressions are available as a standalone Swift executable:

```sh
xcrun swiftc -parse-as-library -module-cache-path /tmp/nba-swift-module-cache \
  NBAScoreTracker/NBAScoreTracker/Models/Game.swift \
  NBAScoreTracker/NBAScoreTracker/Services/{NBAClient,NBAService,BoxScoreCache}.swift \
  NBAScoreTracker/Verification/ReviewRegressions.swift \
  -o /tmp/nba-review-regressions
/tmp/nba-review-regressions
```

These checks cover wake/day rollover during an in-flight request, normal refresh coalescing, player identity through ranking and cache reloads, duplicate/missing IDs, legacy cache decoding, and tolerant scoreboard decoding that drops malformed game rows while keeping their siblings. NBA player IDs are assigned before ranking and persisted in the cache; missing IDs use roster-scoped fallbacks, and old cache records use unique row slots until refreshed.

For refresh changes, verify concurrent refreshes, offline recovery, successful empty schedules, midnight rollover, live-to-final cache transitions, and a slow box score alongside a faster scoreboard. Inspect light/dark appearance, keyboard expansion, refresh/retry, settings, and reopening the menu-bar window.

The September 2026 refactor passed direct Swift compilation and temporary fixture-based regression checks, including HTTP errors, malformed payloads, CDN date mismatch, cache expiry, and preservation of scores/leaders during overlapping work. Offscreen AppKit renders were reviewed in light and dark mode. The local `xcodebuild` installation failed before compilation with a missing `DVTDownloads` symbol in `IDESimulatorFoundation`; direct `swiftc` compilation and linking succeeded. The live NBA CDN returned HTTP 403 in this environment, so real live-game updates still need verification on a working feed. Desktop UI automation also timed out; interactive keyboard/window behavior needs a manual check.
