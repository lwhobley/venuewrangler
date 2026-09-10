#!/usr/bin/env node
/**
 * npm audit gate with explicit, documented exemptions.
 *
 * `npm audit` has no per-advisory exclude flag, so an advisory with no
 * available fix turns the whole gate permanently red — and a permanently red
 * gate is one nobody reads. It also hides the steps that run after it: while
 * the multer advisories were unhandled, the API job never reached its
 * "Verify the patched Prisma config override remains compatible" step at all.
 *
 * This wraps `npm audit --json` instead. Any high/critical advisory that is
 * not listed in ALLOWED below fails the build exactly as before. Listed ones
 * are reported and skipped.
 *
 * An exemption that no longer matches anything in the tree also fails, so a
 * stale entry cannot outlive the advisory it was granted for — when the
 * upstream fix lands, CI tells you to delete the entry rather than letting it
 * quietly keep a future regression suppressed.
 *
 * Usage: node scripts/audit-gate.mjs [...npm audit args]
 */
import { spawnSync } from 'node:child_process';

// No accepted advisories. Multer is patched through a scoped root override.
const ALLOWED = [];
const MULTIPART_MARKERS = /FileInterceptor|FilesInterceptor|@UploadedFiles?\b|MulterModule/;

// Windows cannot spawn npm's .cmd shim directly, and `shell: true` with an
// args array is deprecated (DEP0190, unescaped concatenation). Route through
// cmd.exe explicitly there and spawn normally everywhere else.
function run(command, args) {
  const [file, argv] = process.platform === 'win32'
    ? ['cmd.exe', ['/d', '/s', '/c', command, ...args]]
    : [command, args];
  return spawnSync(file, argv, { encoding: 'utf8', shell: false, maxBuffer: 64 * 1024 * 1024 });
}

const BLOCKING = new Set(['high', 'critical']);
const auditArgs = process.argv.slice(2);

const result = run('npm', ['audit', '--json', ...auditArgs]);

if (!result.stdout) {
  console.error('audit-gate: npm audit produced no output.');
  console.error(result.stderr || '(no stderr)');
  process.exit(1);
}

let report;
try {
  report = JSON.parse(result.stdout);
} catch (error) {
  console.error(`audit-gate: could not parse npm audit output: ${error.message}`);
  process.exit(1);
}

// Collect concrete advisories. Indirect entries (a package whose `via` is just
// another package name) contribute no advisory of their own and resolve
// automatically once the real source is handled.
const found = new Map();
for (const vuln of Object.values(report.vulnerabilities ?? {})) {
  for (const via of vuln.via ?? []) {
    if (typeof via !== 'object' || !via.url) continue;
    const id = via.url.split('/').pop();
    if (!BLOCKING.has(via.severity)) continue;
    if (!found.has(id)) found.set(id, { id, package: via.name, title: via.title, severity: via.severity });
  }
}

const allowedById = new Map(ALLOWED.map((entry) => [entry.id, entry]));
const unexpected = [...found.values()].filter((advisory) => !allowedById.has(advisory.id));
const stale = ALLOWED.filter((entry) => !found.has(entry.id));

for (const advisory of found.values()) {
  if (!allowedById.has(advisory.id)) continue;
  console.log(`accepted  ${advisory.severity.padEnd(8)} ${advisory.package} — ${advisory.id}`);
  console.log(`          ${allowedById.get(advisory.id).reason}`);
}

// An exemption is only valid while the code that makes it unreachable holds.
if (found.size > 0 && [...found.values()].some((a) => a.package === 'multer')) {
  const grep = run('git', ['grep', '-lE', MULTIPART_MARKERS.source, '--', 'packages/api/src']);
  const hits = (grep.stdout || '').split('\n').filter(Boolean).filter((f) => !f.endsWith('.spec.ts'));
  if (hits.length > 0) {
    console.error('\naudit-gate: the multer exemption assumed no route parses multipart, but found:');
    hits.forEach((f) => console.error(`  - ${f}`));
    console.error('The advisories are now reachable. Remove the exemption and address them.');
    process.exit(1);
  }
}

if (stale.length > 0) {
  console.error('\naudit-gate: these exemptions no longer match any advisory in the tree:');
  for (const entry of stale) {
    console.error(`  - ${entry.id} (${entry.package}) — expected removable when: ${entry.removeWhen}`);
  }
  console.error('The upstream fix has probably landed. Delete these entries from scripts/audit-gate.mjs.');
  process.exit(1);
}

if (unexpected.length > 0) {
  console.error(`\naudit-gate: ${unexpected.length} unexempted high/critical advisor${unexpected.length === 1 ? 'y' : 'ies'}:`);
  for (const advisory of unexpected) {
    console.error(`  - ${advisory.severity} ${advisory.package}: ${advisory.title} (${advisory.id})`);
  }
  console.error('\nFix it, or add a documented exemption to scripts/audit-gate.mjs in the same commit.');
  process.exit(1);
}

console.log(`\naudit-gate: no unexempted high/critical advisories (${found.size} accepted).`);
