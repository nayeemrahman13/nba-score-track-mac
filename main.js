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

const mb = menubar({
    index: url,
    browserWindow: {
        width: 360,
        height: 600,
        transparent: true,
        frame: false,
        resizable: false,
        webPreferences: {
            nodeIntegration: true,
            contextIsolation: false,
        },
    },
    icon: path.join(__dirname, 'iconTemplate.png'), // Standard macOS menu bar icon template
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

ipcMain.handle('fetch-nba-scores', async (event, dates) => {
    return new Promise((resolve, reject) => {
        const pythonPath = path.join(__dirname, 'venv/bin/python3');
        const scriptPath = path.join(__dirname, 'src/python/fetch_scores.py');

        const dateArgs = Array.isArray(dates) ? dates.map(d => `"${d}"`).join(' ') : (dates ? `"${dates}"` : '');
        exec(`"${pythonPath}" "${scriptPath}" ${dateArgs}`, { maxBuffer: 1024 * 1024 * 10 }, (error, stdout, stderr) => {
            if (error) {
                console.error(`exec error: ${error}`);
                reject(error);
                return;
            }
            try {
                const data = JSON.parse(stdout);
                resolve(data);
            } catch (parseError) {
                console.error(`parse error: ${parseError}`);
                reject(parseError);
            }
        });
    });
});

ipcMain.handle('quit-app', () => {
    app.quit();
});
