# Build and check the app

You need Xcode with the macOS 13 SDK.

## Build the app

Open `NBAScoreTracker/NBAScoreTracker.xcodeproj`.

Run the `NBAScoreTracker` scheme.

To build from a terminal, run this command from the repository root:

```sh
xcodebuild -project NBAScoreTracker/NBAScoreTracker.xcodeproj \
  -scheme NBAScoreTracker -configuration Debug build
```

## Run the regression executable

The repo has no test target and no lint script.

The regression check is one Swift executable. From the repository root, run these commands:

```sh
xcrun swiftc -parse-as-library -module-cache-path /tmp/nba-swift-module-cache \
  NBAScoreTracker/NBAScoreTracker/Models/Game.swift \
  NBAScoreTracker/NBAScoreTracker/Services/{NBAClient,NBAService,BoxScoreCache,LogoCache,NetworkMonitor,ScoreboardSnapshotCache}.swift \
  NBAScoreTracker/Verification/ReviewRegressions.swift \
  -o /tmp/nba-review-regressions
/tmp/nba-review-regressions
```

Each check prints a line that starts with `PASS`.

A failed check stops the process.

The executable checks these cases:

- A box score ahead of a lagging scoreboard
- Scores that do not move backward
- Final scoreboard totals kept once both feeds are final
- Broadcaster fill for **Today** and negative caching for local-only games
- Trimmed status text
- Local date grouping in Hong Kong
- Pacific dates that span two Eastern schedules, with the next midnight excluded
- Pacific **Today** after Eastern midnight, still on the local date and still on the live CDN
- A year boundary
- A daylight-saving day of 23 hours
- A daylight-saving day of 25 hours
- An overlapping schedule failure, and recovery of that day
- A time zone change during a refresh
- Wake during an in-flight request
- Local midnight during an in-flight request
- Concurrent refreshes joined into one request
- On-demand loading for future days (+1..+3), independent per-day refresh, and decoupled lanes so a slow selected or unselected future day never blocks **Today** polling cycles
- Hidden-window and offline cancellation of polling, in-flight refreshes, and follow-up enrichment; remaining-window sleep alignment and immediate interrupted-enrichment resume on reopen; settled **Yesterday** 30-minute TTL; and `NWPathMonitor` offline deferral + reconnect backoff reset
- Settled final skip (preserving aged `BoxScoreCache` expiry, score-correction invalidation, and TTL expiry), dynamic leader enrichment priority, and guarded `@Published` emissions
- `LogoCache` ImageIO downsampling (≤ 66 px), synchronous L1 hit, L2 disk reload, path-traversal tricode rejection, and failure cooldown
- CDN conditional `If-None-Match` / `If-Modified-Since` → `304 Not Modified` decoded-response caching (skipping JSON decode, enforcing the 24-entry / 8 MiB cap under concurrent eviction, and protecting newer ETags against stale concurrent 304s; non-application to `stats.nba.com`)
- `ScoreboardSnapshotCache` cold-start hydration (preserving `progressByGame` provenance against lagging refreshes), debounced save, expiry, league isolation, `gameTimeUTC` validation, and oversize/corruption rejection
- Player IDs kept across a change in rank and a cache reload
- Missing player IDs
- Old cache records that have no player ID
- Malformed scoreboard rows dropped, and the other rows kept, on the CDN feed and on the stats feed
- An empty game list kept as success
- A response with no valid game kept as failure
- An oversized body with a truthful `Content-Length`
- An oversized body with a dishonest `Content-Length`
- Field limits and collection limits
- A valid box score next to an oversized player list
- Cache expiry
- The disk byte budget (including debounced save pruning)
- Oversized cache files and invalid cache paths
- Leader tie breaks
- A follow-up leader pass when a game starts during a batch

## Check a refresh change

After you change refresh behavior, run the regression executable.

Then confirm these cases:

- Two refreshes running at the same time
- Scores kept during an offline failure, then a successful retry
- A day with no games
- Local midnight during an in-flight request
- A live game becoming final, and the cached box score for that game
- A slow box score next to a faster scoreboard
- Light appearance and dark appearance
- Expanding a row from the keyboard
- Refresh, and **Try again** after an error
- **Settings**
- Closing the menu bar window and opening it again
