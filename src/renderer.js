import './style.css';
console.log('Renderer script executing...');

let ipcRenderer;
try {
    ipcRenderer = window.require('electron').ipcRenderer;
    console.log('ipcRenderer acquired');
} catch (e) {
    console.error('Failed to require electron:', e);
}

const gameList = document.getElementById('game-list');
const quitBtn = document.getElementById('quit-btn');
const dateInputs = document.querySelectorAll('input[name="date-nav"]');

// Cache State
const expandedGames = new Set();
let gameCache = {}; // { 'YYYY-MM-DD': [games], ... }
let selectedDateValue = 'Today';
let isInitialLoading = true;

// Date formatting helper (Local Time)
function getFormattedDate(offset = 0) {
    const d = new Date();
    d.setDate(d.getDate() + offset);
    const year = d.getFullYear();
    const month = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
}

function getTargetDateString() {
    if (selectedDateValue === 'Yesterday') return getFormattedDate(-1);
    if (selectedDateValue === 'Tomorrow') return getFormattedDate(1);
    return getFormattedDate(0);
}

quitBtn.addEventListener('click', () => {
    ipcRenderer.invoke('quit-app');
});

dateInputs.forEach(input => {
    input.addEventListener('change', (e) => {
        if (e.target.checked) {
            selectedDateValue = e.target.value;
            console.log('Tab switched to:', selectedDateValue, 'Date string:', getTargetDateString());
            renderCurrentDate();
        }
    });
});

async function updateScores(fullRefresh = false) {
    try {
        const yesterday = getFormattedDate(-1);
        const today = getFormattedDate(0);
        const tomorrow = getFormattedDate(1);

        let datesToFetch = [];
        if (fullRefresh || isInitialLoading) {
            datesToFetch = [yesterday, today, tomorrow];
        } else {
            const current = getTargetDateString();
            datesToFetch = Array.from(new Set([current, today]));
        }

        console.log('Requesting dates:', datesToFetch);
        const results = await ipcRenderer.invoke('fetch-nba-scores', datesToFetch);

        if (results && typeof results === 'object') {
            console.log('Received results for:', Object.keys(results));
            Object.assign(gameCache, results);
        } else {
            console.error('Invalid results received:', results);
        }

        isInitialLoading = false;
        renderCurrentDate();
    } catch (error) {
        console.error('Failed to fetch scores:', error);
        isInitialLoading = false;
        if (Object.keys(gameCache).length === 0) {
            gameList.innerHTML = `<div class="p-4 text-center text-secondary text-xs">Failed to load scores. Check console for details.</div>`;
        }
    }
}

function renderCurrentDate() {
    const targetDate = getTargetDateString();
    const games = gameCache[targetDate] || [];
    console.log('Rendering games for', targetDate, 'count:', games.length);
    renderGames(games);
}

function getTeamLogo(tricode) {
    if (!tricode) return 'https://a.espncdn.com/i/teamlogos/nba/500/nba.png';

    // Some ESPN scoreboard filenames don't match the NBA tricode
    const mapping = {
        'UTA': 'utah',
        'NOP': 'no'
    };

    const filename = mapping[tricode] || tricode.toLowerCase();
    return `https://a.espncdn.com/i/teamlogos/nba/500/scoreboard/${filename}.png`;
}

function toggleGame(gameId) {
    if (expandedGames.has(gameId)) {
        expandedGames.delete(gameId);
    } else {
        expandedGames.add(gameId);
    }
    renderCurrentDate();
}

window.toggleGame = toggleGame;

function formatBroadcaster(name) {
    if (!name || name === 'LEAGUE PASS') return 'League Pass';
    const upper = name.toUpperCase();
    if (upper.includes('ESPN')) return 'ESPN';
    if (upper.includes('ABC')) return 'ABC';
    if (upper.includes('TNT')) return 'TNT';
    if (upper.includes('PRIME')) return 'Prime Video';
    if (upper.includes('NBC')) return 'NBC';
    if (upper.includes('PEACOCK')) return 'Peacock';
    return name;
}

function renderGames(games) {
    if (isInitialLoading && (!games || games.length === 0)) {
        gameList.innerHTML = `<div class="p-8 flex flex-col items-center justify-center gap-3">
            <div class="h-6 w-6 border-2 border-primary border-t-transparent rounded-full animate-spin"></div>
            <span class="text-[11px] font-medium text-white/40 uppercase tracking-widest">Loading Games</span>
        </div>`;
        return;
    }

    if (!games || games.length === 0) {
        gameList.innerHTML = `<div class="p-12 text-center flex flex-col items-center justify-center">
            <span class="material-symbols-outlined text-[40px] text-white/5 mb-4">sports_basketball</span>
            <div class="text-[11px] font-bold text-white/20 uppercase tracking-widest leading-loose">
                No games scheduled<br/>for ${selectedDateValue}
            </div>
            <div class="text-[9px] text-white/10 mt-1">${getTargetDateString()}</div>
        </div>`;
        return;
    }

    const liveGames = games.filter(g => g.status === 2);
    const finishedGames = games.filter(g => g.status === 3);
    const upcomingGames = games.filter(g => g.status === 1);

    let html = '';

    if (liveGames.length > 0) {
        html += `
        <div class="pt-3 pb-1">
            <div class="px-4 pb-2 flex items-center justify-between">
                <div class="flex items-center gap-2">
                    <h2 class="text-[11px] font-semibold text-secondary uppercase tracking-wider">Live Games</h2>
                    <span class="relative flex h-2 w-2">
                        <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-danger opacity-75"></span>
                        <span class="relative inline-flex rounded-full h-2 w-2 bg-danger"></span>
                    </span>
                </div>
            </div>
            ${liveGames.map(renderLiveGame).join('')}
        </div>`;
    }

    if (upcomingGames.length > 0) {
        html += `
        <div class="pt-2">
            <h2 class="px-4 pb-2 text-[11px] font-semibold text-secondary uppercase tracking-wider">Upcoming</h2>
            <div class="mx-3 mb-2 space-y-1">
                ${upcomingGames.map(renderFinishedOrUpcomingGame).join('')}
            </div>
        </div>`;
    }

    if (finishedGames.length > 0) {
        html += `
        <div class="pt-2">
            <h2 class="px-4 pb-2 text-[11px] font-semibold text-secondary uppercase tracking-wider">Finished</h2>
            <div class="mx-3 mb-2 space-y-1">
                ${finishedGames.map(renderFinishedOrUpcomingGame).join('')}
            </div>
        </div>`;
    }

    gameList.innerHTML = html;
}

function renderLeaders(team, leaders) {
    if (!leaders || leaders.length === 0) return '';

    return `
    <div class="pt-3">
        <h4 class="text-[10px] uppercase font-bold text-white/40 tracking-wider mb-2">${team} leaders</h4>
        <div class="space-y-0.5">
            ${leaders.map(player => `
                <div class="flex items-center justify-between py-1.5 px-2 rounded-lg hover:bg-white/5 transition-colors group/player">
                    <div class="flex items-center gap-2">
                        <div class="w-6 h-6 rounded-full bg-white/10 flex items-center justify-center text-white/50 text-[10px] overflow-hidden">
                            ${player.nameI ? player.nameI.split('.').pop().trim().substring(0, 3).toUpperCase() : 'NBA'}
                        </div>
                        <div class="flex flex-col">
                            <span class="text-[11px] font-medium text-white group-hover/player:text-primary transition-colors">${player.name}</span>
                            <span class="text-[9px] text-white/40">${player.position || 'Player'}</span>
                        </div>
                    </div>
                    <div class="flex items-center gap-3">
                        <div class="flex flex-col items-end w-6">
                            <span class="text-[11px] font-bold text-white tabular-nums">${player.points || 0}</span>
                            <span class="text-[8px] text-white/30 uppercase">Pts</span>
                        </div>
                        <div class="flex flex-col items-end w-6">
                            <span class="text-[11px] font-medium text-white/70 tabular-nums">${player.rebounds || 0}</span>
                            <span class="text-[8px] text-white/30 uppercase">Reb</span>
                        </div>
                        <div class="flex flex-col items-end w-6">
                            <span class="text-[11px] font-medium text-white/70 tabular-nums">${player.assists || 0}</span>
                            <span class="text-[8px] text-white/30 uppercase">Ast</span>
                        </div>
                    </div>
                </div>
            `).join('')}
        </div>
    </div>`;
}

function renderLiveGame(game) {
    const isExpanded = expandedGames.has(game.gameId);
    const broadcaster = formatBroadcaster(game.broadcaster);
    return `
    <div class="mx-3 mb-3 bg-card-bg hover:bg-card-hover border border-white/5 rounded-xl overflow-hidden shadow-sm transition-colors group">
        <div class="flex justify-between items-center px-3 py-2 border-b border-white/5 bg-white/[0.02]" onclick="toggleGame('${game.gameId}')">
            <div class="flex items-center gap-2.5">
                <span class="text-[11px] font-bold text-danger flex items-center gap-1">${game.statusText}</span>
                <span class="px-1.5 py-0.5 bg-white/10 rounded text-[9px] font-black text-white uppercase tracking-tight shadow-sm">${broadcaster}</span>
            </div>
            <span class="material-symbols-outlined text-[16px] text-white/30 transition-transform ${isExpanded ? 'rotate-180' : ''}">expand_more</span>
        </div>
        <div class="flex items-stretch h-16 relative" onclick="toggleGame('${game.gameId}')">
            ${isExpanded ? '' : `<div class="absolute bottom-0 left-0 w-1/2 h-[2px] bg-primary shadow-[0_0_10px_rgba(10,132,255,0.6)] z-10"></div>`}
            <div class="flex-1 flex flex-col items-center justify-center bg-white/5 cursor-pointer hover:bg-white/10 transition-colors">
                <div class="flex items-center gap-2">
                    <span class="text-white font-bold text-base tracking-tight">${game.homeTeam.teamTricode || 'TBD'}</span>
                    <span class="text-xl font-bold text-white tabular-nums">${game.homeTeam.score || 0}</span>
                </div>
                <img src="${getTeamLogo(game.homeTeam.teamTricode)}" class="h-5 w-5 mt-0.5" />
            </div>
            <div class="w-px bg-white/5"></div>
            <div class="flex-1 flex flex-col items-center justify-center cursor-pointer hover:bg-white/5 transition-colors">
                <div class="flex items-center gap-2">
                    <span class="text-white font-bold text-base tracking-tight">${game.awayTeam.teamTricode || 'TBD'}</span>
                    <span class="text-xl font-bold text-white tabular-nums">${game.awayTeam.score || 0}</span>
                </div>
                <img src="${getTeamLogo(game.awayTeam.teamTricode)}" class="h-5 w-5 mt-0.5" />
            </div>
        </div>
        ${isExpanded ? `
            <div class="bg-[#1c1c1e] p-3 border-t border-white/5 shadow-inner">
                ${renderLeaders(game.homeTeam.teamTricode, game.homeTeam.leaders)}
                <div class="my-2 border-t border-white/5"></div>
                ${renderLeaders(game.awayTeam.teamTricode, game.awayTeam.leaders)}
            </div>
        ` : ''}
    </div>`;
}

function renderFinishedOrUpcomingGame(game) {
    const isFinished = game.status === 3;
    const isUpcoming = game.status === 1;
    const isExpanded = expandedGames.has(game.gameId);
    const broadcaster = formatBroadcaster(game.broadcaster);

    return `
    <div class="bg-card-bg hover:bg-card-hover rounded-xl overflow-hidden transition-colors group border border-transparent hover:border-white/5 mb-1">
        <div class="px-3 py-2.5 flex justify-between items-center cursor-pointer" onclick="toggleGame('${game.gameId}')">
            <div class="flex flex-col gap-1 w-full">
                <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2">
                        <img src="${getTeamLogo(game.homeTeam.teamTricode)}" class="h-5 w-5" />
                        <span class="text-[13px] font-medium text-white">${game.homeTeam.teamTricode || 'TBD'}</span>
                        <span class="text-[13px] ${isFinished ? 'font-bold' : 'font-medium opacity-50'} text-white tabular-nums">${game.homeTeam.score || '0'}</span>
                    </div>
                    ${isUpcoming ? `
                        <div class="flex flex-col items-end gap-1">
                            <span class="text-[10px] text-secondary font-medium">${game.statusText}</span>
                            <span class="px-1 py-0.5 bg-white/10 rounded-[4px] text-[8px] text-white font-black uppercase tracking-tighter shadow-sm">${broadcaster}</span>
                        </div>
                    ` : ''}
                </div>
                <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2">
                        <img src="${getTeamLogo(game.awayTeam.teamTricode)}" class="h-5 w-5" />
                        <span class="text-[13px] font-medium text-white">${game.awayTeam.teamTricode || 'TBD'}</span>
                        <span class="text-[13px] ${isFinished ? 'font-bold' : 'font-medium opacity-50'} text-white tabular-nums">${game.awayTeam.score || '0'}</span>
                    </div>
                    ${!isUpcoming && !isFinished ? `<span class="text-[10px] text-secondary font-medium">${game.statusText}</span>` : ''}
                    ${isFinished ? `<span class="text-[10px] text-secondary font-bold uppercase">Final</span>` : ''}
                </div>
            </div>
            ${isFinished ? `<span class="material-symbols-outlined text-[16px] text-white/20 ml-2 transition-transform ${isExpanded ? 'rotate-180' : ''}">expand_more</span>` : ''}
        </div>
        ${isExpanded && isFinished ? `
            <div class="bg-[#1c1c1e] p-3 border-t border-white/5 shadow-inner">
                ${renderLeaders(game.homeTeam.teamTricode, game.homeTeam.leaders)}
                <div class="my-2 border-t border-white/5"></div>
                ${renderLeaders(game.awayTeam.teamTricode, game.awayTeam.leaders)}
            </div>
        ` : ''}
    </div>`;
}

// Initial fetch
updateScores();

// Update every minute (mainly for "Today")
setInterval(() => updateScores(false), 60000);
// Full refresh of neighboring dates every 10 minutes
setInterval(() => updateScores(true), 600000);
