// deno.land/std's bare-URL import doesn't resolve via deno.json's import map the way
// npm:/jsr: specifiers do once nodeModulesDir is "auto" (see deno.json).
// deno-lint-ignore no-import-prefix
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import { deliverPush } from "../_shared/push-delivery.ts";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";

initObservability();

const MANAGER_ROLES = ["venue_manager", "organization_owner", "organization_admin"];
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface NotificationRequest {
  venue_id: string;
  target_user_ids?: string[];
  audience?: "user" | "venue_managers" | "venue_staff" | "organization_owners";
  kind: string;
  title: string;
  body: string;
  data?: Record<string, unknown>;
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing Authorization header" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Authenticate caller
    const userClient = createUserClient(authHeader);
    const { data: { user }, error: userError } = await userClient.auth.getUser();
    if (userError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const payload: NotificationRequest = await req.json();
    const { venue_id, target_user_ids, audience = "user", kind, title, body, data = {} } = payload;

    if (!venue_id || !kind || !title || !body) {
      return new Response(JSON.stringify({ error: "Missing required fields: venue_id, kind, title, body" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // venue_id is interpolated into a PostgREST filter below — validate it first so a crafted
    // value can't inject extra filter clauses.
    if (!UUID_PATTERN.test(venue_id)) {
      return new Response(JSON.stringify({ error: "Invalid venue_id" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (!(["user", "venue_managers", "venue_staff", "organization_owners"] as string[]).includes(audience) ||
      (target_user_ids !== undefined &&
        (!Array.isArray(target_user_ids) || target_user_ids.length > 100 ||
          target_user_ids.some((id) => typeof id !== "string" || !UUID_PATTERN.test(id)))) ||
      data === null || Array.isArray(data) || typeof data !== "object" ||
      ["origin", "aps", "kind", "alert", "sound"].some((key) => Object.hasOwn(data, key))) {
      return new Response(JSON.stringify({ error: "Invalid notification payload" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    // An unfiltered "user" audience used to fall through to every token at the venue, letting
    // any member broadcast. Individual notifications must name their recipients.
    if (audience === "user" && (!target_user_ids || target_user_ids.length === 0)) {
      return new Response(JSON.stringify({ error: "target_user_ids is required for audience 'user'" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const adminClient = createServiceClient();

    const { data: venue } = await adminClient
      .from("venues")
      .select("organization_id")
      .eq("id", venue_id)
      .maybeSingle();

    // Membership is either venue-scoped (venue_manager/supervisor/staff, venue_id set) or
    // org-scoped (organization_owner/admin, venue_id null — enforced by
    // memberships_org_level_roles_check). Same model as app_hidden.is_venue_member. Read
    // through the caller's own RLS-respecting client, never trusting venue_id alone.
    const { data: callerMemberships, error: callerMembershipError } = venue
      ? await userClient
          .from("memberships")
          .select("role")
          .eq("user_id", user.id)
          .or(`venue_id.eq.${venue_id},and(venue_id.is.null,organization_id.eq.${venue.organization_id})`)
      : { data: null, error: null };

    if (callerMembershipError || !callerMemberships || callerMemberships.length === 0) {
      return new Response(JSON.stringify({ error: "Forbidden: not a member of this venue" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const isManager = callerMemberships.some((m: { role: string }) => MANAGER_ROLES.includes(m.role));
    if (audience !== "user" && !isManager) {
      return new Response(JSON.stringify({ error: "Forbidden: manager role required to notify a venue-wide audience" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (audience === "user" && target_user_ids!.some((id) => id !== user.id) && !isManager) {
      return new Response(JSON.stringify({ error: "Forbidden: manager role required to notify other users" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (audience === "user") {
      const recipients = [...new Set(target_user_ids!)];
      const { data: memberships, error: recipientError } = await adminClient
        .from("memberships")
        .select("user_id")
        .eq("organization_id", venue!.organization_id)
        .in("user_id", recipients)
        .or(`venue_id.eq.${venue_id},venue_id.is.null`);
      if (recipientError) throw recipientError;
      const members = new Set((memberships ?? []).map((row: { user_id: string }) => row.user_id));
      if (recipients.some((id) => !members.has(id))) {
        return new Response(JSON.stringify({ error: "Recipient is not a member of this venue" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    }

    // 1. Write in-app notification event(s) first (independent of push delivery success)
    if (audience === "user") {
      const rows = target_user_ids!.map((uid) => ({
        venue_id,
        target_user_id: uid,
        audience: "user" as const,
        kind,
        title,
        body,
        data,
      }));
      const { error: insertError } = await adminClient.from("notification_events").insert(rows);
      if (insertError) throw insertError;
    } else {
      const { error: insertError } = await adminClient.from("notification_events").insert({
        venue_id,
        audience,
        kind,
        title,
        body,
        data,
      });
      if (insertError) throw insertError;
    }

    // 2. Deliver (shared with notifications-dispatch — see _shared/push-delivery.ts)
    const result = await deliverPush(adminClient, {
      venueId: venue_id,
      organizationId: venue!.organization_id,
      audience,
      targetUserIds: target_user_ids,
      kind,
      title,
      body,
      data,
    });

    return new Response(JSON.stringify({ ok: true, ...result }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("notifications-send failed", error);
    captureException(error, { function: "notifications-send", url: req.url });
    await flushObservability();
    return new Response(JSON.stringify({ error: "notification_send_failed" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
