/**
 * Guest-facing reservation emails, sent by a venue to its own customers.
 * Signed "The team at {venueName}", not "The Venue Wrangler Team" — the
 * guest is the venue's customer, not ours.
 */
import { infoTable, p, renderEmailHtml } from '../email-brand';
import type { EmailMessage } from './auth';

export function reservationConfirmedTemplate(args: {
  guestFirstName: string;
  venueName: string;
  when: string;
  partySize: number;
  specialRequests?: string | null;
}): EmailMessage {
  const subject = `${args.venueName} — reservation confirmed for ${args.when}`;
  const rows: Array<[string, string]> = [
    ['Venue', args.venueName],
    ['Date & time', args.when],
    ['Party size', String(args.partySize)],
  ];
  if (args.specialRequests) rows.push(['Notes', args.specialRequests]);
  const rowsText = rows.map(([k, v]) => `${k}: ${v}`).join('\n');
  const text =
    `Hi ${args.guestFirstName},\n\n` +
    `We're looking forward to seeing you at ${args.venueName}. Here are your reservation details:\n\n` +
    `${rowsText}\n\n` +
    `If your plans change, please reply to this email so we can offer the table to another guest.\n\n` +
    `— The team at ${args.venueName}`;
  const html = renderEmailHtml({
    preheader: `You're confirmed at ${args.venueName} for ${args.when}`,
    heading: 'Your reservation is confirmed',
    bodyRows: [
      p`Hi ${args.guestFirstName},`,
      p`We're looking forward to seeing you at <strong>${args.venueName}</strong>. Here are your details:`,
      infoTable(rows),
      p`If your plans change, just reply to this email so we can offer the table to another guest.`,
    ].join(''),
  });
  return { subject, text, html };
}

export function reservationReminderTemplate(args: { guestFirstName: string; venueName: string; when: string; partySize: number }): EmailMessage {
  const subject = `${args.venueName} — reminder: ${args.when}`;
  const rows: Array<[string, string]> = [
    ['Venue', args.venueName],
    ['Date & time', args.when],
    ['Party size', String(args.partySize)],
  ];
  const rowsText = rows.map(([k, v]) => `${k}: ${v}`).join('\n');
  const text =
    `Hi ${args.guestFirstName},\n\n` +
    `Just a quick reminder about your upcoming reservation at ${args.venueName} — we can't wait to see you!\n\n` +
    `${rowsText}\n\n` +
    `If anything's changed, just reply and let us know.\n\n` +
    `— The team at ${args.venueName}`;
  const html = renderEmailHtml({
    preheader: `See you soon at ${args.venueName}`,
    heading: 'See you soon',
    bodyRows: [
      p`Hi ${args.guestFirstName},`,
      p`Just a quick reminder about your upcoming reservation at <strong>${args.venueName}</strong> — we can't wait to see you!`,
      infoTable(rows),
      p`If anything's changed, just reply and let us know.`,
    ].join(''),
  });
  return { subject, text, html };
}

export function tableReadyTemplate(args: { guestFirstName: string; venueName: string; partySize: number }): EmailMessage {
  const subject = `${args.venueName} — your table is ready`;
  const text =
    `Hi ${args.guestFirstName},\n\n` +
    `Good news — a table for ${args.partySize} just opened up at ${args.venueName}.\n\n` +
    `Please check in with the host within 10 minutes to claim your table.\n\n` +
    `— The team at ${args.venueName}`;
  const html = renderEmailHtml({
    preheader: `A table for ${args.partySize} is ready at ${args.venueName}`,
    heading: 'Your table is ready',
    bodyRows: [
      p`Hi ${args.guestFirstName},`,
      p`Good news — a table for <strong>${args.partySize}</strong> just opened up at <strong>${args.venueName}</strong>.`,
      p`Please check in with the host within <strong>10 minutes</strong> to claim your table.`,
    ].join(''),
  });
  return { subject, text, html };
}
