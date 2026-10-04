import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export const MANAGER_ROLES = ["venue_manager", "organization_owner", "organization_admin"];
export const MEMBER_ROLES = [
  "staff",
  "supervisor",
  "venue_manager",
  "organization_owner",
  "organization_admin",
];

// Org owners/admins hold org-level memberships (venue_id null), never venue rows — a
// venue_id-only lookup can never find them. Resolve the venue's organization first,
// then match either the venue row or the org row. Reads through the caller's own
// RLS-respecting client, never trusting venue_id alone.
export async function getCallerVenueRoles(
  userClient: SupabaseClient,
  userId: string,
  venueId: string,
): Promise<{ organizationId: string; roles: string[] } | null> {
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
