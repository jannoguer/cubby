// js_content handler for directory URIs: an "Index of" page without symlinks or dotfiles.
import fs from 'fs';

const ROOT = '/shared';
// Breadcrumb links keep the plain heading look. Columns after the name are styled by position, so rows carry no attributes.
const STYLE = ':root{color-scheme:light dark}body{margin:8px 24px}h1 a{color:inherit;text-decoration:none}'
    + 'table{width:100%}th,td{padding:4px}th{position:sticky;top:0;background:Canvas}th:first-child{text-align:left}'
    + 'th,td:nth-child(n+2){white-space:nowrap}td:nth-child(n+2){text-align:center}'
    + '@media (max-width:600px){th:nth-child(2),td:nth-child(2){display:none}}';

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

function plural(n, word) {
    return `${n} ${word}${n === 1 ? '' : 's'}`;
}

// "Index of /a/b/" as links "Index of /", "a/", "b/", so every slash belongs to a link and the root is easy to hit.
// Relative, so any proxy prefix works. Out of the Tab order: keyboard users go up with the ../ row.
function crumbs(parts) {
    const link = (up, text) => `<a href="${'../'.repeat(up) || './'}" tabindex="-1">${text}</a>`;
    return link(parts.length, 'Index of /') + parts.map((p, i) => link(parts.length - 1 - i, escape(p) + '/')).join('');
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
    let dirs = 0;
    let files = 0;
    let bytes = 0;
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
        if (key[0] === '0') {
            dirs++;
            rows.push(`<tr><td><a href="${href}/">${escape(name)}/</a></td><td>${date(stat.mtimeMs)}</td><td>-</td><td></td></tr>\n`);
        } else {
            files++;
            bytes += stat.size;
            rows.push(`<tr><td><a href="${href}">${escape(name)}</a></td><td>${date(stat.mtimeMs)}</td>`
                + `<td>${size(stat.size)}</td><td><a href="${href}?download=1">download</a></td></tr>\n`);
        }
    }
    const summary = dirs + files ? `${plural(dirs, 'folder')}, ${plural(files, 'file')}, ${size(bytes)}` : 'Empty folder';
    r.headersOut['Content-Type'] = 'text/html; charset=utf-8';
    r.return(200, `<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${title}</title>
<style>${STYLE}</style></head>
<body><h1>${crumbs(parts)}</h1>
<table>
<tr><th>Name</th><th width="165">Last modified (UTC)</th><th width="75">Size</th><th width="90"></th></tr>
${rows.join('')}</table>
<p>${summary}</p>
</body></html>
`);
}

export default { render };
