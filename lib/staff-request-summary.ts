/**
 * A time-correction request carries two independent things: the free-text
 * explanation the staff member typed (`details`) and the replacement punch times
 * the server will actually write on approval (`availability`). The approval
 * screens used to render only the explanation, so a manager could approve
 * replacement times they were never shown — and the two need not agree.
 *
 * `correctionSummary` renders the times being requested, straight from the
 * payload that gets applied, so the approver sees what they are approving.
 */
export type StaffRequestLike = {
  kind: string;
  availability?: unknown;
};

type CorrectionPayload = {
  clockInAt?: unknown;
  clockOutAt?: unknown;
  entryId?: unknown;
};

function asTimestamp(value: unknown): number | null {
  const ms = typeof value === 'number' ? value : typeof value === 'string' ? Number(value) : NaN;
  return Number.isFinite(ms) ? ms : null;
}

export function formatCorrectionTime(ms: number, timeZone?: string | null): string {
  try {
    return new Intl.DateTimeFormat(undefined, {
      month: 'short',
      day: 'numeric',
      hour: 'numeric',
      minute: '2-digit',
      ...(timeZone ? { timeZone } : {}),
    }).format(new Date(ms));
  } catch {
    return new Date(ms).toISOString();
  }
}

/**
 * Returns the replacement times a time-correction request is asking for, or
 * null for any other request kind (or a correction with an unreadable payload,
 * which must read as missing rather than as "no change requested").
 */
export function correctionSummary(request: StaffRequestLike, timeZone?: string | null): string | null {
  if (request.kind !== 'time_correction') return null;
  const payload = (request.availability ?? null) as CorrectionPayload | null;
  if (!payload || typeof payload !== 'object') return 'Requested times unavailable — do not approve without checking.';

  const clockIn = asTimestamp(payload.clockInAt);
  if (clockIn == null) return 'Requested times unavailable — do not approve without checking.';
  const clockOut = asTimestamp(payload.clockOutAt);

  const inLabel = formatCorrectionTime(clockIn, timeZone);
  const outLabel = clockOut == null ? 'still clocked in' : formatCorrectionTime(clockOut, timeZone);
  return `Requested times: in ${inLabel} · out ${outLabel}`;
}
