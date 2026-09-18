import { button, infoTable, p, renderEmailHtml } from '../email-brand';
import type { EmailMessage } from './auth';

export function joinRequestDecidedTemplate(args: { fullName: string; venueName: string; approved: boolean; note?: string | null }): EmailMessage {
  const statusText = args.approved ? 'Approved' : 'Rejected';
  const subject = `Your request to join ${args.venueName} was ${statusText.toLowerCase()}`;
  const rows: Array<[string, string]> = [
    ['Venue', args.venueName],
    ['Status', statusText],
  ];
  if (args.note?.trim()) rows.push(["Manager's note", args.note.trim()]);
  const outcomeLine = args.approved
    ? `You can now sign in to the Venue Wrangler app to see your schedule and get started.`
    : `If you think this was a mistake, reach out to your venue manager directly.`;
  const rowsText = rows.map(([k, v]) => `${k}: ${v}`).join('\n');
  const text =
    `Hi ${args.fullName},\n\n` +
    `Your request to join ${args.venueName} was ${statusText.toLowerCase()} by a manager.\n\n` +
    `${rowsText}\n\n` +
    `${outcomeLine}\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: `Your request to join ${args.venueName} was ${statusText.toLowerCase()}`,
    heading: `Request ${statusText.toLowerCase()}`,
    accent: args.approved ? 'primary' : 'danger',
    bodyRows: [
      p`Hi ${args.fullName},`,
      p`Your request to join <strong>${args.venueName}</strong> was <strong>${statusText.toLowerCase()}</strong> by a manager.`,
      infoTable(rows),
      p`${outcomeLine}`,
    ].join(''),
  });
  return { subject, text, html };
}

export function inviteCheckEmailTemplate(args: {
  venueName: string;
  jobTitle: string;
  signupUrl: string;
  expiresAt: string;
  isNewInvite: boolean;
}): EmailMessage {
  const subject = `Your Venue Wrangler invitation for ${args.venueName}`;
  if (args.isNewInvite) {
    const text =
      `Your email address has been invited to join ${args.venueName} on Venue Wrangler as ${args.jobTitle}.\n\n` +
      `Create your account using this secure link:\n${args.signupUrl}\n\n` +
      `This link expires on ${args.expiresAt}. If you didn't expect this invitation, you can ignore this email.\n\n` +
      `Questions? support@venuewrangler.com\n\n` +
      `— The Venue Wrangler Team`;
    const html = renderEmailHtml({
      preheader: `You're invited to join ${args.venueName}`,
      heading: `You're invited to join ${args.venueName}`,
      bodyRows: [
        p`Your email address has been invited to join <strong>${args.venueName}</strong> on Venue Wrangler as <strong>${args.jobTitle}</strong>.`,
        button('Create your account', args.signupUrl),
        p`This link expires on <strong>${args.expiresAt}</strong>. If you didn't expect this invitation, you can safely ignore this email.`,
      ].join(''),
    });
    return { subject, text, html };
  }
  const text =
    `An active invitation already exists for this email address at ${args.venueName}.\n\n` +
    `Use the secure link in the original invitation email, or ask your manager to send a new one.\n\n` +
    `If you didn't request this reminder, you can ignore it.\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: `You already have a pending invitation to ${args.venueName}`,
    heading: 'You already have a pending invitation',
    bodyRows: [
      p`An active invitation already exists for this email address at <strong>${args.venueName}</strong>.`,
      p`Use the secure link in the original invitation email, or ask your manager to send a new one.`,
      p`If you didn't request this reminder, you can safely ignore it.`,
    ].join(''),
  });
  return { subject, text, html };
}
