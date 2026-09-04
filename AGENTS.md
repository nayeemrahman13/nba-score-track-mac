# NBA Score Tracker (macOS menu bar)

An Electron menubar app (via `menubar`) showing live NBA scores and box-score leaders, styled
with Tailwind, rendered through Vite. `main.js` polls `stats.nba.com` / `cdn.nba.com` directly
from the Electron main process and pushes results to the renderer over `ipcMain.handle`.

## Commands

- Install: `npm install`
- Dev (Vite renderer only, browser preview): `npm run dev`
- Run as the actual menubar app: `npm start` (launches Electron against `main.js`)
- Build renderer assets: `npm run build`

There is no test suite and no lint script configured. Don't invent either speculatively.

## Architecture

- `main.js` — Electron main process: creates the `menubar` window, fetches scores/box-score
  leaders from NBA's stats and CDN endpoints, exposes `fetch-nba-scores` and `quit-app` over IPC.
- `src/renderer.js`, `src/style.css` — the renderer UI, Tailwind-styled.
- `src/python/fetch_scores.py` — **dead code.** Same score-fetching logic as `main.js`, in
  Python via the `nba_api` package. Nothing in `main.js` or `package.json` invokes it. It was
  superseded by the JS port and is not part of the running app.

## Gotchas

- **`webPreferences` sets `nodeIntegration: true, contextIsolation: false`.** That gives the
  renderer full Node access with no isolation from a remote page — normally a serious Electron
  anti-pattern. It's lower-risk here because the renderer only ever loads local `dist/` content
  in production, not third-party pages. Don't add `<webview>`, an external URL load, or any
  remote content to the renderer without revisiting this first.
- **NBA's endpoints are unofficial and undocumented.** The hardcoded `HEADERS` (User-Agent,
  Origin, Referer) exist to look like a browser request; expect them to need updating if NBA
  changes what it accepts. Both `main.js` and the dead `fetch_scores.py` duplicate this — if you
  fix one, the other is still wrong, but only `main.js` matters at runtime.
- **`venv/` exists at the repo root** for the unused Python script. It's not referenced by any
  npm script — don't assume `npm start` needs it activated.

## Boundaries

**Always**
- Manually launch `npm start` and confirm today's games render after touching `main.js`'s
  fetch or IPC logic — there's no automated coverage to catch a broken response shape.

**Ask first**
- Re-enabling `contextIsolation` / `nodeIntegration: false` — worth doing, but it's a real
  refactor of how the renderer talks to `main.js` (needs a preload script and `contextBridge`),
  not a flag flip.

**Never**
- Delete `src/python/fetch_scores.py` silently as part of an unrelated change — flag it and let
  it be a deliberate removal, since removing dead code is still a diff someone should see coming.
- Add a remote/external URL as the `menubar` window's `index`.
