import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import { getGoogleAccessToken } from "../_shared/google-auth.ts";
import { loadApnsConfigFromEnv, sendApnsPush } from "../_shared/apns.ts";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";

initObservability();

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
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

    // 2. Resolve target tokens
    let tokensQuery = adminClient
      .from("push_tokens")
      .select("token, platform, user_id")
      .eq("venue_id", venue_id)
      .eq("enabled", true);

    if (audience === "user") {
      tokensQuery = tokensQuery.in("user_id", target_user_ids!);
    } else if (audience === "venue_managers" || audience === "organization_owners") {
      // Org owners/admins hold org-level memberships (venue_id null), never venue rows — a
      // venue_id-only lookup can never find them. venue_staff is intentionally unfiltered.
      const orgFilter = audience === "venue_managers"
        ? `and(venue_id.eq.${venue_id},role.eq.venue_manager),and(venue_id.is.null,organization_id.eq.${venue!.organization_id},role.in.(organization_owner,organization_admin))`
        : `and(venue_id.is.null,organization_id.eq.${venue!.organization_id},role.eq.organization_owner)`;
      const { data: recipients } = await adminClient
        .from("memberships")
        .select("user_id")
        .or(orgFilter);
      const recipientIds = (recipients || []).map((m: { user_id: string }) => m.user_id);
      tokensQuery = tokensQuery.in("user_id", recipientIds);
    }

    const { data: tokens, error: tokensError } = await tokensQuery;
    if (tokensError || !tokens || tokens.length === 0) {
      return new Response(JSON.stringify({ ok: true, delivered_count: 0, reason: "No active push tokens found" }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // 3. Deliver via direct FCM / APNs (best-effort, delivery errors never throw to caller)
    const fcmServiceAccount = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
    let fcmToken: string | null = null;
    let fcmProjectId: string | null = null;
    if (fcmServiceAccount) {
      try {
        const parsed = JSON.parse(fcmServiceAccount);
        fcmProjectId = parsed.project_id;
        fcmToken = await getGoogleAccessToken(fcmServiceAccount, FCM_SCOPE);
      } catch (err) {
        console.warn("FCM service account configuration invalid or token exchange failed:", err);
      }
    }

    // Native APNs dispatch for iOS tokens. The Flutter client registers raw APNs device tokens
    // (ios/Runner/PushNotificationsPlugin.swift), so iOS delivery requires all four APNS_*
    // secrets — without them iOS tokens fall through to FCM below, which can't deliver to a
    // raw APNs token.
    const apnsConfig = loadApnsConfigFromEnv();

    const deadTokens: string[] = [];
    let deliveredCount = 0;

    for (const tokenRecord of tokens) {
      const { token, platform } = tokenRecord;

      if (platform === "ios" && apnsConfig) {
        try {
          const message = { deviceToken: token, title, body, data: { kind, ...data } };
          let result = await sendApnsPush(apnsConfig, message);
          // Xcode debug builds register sandbox tokens; TestFlight/App Store builds register
          // production ones. Each gateway rejects the other's tokens as BadDeviceToken, so try
          // the other environment before declaring the token dead — otherwise every dev-build
          // token gets disabled on its first push.
          if (!result.ok && result.reason === "BadDeviceToken") {
            result = await sendApnsPush({ ...apnsConfig, sandbox: !apnsConfig.sandbox }, message);
          }
          if (result.ok) {
            deliveredCount++;
          } else if (result.reason === "BadDeviceToken" || result.reason === "Unregistered" || result.status === 410) {
            deadTokens.push(token);
          } else {
            console.warn(`APNs push failed (status ${result.status}): ${result.reason ?? "unknown"}`);
          }
        } catch (err) {
          console.warn("Failed sending APNs push to token:", err);
        }
        continue;
      }

      if (platform === "android" || platform === "web" || (platform === "ios" && !apnsConfig)) {
        // FCM HTTP v1 dispatch
        if (!fcmToken || !fcmProjectId) {
          continue;
        }

        try {
          const res = await fetch(`https://fcm.googleapis.com/v1/projects/${fcmProjectId}/messages:send`, {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Authorization: `Bearer ${fcmToken}`,
            },
            body: JSON.stringify({
              message: {
                token,
                notification: { title, body },
                data: { kind, ...Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v)])) },
              },
            }),
            signal: AbortSignal.timeout(5000),
          });

          if (res.ok) {
            deliveredCount++;
          } else {
            const errBody = await res.json().catch(() => ({}));
            const errCode = errBody?.error?.details?.[0]?.errorCode || errBody?.error?.status;
            if (errCode === "UNREGISTERED" || res.status === 404) {
              deadTokens.push(token);
            }
          }
        } catch (err) {
          console.warn(`Failed sending FCM push to token:`, err);
        }
      }
    }

    // 4. Disable dead tokens if any were reported. A direct update, not
    // rpc("disable_push_tokens"): that function lives in app_hidden, which PostgREST doesn't
    // expose, so the RPC call always failed — and its error was never checked.
    if (deadTokens.length > 0) {
      const now = new Date().toISOString();
      const { error: disableError } = await adminClient
        .from("push_tokens")
        .update({ enabled: false, disabled_at: now, updated_at: now })
        .in("token", deadTokens)
        .eq("enabled", true);
      if (disableError) {
        console.error("failed to disable dead push tokens", disableError);
      }
    }

    return new Response(
      JSON.stringify({
        ok: true,
        targeted_tokens: tokens.length,
        delivered_count: deliveredCount,
        dead_tokens_disabled: deadTokens.length,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
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
