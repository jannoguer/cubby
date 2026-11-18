// js_access handler: Basic auth whose password field is "<four words><6-digit TOTP code>".
import fs from 'fs';
import crypto from 'crypto';
import { hotp } from './totp.js';

const FAIL_LIMIT = 3;
const BLOCK_SECONDS = 3600;
const LOGIN_MS = 15 * 60 * 1000;

// Compares without stopping at the first difference.
function equal(a, b) {
    let diff = 0;
    const n = Math.max(a.length, b.length);
    for (let i = 0; i < n; i++) {
        diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
    }
    return a.length === b.length && diff === 0;
}

function reply(r, status, text) {
    r.headersOut['Content-Type'] = 'text/plain';
    r.return(status, text + '\n');
}

function challenge(r) {
    r.headersOut['WWW-Authenticate'] = 'Basic realm="cubby", charset="UTF-8"';
    reply(r, 401, 'Unauthorized');
}

function blocked(r) {
    r.headersOut['Retry-After'] = String(BLOCK_SECONDS);
    reply(r, 429, 'Too many failed attempts');
}

// The expected password and code against the header's; the counter that matched, or -1.
function verify(header) {
    const basic = /^Basic +([A-Za-z0-9+/=]+)$/i.exec(header);
    const decoded = basic ? Buffer.from(basic[1], 'base64').toString() : '';
    const secret = decoded.slice(decoded.indexOf(':') + 1).toLowerCase();
    const password = secret.slice(0, -6);
    const code = secret.slice(-6);
    const creds = JSON.parse(fs.readFileSync('/data/credentials', 'utf8'));
    const now = Math.floor(Date.now() / 30000);
    let counter = -1;
    for (let c = now - 1; c <= now + 1; c++) {
        if (equal(hotp(creds.seed, c, 6), code)) {
            counter = c;
        }
    }
    const passwordOk = equal(password, creds.password);
    return passwordOk ? counter : -1;
}

function check(r) {
    const ip = r.remoteAddress;
    const shared = ngx.shared;
    if (shared.blocked.get(ip) !== undefined) {
        return blocked(r);
    }
    const header = r.headersIn.Authorization;
    if (!header) {
        return challenge(r);
    }
    const key = crypto.createHash('sha256').update(ip + '\n' + header).digest('hex');
    const until = shared.logins.get(key);
    if (until !== undefined) {
        return Date.now() < until ? undefined : challenge(r);
    }
    const counter = verify(header);
    if (counter >= 0 && shared.used.get(String(counter)) === undefined) {
        shared.used.set(String(counter), 1);
        shared.logins.set(key, Date.now() + LOGIN_MS);
        shared.fails.delete(ip);
        return undefined;
    }
    // get and set, not incr: njs 1.0.1 incr resumes the old count of an expired entry.
    const fails = (shared.fails.get(ip) || 0) + 1;
    shared.fails.set(ip, fails);
    if (fails >= FAIL_LIMIT) {
        shared.blocked.set(ip, 1);
        return blocked(r);
    }
    return challenge(r);
}

export default { check };
