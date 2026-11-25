import {
  BrightHrClient,
  BrightHrError,
  extractDate,
  parseAbsence,
  parseClocking,
  parseEmployee,
  toUtcIso,
} from "./brighthr.ts";

function eq(actual: unknown, expected: unknown, label: string) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${label}: expected ${e}, got ${a}`);
}

type Handler = (url: string, init: RequestInit) => Response;

function fakeFetch(handler: Handler) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fn = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, init: init ?? {} });
    return Promise.resolve(handler(url, init ?? {}));
  }) as typeof fetch;
  return { fn, calls };
}

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });

const TOKEN_URL = "https://login.example/connect/token";
const API = "https://api.example";

function client(handler: Handler) {
  const fake = fakeFetch(handler);
  const sleeps: number[] = [];
  const c = new BrightHrClient({
    clientId: "id",
    clientSecret: "secret",
    fetchFn: fake.fn,
    tokenUrl: TOKEN_URL,
    apiBase: API,
    sleep: (ms) => {
      sleeps.push(ms);
      return Promise.resolve();
    },
  });
  return { c, calls: fake.calls, sleeps };
}

Deno.test("getToken sends a client-credentials form and caches the token", async () => {
  const { c, calls } = client((url) => {
    if (url === TOKEN_URL) return json({ access_token: "tok", token_type: "Bearer", expires_in: 3600 });
    return json({ items: [], continuationToken: null });
  });
  await c.listEmployees();
  await c.listEmployees();
  const tokenCalls = calls.filter((x) => x.url === TOKEN_URL);
  eq(tokenCalls.length, 1, "token fetched once");
  const form = new URLSearchParams(String(tokenCalls[0].init.body));
  eq([form.get("grant_type"), form.get("client_id"), form.get("client_secret")],
    ["client_credentials", "id", "secret"], "form fields");
  const apiCall = calls.find((x) => x.url === `${API}/employees/v1/query`)!;
  eq((apiCall.init.headers as Record<string, string>).Authorization, "Bearer tok", "bearer header");
});

Deno.test("getToken maps a rejected secret to invalid_credentials", async () => {
  const { c } = client(() => json({ error: "invalid_client" }, 400));
  try {
    await c.verifyAccess();
    throw new Error("expected failure");
  } catch (error) {
    if (!(error instanceof BrightHrError) || error.code !== "invalid_credentials") throw error;
  }
});

Deno.test("an expired token is refreshed once and the request retried", async () => {
  let tokens = 0;
  let apiCalls = 0;
  const { c } = client((url) => {
    if (url === TOKEN_URL) return json({ access_token: `tok${++tokens}` });
    apiCalls++;
    return apiCalls === 1 ? json({ type: "token-expired" }, 401) : json({ items: [], continuationToken: null });
  });
  await c.listEmployees();
  eq([tokens, apiCalls], [2, 2], "re-authenticated once");
});

Deno.test("429 waits for Retry-After then retries", async () => {
  let apiCalls = 0;
  const { c, sleeps } = client((url) => {
    if (url === TOKEN_URL) return json({ access_token: "tok" });
    apiCalls++;
    return apiCalls === 1
      ? json({}, 429, { "Retry-After": "3" })
      : json({ items: [], continuationToken: null });
  });
  await c.listEmployees();
  eq(sleeps, [3000], "slept for Retry-After");
});

Deno.test("queries follow continuationToken until it is null", async () => {
  const bodies: Record<string, unknown>[] = [];
  const { c } = client((url, init) => {
    if (url === TOKEN_URL) return json({ access_token: "tok" });
    const body = JSON.parse(String(init.body));
    bodies.push(body);
    return body.continuationToken === "p2"
      ? json({ items: [{ id: "e2", name: { givenName: "B", familyName: "Y" }, email: "b@x" }], continuationToken: null })
      : json({ items: [{ id: "e1", name: { givenName: "A", familyName: "X" }, email: "a@x" }], continuationToken: "p2" });
  });
  const employees = await c.listEmployees();
  eq(employees.map((e) => e.externalEmployeeId), ["e1", "e2"], "both pages");
  eq(bodies.map((b) => b.continuationToken ?? null), [null, "p2"], "token passed on page 2");
  eq(bodies[0].pageSize, 100, "max page size");
});

Deno.test("absence and clocking queries filter by one employee", async () => {
  const bodies: { url: string; body: Record<string, unknown> }[] = [];
  const { c } = client((url, init) => {
    if (url === TOKEN_URL) return json({ access_token: "tok" });
    bodies.push({ url, body: JSON.parse(String(init.body)) });
    return json({ items: [], continuationToken: null });
  });
  await c.listAbsences("emp-1", "2026-01-01", "2026-02-01");
  await c.listClockings("emp-1", "2026-01-01", "2026-01-15", "Europe/London");
  eq(bodies.map((b) => b.url), [`${API}/absences/v1/query`, `${API}/blip/v1/clockings/query`], "paths");
  eq(bodies[0].body.filters, { employeeId: "emp-1", from: "2026-01-01", to: "2026-02-01" }, "filters");
});

Deno.test("setExternalReference PUTs to the encoded employee path", async () => {
  const { c, calls } = client((url) => url === TOKEN_URL ? json({ access_token: "tok" }) : json({ externalReference: "u" }));
  await c.setExternalReference("a/b", "user-1");
  const put = calls.find((x) => x.init.method === "PUT")!;
  eq(put.url, `${API}/employees/v1/a%2Fb/external-reference`, "url");
  eq(JSON.parse(String(put.init.body)), { externalReference: "user-1" }, "body");
});

Deno.test("a 409 on external reference surfaces as conflict", async () => {
  const { c } = client((url) => url === TOKEN_URL ? json({ access_token: "tok" }) : json({}, 409));
  try {
    await c.setExternalReference("e", "u");
    throw new Error("expected failure");
  } catch (error) {
    if (!(error instanceof BrightHrError) || error.code !== "conflict") throw error;
  }
});

Deno.test("parseEmployee keeps only the directory fields", () => {
  eq(parseEmployee({
    id: "e1",
    name: { givenName: " Ada ", familyName: "Lovelace" },
    employment: { jobTitle: "Bartender", start: "2024-03-01", end: null, payrollNumber: "P1" },
    email: "ada@example.com",
    externalReference: null,
    _metadata: { isRegistered: true },
  }), {
    externalEmployeeId: "e1",
    givenName: "Ada",
    familyName: "Lovelace",
    email: "ada@example.com",
    jobTitle: "Bartender",
    employmentStart: "2024-03-01",
    employmentEnd: null,
    externalReference: null,
  }, "employee");
  eq(parseEmployee({ name: {} }), null, "no id");
});

Deno.test("extractDate accepts strings and object shapes, rejects invalid dates", () => {
  eq(extractDate("2026-05-04"), "2026-05-04", "plain");
  eq(extractDate("2026-05-04T09:00:00"), "2026-05-04", "datetime");
  eq(extractDate({ $type: "LocalDatePart", date: "2026-05-04", datePart: "FirstHalf" }), "2026-05-04", "object");
  eq(extractDate({ dateTime: "2026-05-04T10:00:00" }), "2026-05-04", "dateTime key");
  eq(extractDate("2026-02-30"), null, "impossible date");
  eq(extractDate(null), null, "null");
});

Deno.test("parseAbsence drops sickness reason, note and certification", () => {
  const parsed = parseAbsence({
    id: "a1",
    $type: "Sickness",
    displayName: "Sickness",
    start: { $type: "LocalDatePart", date: "2026-06-01", datePart: "SecondHalf" },
    end: { $type: "LocalDatePart", date: "2026-06-03", datePart: "FullDay" },
    duration: { $type: "Days", days: 2.5 },
    reason: { id: 4, description: "Private medical detail" },
    note: "private note",
    isCertified: true,
  }, "emp-1");
  eq(parsed, {
    externalAbsenceId: "a1",
    externalEmployeeId: "emp-1",
    absenceType: "Sickness",
    displayName: "Sickness",
    startDate: "2026-06-01",
    startPart: "SecondHalf",
    endDate: "2026-06-03",
    endPart: "FullDay",
    durationDays: 2.5,
    durationMinutes: null,
  }, "absence");
  if (JSON.stringify(parsed).includes("Private")) throw new Error("sickness reason leaked");
});

Deno.test("parseAbsence defaults a missing end to the start and rejects reversed ranges", () => {
  eq(parseAbsence({ id: "a", $type: "Holiday", start: { date: "2026-01-02" } }, "e")?.endDate, "2026-01-02", "single day");
  eq(parseAbsence({ id: "a", $type: "Holiday", start: "2026-01-05", end: "2026-01-02" }, "e"), null, "reversed");
  eq(parseAbsence({ id: "a", $type: "Mystery", start: "2026-01-05" }, "e")?.absenceType, "Other", "unknown type");
});

Deno.test("toUtcIso honours offsets and converts local wall time in the given zone", () => {
  eq(toUtcIso("2026-07-01T09:00:00Z", null), "2026-07-01T09:00:00.000Z", "UTC");
  eq(toUtcIso("2026-07-01T09:00:00+01:00", null), "2026-07-01T08:00:00.000Z", "offset");
  eq(toUtcIso("2026-07-01T09:00:00", "Europe/London"), "2026-07-01T08:00:00.000Z", "BST");
  eq(toUtcIso("2026-01-15T09:00:00", "Europe/London"), "2026-01-15T09:00:00.000Z", "GMT");
  eq(toUtcIso("2026-01-15T09:00:00", "Australia/Sydney"), "2026-01-14T22:00:00.000Z", "AEDT");
  eq(toUtcIso("2026-01-15T09:00:00", "Not/AZone"), null, "bad zone");
  eq(toUtcIso("yesterday", "Europe/London"), null, "garbage");
});

Deno.test("parseClocking converts times, keeps breaks and falls back to the venue zone", () => {
  eq(parseClocking({
    id: "c1",
    start: "2026-07-01T09:00:00",
    end: "2026-07-01T17:30:00",
    startTimeZone: "Europe/London",
    endTimeZone: "Europe/London",
    breaks: [{ start: "2026-07-01T12:00:00", end: "2026-07-01T12:30:00" }],
    note: null,
  }, "emp-1", "UTC"), {
    externalClockingId: "c1",
    externalEmployeeId: "emp-1",
    clockInAt: "2026-07-01T08:00:00.000Z",
    clockOutAt: "2026-07-01T16:30:00.000Z",
    startTimeZone: "Europe/London",
    endTimeZone: "Europe/London",
    breakPeriods: [{ start: "2026-07-01T11:00:00.000Z", end: "2026-07-01T11:30:00.000Z" }],
  }, "clocking");

  const open = parseClocking({ id: "c2", start: "2026-07-01T09:00:00", end: null, startTimeZone: "bogus", breaks: [] },
    "emp-1", "Europe/London");
  eq([open?.clockInAt, open?.clockOutAt], ["2026-07-01T08:00:00.000Z", null], "fallback zone, still clocked in");
  eq(parseClocking({ id: "c3", start: "not a time" }, "e", "UTC"), null, "unparseable start");
});
