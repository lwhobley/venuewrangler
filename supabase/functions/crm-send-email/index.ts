// Sends a CRM email template to a lead/BEO contact via Resend. This is the only place
// `render_email_template`'s output is ever actually delivered — the RPC itself only does
// {{var}} substitution (see supabase/migrations/20261003002000_crm_schema.sql) and has no
// network access of its own to send anything.
//
// Authorization is delegated to render_email_template itself: it's `security definer` and
// raises 42501 if the caller isn't a venue_manager/organization_owner/organization_admin on
// the template's venue, so this function calls it through the caller's own RLS-respecting
// client rather than re-deriving that check here (same "derive, don't trust" discipline as
// ai-assistant and stripe-create-checkout).
import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";

initObservability();

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

Deno.serve(async (req) => {
  const preflight = handleCorsPreflight(req);
  if (preflight) return preflight;

  try {
    return await handleRequest(req);
  } catch (error) {
    console.error("crm-send-email: unexpected error", error);
    captureException(error, { function: "crm-send-email", url: req.url });
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
  if (!payload.to || !EMAIL_PATTERN.test(payload.to)) {
    return jsonResponse({ error: "missing_or_invalid_to_address" }, 400);
  }

  const userClient = createUserClient(authHeader);
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    return jsonResponse({ error: "invalid_or_expired_session" }, 401);
  }

  // Runs through the caller's own client: render_email_template is `security definer` but
  // still checks has_venue_role internally and raises 42501 if the caller isn't authorized for
  // this template's venue — a non-2xx/empty result here means that check failed.
  const { data: rendered, error: renderError } = await userClient
    .rpc("render_email_template", {
      p_template_id: payload.template_id,
      p_lead_id: payload.lead_id ?? null,
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

  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  const fromAddress = Deno.env.get("EMAIL_FROM");
  if (!resendApiKey || !fromAddress) {
    console.error("Resend is not configured (RESEND_API_KEY / EMAIL_FROM unset)");
    return jsonResponse({ error: "email_not_configured" }, 503);
  }

  const resendResponse = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: fromAddress,
      to: [payload.to],
      subject: rendered.subject,
      // render_email_template's substitution is plain-text ({{var}} replacement, no HTML
      // escaping) — sending as text/plain avoids interpreting template body content as markup.
      text: rendered.body,
    }),
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
  if (payload.lead_id) {
    const serviceClient = createServiceClient();
    const { data: lead } = await serviceClient
      .from("crm_leads")
      .select("organization_id, venue_id")
      .eq("id", payload.lead_id)
      .maybeSingle();
    if (lead) {
      const { error: logError } = await serviceClient.from("crm_activity_log").insert({
        organization_id: lead.organization_id,
        venue_id: lead.venue_id,
        lead_id: payload.lead_id,
        actor_id: userData.user.id,
        kind: "email_sent",
        detail: `Sent "${rendered.subject}" to ${payload.to}`,
      });
      if (logError) console.error("failed to log crm email activity", logError);
    }
  }

  return jsonResponse({ ok: true, resend_id: resendResult?.id ?? null });
}
