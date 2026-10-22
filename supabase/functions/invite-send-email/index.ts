// Emails a staff invitation (launch review A1: invited staff used to get nothing). The app
// creates or renews the invite with public.create_invite / public.resend_invite, then calls this
// function with the invite id. Sent through Resend, the same provider and secrets as
// crm-send-email (RESEND_API_KEY, EMAIL_FROM_TENANT or EMAIL_FROM).
//
// Authorization: the invite is read through the CALLER's RLS-respecting client, and invites are
// only visible to that venue's managers and the organization's owners/admins
// (invites_select_managers), so nobody else can trigger a send. The recipient is the address
// stored on the invite, never one from the request.
//
// Anti-abuse: quota-limited per sender, per organization and per invited address (fails closed,
// like every outbound email). The message is plain text: venue and organization names are
// tenant-controlled and are never interpreted as markup.
//
// The link opens the web app's join screen (INVITE_LINK_BASE_URL, default
// https://venuewrangler.com/app/), which signs the person up or in with the invited address and
// accepts this invite once their email is verified.
import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import { enforceRateLimit } from "../_shared/rate-limit.ts";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";

initObservability();

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DAY_SECONDS = 24 * 60 * 60;
const DEFAULT_LINK_BASE = "https://venuewrangler.com/app/";

const ROLE_LABELS: Record<string, string> = {
  venue_manager: "venue manager",
  supervisor: "supervisor",
  staff: "team member",
};

function envInt(name: string, fallback: number): number {
  const parsed = parseInt(Deno.env.get(name) ?? "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

// The Flutter web app uses hash routing (/app/#/join), so the invite parameters live in the
// fragment where the app's router reads them.
function inviteLink(base: string, inviteId: string, email: string): string {
  const root = base.endsWith("/") ? base : `${base}/`;
  const query = new URLSearchParams({ invite: inviteId, email }).toString();
  return `${root}#/join?${query}`;
}

// Rate-limit keys are capped at 200 characters, so the address is hashed.
async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

// Strips control characters (and so header/line injection) from tenant-provided names.
function clean(value: unknown, fallback: string): string {
  if (typeof value !== "string") return fallback;
  // deno-lint-ignore no-control-regex
  const trimmed = value.replace(/[\u0000-\u001f\u007f]+/g, " ").trim();
  return trimmed.length > 0 ? trimmed.slice(0, 120) : fallback;
}

Deno.serve(async (req) => {
  const preflight = handleCorsPreflight(req);
  if (preflight) return preflight;

  try {
    return await handleRequest(req);
  } catch (error) {
    console.error("invite-send-email: unexpected error", error);
    captureException(error, { function: "invite-send-email", path: new URL(req.url).pathname });
    await flushObservability();
    return jsonResponse({ error: "internal_error" }, 500);
  }
});

async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return jsonResponse({ error: "missing_authorization_header" }, 401);
  }

  let payload: { invite_id?: unknown };
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "invalid_json_body" }, 400);
  }
  if (typeof payload.invite_id !== "string" || !UUID_PATTERN.test(payload.invite_id)) {
    return jsonResponse({ error: "missing_invite_id" }, 400);
  }
  const inviteId = payload.invite_id;

  const userClient = createUserClient(authHeader);
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    return jsonResponse({ error: "invalid_or_expired_session" }, 401);
  }
  const sender = userData.user;

  // RLS: only managers of the invite's venue (and org owners/admins) can see it.
  const { data: invite, error: inviteError } = await userClient
    .from("invites")
    .select("id, organization_id, venue_id, email, role, status, expires_at, full_name")
    .eq("id", inviteId)
    .maybeSingle();
  if (inviteError || !invite) {
    return jsonResponse({ error: "invite_not_found" }, 404);
  }
  if (invite.status !== "pending" || new Date(invite.expires_at as string).getTime() <= Date.now()) {
    return jsonResponse({ error: "invite_not_pending" }, 409);
  }
  const recipient = typeof invite.email === "string" ? invite.email.trim().toLowerCase() : "";
  if (!EMAIL_PATTERN.test(recipient)) {
    return jsonResponse({ error: "invalid_recipient" }, 400);
  }

  const serviceClient = createServiceClient();
  const organizationId = invite.organization_id as string;

  // Sensitive send: the limiter fails CLOSED if it cannot be consulted.
  const userBlock = await enforceRateLimit(
    serviceClient,
    `invite-email:user:${sender.id}`,
    envInt("INVITE_EMAIL_USER_DAILY_LIMIT", 40),
    DAY_SECONDS,
    { failOpen: false },
  );
  if (userBlock) return userBlock;
  const orgBlock = await enforceRateLimit(
    serviceClient,
    `invite-email:org:${organizationId}`,
    envInt("INVITE_EMAIL_ORG_DAILY_LIMIT", 150),
    DAY_SECONDS,
    { failOpen: false },
  );
  if (orgBlock) return orgBlock;
  const recipientBlock = await enforceRateLimit(
    serviceClient,
    `invite-email:to:${organizationId}:${await sha256Hex(recipient)}`,
    envInt("INVITE_EMAIL_RECIPIENT_DAILY_LIMIT", 5),
    DAY_SECONDS,
    { failOpen: false },
  );
  if (recipientBlock) return recipientBlock;

  // Names for the message. The caller is already authorized for this invite.
  const [{ data: venue }, { data: organization }, { data: senderProfile }] = await Promise.all([
    serviceClient.from("venues").select("name").eq("id", invite.venue_id).maybeSingle(),
    serviceClient.from("organizations").select("name").eq("id", organizationId).maybeSingle(),
    serviceClient.from("profiles").select("display_name").eq("id", sender.id).maybeSingle(),
  ]);
  const venueName = clean(venue?.name, "your venue");
  const organizationName = clean(organization?.name, venueName);
  const inviterName = clean(senderProfile?.display_name, "Your manager");
  const inviteeName = clean(invite.full_name, "");
  const roleLabel = ROLE_LABELS[invite.role as string] ?? "team member";
  const expires = new Date(invite.expires_at as string).toLocaleDateString("en-US", {
    month: "long",
    day: "numeric",
    year: "numeric",
    timeZone: "UTC",
  });

  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  // Tenant-triggered mail goes out on the tenant stream, like crm-send-email.
  const fromAddress = Deno.env.get("EMAIL_FROM_TENANT") || Deno.env.get("EMAIL_FROM");
  if (!resendApiKey || !fromAddress) {
    console.error("Resend is not configured (RESEND_API_KEY / EMAIL_FROM unset)");
    return jsonResponse({ error: "email_not_configured" }, 503);
  }

  const link = inviteLink(Deno.env.get("INVITE_LINK_BASE_URL") || DEFAULT_LINK_BASE, inviteId, recipient);
  const greeting = inviteeName ? `Hi ${inviteeName},` : "Hi,";
  const venueLine = organizationName === venueName ? venueName : `${venueName} (${organizationName})`;
  const text = [
    greeting,
    "",
    `${inviterName} invited you to join ${venueLine} on Venue Wrangler as a ${roleLabel}.`,
    "",
    "Open this link to create your account (or sign in) and join the team:",
    link,
    "",
    `Use this email address (${recipient}). We will ask you to confirm it, then you land straight in ${venueName}.`,
    "Already have the Venue Wrangler app? Open it, choose \"Joining your team?\" and sign up or sign in with this address.",
    "",
    `This invitation expires on ${expires}. If it has expired, ask ${inviterName} to send a new one.`,
    "If you were not expecting this, you can ignore this email.",
  ].join("\n");

  const emailPayload: Record<string, unknown> = {
    from: fromAddress,
    to: [recipient],
    subject: `You're invited to join ${venueName} on Venue Wrangler`,
    text,
  };
  if (sender.email && EMAIL_PATTERN.test(sender.email)) emailPayload.reply_to = sender.email;

  const resendResponse = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(emailPayload),
    signal: AbortSignal.timeout(10000),
  });

  if (!resendResponse.ok) {
    const errBody = await resendResponse.text().catch(() => "");
    console.error("Resend send failed", resendResponse.status, errBody);
    return jsonResponse({ error: "email_send_failed" }, 502);
  }
  const resendResult = await resendResponse.json().catch(() => ({}));

  // Best effort: the email already went out, so a bookkeeping failure must not fail the call.
  const { error: recordError } = await serviceClient.rpc("record_invite_email_sent", {
    p_invite_id: inviteId,
  });
  if (recordError) console.error("failed to record invite email send", recordError);

  return jsonResponse({ ok: true, resend_id: resendResult?.id ?? null });
}
