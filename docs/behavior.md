# Score behavior

`NBAClient` fetches scores. `NBAService` publishes each date separately. `BoxScoreCache` stores final box scores.

The league endpoints are unofficial and can change without notice.

## Dates

A requested date is a local Gregorian calendar day.

The day starts at local midnight and ends before the next midnight.

A daylight-saving day of 23 hours or 25 hours uses those same bounds.

The client loads each Eastern league date that overlaps the local day. Eastern time is `America/New_York`.

Two local days that need the same Eastern date share one in-flight request.

The local day is published only when every Eastern date it needs has succeeded.

The live CDN file is `todaysScoreboard_00.json` on `cdn.nba.com`.

The client uses that file for the current Eastern date and for the Eastern date 12 hours earlier.

The CDN `gameDate` must equal the requested league date.

If that check fails, or the CDN request fails, the client loads `scoreboardv3` from `stats.nba.com` for the same league date.

A cancelled request does not use that fallback.

The NBA stats URL sets `LeagueID=00`.

An empty CDN scoreboard with a matching date is success. The client does not call the stats feed for that response.

Outside the live CDN window, the client uses only the stats feed.

An HTTP failure throws. It does not become an empty schedule.

An invalid date key throws.

A response with more than 64 games throws.

A malformed game is dropped. The other games in that response stay.

If every game in the response is malformed, the request throws.

An empty game list is a successful empty day.

A game with no usable UTC tipoff is malformed.

After a successful fetch, games outside the local day are removed. That day can then be empty.

Duplicate game IDs fail that local date. The previous games for the date stay.

A failure keeps that date's last games and its last update time.

Leader updates write only the date that started them.

A newer scoreboard for that date drops an in-flight leader result.

Requests send a browser user agent, `Accept: application/json`, an `Origin` of `https://www.nba.com`, and a `Referer` of `https://www.nba.com/`.

Each request times out after 8 seconds. Each resource times out after 12 seconds.

Each host allows 4 connections. The app uses one session for the scoreboard and another session for box scores.

The sessions are ephemeral and ignore the HTTP cache.

## Score selection

The scoreboard decides which games exist and when they tip off.

For status, period, clock, and score, the app keeps the later of the scoreboard and the box score.

The app compares the two states in this order. The first difference decides.

1. Compare status in this order: upcoming, live, final.
2. Compare period. A higher period is later.
3. Compare the clock when both clocks parse. Less time remaining is later.
4. Compare the combined score only when the game is not final. A higher total is later.
5. If the row is final and the earlier steps tie, treat the rows as the same moment.

At that tie, the scoreboard totals remain, even when the points differ.

The app stores a newer box score and applies it on later scoreboard updates until the scoreboard is no longer behind.

A box score behind the displayed state is ignored. Its player leaders are ignored too.

Player leaders update when the box score matches the displayed state or is later than that state.

The app also requests a box score for an upcoming game whose tipoff time has passed.

Each date requests at most 3 box scores at a time.

## Player leaders

A positive `personId` becomes the ID `nba:` plus that number.

Any other player uses `roster:<team>:<index>`. The index is the roster index from before the leader sort.

A repeated ID becomes that ID plus `:duplicate:` plus the same index.

The ID is assigned before the sort. A later change in rank does not change the ID of a player who has no NBA ID.

Leaders sort by points, then rebounds, then assists, then steals, then blocks.

When points, rebounds, assists, steals, and blocks all match, a player with minutes comes before a player with no minutes.

The remaining tie uses the player name.

Each team shows at most 3 leaders.

A missing player name is shown as **Unknown**.

A cached player with no ID is shown as `legacy:<team>:<index>` until a refresh replaces the record.

In the row, the away team is above the home team. The leaders use that same order.

When both teams have no leaders and a fetch is running, the expanded row shows **Loading leaders…**.

When both teams have no leaders after the fetch, the expanded row shows **Leaders unavailable**.

## Broadcasters

The live CDN scoreboard does not include national TV.

When any game on a league date has no stored broadcaster, the client loads the stats feed for that date in the background.

It starts that load at most once every 30 minutes per league date.

A failure of that load does not fail the scores.

A broadcaster from that load appears on a later scoreboard refresh.

The same game ID keeps one broadcaster on every day.

Both feeds pad status text. The app trims that padding.

A missing broadcaster stays blank.

A national name whose letters include AMAZON is shown as **Prime Video**.

## Polling

The poll waits until the current refresh finishes, then sleeps for the interval below.

| Window | Condition | Wait |
| --- | --- | --- |
| Visible | At least one live game | 15 seconds |
| Visible | No live game and no error | 60 seconds |
| Visible | No live game, and at least one date has an error | 30 seconds |
| Hidden | At least one live game | 5 minutes |
| Hidden | No live game | 15 minutes |

A live game on any loaded day selects the live row, even when another day has an error.

The visible wait of 30 seconds is only the loop wait. A failed date has its own retry wait.

The first failure waits 30 seconds. Each later failure doubles the previous wait. The wait stops at 5 minutes.

A successful date keeps its own interval. It does not use a failed date's retry wait.

**Today**, the selected day, and any day that contains a live game use the loop wait as their refresh interval.

Any other day with no current failure refreshes at most every 5 minutes.

When no refresh is running, a manual refresh skips the freshness wait and the failure wait.

When a refresh is already running, the manual refresh waits for that refresh.

The running refresh then checks freshness once more. That extra check still uses the freshness wait and the failure wait.

Wake, a clock change, a time zone change, and local midnight clear the freshness times and start a new poll.

Showing or hiding the window starts a new poll. Changing the selected day starts a new poll.

Opening the window selects **Today**.

The refresh button is disabled while a refresh is running.

## Box score cache

The cache stores a box score only when the game is final on both feeds and the two team totals match the scoreboard.

An in-progress box score is not written.

Entries expire after 6 hours.

The directory is `NBAScoreTracker/boxscores-v2` inside the user caches directory.

Older cache directories are not read.

The disk cache holds at most 100 files and 16 MiB.

Each file is at most 256 KiB.

A write prunes the directory immediately. A read prunes it at most every 5 minutes.

The prune looks only at JSON files.

It deletes expired files, symbolic links, and files that are not regular files.

It deletes files larger than 256 KiB, and files whose names are not game IDs.

## Request limits

The client stops a download at 2 MiB.

A `Content-Length` above 2 MiB cancels the response before the body is read.

The client also stops reading when the next bytes would exceed 2 MiB. A missing or short `Content-Length` does not raise that cap.

These fields use the following UTF-8 limits:

| Field | Limit |
| --- | --- |
| Game id | 1 to 20 digits |
| Team code | 2 to 4 uppercase letters |
| Games in one response | 64 |
| Players on one team | 64 |
| Status text and broadcaster | 256 bytes |
| `gameTimeUTC` | 64 bytes |
| Game clock | 32 bytes |
| `name` and `nameI` | 128 bytes each |
| Position | 16 bytes |
| Minutes | 64 bytes |

A box score with no players, or with more than 64 players on a team, fails.

## Window

The window lists five local days: **Yesterday**, **Today**, and the next three days.

**Yesterday** and **Today** use those words. The other days use an abbreviated weekday.

Every open of the window returns to **Today** and closes **Settings**.

The service tracks all five days. Each day keeps its own loading state, empty state, error, and last games.

A red dot marks a day with a live game.

Command-Left and Command-Right change the day.

Command-R refreshes the scores.

Command-Comma opens **Settings**. Escape closes **Settings**.

**Settings** replaces the score list in the same window.

Launch at login is reloaded when **Settings** appears and when the app becomes active.

The footer shows the update time for the selected day.

The footer adds **Out of date** when that day has an error or the update is older than 120 seconds.

The first load of a day shows **Loading scores…**.

A failed first load shows **Scores unavailable** and **Try again**.

A later failure keeps the games and shows **Couldn't refresh. Showing the last update.**

A successful empty day shows **No games** with the day name.

When the selected day has no update time and a load is in progress, the footer shows **Connecting to NBA…**.

When the selected day has no update time and no load is in progress, the footer shows **Waiting for scores**.

Live rows and final rows are buttons. Upcoming rows are not buttons.

Expanded leaders stay open when a game moves among **Live**, **Upcoming**, and **Final**.

Changing the day, or expanding a row, uses a spring with response 0.3 and damping fraction 1.

**Reduce Motion** removes that spring.

A score change does not animate.

Tipoff times use the local time zone.

## Updates

Sparkle 2.10.0 checks for updates.

Automatic checks are on at first launch.

Automatic download is off until the user turns on **Install Updates** in **Settings**.

The button reads **Check for Updates…**. When an update is ready, the button reads **Install Available Update…**.

The app reads `appcast.xml` from the latest GitHub release of this repo. [Prepare a public release](releases.md) covers signing and publishing.

Sparkle does not send a system profile.

## Debug league override

A debug build launched with `NBA_LEAGUE=10` uses the WNBA feeds.

The scoreboard is `todaysScoreboard_10.json` on `cdn.wnba.com`.

The box score is `boxscore_<id>.json` on that same host.

The stats fallback sets `LeagueID=10`.

Release builds ignore `NBA_LEAGUE`.

The league 10 scoreboard on `cdn.nba.com` is a 2020 Finals game. The debug override does not read that file.
