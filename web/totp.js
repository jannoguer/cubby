// RFC 6238 TOTP (HMAC-SHA1) and RFC 4648 base32, shared by auth.js and creds.js.
import crypto from 'crypto';

const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function base32(bytes) {
    let out = '';
    let acc = 0;
    let bits = 0;
    for (const b of bytes) {
        acc = ((acc << 8) | b) & 0xfff;
        bits += 8;
        while (bits >= 5) {
            out += ALPHABET[(acc >>> (bits - 5)) & 31];
            bits -= 5;
        }
    }
    if (bits > 0) {
        out += ALPHABET[(acc << (5 - bits)) & 31];
    }
    return out;
}

function unbase32(text) {
    const bytes = [];
    let acc = 0;
    let bits = 0;
    for (const ch of text) {
        acc = ((acc << 5) | ALPHABET.indexOf(ch)) & 0xfff;
        bits += 5;
        if (bits >= 8) {
            bytes.push((acc >>> (bits - 8)) & 255);
            bits -= 8;
        }
    }
    return Buffer.from(bytes);
}

// The code for 30 s step number `counter`, as a zero-padded string of `digits` digits.
export function hotp(seed, counter, digits) {
    const msg = Buffer.alloc(8);
    msg.writeUInt32BE(Math.floor(counter / 4294967296), 0);
    msg.writeUInt32BE(counter % 4294967296, 4);
    const mac = crypto.createHmac('sha1', unbase32(seed)).update(msg).digest();
    const off = mac[mac.length - 1] & 15;
    const bin = ((mac[off] & 0x7f) << 24) | (mac[off + 1] << 16) | (mac[off + 2] << 8) | mac[off + 3];
    return String(bin % Math.pow(10, digits)).padStart(digits, '0');
}

// The code at unix time `seconds`.
export function totp(seed, seconds, digits) {
    return hotp(seed, Math.floor(seconds / 30), digits);
}
