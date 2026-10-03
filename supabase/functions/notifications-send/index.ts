import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import { getGoogleAccessToken } from "../_shared/google-auth.ts";

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

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

    // Verify the caller actually belongs to this venue before letting them notify anyone in
    // it — never trust a venue_id the client sends without checking it against their own
    // RLS-respecting membership first (same pattern as toast-pos's outbound-command check).
    const { data: callerMembership, error: callerMembershipError } = await userClient
      .from("memberships")
      .select("role")
      .eq("venue_id", venue_id)
      .maybeSingle();

    if (callerMembershipError || !callerMembership) {
      return new Response(JSON.stringify({ error: "Forbidden: not a member of this venue" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const managerRoles = ["venue_manager", "organization_owner", "organization_admin"];
    const isManager = managerRoles.includes(callerMembership.role);
    if (audience !== "user" && !isManager) {
      return new Response(JSON.stringify({ error: "Forbidden: manager role required to notify a venue-wide audience" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (audience === "user" && target_user_ids && target_user_ids.some((id) => id !== user.id) && !isManager) {
      return new Response(JSON.stringify({ error: "Forbidden: manager role required to notify other users" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const adminClient = createServiceClient();

    // 1. Write in-app notification event(s) first (independent of push delivery success)
    if (audience === "user" && target_user_ids && target_user_ids.length > 0) {
      const rows = target_user_ids.map((uid) => ({
        venue_id,
        target_user_id: uid,
        audience: "user" as const,
        kind,
        title,
        body,
        data,
      }));
      await adminClient.from("notification_events").insert(rows);
    } else {
      await adminClient.from("notification_events").insert({
        venue_id,
        audience,
        kind,
        title,
        body,
        data,
      });
    }

    // 2. Resolve target tokens
    let tokensQuery = adminClient
      .from("push_tokens")
      .select("token, platform, user_id")
      .eq("venue_id", venue_id)
      .eq("enabled", true);

    if (audience === "user" && target_user_ids && target_user_ids.length > 0) {
      tokensQuery = tokensQuery.in("user_id", target_user_ids);
    } else if (audience === "venue_managers") {
      // Find venue managers and owners
      const { data: managerMembers } = await adminClient
        .from("memberships")
        .select("user_id")
        .eq("venue_id", venue_id)
        .in("role", ["venue_manager", "organization_owner", "organization_admin"]);
      const managerIds = (managerMembers || []).map((m: { user_id: string }) => m.user_id);
      if (managerIds.length > 0) {
        tokensQuery = tokensQuery.in("user_id", managerIds);
      } else {
        tokensQuery = tokensQuery.in("user_id", []); // No managers found
      }
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

    const deadTokens: string[] = [];
    let deliveredCount = 0;

    for (const tokenRecord of tokens) {
      const { token, platform } = tokenRecord;
      if (platform === "android" || platform === "web" || !Deno.env.get("APNS_KEY")) {
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

    // 4. Disable dead tokens if any were reported
    if (deadTokens.length > 0) {
      await adminClient.rpc("disable_push_tokens", { p_tokens: deadTokens });
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
    const message = error instanceof Error ? error.message : String(error);
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
