import { weekStartFor } from '../../common/pay-period';
import { zonedIsoDate } from '../../common/venue-time';

export const WEEKLY_REGULAR_HOURS = 40;
export const GUSTO_API_VERSION = '2024-04-01';

export type PunchHours = {
  id: string;
  profileId: string | null;
  employeeName: string;
  payrollEmployeeId: string | null;
  clockInAt: Date;
  clockOutAt: Date;
  hours: number;
  regular: number;
  overtime: number;
};

export function roundHours(hours: number): number {
  return Math.round(hours * 1000) / 1000;
}

export function overlapsPeriod(entry: { clockInAt: Date; clockOutAt: Date | null }, periodStart: Date, periodEnd: Date): boolean {
  if (!entry.clockOutAt) return false;
  return entry.clockOutAt.getTime() > periodStart.getTime() && entry.clockInAt.getTime() < periodEnd.getTime();
}

export function workedHours(entry: {
  clockInAt: Date;
  clockOutAt: Date | null;
  breaks: unknown;
}): number {
  if (!entry.clockOutAt) return 0;
  const start = entry.clockInAt.getTime();
  const end = entry.clockOutAt.getTime();
  let durationMs = Math.max(0, end - start);
  const breaks = Array.isArray(entry.breaks) ? entry.breaks : [];
  for (const item of breaks) {
    if (!item || typeof item !== 'object') continue;
    const brk = item as { type?: string; startAt?: number; endAt?: number };
    if (brk.type !== 'unpaid' || !brk.startAt || !brk.endAt) continue;
    const breakStart = Math.max(start, Number(brk.startAt));
    const breakEnd = Math.min(end, Number(brk.endAt));
    if (!Number.isFinite(breakStart) || !Number.isFinite(breakEnd)) continue;
    durationMs -= Math.max(0, breakEnd - breakStart);
  }
  return roundHours(Math.max(0, durationMs) / 3_600_000);
}

export function classifyAgainstWeek(hours: number, weekHoursSoFar: number): { regular: number; overtime: number } {
  const room = Math.max(0, WEEKLY_REGULAR_HOURS - weekHoursSoFar);
  const regular = Math.min(hours, room);
  return { regular: roundHours(regular), overtime: roundHours(Math.max(0, hours - regular)) };
}

export function weekKey(timezone: string | null, at: Date): string {
  return weekStartFor(zonedIsoDate(timezone, at.getTime()));
}
