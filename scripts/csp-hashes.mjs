#!/usr/bin/env node
/**
 * Inline-script CSP hashes for the static marketing/join site.
 *
 * site/_headers sets `script-src 'self' 'sha256-...'` instead of 'unsafe-inline'. Every
 * executable inline <script> in site/**\/*.html (except the Flutter bundle under site/app)
 * therefore has to be listed by hash. If a page's script changes and the header does not, the
 * script is blocked in production; if the header lists a hash no page uses, it is dead weight.
 * Both directions fail `npm test` (tests/site-csp.spec.ts) and `npm run build:site`.
 *
 * Usage:
 *   node scripts/csp-hashes.mjs          print the hashes the pages currently need
 *   node scripts/csp-hashes.mjs --write  rewrite the script-src hashes in site/_headers
 *
 * Line endings are normalised to LF before hashing: the browser hashes the bytes it receives,
 * and Cloudflare deploys from a Linux checkout, so a CRLF working copy on Windows must not
 * produce different hashes. (.gitattributes pins site HTML to LF as well.)
 */
import { createHash } from 'node:crypto';
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

// Script types that are NOT executed (data blocks such as JSON-LD) and so need no hash.
const EXECUTABLE_TYPES = new Set(['', 'module', 'text/javascript', 'application/javascript']);

export function listHtml(dir = join(root, 'site'), base = dir) {
  const files = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      // site/app is the generated Flutter bundle and has its own CSP (site/_worker.js).
      if (full === join(base, 'app') || entry.name === 'node_modules') continue;
      files.push(...listHtml(full, base));
    } else if (entry.name.endsWith('.html')) {
      files.push(full);
    }
  }
  return files;
}

/** @returns {{file: string, hash: string}[]} one entry per executable inline script. */
export function collectInlineScripts(siteDir = join(root, 'site')) {
  const found = [];
  for (const file of listHtml(siteDir)) {
    const html = readFileSync(file, 'utf8');
    for (const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi)) {
      const attrs = match[1];
      if (/\bsrc\s*=/i.test(attrs)) continue;
      const type = (/\btype\s*=\s*["']?([^"'\s>]*)/i.exec(attrs)?.[1] ?? '').toLowerCase();
      if (!EXECUTABLE_TYPES.has(type)) continue;
      const body = match[2].replace(/\r\n/g, '\n');
      const hash = `sha256-${createHash('sha256').update(body, 'utf8').digest('base64')}`;
      found.push({ file: relative(siteDir, file).split(sep).join('/'), hash });
    }
  }
  return found;
}

/** The sha256 sources listed in the script-src directive of the `/*` block of site/_headers. */
export function headerScriptSrc(headersText) {
  const csp = /^\s*Content-Security-Policy:\s*(.+)$/m.exec(headersText)?.[1] ?? '';
  const directive = csp.split(';').map((d) => d.trim()).find((d) => d.startsWith('script-src ')) ?? '';
  return {
    csp,
    directive,
    hashes: [...directive.matchAll(/'(sha256-[A-Za-z0-9+/=]+)'/g)].map((m) => m[1]),
  };
}

export function checkHeaderHashes(siteDir = join(root, 'site')) {
  const headersText = readFileSync(join(siteDir, '_headers'), 'utf8');
  const { directive, hashes } = headerScriptSrc(headersText);
  const needed = new Set(collectInlineScripts(siteDir).map((s) => s.hash));
  const listed = new Set(hashes);
  return {
    directive,
    missing: [...needed].filter((h) => !listed.has(h)),
    stale: [...listed].filter((h) => !needed.has(h)),
    unsafeInline: /'unsafe-inline'/.test(directive),
  };
}

function rewriteHeaders(siteDir = join(root, 'site')) {
  const path = join(siteDir, '_headers');
  const text = readFileSync(path, 'utf8');
  const needed = [...new Set(collectInlineScripts(siteDir).map((s) => s.hash))].sort();
  const sources = ["'self'", ...needed.map((h) => `'${h}'`)].join(' ');
  // Only touch the Content-Security-Policy line, never the explanatory comments above it.
  const next = text.replace(
    /^(\s*Content-Security-Policy:.*?)script-src [^;]+;/m,
    (_, before) => `${before}script-src ${sources};`,
  );
  writeFileSync(path, next);
  return needed;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.includes('--write')) {
    for (const h of rewriteHeaders()) console.log(`'${h}'`);
    console.log('site/_headers updated.');
  } else {
    for (const { file, hash } of collectInlineScripts()) console.log(`${hash}  ${file}`);
  }
}
