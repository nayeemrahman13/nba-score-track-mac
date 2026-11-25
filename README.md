# NBA Score Tracker

NBA Score Tracker is a macOS menu bar app for NBA scores and player leaders.

The project is a SwiftUI app for macOS 13 and later. Open `NBAScoreTracker/NBAScoreTracker.xcodeproj`.

## Why the box score can override the scoreboard

The league publishes an unofficial scoreboard and an unofficial box score. The scoreboard names the games and their tipoff times. The box score can be minutes ahead of the scoreboard. The scoreboard can still list a game as live after the game has ended.

The app shows the later of those two states. It does not replace a later state with an older score. [Score behavior](docs/behavior.md) defines the comparison.

The endpoints can change without notice.

## Documents

Read these pages for procedures and for the behavior reference.

- [Build and check the app](docs/build.md) covers compiling the app and running the regression executable.
- [Score behavior](docs/behavior.md) is the reference for dates, polling, the cache, and the window.
- [Prepare a public release](docs/releases.md) explains signing, notarization, and Sparkle.
