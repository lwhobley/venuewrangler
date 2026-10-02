import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

// RLS-respecting client: forwards the caller's own JWT, so every query runs under their
// actual permissions. Used to verify the caller is who they claim and belongs to the venue
// they're asking about — never trust a venue_id/organization_id the client sends without
// this check passing first.
export function createUserClient(authHeader: string): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
}

// Bypasses RLS entirely. Only used for the writes that are policy-forbidden to `authenticated`
// by design (ai_usage_events, ai_budget_reservations) — never used to read or write anything
// the caller's own membership wouldn't already entitle them to.
export function createServiceClient(): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
}
