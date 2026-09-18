import { button, infoTable, list, p, renderEmailHtml } from '../email-brand';
import type { EmailMessage } from './auth';

export function accountUpdatedTemplate(args: { fullName: string; role: string; jobTitle: string; venueName: string | null }): EmailMessage {
  const rows: Array<[string, string]> = [
    ['Name', args.fullName],
    ['Role', args.role],
    ['Job title', args.jobTitle],
  ];
  if (args.venueName) rows.push(['Venue', args.venueName]);
  const rowsText = rows.map(([k, v]) => `${k}: ${v}`).join('\n');

  const subject = 'Your Venue Wrangler account was updated';
  const text =
    `Hi ${args.fullName},\n\n` +
    `Your Venue Wrangler account profile was just updated. Here's what's on file now:\n\n` +
    `${rowsText}\n\n` +
    `If you didn't make this change, please contact support right away.\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: 'Your account profile was just updated',
    heading: 'Your account was updated',
    bodyRows: [
      p`Hi ${args.fullName},`,
      p`Your Venue Wrangler account profile was just updated. Here's what's on file now:`,
      infoTable(rows),
      p`If you didn't make this change, please contact support right away.`,
    ].join(''),
  });
  return { subject, text, html };
}

export function teamInviteTemplate(args: { inviterName: string; venueName: string; code: string; inviteUrl: string }): EmailMessage {
  const subject = `You're invited to join ${args.venueName} on Venue Wrangler`;
  const text =
    `Hi there,\n\n` +
    `${args.inviterName} invited you to join the team at ${args.venueName} on Venue Wrangler.\n\n` +
    `To accept:\n` +
    `1. Open the Venue Wrangler app and choose "Join a team"\n` +
    `2. Enter this invite code: ${args.code}\n\n` +
    `Or tap this link on your phone: ${args.inviteUrl}\n\n` +
    `This invitation is valid for 7 days.\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: `${args.inviterName} invited you to join ${args.venueName}`,
    heading: `You're invited to join ${args.venueName}`,
    bodyRows: [
      p`Hi there,`,
      p`<strong>${args.inviterName}</strong> invited you to join the team at <strong>${args.venueName}</strong> on Venue Wrangler.`,
      button('Accept your invitation', args.inviteUrl),
      p`On your phone without the link handy? Open the Venue Wrangler app, choose <strong>Join a team</strong>, and enter this code:`,
      infoTable([['Invite code', args.code]]),
      p`This invitation is valid for <strong>7 days</strong>.`,
    ].join(''),
  });
  return { subject, text, html };
}

export function accountDeletedTemplate(args: { fullName: string; deletedVenueCount: number }): EmailMessage {
  const subject = 'Your Venue Wrangler account has been deleted';
  const closingText =
    args.deletedVenueCount > 0
      ? `${args.deletedVenueCount} owned venue${args.deletedVenueCount === 1 ? '' : 's'} and its operational data were also deleted. Media removal runs through a durable purge queue and may take a little longer to finish.`
      : `Any timeclock records your employer is legally required to retain have been de-identified and remain available to the venue for wage and compliance purposes only.`;
  const text =
    `Hi ${args.fullName},\n\n` +
    `Your Venue Wrangler account has been deleted, as requested.\n\n` +
    `${closingText}\n\n` +
    `Thank you for using Venue Wrangler.\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: 'Your account has been deleted, as requested',
    heading: 'Your account has been deleted',
    bodyRows: [
      p`Hi ${args.fullName},`,
      p`Your Venue Wrangler account has been deleted, as requested.`,
      p`${closingText}`,
      p`Thank you for using Venue Wrangler — we hope it made the shift a little easier while it lasted.`,
    ].join(''),
  });
  return { subject, text, html };
}
