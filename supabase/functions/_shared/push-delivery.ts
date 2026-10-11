// Shared push delivery: resolves a notification's recipients to device tokens and sends via
// native APNs (iOS) or FCM (Android/web). Used by both notifications-send (a signed-in manager
// sending an ad-hoc notification) and notifications-dispatch (the database trigger path), so
// the two can never drift in how they pick recipients or treat dead tokens.
import type { SupabaseClient } from "@supabase/supabase-js";
import { getGoogleAccessToken } from "./google-auth.ts";
import { loadApnsConfigFromEnv, sendApnsPush } from "./apns.ts";

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

export type NotificationAudience = "user" | "venue_managers" | "venue_staff" | "organization_owners";

export interface PushRequest {
  venueId: string;
  organizationId: string;
  audience: NotificationAudience;
  targetUserIds?: string[];
  kind: string;
  title: string;
  body: string;
  data?: Record<string, unknown>;
}

export interface PushResult {
  targeted_tokens: number;
  delivered_count: number;
  dead_tokens_disabled: number;
  reason?: string;
}

export async function deliverPush(adminClient: SupabaseClient, req: PushRequest): Promise<PushResult> {
  const { venueId, organizationId, audience, targetUserIds, kind, title, body, data = {} } = req;

  let tokensQuery = adminClient
    .from("push_tokens")
    .select("token, platform, user_id")
    .eq("venue_id", venueId)
    .eq("enabled", true);

  // Revalidate every recipient at delivery time. Push-token registrations can outlive a
  // membership, and direct user targets are not an authorization decision.
  let membershipQuery = adminClient
    .from("memberships")
    .select("user_id, venue_id, role")
    .eq("organization_id", organizationId)
    .or(`venue_id.eq.${venueId},venue_id.is.null`);
  if (audience === "user") {
    membershipQuery = membershipQuery.in("user_id", targetUserIds ?? []);
  }

  const { data: memberships, error: membershipError } = await membershipQuery;
  if (membershipError || !memberships) {
    console.error("Failed to resolve current push recipients", membershipError);
    return { targeted_tokens: 0, delivered_count: 0, dead_tokens_disabled: 0, reason: "Could not verify recipient membership" };
  }

  const allowedUsers = new Set<string>();
  for (const membership of memberships as { user_id: string; venue_id: string | null; role: string }[]) {
    const isOrgManager = membership.venue_id === null &&
      ["organization_owner", "organization_admin"].includes(membership.role);
    const isVenueManager = membership.venue_id === venueId && membership.role === "venue_manager";
    const isVenueStaff = isOrgManager || (membership.venue_id === venueId &&
      ["staff", "supervisor", "venue_manager"].includes(membership.role));
    if (
      audience === "user" ||
      (audience === "venue_staff" && isVenueStaff) ||
      (audience === "venue_managers" && (isVenueManager || isOrgManager)) ||
      (audience === "organization_owners" && membership.venue_id === null &&
        membership.role === "organization_owner")
    ) {
      allowedUsers.add(membership.user_id);
    }
  }
  tokensQuery = tokensQuery.in("user_id", [...allowedUsers]);

  const { data: tokens, error: tokensError } = await tokensQuery;
  if (tokensError || !tokens || tokens.length === 0) {
    return { targeted_tokens: 0, delivered_count: 0, dead_tokens_disabled: 0, reason: "No active push tokens found" };
  }

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

  // The Flutter client registers raw APNs device tokens on iOS, so iOS delivery requires all
  // four APNS_* secrets — without them iOS tokens fall through to FCM, which can't deliver
  // to a raw APNs token.
  const apnsConfig = loadApnsConfigFromEnv();

  const deadTokens: string[] = [];
  let deliveredCount = 0;

  for (const { token, platform } of tokens as { token: string; platform: string }[]) {
    if (platform === "ios" && apnsConfig) {
      try {
        const payload = { ...data, kind, venue_id: venueId, organization_id: organizationId };
        const message = { deviceToken: token, title, body, data: payload };
        let result = await sendApnsPush(apnsConfig, message);
        // Xcode debug builds register sandbox tokens; TestFlight/App Store builds register
        // production ones, and each gateway rejects the other's as BadDeviceToken — try the
        // other environment before declaring the token dead.
        if (!result.ok && result.reason === "BadDeviceToken") {
          result = await sendApnsPush({ ...apnsConfig, sandbox: !apnsConfig.sandbox }, message);
        }
        if (result.ok) {
          deliveredCount++;
        } else if (
          result.reason === "BadDeviceToken" || result.reason === "Unregistered" || result.status === 410
        ) {
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
      if (!fcmToken || !fcmProjectId) continue;
      try {
        const res = await fetch(`https://fcm.googleapis.com/v1/projects/${fcmProjectId}/messages:send`, {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${fcmToken}` },
          body: JSON.stringify({
            message: {
              token,
              notification: { title, body },
              data: Object.fromEntries(
                Object.entries({ ...data, kind, venue_id: venueId, organization_id: organizationId })
                  .map(([k, v]) => [k, String(v)]),
              ),
            },
          }),
          signal: AbortSignal.timeout(5000),
        });
        if (res.ok) {
          deliveredCount++;
        } else {
          const errBody = await res.json().catch(() => ({}));
          const errCode = errBody?.error?.details?.[0]?.errorCode || errBody?.error?.status;
          if (errCode === "UNREGISTERED" || res.status === 404) deadTokens.push(token);
        }
      } catch (err) {
        console.warn("Failed sending FCM push to token:", err);
      }
    }
  }

  // A direct update, not rpc("disable_push_tokens"): that function lives in app_hidden, which
  // PostgREST doesn't expose. Scoped to this venue so one venue's dead-token report can't
  // disable the same device's registration at another venue.
  if (deadTokens.length > 0) {
    const now = new Date().toISOString();
    const { error: disableError } = await adminClient
      .from("push_tokens")
      .update({ enabled: false, disabled_at: now, updated_at: now })
      .eq("venue_id", venueId)
      .in("token", deadTokens)
      .eq("enabled", true);
    if (disableError) console.error("failed to disable dead push tokens", disableError);
  }

  return {
    targeted_tokens: tokens.length,
    delivered_count: deliveredCount,
    dead_tokens_disabled: deadTokens.length,
  };
}
