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

quitBtn.addEventListener('click', () => {
    ipcRenderer.invoke('quit-app');
});

async function updateScores() {
    try {
        const games = await ipcRenderer.invoke('fetch-nba-scores');
        renderGames(games);
    } catch (error) {
        console.error('Failed to fetch scores:', error);
        gameList.innerHTML = `<div class="p-4 text-center text-secondary text-xs">Failed to load scores.</div>`;
    }
}

function renderGames(games) {
    if (!games || games.length === 0) {
        gameList.innerHTML = `<div class="p-4 text-center text-secondary text-xs">No games today.</div>`;
        return;
    }

    const liveGames = games.filter(g => g.status === 2);
    const finishedGames = games.filter(g => g.status === 3);
    const upcomingGames = games.filter(g => g.status === 1);

    let html = '';

    if (liveGames.length > 0) {
        html += `
        <div class="pt-3 pb-1">
            <div class="px-4 pb-2 flex items-center gap-2">
                <h2 class="text-[11px] font-semibold text-secondary uppercase tracking-wider">Live Games</h2>
                <span class="relative flex h-2 w-2">
                    <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-danger opacity-75"></span>
                    <span class="relative inline-flex rounded-full h-2 w-2 bg-danger"></span>
                </span>
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

function renderLiveGame(game) {
    return `
    <div class="mx-3 mb-3 bg-card-bg hover:bg-card-hover border border-white/5 rounded-xl overflow-hidden shadow-sm transition-colors group">
        <div class="flex justify-between items-center px-3 py-2 border-b border-white/5 bg-white/[0.02]">
            <span class="text-[11px] font-bold text-danger flex items-center gap-1">${game.statusText}</span>
        </div>
        <div class="flex items-stretch h-16 relative">
            <div class="flex-1 flex flex-col items-center justify-center bg-white/5 cursor-pointer hover:bg-white/10 transition-colors">
                <div class="flex items-center gap-2">
                    <span class="text-white font-bold text-base tracking-tight">${game.homeTeam.teamTricode}</span>
                    <span class="text-xl font-bold text-white tabular-nums">${game.homeTeam.score}</span>
                </div>
            </div>
            <div class="w-px bg-white/5"></div>
            <div class="flex-1 flex flex-col items-center justify-center cursor-pointer hover:bg-white/5 transition-colors">
                <div class="flex items-center gap-2">
                    <span class="text-white font-bold text-base tracking-tight">${game.awayTeam.teamTricode}</span>
                    <span class="text-xl font-bold text-white tabular-nums">${game.awayTeam.score}</span>
                </div>
            </div>
        </div>
    </div>`;
}

function renderFinishedOrUpcomingGame(game) {
    const isFinished = game.status === 3;
    return `
    <div class="bg-card-bg hover:bg-card-hover rounded-xl px-3 py-2.5 flex justify-between items-center cursor-pointer transition-colors group border border-transparent hover:border-white/5">
        <div class="flex flex-col gap-1 w-full">
            <div class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                    <span class="text-[13px] font-medium text-white">${game.homeTeam.teamTricode}</span>
                    <span class="text-[13px] ${isFinished ? 'font-bold' : 'font-medium opacity-50'} text-white tabular-nums">${game.homeTeam.score}</span>
                </div>
                ${!isFinished ? `<span class="text-[10px] text-secondary font-medium">${game.statusText}</span>` : ''}
            </div>
            <div class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                    <span class="text-[13px] font-medium text-white">${game.awayTeam.teamTricode}</span>
                    <span class="text-[13px] ${isFinished ? 'font-bold' : 'font-medium opacity-50'} text-white tabular-nums">${game.awayTeam.score}</span>
                </div>
            </div>
        </div>
    </div>`;
}

// Initial fetch
updateScores();

// Update every minute
setInterval(updateScores, 60000);
