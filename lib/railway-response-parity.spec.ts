import { readdirSync, readFileSync } from 'node:fs';
import { extname, join } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * Response-SHAPE parity between screens and the endpoints they call.
 *
 * railway-route-parity.spec.ts already proves every registry entry resolves to
 * a real (method, path) on a real controller. It says nothing about what comes
 * back. Two production bugs lived in exactly that gap:
 *
 *   - app/(tabs)/reports.tsx read seven fields off GET /v1/app/manager-insights,
 *     which returned three. Six manager KPIs rendered a confident `0` because
 *     `?? 0` swallowed the undefined.
 *   - The same screen read `payroll.totalHours` off GET /v1/payroll/summary,
 *     which nests everything under `totals`, rendering "undefinedh".
 *
 * Neither is catchable by the compiler: lib/railway-hooks.ts is type-erased by
 * design, so screens hand-write the response type or cast to `any`.
 *
 * This walks each screen's first-level property accesses on a query result and
 * asserts every one is a key the controller actually returns.
 */

const CLIENT_ROOTS = ['app', 'components'];
const API_ROOT = 'packages/api/src';
const HTTP_METHODS = ['Get', 'Post', 'Patch', 'Delete', 'Put'] as const;

/**
 * Routes whose response cannot be resolved to a single object literal — the
 * handler returns a mapped array, branches across several returns, or delegates
 * to a service. Listed explicitly so the blind spots are visible and countable
 * rather than silently skipped; shrink this list, never grow it.
 */
const UNANALYSABLE_ROUTES = new Set([
  'app.getDashboard',
  'app.getClockBoard',
  'app.getMyTimeClock',
  'app.getNotifications',
  'app.listVenueStaff',
  'app.listStaffOnboarding',
  'app.listStaffAuditLog',
  'app.listStaffRequests',
  'app.exportTimeEntriesCsv',
  'app.getMyVenueBilling',
  'app.getVenueJoinCode',
  'app.getMe',
  'staffAuth.listVenueRoles',
  'scheduling.listBlackouts',
  'scheduling.getManagerSchedule',
  'scheduling.getLaborForecast',
  'scheduling.listScheduleMemory',
  'scheduling.previewAutoSchedule',
  'scheduling.listScheduleTemplates',
  'scheduling.getMySchedule',
  'scheduling.getMyShiftSwaps',
  'scheduling.listShiftSwaps',
  'pos.getPosOverview',
  'pos.getSalesByServer',
  'pos.getTopMenuItems',
  'pos.getLaborSummary',
  'operations.getManagerDashboard',
  'operations.getDailyBrief',
  'operations.getCommandCenter',
  'operations.getCommandCenterEvent',
  'operations.listLogbook',
  'operations.getChecklist',
  'reservations.getReservationsPage',
  'reservations.exportReservationsCsv',
  'reservations.getCoverPacing',
  'reservations.guestAutofill',
  'reservations.listHolds',
  'payroll.exportPayrollCsv',
  'barInventory.getBarStock',
  'barInventory.listRecipes',
  'barInventory.getUsageVelocity',
  'barInventory.getItemMovements',
  'barInventory.exportStockCsv',
  'barInventory.exportMovementsCsv',
  'barInventory.getShrinkageReport',
  'barInventory.getPurchaseOrder',
  'barInventory.exportPurchaseOrderCsv',
  'barInventory.getCostHistory',
  'barInventory.getAgingReport',
  'barInventory.listPrepBoard',
  'cosmicInsights.getLatestInsights',
  'floor.getActiveFloorPlan',
  'floor.getFloorStats',
  'floorBinding.getActiveFloorPlan',
  'floorBinding.getUnassignedReservations',
  'floorBinding.getOpenWaitlist',
  'chat.listConversations',
  'chat.listDirectory',
  'chat.getMessages',
  'guests.listGuests',
  'guests.getGuestProfile',
  'crm.listLeads',
  'crm.listBeos',
  'crm.listContracts',
  'crm.getLead',
  'crm.getForecast',
  'crm.getSourceRoi',
  'crm.getStaleLeads',
  'crm.getLeadActivity',
  'crm.listTemplates',
  'reservationIntegrations.getReservationIntegrationOverview',
  'documents.list',
]);

/** Members that exist on every JS value, so an access proves nothing. */
const UNIVERSAL_MEMBERS = new Set([
  'length', 'map', 'filter', 'find', 'forEach', 'reduce', 'slice', 'some', 'every',
  'sort', 'flatMap', 'includes', 'indexOf', 'join', 'concat', 'at', 'toString',
  'then', 'catch', 'finally', 'valueOf', 'hasOwnProperty', 'constructor',
]);

describe('Railway response-shape parity', () => {
  it('only reads response fields the controller actually returns', () => {
    const routeSource = readFileSync('lib/railway-hooks.ts', 'utf8');
    const registry = extractQueryRoutes(routeSource);
    const controllerReturns = collectControllerReturnKeys();

    const violations: string[] = [];

    for (const file of CLIENT_ROOTS.flatMap((root) => sourceFiles(root))) {
      if (file.includes('.spec.')) continue;
      const source = readFileSync(file, 'utf8');
      for (const binding of extractQueryBindings(source)) {
        if (UNANALYSABLE_ROUTES.has(binding.routeKey)) continue;
        const entry = registry.get(binding.routeKey);
        if (!entry) continue; // route-existence is the other spec's job
        const returned = controllerReturns.get(`${entry.method} ${normalizeParams(entry.path)}`);
        if (!returned) continue;

        for (const property of readProperties(source, binding.identifier)) {
          if (UNIVERSAL_MEMBERS.has(property)) continue;
          if (returned.has(property)) continue;
          violations.push(
            `${file}: ${binding.identifier}.${property} — ` +
            `${binding.routeKey} returns { ${[...returned].sort().join(', ')} }`,
          );
        }
      }
    }

    expect(violations).toEqual([]);
  });

  it('keeps the unanalysable-route list honest', () => {
    const routeSource = readFileSync('lib/railway-hooks.ts', 'utf8');
    const registry = extractQueryRoutes(routeSource);
    // Every skipped route must still be a real registry entry, so a renamed or
    // deleted route cannot leave a stale exemption sitting here forever.
    const stale = [...UNANALYSABLE_ROUTES].filter((key) => !registry.has(key));
    expect(stale).toEqual([]);
  });

  it('resolves a return shape for every route not explicitly exempted', () => {
    // Without this, a route whose path template the extractor cannot parse just
    // disappears from the check above and the screen calling it goes unguarded
    // — a silent hole that looks exactly like a passing test.
    const routeSource = readFileSync('lib/railway-hooks.ts', 'utf8');
    const registry = extractQueryRoutes(routeSource);
    const controllerReturns = collectControllerReturnKeys();

    const unresolved = [...registry.entries()]
      .filter(([key]) => !UNANALYSABLE_ROUTES.has(key))
      .filter(([, entry]) => !controllerReturns.has(`${entry.method} ${normalizeParams(entry.path)}`))
      .map(([key, entry]) => `${key} -> ${entry.method} ${normalizeParams(entry.path)}`);

    expect(unresolved).toEqual([]);
  });
});

function sourceFiles(root: string): string[] {
  return readdirSync(root, { withFileTypes: true }).flatMap((entry) => {
    const path = join(root, entry.name);
    if (entry.isDirectory()) return sourceFiles(path);
    return ['.ts', '.tsx'].includes(extname(path)) ? [path] : [];
  });
}

function normalizeParams(path: string): string {
  return path.replace(/:[^/]+/g, ':param').replace(/\/$/, '') || '/';
}

/**
 * Text of the template literal opening at `` source[openIndex] === '`' ``.
 *
 * Backticks cannot be matched by toggling a flag: these route templates nest
 * (`` `/x${cond ? `?a=${v}` : ''}` ``), so an inner opening backtick would look
 * like the outer one closing. Track whether we are inside a `${…}` expression
 * to tell the two apart.
 */
function templateBody(source: string, openIndex: number): string {
  const stack: Array<'template' | 'expr'> = ['template'];
  for (let i = openIndex + 1; i < source.length; i += 1) {
    const char = source[i];
    if (char === '\\') { i += 1; continue; }
    const top = stack[stack.length - 1];
    if (char === '`') {
      if (top === 'template') {
        stack.pop();
        if (stack.length === 0) return source.slice(openIndex + 1, i);
      } else {
        stack.push('template');
      }
    } else if (char === '$' && source[i + 1] === '{' && top === 'template') {
      stack.push('expr');
      i += 1;
    } else if (char === '{' && top === 'expr') {
      stack.push('expr');
    } else if (char === '}' && top === 'expr') {
      stack.pop();
    }
  }
  return '';
}

/**
 * Reduce a route template to the static path the controller declares.
 *
 * Two kinds of `${...}` appear in the registry and they must be treated
 * differently. A path parameter (`${enc(args.leadId)}`) becomes `:param`; a
 * query-string builder (`${args.startDate ? `?startDate=...` : ''}`) is not part
 * of the path at all and everything from it onward is dropped. Getting this
 * wrong makes the route unresolvable, and an unresolvable route was silently
 * skipped — which is exactly how a shape mismatch would slip through.
 */
function templatePath(raw: string): string {
  let out = '';
  for (let i = 0; i < raw.length; i += 1) {
    if (raw[i] === '$' && raw[i + 1] === '{') {
      let depth = 0;
      let end = i;
      for (let j = i + 1; j < raw.length; j += 1) {
        if (raw[j] === '{') depth += 1;
        else if (raw[j] === '}') {
          depth -= 1;
          if (depth === 0) { end = j; break; }
        }
      }
      const inner = raw.slice(i + 2, end);
      // A builder that assembles `?key=value` contributes a query string, not a
      // path segment — the path ends here.
      if (inner.includes('?') && inner.includes('=')) return out.split('?')[0];
      out += ':param';
      i = end;
      continue;
    }
    out += raw[i];
  }
  return out.split('?')[0];
}

type RouteEntry = { path: string; method: string };

/** Query routes only — mutation responses are rarely destructured by screens. */
function extractQueryRoutes(source: string): Map<string, RouteEntry> {
  const entries = new Map<string, RouteEntry>();
  const start = source.indexOf('const queryRoutes');
  const end = source.indexOf('const mutationRoutes');
  if (start < 0 || end < 0) throw new Error('Could not locate queryRoutes in lib/railway-hooks.ts');
  const block = source.slice(start, end);

  const keyPattern = /'([A-Za-z0-9_]+\.[A-Za-z0-9_]+)'\s*:\s*\{/g;
  let match: RegExpExecArray | null;
  while ((match = keyPattern.exec(block))) {
    const body = braceBody(block, keyPattern.lastIndex - 1);
    const literal = body.match(/path:\s*'([^']*)'/);
    const template = literal ? null : body.match(/path:\s*\(args[^)]*\)\s*=>\s*`/);
    let raw: string;
    if (literal) {
      raw = literal[1];
    } else if (template) {
      raw = templateBody(body, body.indexOf('`', template.index!));
    } else {
      continue;
    }
    const methodMatch = body.match(/method:\s*'(GET|POST|PATCH|DELETE|PUT)'/);
    entries.set(match[1], { path: templatePath(raw), method: methodMatch?.[1] ?? 'GET' });
  }
  return entries;
}

/**
 * Map "METHOD /normalized/path" -> the set of top-level keys of the single
 * object literal the handler returns. Handlers with zero or several literal
 * returns are omitted, which is what UNANALYSABLE_ROUTES documents.
 */
function collectControllerReturnKeys(): Map<string, Set<string>> {
  const byRoute = new Map<string, Set<string>>();
  for (const file of sourceFiles(API_ROOT)) {
    if (file.includes('.spec.')) continue;
    const source = readFileSync(file, 'utf8');
    const controllerMatch = source.match(/@Controller\(\s*'([^']*)'\s*\)/);
    if (!controllerMatch) continue;
    const base = controllerMatch[1].replace(/^\/|\/$/g, '');

    const decoratorPattern = new RegExp(`@(${HTTP_METHODS.join('|')})\\(\\s*(?:'([^']*)')?\\s*\\)`, 'g');
    let match: RegExpExecArray | null;
    while ((match = decoratorPattern.exec(source))) {
      const method = match[1].toUpperCase();
      const sub = (match[2] ?? '').replace(/^\/|\/$/g, '');
      const route = `${method} ${normalizeParams('/' + [base, sub].filter(Boolean).join('/'))}`;

      const bodyStart = source.indexOf('{', source.indexOf(')', decoratorPattern.lastIndex));
      if (bodyStart < 0) continue;
      const body = braceBody(source, bodyStart);
      const keys = singleReturnLiteralKeys(body);
      if (keys) byRoute.set(route, keys);
    }
  }
  return byRoute;
}

/**
 * Keys of the handler's returned object literal, or null when the shape is not
 * a single unambiguous literal (multiple literal returns, `.map(...)`, a bare
 * identifier, a delegated service call).
 */
function singleReturnLiteralKeys(body: string): Set<string> | null {
  const literals: Set<string>[] = [];
  const returnPattern = /\breturn\s*\{/g;
  let match: RegExpExecArray | null;
  while ((match = returnPattern.exec(body))) {
    // Only top-level returns of this handler; a nested arrow's return sits
    // deeper. `body` is the text INSIDE the method braces, so its own top level
    // is depth 0.
    if (depthAt(body, match.index) !== 0) continue;
    literals.push(topLevelKeys(braceBody(body, returnPattern.lastIndex - 1)));
  }
  if (literals.length !== 1) return null;
  return literals[0];
}

/** Brace depth at `index`, ignoring braces inside strings and template literals. */
function depthAt(source: string, index: number): number {
  let depth = 0;
  let quote: string | null = null;
  for (let i = 0; i < index; i += 1) {
    const char = source[i];
    if (quote) {
      if (char === '\\') { i += 1; continue; }
      if (char === quote) quote = null;
      continue;
    }
    if (char === "'" || char === '"' || char === '`') { quote = char; continue; }
    if (char === '{') depth += 1;
    else if (char === '}') depth -= 1;
  }
  return depth;
}

/** The text between `source[openIndex]` ('{') and its matching close brace. */
function braceBody(source: string, openIndex: number): string {
  let depth = 0;
  let quote: string | null = null;
  for (let i = openIndex; i < source.length; i += 1) {
    const char = source[i];
    if (quote) {
      if (char === '\\') { i += 1; continue; }
      if (char === quote) quote = null;
      continue;
    }
    if (char === "'" || char === '"' || char === '`') { quote = char; continue; }
    if (char === '{') depth += 1;
    else if (char === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(openIndex + 1, i);
    }
  }
  return '';
}

/** Is `token` a bare JS identifier? Anything else is comment or syntax noise. */
function isIdentifier(token: string): boolean {
  return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(token);
}

/**
 * Top-level `key:` and shorthand `key,` names of one object-literal body.
 * Tokens that are not bare identifiers — comment text, spread expressions,
 * computed keys — are discarded, so a comment sitting between properties can
 * neither invent a key nor mask a missing one.
 */
function topLevelKeys(literal: string): Set<string> {
  const keys = new Set<string>();
  let depth = 0;
  let quote: string | null = null;
  let token = '';
  let expectingKey = true;
  for (let i = 0; i < literal.length; i += 1) {
    const char = literal[i];
    if (quote) {
      if (char === '\\') { i += 1; continue; }
      if (char === quote) quote = null;
      continue;
    }
    if (char === "'" || char === '"' || char === '`') { quote = char; continue; }
    if (char === '{' || char === '[' || char === '(') { depth += 1; continue; }
    if (char === '}' || char === ']' || char === ')') { depth -= 1; continue; }
    if (depth !== 0) continue;

    if (char === ':') {
      // A `:` on a comment line ("// note: x") leaves a non-identifier token,
      // which isIdentifier then rejects.
      if (expectingKey) addKey(keys, token);
      expectingKey = false;
      token = '';
    } else if (char === ',') {
      // Shorthand property (`venueId,`) — the token is both key and value.
      if (expectingKey) addKey(keys, token);
      expectingKey = true;
      token = '';
    } else {
      token += char;
    }
  }
  if (expectingKey) addKey(keys, token);
  return keys;
}

function addKey(keys: Set<string>, rawToken: string) {
  // Keep only the last line: a preceding comment line is separated by \n from
  // the identifier that actually precedes the delimiter.
  const token = rawToken.split('\n').pop()!.trim();
  if (isIdentifier(token)) keys.add(token);
}

type Binding = { identifier: string; routeKey: string };

/**
 * Query results bound to a name we can then scan for property reads. Covers the
 * two forms used in this codebase:
 *   const x = useQuery(api.ns.fn, ...) as T
 *   const { data: x, ... } = useQueryState<T>(api.ns.fn, ...)
 */
function extractQueryBindings(source: string): Binding[] {
  const bindings: Binding[] = [];

  const direct = /const\s+([A-Za-z0-9_$]+)\s*=\s*useQuery(?:State)?\s*(?:<[^>]*>)?\s*\(\s*api\.([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)/g;
  let match: RegExpExecArray | null;
  while ((match = direct.exec(source))) {
    bindings.push({ identifier: match[1], routeKey: `${match[2]}.${match[3]}` });
  }

  const destructured = /const\s*\{([^}]*)\}\s*=\s*useQueryState\s*(?:<[^>]*>)?\s*\(\s*api\.([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)/g;
  while ((match = destructured.exec(source))) {
    const dataAlias = match[1].match(/\bdata\s*:\s*([A-Za-z0-9_$]+)/);
    if (dataAlias) bindings.push({ identifier: dataAlias[1], routeKey: `${match[2]}.${match[3]}` });
  }

  return bindings;
}

/**
 * First-level property names read off `identifier` (`x.foo`, `x?.foo`).
 *
 * String contents are blanked first: an i18n key like `t('reports.payroll.summary')`
 * otherwise reads as `payroll.summary` on a variable that happens to share the
 * name. The lookbehind then rejects `something.payroll.foo`, where `payroll` is
 * itself a property rather than the binding we care about.
 */
function readProperties(source: string, identifier: string): Set<string> {
  const properties = new Set<string>();
  const code = blankStringLiterals(source);
  const pattern = new RegExp(`(?<![.\\w$])${identifier}\\s*\\??\\.\\s*([A-Za-z0-9_$]+)`, 'g');
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(code))) properties.add(match[1]);
  return properties;
}

/**
 * Blank out comments and string/template literal TEXT, keeping real code —
 * including the code inside `${…}` interpolations, which is as much a property
 * read as anything else.
 *
 * Comments must go first and cannot be skipped: a backtick inside a `//` comment
 * would otherwise open a phantom template literal and blank the rest of the file,
 * which silently disables this whole check.
 */
function blankStringLiterals(source: string): string {
  let out = '';
  let i = 0;
  const keepLayout = (text: string) => text.replace(/[^\n]/g, ' ');

  while (i < source.length) {
    const char = source[i];
    const next = source[i + 1];

    if (char === '/' && next === '/') {
      const end = source.indexOf('\n', i);
      const stop = end === -1 ? source.length : end;
      out += keepLayout(source.slice(i, stop));
      i = stop;
      continue;
    }
    if (char === '/' && next === '*') {
      const end = source.indexOf('*/', i + 2);
      const stop = end === -1 ? source.length : end + 2;
      out += keepLayout(source.slice(i, stop));
      i = stop;
      continue;
    }
    if (char === "'" || char === '"') {
      out += ' ';
      i += 1;
      while (i < source.length && source[i] !== char) {
        if (source[i] === '\\') { out += ' '; i += 1; }
        out += source[i] === '\n' ? '\n' : ' ';
        i += 1;
      }
      out += ' ';
      i += 1;
      continue;
    }
    if (char === '`') {
      out += ' ';
      i += 1;
      while (i < source.length && source[i] !== '`') {
        if (source[i] === '\\') { out += ' '; i += 2; continue; }
        if (source[i] === '$' && source[i + 1] === '{') {
          // Recurse over the interpolation so `${payroll.totalHours}` is seen.
          let depth = 0;
          const start = i + 2;
          let j = i + 1;
          for (; j < source.length; j += 1) {
            if (source[j] === '{') depth += 1;
            else if (source[j] === '}') { depth -= 1; if (depth === 0) break; }
          }
          out += '  ' + blankStringLiterals(source.slice(start, j)) + ' ';
          i = j + 1;
          continue;
        }
        out += source[i] === '\n' ? '\n' : ' ';
        i += 1;
      }
      out += ' ';
      i += 1;
      continue;
    }
    out += char;
    i += 1;
  }
  return out;
}
