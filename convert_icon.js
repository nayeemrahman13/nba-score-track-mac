import sharp from 'sharp';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const svgPath = path.join(__dirname, 'iconTemplate.svg');
const pngPath = path.join(__dirname, 'iconTemplate.png');

async function convert() {
    try {
        const svgBuffer = fs.readFileSync(svgPath);
        // We create a 22x22 PNG as required for macOS menu bar icons
        await sharp(svgBuffer)
            .resize(22, 22)
            .png()
            .toFile(pngPath);
        console.log('Successfully converted SVG to PNG for menu bar icon.');
    } catch (err) {
        console.error('Error converting SVG to PNG:', err);
        process.exit(1);
    }
}

convert();
