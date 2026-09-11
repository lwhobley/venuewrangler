/**
 * Shared by StaffController and AppStaffController (/v1/staff and
 * /v1/app/staff), which perform the same roster mutation through two
 * different route surfaces. The content used to be duplicated verbatim in
 * both files; it now lives here once so the two can't drift apart.
 */
import { infoTable, list, p, renderEmailHtml } from '../email-brand';
import type { EmailMessage } from './auth';

export function rosterInvitedTemplate(args: { fullName: string; venueName: string; jobTitle: string; email: string }): EmailMessage {
  const subject = `You've been added to the team at ${args.venueName}`;
  const text =
    `Hi ${args.fullName},\n\n` +
    `Welcome! Your manager added you to the team at ${args.venueName} as a ${args.jobTitle}.\n\n` +
    `To get started:\n` +
    `1. Create a Venue Wrangler account (or sign in, if you already have one) using this email: ${args.email}\n` +
    `2. You'll be linked to the venue automatically and can see your schedule right away\n\n` +
    `Once you're in, you can view your shifts, request time off, and pick up open shifts.\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: `You've been added to the team at ${args.venueName}`,
    heading: `Welcome to ${args.venueName}`,
    bodyRows: [
      p`Hi ${args.fullName},`,
      p`Welcome! Your manager added you to the team at <strong>${args.venueName}</strong> as a <strong>${args.jobTitle}</strong>.`,
      infoTable([['Sign in with', args.email]]),
      p`Create an account or sign in with that email and you'll be linked to the venue automatically — no invite code needed.`,
      list(['View your schedule the moment it\'s published', 'Request time off or a shift swap', 'Pick up open shifts for extra hours']),
    ].join(''),
  });
  return { subject, text, html };
}

export function rosterProfileUpdatedTemplate(args: { fullName: string; venueName: string; role: string; jobTitle: string }): EmailMessage {
  const subject = 'Your Venue Wrangler profile was updated';
  const rowsText = `Name: ${args.fullName}\nRole: ${args.role}\nJob title: ${args.jobTitle}`;
  const text =
    `Hi ${args.fullName},\n\n` +
    `Your team profile at ${args.venueName} was just updated. Here's what's on file now:\n\n` +
    `${rowsText}\n\n` +
    `If you didn't expect this change or have questions, reach out to your manager.\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: 'A manager updated your profile',
    heading: 'Your profile was updated',
    bodyRows: [
      p`Hi ${args.fullName},`,
      p`Your team profile at <strong>${args.venueName}</strong> was just updated. Here's what's on file now:`,
      infoTable([
        ['Name', args.fullName],
        ['Role', args.role],
        ['Job title', args.jobTitle],
      ]),
      p`If you didn't expect this change or have questions, reach out to your manager.`,
    ].join(''),
  });
  return { subject, text, html };
}
