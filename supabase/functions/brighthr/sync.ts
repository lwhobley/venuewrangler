// One BrightHR sync pass for one venue connection. Runs with the service client only.
//
// 1. Employees: upsert the full directory; remove ones BrightHR no longer returns (which
//    cascades their link). An empty directory never wipes existing rows.
// 2. External references: write the linked member's id back to BrightHR where it differs.
// 3. Absences (-30d..+180d) and clockings (-14d..+1d) for linked employees only, least recently
//    synced first, within a time budget; stale rows in each fetched window are removed.
// 4. Prune: data for unlinked employees, and anything older than the 90 day retention window.
import type { SupabaseClient } from "@supabase/supabase-js";
import { decryptToken } from "../_shared/crypto.ts";
import { BrightHrClient, BrightHrError, type BrightHrClientOptions } from "../_shared/brighthr.ts";

export type SyncTrigger = "connect" | "manual" | "scheduled";

const SYNC_INTERVAL_MS = 30 * 60 * 1000;
const RETRY_SOON_MS = 5 * 60 * 1000;
const CREDENTIAL_ERROR_BACKOFF_MS = 6 * 60 * 60 * 1000;
const RETENTION_DAYS = 90;
const DEFAULT_TIME_BUDGET_MS = 100_000;
const UPSERT_CHUNK = 500;

export interface SyncResult {
  status: "succeeded" | "partial" | "failed";
  employees: number;
  absences: number;
  clockings: number;
  errorCode: string | null;
}

function isoDate(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

function userFacingError(code: string): string | null {
  if (code.startsWith("external_reference_")) {
    return code === "external_reference_conflict"
      ? "BrightHR refused an external reference because another employee already uses it. Check the employee links."
      : "Could not update an employee's external reference in BrightHR. Sync will retry.";
  }
  switch (code) {
    case "time_budget_exhausted":
      return null; // Large roster: the next run continues with the remaining employees.
    case "invalid_credentials":
      return "BrightHR rejected the Client ID or Secret. Create a new secret in BrightHR and reconnect.";
    case "forbidden":
      return "The BrightHR API application does not have access to this data.";
    case "rate_limited":
      return "BrightHR is rate limiting requests. Sync will retry shortly.";
    default:
      return "Could not reach BrightHR. Sync will retry shortly.";
  }
}

async function upsertChunks(
  admin: SupabaseClient,
  table: string,
  rows: Record<string, unknown>[],
  onConflict: string,
): Promise<void> {
  for (let i = 0; i < rows.length; i += UPSERT_CHUNK) {
    const { error } = await admin.from(table).upsert(rows.slice(i, i + UPSERT_CHUNK), { onConflict });
    if (error) throw error;
  }
}

export async function syncConnection(
  admin: SupabaseClient,
  connectionId: string,
  trigger: SyncTrigger,
  opts: {
    encryptionKey: string;
    clientOptions?: Partial<BrightHrClientOptions>;
    timeBudgetMs?: number;
    now?: () => number;
  },
): Promise<SyncResult> {
  const now = opts.now ?? Date.now;
  const startedAt = now();
  const budget = opts.timeBudgetMs ?? DEFAULT_TIME_BUDGET_MS;
  const result: SyncResult = { status: "succeeded", employees: 0, absences: 0, clockings: 0, errorCode: null };

  const { data: connection, error: connectionError } = await admin
    .from("brighthr_connections")
    .select("id, venue_id, client_id, encrypted_client_secret, venues(timezone)")
    .eq("id", connectionId)
    .maybeSingle();
  if (connectionError) throw connectionError;
  if (!connection) return { ...result, status: "failed", errorCode: "not_found" };

  const venueId = connection.venue_id as string;
  const venue = connection.venues as { timezone?: string } | { timezone?: string }[] | null;
  const venueTimeZone = (Array.isArray(venue) ? venue[0]?.timezone : venue?.timezone) ?? "UTC";

  const { data: run } = await admin
    .from("brighthr_sync_runs")
    .insert({ connection_id: connectionId, trigger })
    .select("id")
    .single();

  const markPartial = (code: string) => {
    result.status = "partial";
    result.errorCode ??= code;
  };

  try {
    const clientSecret = await decryptToken(connection.encrypted_client_secret as string, opts.encryptionKey, {
      venueId,
      provider: "brighthr",
    });
    const client = new BrightHrClient({
      ...opts.clientOptions,
      clientId: connection.client_id as string,
      clientSecret,
    });

    // 1. Employee directory.
    const employees = await client.listEmployees();
    const syncedAt = new Date(now()).toISOString();
    await upsertChunks(
      admin,
      "brighthr_employees",
      employees.map((e) => ({
        connection_id: connectionId,
        external_employee_id: e.externalEmployeeId,
        given_name: e.givenName,
        family_name: e.familyName,
        email: e.email,
        job_title: e.jobTitle,
        employment_start: e.employmentStart,
        employment_end: e.employmentEnd,
        external_reference: e.externalReference,
        synced_at: syncedAt,
      })),
      "connection_id,external_employee_id",
    );
    result.employees = employees.length;

    if (employees.length > 0) {
      const { error } = await admin
        .from("brighthr_employees")
        .delete()
        .eq("connection_id", connectionId)
        .lt("synced_at", syncedAt);
      if (error) throw error;
    }

    // 2 + 3. Linked employees.
    const { data: mappings, error: mappingError } = await admin
      .from("brighthr_employee_mappings")
      .select("external_employee_id, staff_id, external_reference_synced_at, data_synced_at")
      .eq("connection_id", connectionId)
      .order("data_synced_at", { ascending: true, nullsFirst: true });
    if (mappingError) throw mappingError;

    const referenceById = new Map(employees.map((e) => [e.externalEmployeeId, e.externalReference]));
    const linkedIds = (mappings ?? []).map((m) => m.external_employee_id as string);

    for (const mapping of mappings ?? []) {
      const employeeId = mapping.external_employee_id as string;
      const staffId = mapping.staff_id as string;
      if (referenceById.get(employeeId) === staffId && mapping.external_reference_synced_at) continue;
      try {
        await client.setExternalReference(employeeId, staffId);
        await admin.from("brighthr_employee_mappings")
          .update({ external_reference_synced_at: new Date(now()).toISOString() })
          .eq("connection_id", connectionId).eq("external_employee_id", employeeId).eq("staff_id", staffId);
        await admin.from("brighthr_employees")
          .update({ external_reference: staffId })
          .eq("connection_id", connectionId).eq("external_employee_id", employeeId);
      } catch (error) {
        if (error instanceof BrightHrError && error.code === "invalid_credentials") throw error;
        markPartial(error instanceof BrightHrError ? `external_reference_${error.code}` : "external_reference_failed");
      }
    }

    const today = now();
    const absenceFrom = isoDate(today - 30 * 86_400_000);
    const absenceTo = isoDate(today + 180 * 86_400_000);
    const clockingFrom = isoDate(today - 14 * 86_400_000);
    const clockingTo = isoDate(today + 86_400_000);

    for (const employeeId of linkedIds) {
      if (now() - startedAt > budget) {
        markPartial("time_budget_exhausted");
        break;
      }
      try {
        const absences = await client.listAbsences(employeeId, absenceFrom, absenceTo);
        const clockings = await client.listClockings(employeeId, clockingFrom, clockingTo, venueTimeZone);
        const rowSyncedAt = new Date(now()).toISOString();

        await upsertChunks(admin, "brighthr_absences", absences.map((a) => ({
          connection_id: connectionId,
          external_absence_id: a.externalAbsenceId,
          external_employee_id: employeeId,
          absence_type: a.absenceType,
          display_name: a.displayName,
          start_date: a.startDate,
          start_part: a.startPart,
          end_date: a.endDate,
          end_part: a.endPart,
          duration_days: a.durationDays,
          duration_minutes: a.durationMinutes,
          synced_at: rowSyncedAt,
        })), "connection_id,external_absence_id");

        await upsertChunks(admin, "brighthr_clockings", clockings.map((c) => ({
          connection_id: connectionId,
          external_clocking_id: c.externalClockingId,
          external_employee_id: employeeId,
          clock_in_at: c.clockInAt,
          clock_out_at: c.clockOutAt,
          start_time_zone: c.startTimeZone,
          end_time_zone: c.endTimeZone,
          break_periods: c.breakPeriods,
          synced_at: rowSyncedAt,
        })), "connection_id,external_clocking_id");

        // Anything in the fetched windows that BrightHR did not return again was cancelled/removed.
        await admin.from("brighthr_absences").delete()
          .eq("connection_id", connectionId).eq("external_employee_id", employeeId)
          .lte("start_date", absenceTo).gte("end_date", absenceFrom)
          .lt("synced_at", rowSyncedAt);
        await admin.from("brighthr_clockings").delete()
          .eq("connection_id", connectionId).eq("external_employee_id", employeeId)
          .gte("clock_in_at", `${clockingFrom}T00:00:00Z`).lt("clock_in_at", `${clockingTo}T00:00:00Z`)
          .lt("synced_at", rowSyncedAt);

        await admin.from("brighthr_employee_mappings")
          .update({ data_synced_at: rowSyncedAt })
          .eq("connection_id", connectionId).eq("external_employee_id", employeeId);

        result.absences += absences.length;
        result.clockings += clockings.length;
      } catch (error) {
        if (error instanceof BrightHrError && error.code === "invalid_credentials") throw error;
        console.error("brighthr: employee data sync failed", error instanceof BrightHrError ? error.code : error);
        markPartial(error instanceof BrightHrError ? error.code : "employee_sync_failed");
      }
    }

    // 4. Prune unlinked and expired data.
    const retentionCutoff = isoDate(today - RETENTION_DAYS * 86_400_000);
    const linkedFilter = `(${linkedIds.map((id) => `"${id.replaceAll('"', "")}"`).join(",")})`;
    for (const table of ["brighthr_absences", "brighthr_clockings"]) {
      let query = admin.from(table).delete().eq("connection_id", connectionId);
      if (linkedIds.length > 0) query = query.not("external_employee_id", "in", linkedFilter);
      await query;
    }
    await admin.from("brighthr_absences").delete().eq("connection_id", connectionId).lt("end_date", retentionCutoff);
    await admin.from("brighthr_clockings").delete().eq("connection_id", connectionId)
      .lt("clock_in_at", `${retentionCutoff}T00:00:00Z`);
  } catch (error) {
    result.status = "failed";
    result.errorCode = error instanceof BrightHrError ? error.code : "internal_error";
    if (!(error instanceof BrightHrError)) console.error("brighthr: sync failed", error);
  }

  const finishedAt = new Date(now()).toISOString();
  const credentialFailure = result.errorCode === "invalid_credentials" || result.errorCode === "forbidden";
  const nextSyncMs = result.status === "succeeded"
    ? SYNC_INTERVAL_MS
    : credentialFailure
    ? CREDENTIAL_ERROR_BACKOFF_MS
    : result.errorCode === "time_budget_exhausted"
    ? RETRY_SOON_MS
    : RETRY_SOON_MS * 3;

  await admin.from("brighthr_connections").update({
    status: credentialFailure ? "error" : "connected",
    last_sync_at: finishedAt,
    last_sync_status: result.status,
    last_error: result.status === "succeeded" || !result.errorCode ? null : userFacingError(result.errorCode),    next_sync_at: new Date(now() + nextSyncMs).toISOString(),
    sync_lease_until: null,
  }).eq("id", connectionId);

  if (run?.id) {
    await admin.from("brighthr_sync_runs").update({
      status: result.status,
      employees_synced: result.employees,
      absences_synced: result.absences,
      clockings_synced: result.clockings,
      error_code: result.errorCode,
      finished_at: finishedAt,
    }).eq("id", run.id);
  }

  return result;
}
