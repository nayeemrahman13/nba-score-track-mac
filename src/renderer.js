import './style.css';

const gameList = document.getElementById('game-list');

// Static data from mockup for initial render
const staticGames = `
<div class="pt-3 pb-1">
    <div class="px-4 pb-2 flex items-center gap-2">
        <h2 class="text-[11px] font-semibold text-secondary uppercase tracking-wider">Live Games</h2>
        <span class="relative flex h-2 w-2">
            <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-danger opacity-75"></span>
            <span class="relative inline-flex rounded-full h-2 w-2 bg-danger"></span>
        </span>
    </div>
    <div class="mx-3 mb-3 bg-card-bg hover:bg-card-hover border border-white/5 rounded-xl overflow-hidden shadow-sm transition-colors group">
        <div class="flex justify-between items-center px-3 py-2 border-b border-white/5 bg-white/[0.02]">
            <span class="text-[11px] font-bold text-danger flex items-center gap-1">Q4 2:00</span>
            <div class="flex items-center gap-1 px-1.5 py-0.5 rounded bg-white/10">
                <span class="material-symbols-outlined text-[10px] text-white/50">tv</span>
                <span class="text-[9px] font-medium text-white/70">TNT</span>
            </div>
        </div>
        <div class="flex items-stretch h-16 relative">
            <div class="absolute bottom-0 left-0 w-1/2 h-[2px] bg-primary shadow-[0_0_10px_rgba(10,132,255,0.6)] z-10"></div>
            <div class="flex-1 flex flex-col items-center justify-center bg-white/5 cursor-pointer hover:bg-white/10 transition-colors">
                <div class="flex items-center gap-2">
                    <span class="text-white font-bold text-base tracking-tight">LAL</span>
                    <span class="text-xl font-bold text-white tabular-nums">102</span>
                </div>
            </div>
            <div class="w-px bg-white/5"></div>
            <div class="flex-1 flex flex-col items-center justify-center cursor-pointer hover:bg-white/5 transition-colors opacity-60 hover:opacity-100">
                <div class="flex items-center gap-2">
                    <span class="text-white font-bold text-base tracking-tight">GSW</span>
                    <span class="text-xl font-bold text-white tabular-nums">98</span>
                </div>
            </div>
        </div>
    </div>
</div>

<div class="pt-2">
    <h2 class="px-4 pb-2 text-[11px] font-semibold text-secondary uppercase tracking-wider">Finished</h2>
    <div class="mx-3 mb-2 space-y-1">
        <div class="bg-card-bg hover:bg-card-hover rounded-xl px-3 py-2.5 flex justify-between items-center cursor-pointer transition-colors group border border-transparent hover:border-white/5">
            <div class="flex flex-col gap-1 w-full">
                <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2">
                        <span class="text-[13px] font-medium text-white">NYK</span>
                        <span class="text-[13px] font-bold text-white tabular-nums">110</span>
                    </div>
                </div>
                <div class="flex items-center justify-between opacity-50">
                    <div class="flex items-center gap-2">
                        <span class="text-[13px] font-medium text-white">PHI</span>
                        <span class="text-[13px] font-medium text-white tabular-nums">105</span>
                    </div>
                </div>
            </div>
        </div>
    </div>
</div>
`;

gameList.innerHTML = staticGames;
