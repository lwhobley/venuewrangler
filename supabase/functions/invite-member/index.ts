import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import {
  createServiceClient,
  createUserClient,
} from "../_shared/supabase-clients.ts";
import { enforceRateLimit } from "../_shared/rate-limit.ts";

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// The caller RPC authorizes the venue and derives organization and inviter. Never use a
// service-role insert for caller-supplied venue/role data. Sending failure remains visible.
export interface InviteDeps {
  userClient: typeof createUserClient;
  serviceClient: typeof createServiceClient;
  rateLimit: typeof enforceRateLimit;
  env: (name: string) => string | undefined;
  send: typeof fetch;
}
const defaults: InviteDeps = {
  userClient: createUserClient,
  serviceClient: createServiceClient,
  rateLimit: enforceRateLimit,
  env: (name) => Deno.env.get(name),
  send: (...args) => fetch(...args),
};
export async function handleInvite(
  req: Request,
  deps: InviteDeps = defaults,
): Promise<Response> {
  const preflight = handleCorsPreflight(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const header = req.headers.get("Authorization");
  if (!header) return json({ error: "unauthorized" }, 401);
  const user = deps.userClient(header);
  const { data: auth, error: authError } = await user.auth.getUser();
  if (authError || !auth.user) return json({ error: "unauthorized" }, 401);
  const body = await req.json().catch(() => null);
  if (
    !body || typeof body.venue_id !== "string" ||
    !/^[0-9a-f-]{36}$/i.test(body.venue_id) ||
    typeof body.email !== "string" || body.email.length > 254 ||
    !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(body.email) ||
    !["staff", "supervisor", "venue_manager"].includes(body.role) ||
    (body.display_name != null &&
      (typeof body.display_name !== "string" || body.display_name.length > 120))
  ) {
    return json({ error: "invalid_invite" }, 400);
  }
  const key = deps.env("RESEND_API_KEY");
  const from = deps.env("EMAIL_FROM");
  const appUrl = deps.env("INVITE_APP_URL");
  if (!key || !from || !appUrl || !appUrl.startsWith("https://")) {
    return json({ error: "invite_email_not_configured" }, 503);
  }
  const block = await deps.rateLimit(
    deps.serviceClient(),
    `invite:user:${auth.user.id}`,
    50,
    86400,
  );
  if (block) return block;
  const { data: invite, error } = await user.rpc("prepare_staff_invite", {
    p_venue_id: body.venue_id,
    p_email: body.email,
    p_role: body.role,
    p_display_name: body.display_name ?? null,
  });
  if (error || !invite) {
    return json(
      { error: "invite_not_allowed" },
      error?.code === "42501" ? 403 : 400,
    );
  }
  // No bearer token in this link: membership acceptance requires a confirmed session for
  // exactly the stored email. The configured URL is a deployment value, never request input.
  const response = await deps.send("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
      "Idempotency-Key": `staff-invite-${invite.id}`,
    },
    body: JSON.stringify({
      from,
      to: [invite.email],
      subject: "Join your team on Venue Wrangler",
      text:
        `Your manager invited you to Venue Wrangler. Open ${appUrl}, choose Join your team and sign up with ${invite.email}. Confirm your email, then accept your pending invitation. If you already have an account, sign in and open Invitations. This invitation expires in 14 days.`,
    }),
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) {
    return json(
      { error: "invite_saved_email_failed", invite_id: invite.id },
      502,
    );
  }
  return json({ ok: true, invite_id: invite.id });
}

if (import.meta.main) {
  Deno.serve(async (req) => {
    try {
      return await handleInvite(req);
    } catch {
      return json({ error: "invite_unavailable" }, 503);
    }
  });
}
