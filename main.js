import { menubar } from 'menubar';
import path from 'path';
import { fileURLToPath } from 'url';
import { app, ipcMain } from 'electron';
import { exec } from 'child_process';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const isDev = !app.isPackaged;
const PORT = process.env.PORT || 3000;
const url = isDev
    ? `http://localhost:${PORT}`
    : `file://${path.join(__dirname, 'dist/index.html')}`;

const HEADERS = {
    'Host': 'stats.nba.com',
    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'en-US,en;q=0.9',
    'Origin': 'https://www.nba.com',
    'Referer': 'https://www.nba.com/',
    'Connection': 'keep-alive',
};

const mb = menubar({
    index: url,
    browserWindow: {
        width: 360,
        height: 600,
        transparent: true,
        frame: false,
        resizable: false,
        vibrancy: 'under-window', // macOS exclusive vibrancy effect
        visualEffectState: 'active',
        webPreferences: {
            nodeIntegration: true,
            contextIsolation: false,
        },
    },
    icon: path.join(__dirname, 'iconTemplate.png'),
    showDockIcon: false,
});

mb.on('ready', () => {
    console.log('App is ready');
});

mb.on('after-create-window', () => {
    console.log('Window created');
    if (isDev && mb.window) {
        mb.window.webContents.openDevTools({ mode: 'detach' });
    }
});

function getTeamLeaders(players) {
    if (!players || !Array.isArray(players)) return [];

    const getVal = (p, key) => (p.statistics && p.statistics[key]) || 0;

    return players
        .sort((a, b) => {
            const pts = getVal(b, 'points') - getVal(a, 'points');
            if (pts !== 0) return pts;
            const reb = getVal(b, 'reboundsTotal') - getVal(a, 'reboundsTotal');
            if (reb !== 0) return reb;
            return getVal(b, 'assists') - getVal(a, 'assists');
        })
        .slice(0, 3)
        .map(p => ({
            name: p.name || 'Unknown',
            nameI: p.nameI || (p.name ? `${p.name[0]}. ${p.name.split(' ').pop()}` : 'Player'),
            position: p.position || '',
            points: getVal(p, 'points'),
            rebounds: getVal(p, 'reboundsTotal'),
            assists: getVal(p, 'assists'),
        }));
}

async function fetchGameLeaders(gameId) {
    try {
        const response = await fetch(`https://cdn.nba.com/static/json/liveData/boxscore/boxscore_${gameId}.json`, { headers: HEADERS });
        if (!response.ok) return null;
        const data = await response.json();
        const gameBox = data.game;
        if (!gameBox) return null;

        return {
            homeLeaders: getTeamLeaders(gameBox.homeTeam?.players),
            awayLeaders: getTeamLeaders(gameBox.awayTeam?.players),
        };
    } catch (e) {
        console.error(`Error fetching leaders for ${gameId}:`, e);
        return null;
    }
}

function getPrimaryBroadcaster(broadcasters) {
    if (!broadcasters) return "LEAGUE PASS";

    const national = broadcasters.nationalBroadcasters || [];
    if (national.length > 0) {
        const display = national[0].broadcastDisplay || '';
        if (display.toUpperCase() === 'AMAZON') return 'Prime Video';
        return display;
    }

    const nationalOtt = broadcasters.nationalOttBroadcasters || [];
    if (nationalOtt.length > 0) {
        return nationalOtt[0].broadcastDisplay || 'LEAGUE PASS';
    }

    return "LEAGUE PASS";
}

async function fetchSingleDate(targetDate) {
    try {
        const response = await fetch(`https://stats.nba.com/stats/scoreboardv3?GameDate=${targetDate}&LeagueID=00`, { headers: HEADERS });
        if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);
        const data = await response.json();
        const gamesRaw = data.scoreboard?.games || [];

        const formattedGames = await Promise.all(gamesRaw.map(async (game) => {
            const gameId = game.gameId;
            const statusId = game.gameStatus;

            const g = {
                gameId: gameId,
                status: statusId,
                statusText: game.gameStatusText || '',
                broadcaster: getPrimaryBroadcaster(game.broadcasters),
                homeTeam: {
                    teamTricode: game.homeTeam?.teamTricode,
                    score: game.homeTeam?.score || 0,
                    leaders: []
                },
                awayTeam: {
                    teamTricode: game.awayTeam?.teamTricode,
                    score: game.awayTeam?.score || 0,
                    leaders: []
                },
                period: game.period || 0,
                gameTimeUTC: game.gameTimeUTC || '',
            };

            if (statusId === 2 || statusId === 3) {
                const leaders = await fetchGameLeaders(gameId);
                if (leaders) {
                    g.homeTeam.leaders = leaders.homeLeaders;
                    g.awayTeam.leaders = leaders.awayLeaders;
                }
            }

            return g;
        }));

        return formattedGames;
    } catch (e) {
        console.error(`Error fetching scores for ${targetDate}:`, e);
        return [];
    }
}

ipcMain.handle('fetch-nba-scores', async (event, dates) => {
    const dateArray = Array.isArray(dates) ? dates : [dates];
    const results = {};

    await Promise.all(dateArray.map(async (d) => {
        results[d] = await fetchSingleDate(d);
    }));

    return results;
});

ipcMain.handle('quit-app', () => {
    app.quit();
});
