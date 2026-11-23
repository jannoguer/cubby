// js_content handler for directory URIs: an "Index of" page without symlinks or dotfiles.
import fs from 'fs';

const ROOT = '/shared';

function escape(text) {
    return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function size(bytes) {
    const units = ['B', 'K', 'M', 'G', 'T'];
    let n = bytes;
    let i = 0;
    while (n >= 1024 && i < units.length - 1) {
        n /= 1024;
        i++;
    }
    return (i === 0 ? String(n) : n.toFixed(1)) + units[i];
}

function date(ms) {
    return new Date(ms).toISOString().slice(0, 16).replace('T', ' ');
}

function notFound(r) {
    r.headersOut['Content-Type'] = 'text/plain';
    r.return(404, 'Not found\n');
}

function render(r) {
    // disable_symlinks guards nginx's own file access only; fs here would follow a planted link out of /shared.
    const parts = r.uri.split('/').filter(p => p !== '');
    let dir = ROOT;
    for (const p of parts) {
        dir += '/' + p;
        let stat;
        try {
            stat = fs.lstatSync(dir);
        } catch {
            return notFound(r);
        }
        if (!stat.isDirectory()) {
            return notFound(r);
        }
    }

    // Sorted without a comparator, which is much faster in njs: '0' puts directories first, the key is
    // case-insensitive, and NUL sorts lowest and cannot occur in a name, so the real name follows it.
    const keys = [];
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        if (e.name.startsWith('.') || !(e.isDirectory() || e.isFile())) {
            continue;
        }
        keys.push((e.isDirectory() ? '0' : '1') + e.name.toLowerCase() + '\0' + e.name);
    }
    keys.sort();

    const title = escape('Index of ' + r.uri);
    // An array join: appending to one string takes seconds in njs at 200k rows.
    const rows = parts.length ? ['<tr><td><a href="../">../</a></td><td></td><td></td><td></td></tr>\n'] : [];
    for (const key of keys) {
        const name = key.slice(key.indexOf('\0') + 1);
        let stat;
        try {
            stat = fs.lstatSync(dir + '/' + name);
        } catch {
            // A name that is not valid UTF-8 comes back lossy and cannot be looked up; skip it, not the page.
            continue;
        }
        const href = encodeURIComponent(name);
        rows.push(key[0] === '0'
            ? `<tr><td><a href="${href}/">${escape(name)}/</a></td><td align="center" nowrap>${date(stat.mtimeMs)}</td><td align="center">-</td><td></td></tr>\n`
            : `<tr><td><a href="${href}">${escape(name)}</a></td><td align="center" nowrap>${date(stat.mtimeMs)}</td>`
                + `<td align="center" nowrap>${size(stat.size)}</td><td align="center"><a href="${href}?download=1">download</a></td></tr>\n`);
    }
    r.headersOut['Content-Type'] = 'text/html; charset=utf-8';
    r.return(200, `<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${title}</title></head>
<body leftmargin="24"><h1>${title}</h1>
<table width="100%" cellpadding="4">
<tr><th align="left">Name</th><th width="165" nowrap>Last modified (UTC)</th><th width="75">Size</th><th width="90"></th></tr>
${rows.join('')}</table>
</body></html>
`);
}

export default { render };
