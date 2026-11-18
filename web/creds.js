// "creds.js init" writes /data/credentials; "creds.js show" prints them. Run with the njs CLI.
import fs from 'fs';
import { base32 } from './totp.js';

const FILE = '/data/credentials';

function init() {
    const words = fs.readFileSync('/web/english.txt', 'utf8').split('\n').filter(w => w !== '');
    if (words.length !== 2048) {
        throw new Error('/web/english.txt must hold 2048 words, found ' + words.length);
    }
    // 65536 is a multiple of 2048, so masking the draw adds no bias.
    const draw = new Uint16Array(4);
    globalThis.crypto.getRandomValues(draw);
    const password = Array.from(draw, n => words[n & 2047]).join('-');
    const raw = new Uint8Array(20);
    globalThis.crypto.getRandomValues(raw);
    fs.writeFileSync(FILE + '.tmp', JSON.stringify({ password, seed: base32(raw) }), { mode: 0o600 });
    fs.renameSync(FILE + '.tmp', FILE);
}

function show() {
    const { password, seed } = JSON.parse(fs.readFileSync(FILE, 'utf8'));
    console.log('password: ' + password);
    console.log('seed: ' + seed.match(/.{4}/g).join(' '));
    console.log('otpauth://totp/Cubby?secret=' + seed + '&issuer=Cubby');
    console.log('');
    console.log('login: password then the 6-digit code, no space, e.g. ' + password + '492817');
}

const command = process.argv[2];
if (command === 'init') {
    init();
} else if (command === 'show') {
    show();
} else {
    throw new Error('usage: creds.js init|show');
}
