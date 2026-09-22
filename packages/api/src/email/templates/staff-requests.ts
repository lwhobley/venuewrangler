import { infoTable, p, renderEmailHtml } from '../email-brand';
import type { EmailMessage } from './auth';

export function staffRequestSubmittedTemplate(args: {
  employeeName: string;
  kindLabel: string;
  title: string;
  details: string;
  dateRange?: string | null;
}): EmailMessage {
  const subject = `${args.kindLabel} request needs your review`;
  const rows: Array<[string, string]> = [
    ['Employee', args.employeeName],
    ['Type', args.kindLabel],
    ['Title', args.title],
    ['Details', args.details],
  ];
  if (args.dateRange) rows.push(['Date(s)', args.dateRange]);
  const rowsText = rows.map(([k, v]) => `${k}: ${v}`).join('\n');
  const text =
    `Hi Manager,\n\n` +
    `${args.employeeName} submitted a new ${args.kindLabel.toLowerCase()} request. Please review it in the app.\n\n` +
    `${rowsText}\n\n` +
    `Open Requests & Approvals, select the request, and tap Approve or Deny — the employee is notified instantly.\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: `${args.employeeName} submitted a ${args.kindLabel.toLowerCase()} request`,
    heading: 'A request needs your review',
    bodyRows: [
      p`Hi Manager,`,
      p`<strong>${args.employeeName}</strong> submitted a new <strong>${args.kindLabel.toLowerCase()}</strong> request.`,
      infoTable(rows),
      p`Open <strong>Requests &amp; Approvals</strong>, select the request, and tap Approve or Deny — the employee is notified instantly.`,
    ].join(''),
  });
  return { subject, text, html };
}

export function staffRequestDecidedTemplate(args: {
  kindLabel: string;
  approved: boolean;
  title: string;
  reviewerName: string;
  note?: string | null;
}): EmailMessage {
  const statusText = args.approved ? 'Approved' : 'Denied';
  const subject = `Your ${args.kindLabel.toLowerCase()} request was ${statusText.toLowerCase()}`;
  const rows: Array<[string, string]> = [
    ['Type', args.kindLabel],
    ['Title', args.title],
    ['Status', statusText],
    ['Reviewed by', args.reviewerName],
  ];
  if (args.note?.trim()) rows.push(["Manager's note", args.note.trim()]);
  const rowsText = rows.map(([k, v]) => `${k}: ${v}`).join('\n');
  const text =
    `Hi there,\n\n` +
    `Your ${args.kindLabel.toLowerCase()} request was ${statusText.toLowerCase()} by ${args.reviewerName}.\n\n` +
    `${rowsText}\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: `Your request was ${statusText.toLowerCase()}`,
    heading: `Request ${statusText.toLowerCase()}`,
    accent: args.approved ? 'primary' : 'danger',
    bodyRows: [
      p`Hi there,`,
      p`Your <strong>${args.kindLabel.toLowerCase()}</strong> request was <strong>${statusText.toLowerCase()}</strong> by ${args.reviewerName}.`,
      infoTable(rows),
    ].join(''),
  });
  return { subject, text, html };
}
