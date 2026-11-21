// js_access handler: Basic auth with any username and CUBBY_WEB_PASSWORD; an empty password lets everyone in.
const PASSWORD = process.env.CUBBY_WEB_PASSWORD;

// Compares without stopping at the first difference.
function equal(a, b) {
    let diff = 0;
    const n = Math.max(a.length, b.length);
    for (let i = 0; i < n; i++) {
        diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
    }
    return a.length === b.length && diff === 0;
}

function check(r) {
    if (PASSWORD === '') {
        return undefined;
    }
    const basic = /^Basic +([A-Za-z0-9+/=]+)$/i.exec(r.headersIn.Authorization || '');
    const decoded = basic ? Buffer.from(basic[1], 'base64').toString() : '';
    const colon = decoded.indexOf(':');
    if (colon >= 0 && equal(decoded.slice(colon + 1), PASSWORD)) {
        return undefined;
    }
    r.headersOut['WWW-Authenticate'] = 'Basic realm="cubby", charset="UTF-8"';
    r.headersOut['Content-Type'] = 'text/plain';
    r.return(401, 'Unauthorized\n');
}

export default { check };
