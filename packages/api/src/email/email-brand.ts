/**
 * Shared branded HTML shell + content primitives for every transactional
 * email the API sends. One place decides what "a Venue Wrangler email"
 * looks like, so branding, layout, and email-client compatibility are
 * solved once instead of per call site.
 *
 * Design tokens are pulled from the app's real design system
 * (lib/theme.ts `designPalettes.light`) rather than the marketing site's
 * illustrative palette — these emails are an extension of the product a
 * person already uses, not the landing page.
 *
 * HTML follows table-based, fully-inline-style email conventions
 * (Outlook still does not reliably support flexbox/grid/external CSS):
 *   - Outer 100%-wide table for the page background, inner 600px card.
 *   - Every color/font/spacing is inline; no external stylesheet is relied
 *     on for anything load-bearing.
 *   - Fonts declare real web-safe fallbacks; the Google Fonts <link> is a
 *     progressive enhancement only.
 *   - Buttons are <a> styled as buttons, never <button>.
 */

export const BRAND = {
  logoUrl: 'https://venuewrangler.com/assets/logo.jpg',
  // Actual pixel dimensions of the source file (1024x559) — declared
  // explicitly on <img> per email-HTML convention, scaled to a sane header
  // width while preserving aspect ratio.
  logoWidth: 168,
  logoHeight: 92,
  colors: {
    // Deep green — the product's primary color (designPalettes.light.primary).
    primary: '#17643B',
    primaryDark: '#0F4A2A',
    // Warm amber — designPalettes.light.secondary. Used sparingly: the OTP
    // code chip and small emphasis, never competing with the primary CTA.
    accent: '#A86514',
    ink: '#1D2420',
    muted: '#68706A',
    bgOuter: '#F2F4F0',
    card: '#FFFFFF',
    border: '#E5E8E2',
    borderStrong: '#DDE1DA',
    soft: '#EEF5F0',
    danger: '#B4483F',
    dangerSoft: '#FBEEEC',
  },
  fontHead: "'Baloo 2', Arial, Helvetica, sans-serif",
  fontBody: "'Nunito', Arial, Helvetica, sans-serif",
  supportEmail: 'support@venuewrangler.com',
} as const;

function esc(value: string | number): string {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

/**
 * A single paragraph of body copy — called as a tagged template:
 * `` p`Hi ${fullName},` ``. Every interpolated `${...}` value is HTML-escaped
 * automatically; the literal markup you write around it (e.g. `<strong>`)
 * passes through untouched.
 *
 * This is the reason `p` is a tag rather than a plain function taking a
 * pre-built string: nearly every call site interpolates data a venue's own
 * users control — a profile name, a venue name, a manager's note — and a
 * plain function makes it the caller's job to remember to escape it. A
 * missed `esc()` call anywhere would land raw markup in an HTML email.
 * Tagging makes that mistake structurally impossible instead of a matter of
 * discipline.
 */
export function p(strings: TemplateStringsArray, ...values: Array<string | number>): string {
  const html = strings.reduce((acc, str, i) => acc + str + (i < values.length ? esc(values[i]) : ''), '');
  return `<tr><td style="padding:0 0 16px;font-family:${BRAND.fontBody};font-size:15px;line-height:24px;color:${BRAND.colors.ink};">${html}</td></tr>`;
}

/** A small section heading above a block (table, list, etc.). */
export function h(text: string): string {
  return `<tr><td style="padding:24px 0 8px;font-family:${BRAND.fontHead};font-weight:700;font-size:14px;letter-spacing:.02em;color:${BRAND.colors.primary};">${esc(text)}</td></tr>`;
}

/** Bold inline emphasis, safe to drop into a paragraph. */
export function strong(text: string): string {
  return `<strong style="color:${BRAND.colors.ink};">${esc(text)}</strong>`;
}

/**
 * A bulletproof button. Table-wrapped <a> rather than <button>, which many
 * clients (notably Outlook) refuse to style.
 */
export function button(label: string, url: string): string {
  return `<tr><td style="padding:8px 0 20px;">
    <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
      <td style="border-radius:8px;background-color:${BRAND.colors.primary};" bgcolor="${BRAND.colors.primary}">
        <a href="${esc(url)}" style="display:inline-block;padding:13px 28px;font-family:${BRAND.fontBody};font-weight:700;font-size:15px;color:#FFFFFF;text-decoration:none;border-radius:8px;">${esc(label)}</a>
      </td>
    </tr></table>
  </td></tr>`;
}

/**
 * A large, letter-spaced one-time code — the thing a person is most likely
 * to mis-copy, so it gets the most visual weight in the email.
 */
export function codeBlock(code: string): string {
  return `<tr><td style="padding:4px 0 20px;">
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%"><tr>
      <td align="center" style="background-color:${BRAND.colors.soft};border:1px solid ${BRAND.colors.border};border-radius:10px;padding:18px 12px;">
        <span style="font-family:'JetBrains Mono',Consolas,'Courier New',monospace;font-size:28px;font-weight:700;letter-spacing:.3em;color:${BRAND.colors.primary};">${esc(code)}</span>
      </td>
    </tr></table>
  </td></tr>`;
}

/** A two-column label/value table — replaces the old tab-separated text blocks. */
export function infoTable(rows: Array<[string, string]>): string {
  const body = rows
    .map(
      ([label, value], i) => `<tr>
        <td style="padding:10px 14px;font-family:${BRAND.fontBody};font-size:13px;color:${BRAND.colors.muted};border-top:${i === 0 ? 'none' : `1px solid ${BRAND.colors.border}`};white-space:nowrap;">${esc(label)}</td>
        <td style="padding:10px 14px;font-family:${BRAND.fontBody};font-size:14px;font-weight:600;color:${BRAND.colors.ink};border-top:${i === 0 ? 'none' : `1px solid ${BRAND.colors.border}`};text-align:right;">${esc(value)}</td>
      </tr>`,
    )
    .join('');
  return `<tr><td style="padding:4px 0 20px;">
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background-color:${BRAND.colors.soft};border:1px solid ${BRAND.colors.border};border-radius:10px;overflow:hidden;">${body}</table>
  </td></tr>`;
}

/** A before/after comparison table — used for shift-change notices. */
export function compareTable(header: [string, string, string], rows: Array<[string, string, string]>): string {
  const headRow = `<tr>${header
    .map(
      (label, i) =>
        `<td style="padding:9px 12px;font-family:${BRAND.fontBody};font-size:11px;font-weight:700;letter-spacing:.05em;text-transform:uppercase;color:${BRAND.colors.muted};${i > 0 ? 'text-align:right;' : ''}">${esc(label)}</td>`,
    )
    .join('')}</tr>`;
  const body = rows
    .map(
      (cells) => `<tr>${cells
        .map(
          (cell, i) =>
            `<td style="padding:9px 12px;font-family:${BRAND.fontBody};font-size:13px;${i === 0 ? `font-weight:600;color:${BRAND.colors.ink};` : `color:${BRAND.colors.muted};text-align:right;`}border-top:1px solid ${BRAND.colors.border};">${esc(cell)}</td>`,
        )
        .join('')}</tr>`,
    )
    .join('');
  return `<tr><td style="padding:4px 0 20px;">
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background-color:${BRAND.colors.soft};border:1px solid ${BRAND.colors.border};border-radius:10px;overflow:hidden;">${headRow}${body}</table>
  </td></tr>`;
}

/**
 * A simple checklist — replaces the old bare-line lists ("Edit a shift - ...").
 * Unlike `p`, this is a plain function: items are HTML-escaped as a whole
 * (via `esc`), so an item may not embed markup like `<strong>`. Every
 * current call site passes either static copy or the output of `strong()`
 * around a hardcoded string — if a future call site needs to interpolate
 * user-controlled data into a list item, escape it explicitly first.
 */
export function list(items: string[]): string {
  const rows = items
    .map(
      (item) => `<tr>
        <td valign="top" style="padding:0 8px 8px 0;width:18px;font-family:${BRAND.fontBody};font-size:14px;color:${BRAND.colors.primary};font-weight:700;">&bull;</td>
        <td style="padding:0 0 8px;font-family:${BRAND.fontBody};font-size:14px;line-height:21px;color:${BRAND.colors.ink};">${esc(item)}</td>
      </tr>`,
    )
    .join('');
  return `<tr><td style="padding:0 0 12px;"><table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">${rows}</table></td></tr>`;
}

/** A subtle divider between sections. */
export function divider(): string {
  return `<tr><td style="padding:8px 0;"><hr style="border:none;border-top:1px solid ${BRAND.colors.border};margin:0;" /></td></tr>`;
}

export type EmailContext = {
  /** Hidden preview text shown next to the subject line in the inbox list. */
  preheader: string;
  /** Large headline at the top of the card. */
  heading: string;
  /** Pre-built <tr> rows from the helpers above (p, h, button, infoTable, ...). */
  bodyRows: string;
  /** Optional colored accent bar under the header — 'primary' (default) or 'danger' for security alerts. */
  accent?: 'primary' | 'danger';
};

/**
 * Wrap content rows in the full branded shell: logo header, accent bar,
 * white card, closing line, and footer.
 */
export function renderEmailHtml({ preheader, heading, bodyRows, accent = 'primary' }: EmailContext): string {
  const accentColor = accent === 'danger' ? BRAND.colors.danger : BRAND.colors.primary;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<title>${esc(heading)}</title>
<link href="https://fonts.googleapis.com/css2?family=Baloo+2:wght@700;800&family=Nunito:wght@500;600;700&display=swap" rel="stylesheet">
</head>
<body style="margin:0;padding:0;background-color:${BRAND.colors.bgOuter};">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;font-size:1px;line-height:1px;color:${BRAND.colors.bgOuter};">${esc(preheader)}&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;</div>
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" bgcolor="${BRAND.colors.bgOuter}" style="background-color:${BRAND.colors.bgOuter};">
<tr><td align="center" style="padding:32px 16px;">
  <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" style="width:600px;max-width:100%;">
    <tr><td style="padding:0 0 20px;text-align:center;">
      <img src="${BRAND.logoUrl}" width="${BRAND.logoWidth}" height="${BRAND.logoHeight}" alt="Venue Wrangler" border="0" style="display:inline-block;max-width:${BRAND.logoWidth}px;height:auto;" />
    </td></tr>
    <tr><td style="background-color:${accentColor};height:4px;line-height:4px;font-size:0;border-radius:4px 4px 0 0;" bgcolor="${accentColor}">&nbsp;</td></tr>
    <tr><td bgcolor="${BRAND.colors.card}" style="background-color:${BRAND.colors.card};border:1px solid ${BRAND.colors.border};border-top:none;border-radius:0 0 12px 12px;padding:32px 32px 24px;">
      <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
        <tr><td style="padding:0 0 18px;font-family:${BRAND.fontHead};font-weight:800;font-size:22px;line-height:28px;color:${BRAND.colors.ink};">${esc(heading)}</td></tr>
        ${bodyRows}
      </table>
    </td></tr>
    <tr><td style="padding:24px 8px 0;text-align:center;">
      <p style="margin:0 0 4px;font-family:${BRAND.fontBody};font-size:13px;color:${BRAND.colors.muted};">Questions? <a href="mailto:${BRAND.supportEmail}" style="color:${BRAND.colors.primary};text-decoration:none;font-weight:600;">${BRAND.supportEmail}</a></p>
      <p style="margin:0;font-family:${BRAND.fontBody};font-size:12px;color:${BRAND.colors.muted};">&copy; ${new Date().getFullYear()} Venue Wrangler &middot; Every venue, wrangled.</p>
    </td></tr>
  </table>
</td></tr>
</table>
</body>
</html>`;
}
