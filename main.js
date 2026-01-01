import { menubar } from 'menubar';
import path from 'path';
import { fileURLToPath } from 'url';
import { app } from 'electron';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const isDev = !app.isPackaged;
const url = isDev
    ? 'http://localhost:3000'
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
