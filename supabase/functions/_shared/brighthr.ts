// BrightHR Customer API client (https://docs.bright.hr). Client-credentials OAuth2 only: the
// customer's BrightHR admin creates a Client ID/Secret at account.brighthr.com/manage-api.
//
// Documented surface (as of 2026-11): POST /employees/v1/query, POST /absences/v1/query,
// POST /blip/v1/clockings/query, PUT /employees/v1/{id}/external-reference. Lists paginate with
// `continuationToken` (null on the last page) and `pageSize` (1-100). Errors are problem+json;
// 401 = token expired, 429 = rate limited (token bucket, X-Rate-Limit-* headers).
//
// NOT verified against a live BrightHR tenant (no credentials were available). The reference
// leaves several shapes undocumented: the absence `end` object, the Blip `start`/`end` string
// format, `breaks[].start`, and the date format of `filters.from`/`filters.to`. The parsers below
// therefore accept every plausible shape and drop a record rather than guess. Confirm against a
// real tenant before relying on this in production.

export const DEFAULT_BRIGHTHR_TOKEN_URL = "https://login.brighthr.com/connect/token";
export const DEFAULT_BRIGHTHR_API_BASE = "https://api.bright.hr";

const REQUEST_TIMEOUT_MS = 15_000;
const MAX_RATE_LIMIT_RETRIES = 3;
const MAX_PAGES = 200;

export type BrightHrErrorCode =
  | "invalid_credentials"
  | "forbidden"
  | "not_found"
  | "conflict"
  | "validation_failed"
  | "rate_limited"
  | "upstream_error"
  | "bad_response";

export class BrightHrError extends Error {
  constructor(readonly code: BrightHrErrorCode, readonly status?: number) {
    super(`BrightHR ${code}${status ? ` (${status})` : ""}`);
    this.name = "BrightHrError";
  }
}

export interface BrightHrClientOptions {
  clientId: string;
  clientSecret: string;
  fetchFn?: typeof fetch;
  tokenUrl?: string;
  apiBase?: string;
  sleep?: (ms: number) => Promise<void>;
}

type Json = Record<string, unknown>;

function isObject(value: unknown): value is Json {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function str(value: unknown, max = 500): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length === 0 ? null : trimmed.slice(0, max);
}

export class BrightHrClient {
  private readonly fetchFn: typeof fetch;
  private readonly tokenUrl: string;
  private readonly apiBase: string;
  private readonly sleep: (ms: number) => Promise<void>;
  private token: string | null = null;

  constructor(private readonly options: BrightHrClientOptions) {
    this.fetchFn = options.fetchFn ?? fetch;
    this.tokenUrl = options.tokenUrl ?? DEFAULT_BRIGHTHR_TOKEN_URL;
    this.apiBase = (options.apiBase ?? DEFAULT_BRIGHTHR_API_BASE).replace(/\/+$/, "");
    this.sleep = options.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  }

  /** Fetches (or reuses) a bearer token. Throws invalid_credentials on a 400/401 from BrightHR. */
  async getToken(force = false): Promise<string> {
    if (this.token && !force) return this.token;
    let response: Response;
    try {
      response = await this.fetchFn(this.tokenUrl, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "client_credentials",
          client_id: this.options.clientId,
          client_secret: this.options.clientSecret,
        }),
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
    } catch {
      throw new BrightHrError("upstream_error");
    }
    if (response.status === 400 || response.status === 401) {
      await response.body?.cancel();
      throw new BrightHrError("invalid_credentials", response.status);
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new BrightHrError("upstream_error", response.status);
    }
    const body = await response.json().catch(() => null);
    const token = isObject(body) ? str(body.access_token, 10_000) : null;
    if (!token) throw new BrightHrError("bad_response");
    this.token = token;
    return token;
  }

  private async request(method: "POST" | "PUT", path: string, body: Json): Promise<Json> {
    let reauthenticated = false;
    let rateLimitRetries = 0;
    for (;;) {
      const token = await this.getToken();
      let response: Response;
      try {
        response = await this.fetchFn(`${this.apiBase}${path}`, {
          method,
          headers: {
            "Authorization": `Bearer ${token}`,
            "Content-Type": "application/json",
            "Accept": "application/json",
          },
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        });
      } catch {
        throw new BrightHrError("upstream_error");
      }

      if (response.status === 401 && !reauthenticated) {
        await response.body?.cancel();
        reauthenticated = true;
        await this.getToken(true);
        continue;
      }
      if (response.status === 429 && rateLimitRetries < MAX_RATE_LIMIT_RETRIES) {
        await response.body?.cancel();
        rateLimitRetries++;
        const retryAfter = Number(response.headers.get("Retry-After"));
        const waitMs = Number.isFinite(retryAfter) && retryAfter > 0
          ? Math.min(retryAfter, 30) * 1000
          : 1000 * 2 ** rateLimitRetries;
        await this.sleep(waitMs);
        continue;
      }
      if (!response.ok) {
        await response.body?.cancel();
        throw new BrightHrError(errorCodeForStatus(response.status), response.status);
      }
      const json = await response.json().catch(() => null);
      if (!isObject(json)) throw new BrightHrError("bad_response", response.status);
      return json;
    }
  }

  private async queryAll(path: string, body: Json): Promise<unknown[]> {
    const items: unknown[] = [];
    let continuationToken: unknown = undefined;
    for (let page = 0; page < MAX_PAGES; page++) {
      const requestBody: Json = { ...body, pageSize: 100 };
      if (continuationToken !== undefined && continuationToken !== null) {
        requestBody.continuationToken = continuationToken;
      }
      const response = await this.request("POST", path, requestBody);
      if (!Array.isArray(response.items)) throw new BrightHrError("bad_response");
      items.push(...response.items);
      continuationToken = response.continuationToken;
      if (continuationToken === undefined || continuationToken === null || continuationToken === "") {
        return items;
      }
    }
    // A tenant with more than MAX_PAGES * 100 records per query is not expected for one venue.
    throw new BrightHrError("bad_response");
  }

  /** Cheap credential + API-access check used when connecting. */
  async verifyAccess(): Promise<void> {
    await this.getToken(true);
    await this.request("POST", "/employees/v1/query", { pageSize: 1 });
  }

  async listEmployees(): Promise<BrightHrEmployee[]> {
    const raw = await this.queryAll("/employees/v1/query", {});
    return raw.map(parseEmployee).filter((e): e is BrightHrEmployee => e !== null);
  }

  async listAbsences(employeeId: string, from: string, to: string): Promise<BrightHrAbsence[]> {
    const raw = await this.queryAll("/absences/v1/query", {
      filters: { employeeId, from, to },
    });
    return raw
      .map((item) => parseAbsence(item, employeeId))
      .filter((a): a is BrightHrAbsence => a !== null);
  }

  async listClockings(
    employeeId: string,
    from: string,
    to: string,
    fallbackTimeZone: string,
  ): Promise<BrightHrClocking[]> {
    const raw = await this.queryAll("/blip/v1/clockings/query", {
      filters: { employeeId, from, to },
    });
    return raw
      .map((item) => parseClocking(item, employeeId, fallbackTimeZone))
      .filter((c): c is BrightHrClocking => c !== null);
  }

  async setExternalReference(employeeId: string, externalReference: string): Promise<void> {
    await this.request(
      "PUT",
      `/employees/v1/${encodeURIComponent(employeeId)}/external-reference`,
      { externalReference },
    );
  }
}

function errorCodeForStatus(status: number): BrightHrErrorCode {
  switch (status) {
    case 401:
      return "invalid_credentials";
    case 403:
      return "forbidden";
    case 404:
      return "not_found";
    case 409:
      return "conflict";
    case 400:
    case 422:
      return "validation_failed";
    case 429:
      return "rate_limited";
    default:
      return "upstream_error";
  }
}

// ---------------------------------------------------------------------------
// Parsers. Each returns null for a record it cannot interpret safely.
// ---------------------------------------------------------------------------

export interface BrightHrEmployee {
  externalEmployeeId: string;
  givenName: string | null;
  familyName: string | null;
  email: string | null;
  jobTitle: string | null;
  employmentStart: string | null;
  employmentEnd: string | null;
  externalReference: string | null;
}

const DATE_PREFIX = /^(\d{4}-\d{2}-\d{2})/;

/** Pulls a YYYY-MM-DD date out of a string or any of the object shapes BrightHR may use. */
export function extractDate(value: unknown): string | null {
  if (typeof value === "string") {
    const match = DATE_PREFIX.exec(value.trim());
    if (!match) return null;
    const parsed = new Date(`${match[1]}T00:00:00Z`);
    return Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== match[1]
      ? null
      : match[1];
  }
  if (isObject(value)) {
    for (const key of ["date", "localDate", "dateTime", "localDateTime", "value"]) {
      const found = extractDate(value[key]);
      if (found) return found;
    }
  }
  return null;
}

export function parseEmployee(raw: unknown): BrightHrEmployee | null {
  if (!isObject(raw)) return null;
  const id = str(raw.id, 100);
  if (!id) return null;
  const name = isObject(raw.name) ? raw.name : {};
  const employment = isObject(raw.employment) ? raw.employment : {};
  return {
    externalEmployeeId: id,
    givenName: str(name.givenName, 200),
    familyName: str(name.familyName, 200),
    email: str(raw.email, 320),
    jobTitle: str(employment.jobTitle, 200),
    employmentStart: extractDate(employment.start),
    employmentEnd: extractDate(employment.end),
    externalReference: str(raw.externalReference, 200),
  };
}

export type AbsenceType = "Sickness" | "Toil" | "Holiday" | "Other";
export type DatePart = "FirstHalf" | "SecondHalf" | "FullDay";

export interface BrightHrAbsence {
  externalAbsenceId: string;
  externalEmployeeId: string;
  absenceType: AbsenceType;
  displayName: string | null;
  startDate: string;
  startPart: DatePart;
  endDate: string;
  endPart: DatePart;
  durationDays: number | null;
  durationMinutes: number | null;
}

const ABSENCE_TYPES: readonly AbsenceType[] = ["Sickness", "Toil", "Holiday", "Other"];
const DATE_PARTS: readonly DatePart[] = ["FirstHalf", "SecondHalf", "FullDay"];

function datePart(value: unknown): DatePart {
  const part = isObject(value) ? value.datePart : undefined;
  return DATE_PARTS.includes(part as DatePart) ? part as DatePart : "FullDay";
}

function nonNegativeNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null;
}

// Deliberately ignores `reason`, `note`, `isCertified` and `estimatedReturn`: sickness details
// are health data the app has no need to hold.
export function parseAbsence(raw: unknown, employeeId: string): BrightHrAbsence | null {
  if (!isObject(raw)) return null;
  const id = str(raw.id, 100);
  const type = raw.$type;
  const startDate = extractDate(raw.start);
  const endDate = extractDate(raw.end) ?? startDate;
  if (!id || !startDate || !endDate || endDate < startDate) return null;
  const duration = isObject(raw.duration) ? raw.duration : {};
  return {
    externalAbsenceId: id,
    externalEmployeeId: employeeId,
    absenceType: ABSENCE_TYPES.includes(type as AbsenceType) ? type as AbsenceType : "Other",
    displayName: str(raw.displayName, 200),
    startDate,
    startPart: datePart(raw.start),
    endDate,
    endPart: datePart(raw.end),
    durationDays: nonNegativeNumber(duration.days),
    durationMinutes: nonNegativeNumber(duration.minutes),
  };
}

export interface BrightHrClocking {
  externalClockingId: string;
  externalEmployeeId: string;
  clockInAt: string;
  clockOutAt: string | null;
  startTimeZone: string | null;
  endTimeZone: string | null;
  breakPeriods: { start: string | null; end: string | null }[];
}

function isValidTimeZone(timeZone: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone });
    return true;
  } catch {
    return false;
  }
}

function zoneOffsetMs(instantMs: number, timeZone: string): number {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    }).formatToParts(new Date(instantMs)).map((p) => [p.type, p.value]),
  );
  const asUtc = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    Number(parts.hour),
    Number(parts.minute),
    Number(parts.second),
  );
  return asUtc - Math.floor(instantMs / 1000) * 1000;
}

const LOCAL_DATE_TIME =
  /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?$/;
const HAS_OFFSET = /(Z|[+-]\d{2}:?\d{2})$/i;

/**
 * Converts a BrightHR timestamp to a UTC ISO string. A value carrying an offset is parsed as is;
 * an offset-less local wall time is interpreted in `timeZone` (an IANA zone). Null if unusable.
 */
export function toUtcIso(value: unknown, timeZone: string | null): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (HAS_OFFSET.test(trimmed)) {
    const parsed = new Date(trimmed);
    return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
  }
  const match = LOCAL_DATE_TIME.exec(trimmed);
  if (!match || !timeZone || !isValidTimeZone(timeZone)) return null;
  const [, y, mo, d, h, mi, s, frac] = match;
  const wallMs = Date.UTC(
    Number(y),
    Number(mo) - 1,
    Number(d),
    Number(h),
    Number(mi),
    Number(s ?? 0),
    Number((frac ?? "0").padEnd(3, "0").slice(0, 3)),
  );
  if (Number.isNaN(wallMs)) return null;
  // Two passes settle the offset across a DST transition.
  let utcMs = wallMs - zoneOffsetMs(wallMs, timeZone);
  const corrected = wallMs - zoneOffsetMs(utcMs, timeZone);
  if (corrected !== utcMs) utcMs = corrected;
  return new Date(utcMs).toISOString();
}

export function parseClocking(
  raw: unknown,
  employeeId: string,
  fallbackTimeZone: string,
): BrightHrClocking | null {
  if (!isObject(raw)) return null;
  const id = str(raw.id, 100);
  if (!id) return null;
  const startTimeZone = str(raw.startTimeZone, 64);
  const endTimeZone = str(raw.endTimeZone, 64) ?? startTimeZone;
  const startZone = startTimeZone && isValidTimeZone(startTimeZone) ? startTimeZone : fallbackTimeZone;
  const endZone = endTimeZone && isValidTimeZone(endTimeZone) ? endTimeZone : startZone;
  const clockInAt = toUtcIso(raw.start, startZone);
  if (!clockInAt) return null;
  let clockOutAt = toUtcIso(raw.end, endZone);
  if (clockOutAt && clockOutAt < clockInAt) clockOutAt = null;
  const breaks = Array.isArray(raw.breaks) ? raw.breaks : [];
  return {
    externalClockingId: id,
    externalEmployeeId: employeeId,
    clockInAt,
    clockOutAt,
    startTimeZone,
    endTimeZone,
    breakPeriods: breaks.filter(isObject).slice(0, 50).map((b) => ({
      start: toUtcIso(b.start, startZone),
      end: toUtcIso(b.end, endZone),
    })),
  };
}
