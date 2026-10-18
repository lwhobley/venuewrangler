import type { SupabaseClient } from "@supabase/supabase-js";

export const MANAGER_ROLES = ["venue_manager", "organization_owner", "organization_admin"];
export const MEMBER_ROLES = [
  "staff",
  "supervisor",
  "venue_manager",
  "organization_owner",
  "organization_admin",
];

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** True only for a canonical UUID string. Gate for any id interpolated into a PostgREST filter. */
export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

// Org owners/admins hold org-level memberships (venue_id null), never venue rows — a
// venue_id-only lookup can never find them. Resolve the venue's organization first,
// then match either the venue row or the org row. Reads through the caller's own
// RLS-respecting client, never trusting venue_id alone.
export async function getCallerVenueRoles(
  userClient: SupabaseClient,
  userId: string,
  venueId: string,
): Promise<{ organizationId: string; roles: string[] } | null> {
  // venueId is interpolated into a PostgREST .or() filter below; a non-UUID could inject
  // extra filter clauses (audit B-09), so treat it as "no such venue" (callers answer 403/404;
  // endpoints that want a 400 should check isUuid() themselves first).
  if (!isUuid(venueId) || !isUuid(userId)) return null;
  const { data: venue } = await userClient
    .from("venues")
    .select("organization_id")
    .eq("id", venueId)
    .maybeSingle();
  if (!venue) return null;
  const organizationId = venue.organization_id as string;
  const { data: memberships } = await userClient
    .from("memberships")
    .select("role")
    .eq("user_id", userId)
    .or(`venue_id.eq.${venueId},and(venue_id.is.null,organization_id.eq.${organizationId})`);
  if (!memberships || memberships.length === 0) return null;
  return {
    organizationId,
    roles: (memberships as { role: string }[]).map((m) => m.role),
  };
}

export function isManager(roles: string[]): boolean {
  return roles.some((r) => MANAGER_ROLES.includes(r));
}

/** Rechecks manager authority using the service client at sensitive callback time. */
export async function isCurrentVenueManager(
  adminClient: SupabaseClient,
  userId: string,
  venueId: string,
): Promise<boolean> {
  if (!isUuid(venueId) || !isUuid(userId)) return false;
  const { data: venue, error: venueError } = await adminClient
    .from("venues")
    .select("organization_id")
    .eq("id", venueId)
    .maybeSingle();
  if (venueError || !venue) return false;

  const { data: memberships, error: membershipError } = await adminClient
    .from("memberships")
    .select("role")
    .eq("user_id", userId)
    .eq("organization_id", venue.organization_id)
    .or(`venue_id.eq.${venueId},venue_id.is.null`);
  if (membershipError || !memberships) return false;
  return isManager(memberships.map((membership) => membership.role));
}
