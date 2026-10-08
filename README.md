# NBA Score Tracker

A native SwiftUI macOS menu-bar app for NBA scores and player leaders.

## Build the native app

Open `NBAScoreTracker/NBAScoreTracker.xcodeproj` in Xcode and run the `NBAScoreTracker` scheme (macOS 13+). From a terminal:

```sh
xcodebuild -project NBAScoreTracker/NBAScoreTracker.xcodeproj \
  -scheme NBAScoreTracker -configuration Debug build
```

## Refresh architecture

- `NBAClient` owns HTTP, decoding, CDN date validation, and the dated stats fallback. A requested date is a local Gregorian calendar day. The client fetches the Eastern NBA schedule dates that overlap that day, then groups games by their UTC tipoff time. Adjacent local dates share in-flight schedule requests. Every overlapping schedule must succeed before a local date updates. Requests have bounded timeouts and HTTP failures are thrown, never converted to empty schedules. Box scores use a separate connection pool.
- `NBAService` owns published UI state and coalesces overlapping refreshes. Dates publish independently; failures retain the last successful games and timestamp. Box-score enrichment cannot overwrite scoreboard scores, erase another date's changes, or apply live details after a game becomes final.
- While visible, polling waits 15 seconds between completed refreshes with live games — live takes precedence over the error-state interval — 60 seconds with no live games or errors, or 30 seconds while any date is in the error state and none are live. That 30-second value is the loop's cadence, not the failing date's retry rate, which stays on per-date backoff. Hidden windows use 5/15-minute intervals. Unselected non-live dates refresh at most every five minutes. Each failed date backs off independently from 30 seconds to five minutes, without slowing successful live dates. Manual refresh bypasses freshness/backoff and joins any request already running.
- Window visibility, wake, clock, timezone, and calendar-day notifications update polling. The CDN's `gameDate` must match the requested Eastern league date before its response is accepted. Local days use calendar boundaries, including 23-hour and 25-hour DST days, and exclude the next midnight. Rows without a usable UTC tipoff are malformed and cannot be assigned to a local date.
- `BoxScoreCache` accepts only confirmed final results with matching scoreboard totals. Entries expire after six hours to allow official corrections. The v2 directory excludes potentially incomplete data from the previous implementation.

Settings opens in a retained, independent window rather than a sheet on the transient menu-bar panel, so login-item approval and focus changes cannot dismiss it. Login-item status is refreshed when the app becomes active again.

Upcoming shows the next three calendar days starting tomorrow, grouped under date headings and ordered by tipoff within each day. All three schedules are prefetched; each keeps its own loading, empty, error, and retained-data state. The footer reports partial loading until all three dates have succeeded, and uses the oldest update time for the group. Yesterday and Today remain single-day views.

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

These checks cover local date grouping in Hong Kong and Pacific time, overlapping schedule failures and recovery, timezone changes, DST boundaries, wake/day rollover during an in-flight request, normal refresh coalescing, player identity through ranking and cache reloads, duplicate/missing IDs, legacy cache decoding, the three-day schedule across year boundaries with partial failures, and tolerant scoreboard decoding that drops malformed game rows while keeping their siblings. NBA player IDs are assigned before ranking and persisted in the cache; missing IDs use roster-scoped fallbacks, and old cache records use unique row slots until refreshed.

For refresh changes, verify concurrent refreshes, offline recovery, successful empty schedules, midnight rollover, live-to-final cache transitions, and a slow box score alongside a faster scoreboard. Inspect light/dark appearance, keyboard expansion, refresh/retry, settings, and reopening the menu-bar window.

The September 2026 refactor passed direct Swift compilation and temporary fixture-based regression checks, including HTTP errors, malformed payloads, CDN date mismatch, cache expiry, and preservation of scores/leaders during overlapping work. Offscreen AppKit renders were reviewed in light and dark mode. The local `xcodebuild` installation failed before compilation with a missing `DVTDownloads` symbol in `IDESimulatorFoundation`; direct `swiftc` compilation and linking succeeded. The live NBA CDN returned HTTP 403 in this environment, so real live-game updates still need verification on a working feed. Desktop UI automation also timed out; interactive keyboard/window behavior needs a manual check.

The October 2026 date-grouping fix passed `xcodebuild` and all 21 standalone regression checks. Native HTTP checks against the preseason feeds placed the live Minnesota–Indiana game and the other four morning games under Today in Hong Kong, with completed games under Yesterday. A full 15-second polling interval refreshed Today, and an injected connection failure retained scores and leaders before a manual refresh recovered. Real live-to-final transitions and interactive keyboard/window behavior still need a manual check.
