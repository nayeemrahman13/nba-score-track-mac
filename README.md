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
- `NBAService` owns published UI state and coalesces overlapping refreshes. Dates publish independently; failures retain the last successful games and timestamp. The scoreboard decides which games exist and when they tip off. For each game's score, status, period, and clock, whichever of the scoreboard and the CDN box score is further into the game wins: both scoreboard feeds can lag the box score by minutes, including staying live after the final buzzer. The accepted box-score state is reapplied on later refreshes while the scoreboard lags, so scores never move backward. A box score behind the displayed state, such as live details after a game is final, is never applied. Once both sources are final, the scoreboard's official result wins. Box scores are also checked for games still listed as upcoming after their tipoff time. Enrichment cannot erase another date's changes.
- The CDN live scoreboard has no national TV data. `NBAClient` fetches the stats feed for the same league date in the background, at most every 30 minutes, and fills missing broadcasters from the next refresh onward. That request never delays or fails the CDN scores. Both feeds pad status text, which is trimmed.
- While visible, polling waits 15 seconds between completed refreshes with live games — live takes precedence over the error-state interval — 60 seconds with no live games or errors, or 30 seconds while any date is in the error state and none are live. That 30-second value is the loop's cadence, not the failing date's retry rate, which stays on per-date backoff. Hidden windows use 5/15-minute intervals. Unselected non-live dates refresh at most every five minutes. Each failed date backs off independently from 30 seconds to five minutes, without slowing successful live dates. Manual refresh bypasses freshness/backoff and joins any request already running.
- Window visibility, wake, clock, timezone, and calendar-day notifications update polling. The CDN's `gameDate` must match the requested Eastern league date before its response is accepted. Local days use calendar boundaries, including 23-hour and 25-hour DST days, and exclude the next midnight. Rows without a usable UTC tipoff are malformed and cannot be assigned to a local date.
- `BoxScoreCache` accepts only confirmed final results with matching scoreboard totals. Entries expire after six hours to allow official corrections. The v2 directory excludes potentially incomplete data from the previous implementation.

Network responses have a 2 MiB limit enforced during download, including responses without a trustworthy `Content-Length`. Feed validation bounds game IDs, team codes, text, and collection sizes. The disk cache removes expired files and keeps at most 100 entries totaling 16 MiB, with a 256 KiB limit per entry. Maintenance runs on writes and at most every five minutes on reads.

Settings opens inline within the menu-bar window rather than as a modal sheet or separate window, keeping navigation in one place. Login-item status is refreshed when Settings appears and when the app becomes active again.

A five-day strip shows Yesterday, Today, and the next three dated days, one day at a time. All five schedules are prefetched; each keeps its own loading, empty, error, and retained-data state. Live dots mark days with games in progress. Use ⌘← and ⌘→ to change days. The footer reports the selected day's update time and labels stale scores explicitly.

The UI distinguishes initial loading, a successful empty schedule, initial failure, and failure with retained scores. Refresh is available through the toolbar or ⌘R. Live and final game rows are native keyboard-accessible buttons; upcoming rows have no interactive hover highlight. Expanded leaders stay open when a game moves between sections. Day selection and expansion use short, non-bouncing springs, disabled under Reduce Motion; score updates do not animate. Tipoff times use the local timezone. Missing broadcast information is omitted rather than guessed.

## Updates and public releases

Sparkle 2.10.0 provides automatic update checks, an opt-in setting for downloading and installing updates when the app quits, and a manual **Check for Updates** button in Settings. Updates use signed appcasts and archives hosted on this repository's GitHub Releases.

Release builds use Developer ID signing, Hardened Runtime, and the existing app sandbox. Follow [the release guide](docs/releases.md) to archive, export, notarize, staple, and verify an app before publishing.

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

These checks cover a box score that is further along than a lagging scoreboard (including never moving a score backward and the official final winning), Today's broadcaster fill and status trimming, local date grouping in Hong Kong and Pacific time, overlapping schedule failures and recovery, timezone changes, DST boundaries, wake/day rollover during an in-flight request, normal refresh coalescing, player identity through ranking and cache reloads, duplicate/missing IDs, legacy cache decoding, the three-day schedule across year boundaries with partial failures, and tolerant scoreboard decoding that drops malformed game rows while keeping their siblings. NBA player IDs are assigned before ranking and persisted in the cache; missing IDs use roster-scoped fallbacks, and old cache records use unique row slots until refreshed.

Day-strip checks verify independent refresh selection for all three future days. The security checks also exercise oversized HTTP responses with truthful and dishonest length headers, field and collection limits, cache expiry cleanup, disk budgets, oversized cache files, and invalid cache paths.

For refresh changes, verify concurrent refreshes, offline recovery, successful empty schedules, midnight rollover, live-to-final cache transitions, and a slow box score alongside a faster scoreboard. Inspect light/dark appearance, keyboard expansion, refresh/retry, settings, and reopening the menu-bar window.

The October 2026 security pass completed all 27 standalone checks, Debug and universal Release builds, a Developer ID export, and verification of the app and Sparkle helper signatures. A live request loaded five games and a box score through the bounded client. Settings renders were reviewed in light and dark mode. Temporary signed fixtures verified that Sparkle discovers an update and rejects a modified feed; the release verifier also rejected a modified ZIP and assets signed with the wrong key. Public release verification still includes Apple's notarization acceptance and a complete update between two published builds; follow the release guide for those checks. Interactive keyboard and window behavior remains a manual check.

The October 2026 date-grouping fix passed `xcodebuild` and all 21 standalone regression checks. Native HTTP checks against the preseason feeds placed the live Minnesota–Indiana game and the other four morning games under Today in Hong Kong, with completed games under Yesterday. A full 15-second polling interval refreshed Today, and an injected connection failure retained scores and leaders before a manual refresh recovered. Real live-to-final transitions and interactive keyboard/window behavior still need a manual check.
