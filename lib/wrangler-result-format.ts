/**
 * Renders a Wrangler operator result for a person to read.
 *
 * Two copies of this lived in HomeWranglerSurface and WranglerIntelligencePanel
 * and had already drifted apart. Both fell back to a bare "Done." for any
 * result object without a name-ish key — which is the shape several supported
 * commands actually return (LIST_INVENTORY answers
 * `{ inventory: [...], eightySixItems: [...] }`), so Wrangler would find the
 * right records and show the manager nothing but "Done".
 */

const NAME_KEYS = ['guestName', 'staffName', 'fullName', 'label', 'title', 'itemName', 'name'] as const;

function timeLabel(value: unknown): string {
  return new Date(Number(value)).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
}

function rowLabel(row: unknown): string {
  if (!row || typeof row !== 'object') return String(row);
  const item = row as Record<string, unknown>;
  const named = NAME_KEYS.map((key) => item[key]).find((value) => value != null);
  const name = String(named ?? item.jobTitle ?? 'Record');
  const pieces: string[] = [];
  if (item.partySize != null) pieces.push(`party ${item.partySize}`);
  if (item.status != null) pieces.push(String(item.status));
  if (item.onHand != null) pieces.push(`on hand: ${item.onHand}`);
  if (item.startMinutes != null && item.endMinutes != null) pieces.push(`${item.startMinutes}-${item.endMinutes}`);
  if (item.clockInAt != null) pieces.push(`in ${timeLabel(item.clockInAt)}`);
  if (item.clockOutAt != null) pieces.push(`out ${timeLabel(item.clockOutAt)}`);
  if (item.reservationTime != null) pieces.push(new Date(Number(item.reservationTime)).toLocaleString());
  if (item.jobTitle != null && name !== String(item.jobTitle)) pieces.push(String(item.jobTitle));
  return `• ${name}${pieces.length ? ` — ${pieces.join(' · ')}` : ''}`;
}

function formatRows(rows: unknown[], limit: number): string {
  if (rows.length === 0) return 'No matching records found.';
  const shown = rows.slice(0, limit).map(rowLabel);
  if (rows.length > limit) shown.push(`…and ${rows.length - limit} more`);
  return shown.join('\n');
}

export function formatOperatorResult(result: unknown, limit = 8): string {
  if (Array.isArray(result)) return formatRows(result, limit);

  if (result && typeof result === 'object') {
    const item = result as Record<string, unknown>;
    const named = NAME_KEYS.map((key) => item[key]).find((value) => value != null);
    if (named != null) return rowLabel(item);

    // No name of its own: describe what it actually contains rather than
    // collapsing to "Done". Named collections first, then plain scalars.
    const sections = Object.entries(item)
      .filter(([, value]) => Array.isArray(value))
      .map(([key, value]) => {
        const rows = value as unknown[];
        const heading = key.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/^./, (c) => c.toUpperCase());
        return `${heading} (${rows.length})\n${formatRows(rows, limit)}`;
      });

    const scalars = Object.entries(item)
      .filter(([, value]) => value != null && (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean'))
      .map(([key, value]) => `${key}: ${value}`);

    if (sections.length || scalars.length) {
      return [...sections, ...(scalars.length ? [scalars.join(' · ')] : [])].join('\n\n');
    }
    // An object with nothing readable in it: "Done." is the honest answer,
    // and String(result) here would print "[object Object]".
    return 'Done.';
  }

  return result == null ? 'Done.' : String(result);
}
