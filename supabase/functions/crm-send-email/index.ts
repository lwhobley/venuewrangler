// Sends a CRM email template to a lead/BEO contact via Resend. This is the only place
// `render_email_template`'s output is ever actually delivered — the RPC itself only does
// {{var}} substitution (see supabase/migrations/20261003005913_crm_schema.sql) and has no
// network access of its own to send anything.
//
// Authorization is delegated to render_email_template itself: it's `security definer` and
// raises 42501 if the caller isn't a venue_manager/organization_owner/organization_admin on
// the template's venue, so this function calls it through the caller's own RLS-respecting
// client rather than re-deriving that check here (same "derive, don't trust" discipline as
// ai-assistant and stripe-create-checkout).
//
// Anti-abuse (audit B-01): the recipient is NEVER taken from the request. The caller must name
// a lead or BEO, and the address is read server-side (through the caller's RLS) from that
// lead's stored email. A `to` in the payload is only accepted if it equals the stored address.
// Sends are also entitlement-gated and quota-limited per user and per organization.
import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import { enforceRateLimit, requireEntitlement } from "../_shared/rate-limit.ts";
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

function envInt(name: string, fallback: number): number {
  const parsed = parseInt(Deno.env.get(name) ?? "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

Deno.serve(async (req) => {
  const preflight = handleCorsPreflight(req);
  if (preflight) return preflight;

  try {
    return await handleRequest(req);
  } catch (error) {
    console.error("crm-send-email: unexpected error", error);
    captureException(error, { function: "crm-send-email", path: new URL(req.url).pathname });
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

  let payload: { template_id?: string; lead_id?: string; beo_id?: string; to?: string };
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "invalid_json_body" }, 400);
  }

  if (!payload.template_id || typeof payload.template_id !== "string") {
    return jsonResponse({ error: "missing_template_id" }, 400);
  }
  const hasLead = payload.lead_id !== undefined && payload.lead_id !== null;
  const hasBeo = payload.beo_id !== undefined && payload.beo_id !== null;
  if (!hasLead && !hasBeo) {
    return jsonResponse({ error: "missing_recipient_reference" }, 400);
  }
  if ((hasLead && (typeof payload.lead_id !== "string" || !UUID_PATTERN.test(payload.lead_id))) ||
    (hasBeo && (typeof payload.beo_id !== "string" || !UUID_PATTERN.test(payload.beo_id)))) {
    return jsonResponse({ error: "invalid_recipient_reference" }, 400);
  }
  if (payload.to !== undefined && payload.to !== null &&
    (typeof payload.to !== "string" || !EMAIL_PATTERN.test(payload.to))) {
    return jsonResponse({ error: "missing_or_invalid_to_address" }, 400);
  }

  const userClient = createUserClient(authHeader);
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    return jsonResponse({ error: "invalid_or_expired_session" }, 401);
  }
  const callerEmail = userData.user.email ?? null;

  // Resolve the template venue through the caller's client before sending.
  const { data: template, error: templateError } = await userClient
    .from("email_templates")
    .select("venue_id")
    .eq("id", payload.template_id)
    .maybeSingle();
  if (templateError || !template) {
    return jsonResponse({ error: "template_not_found" }, 404);
  }

  // Everything below reads through the caller's own RLS-respecting client.
  let leadIdForEmail: string | null = hasLead ? payload.lead_id! : null;
  if (hasBeo) {
    const { data: beo, error: beoError } = await userClient
      .from("crm_beos")
      .select("id, lead_id")
      .eq("id", payload.beo_id!)
      .eq("venue_id", template.venue_id)
      .maybeSingle();
    if (beoError || !beo) {
      return jsonResponse({ error: "beo_not_in_template_venue" }, 400);
    }
    if (hasLead) {
      if (beo.lead_id && beo.lead_id !== payload.lead_id) {
        return jsonResponse({ error: "beo_lead_mismatch" }, 400);
      }
    } else {
      // BEOs carry no contact email of their own; the contact is the BEO's lead.
      leadIdForEmail = (beo.lead_id as string | null) ?? null;
    }
  }

  let storedRecipient: string | null = null;
  let activityLeadId: string | null = null;
  if (leadIdForEmail) {
    const { data: lead, error: leadError } = await userClient
      .from("crm_leads")
      .select("id, email")
      .eq("id", leadIdForEmail)
      .eq("venue_id", template.venue_id)
      .maybeSingle();
    if (leadError || !lead) {
      return jsonResponse({ error: "lead_not_in_template_venue" }, 400);
    }
    storedRecipient = typeof lead.email === "string" ? lead.email.trim() : null;
    activityLeadId = lead.id as string;
  }
  if (!storedRecipient || !EMAIL_PATTERN.test(storedRecipient)) {
    return jsonResponse({ error: "recipient_has_no_email" }, 400);
  }
  if (payload.to && payload.to.trim().toLowerCase() !== storedRecipient.toLowerCase()) {
    return jsonResponse({ error: "recipient_mismatch" }, 400);
  }

  // Runs through the caller's own client: render_email_template is `security definer` but
  // still checks has_venue_role internally and raises 42501 if the caller isn't authorized for
  // this template's venue — a non-2xx/empty result here means that check failed.
  const { data: rendered, error: renderError } = await userClient
    .rpc("render_email_template", {
      p_template_id: payload.template_id,
      p_lead_id: leadIdForEmail,
      p_beo_id: payload.beo_id ?? null,
    })
    .maybeSingle<{ subject: string; body: string }>();

  if (renderError) {
    const forbidden = renderError.code === "42501";
    return jsonResponse(
      { error: forbidden ? "forbidden" : "template_render_failed" },
      forbidden ? 403 : 400,
    );
  }
  if (!rendered) {
    return jsonResponse({ error: "template_not_found" }, 404);
  }

  // Only authorized callers reach this point, so quota is never spent by an outsider.
  const serviceClient = createServiceClient();
  const { data: venue, error: venueError } = await userClient
    .from("venues")
    .select("organization_id")
    .eq("id", template.venue_id)
    .maybeSingle();
  if (venueError || !venue) {
    return jsonResponse({ error: "venue_not_found_or_not_a_member" }, 403);
  }
  const organizationId = venue.organization_id as string;

  const entitlementBlock = await requireEntitlement(serviceClient, organizationId);
  if (entitlementBlock) return entitlementBlock;

  // Sensitive send: the limiter fails CLOSED if it cannot be consulted.
  const userBlock = await enforceRateLimit(
    serviceClient,
    `email:user:${userData.user.id}`,
    envInt("CRM_EMAIL_USER_DAILY_LIMIT", 50),
    DAY_SECONDS,
    { failOpen: false },
  );
  if (userBlock) return userBlock;
  const orgBlock = await enforceRateLimit(
    serviceClient,
    `email:org:${organizationId}`,
    envInt("CRM_EMAIL_ORG_DAILY_LIMIT", 200),
    DAY_SECONDS,
    { failOpen: false },
  );
  if (orgBlock) return orgBlock;

  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  // Tenant mail goes out on its own sending stream/subdomain so a bad tenant cannot damage
  // deliverability of platform (auth, billing) mail sent from EMAIL_FROM.
  const fromAddress = Deno.env.get("EMAIL_FROM_TENANT") || Deno.env.get("EMAIL_FROM");
  if (!resendApiKey || !fromAddress) {
    console.error("Resend is not configured (RESEND_API_KEY / EMAIL_FROM unset)");
    return jsonResponse({ error: "email_not_configured" }, 503);
  }

  const emailPayload: Record<string, unknown> = {
    from: fromAddress,
    to: [storedRecipient],
    subject: rendered.subject,
    // render_email_template's substitution is plain-text ({{var}} replacement, no HTML
    // escaping) — sending as text/plain avoids interpreting template body content as markup.
    text: rendered.body,
  };
  // Replies go to the signed-in sender, not to the shared platform mailbox.
  if (callerEmail && EMAIL_PATTERN.test(callerEmail)) emailPayload.reply_to = callerEmail;
  const unsubscribeAddress = Deno.env.get("EMAIL_UNSUBSCRIBE_ADDRESS");
  if (unsubscribeAddress && EMAIL_PATTERN.test(unsubscribeAddress)) {
    emailPayload.headers = { "List-Unsubscribe": `<mailto:${unsubscribeAddress}>` };
  }

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

  // Best-effort activity log entry (service-role: crm_activity_log has no client insert
  // policy, matching the rest of this module's audit trail). A logging failure here must never
  // fail the overall send — the email already went out.
  if (activityLeadId) {
    const { data: lead } = await serviceClient
      .from("crm_leads")
      .select("organization_id, venue_id")
      .eq("id", activityLeadId)
      .eq("venue_id", template.venue_id)
      .maybeSingle();
    if (lead) {
      const { error: logError } = await serviceClient.from("crm_activity_log").insert({
        organization_id: lead.organization_id,
        venue_id: lead.venue_id,
        lead_id: activityLeadId,
        actor_id: userData.user.id,
        kind: "email_sent",
        detail: `Sent "${rendered.subject}" to ${storedRecipient}`,
      });
      if (logError) console.error("failed to log crm email activity", logError);
    }
  }

  return jsonResponse({ ok: true, resend_id: resendResult?.id ?? null });
}
