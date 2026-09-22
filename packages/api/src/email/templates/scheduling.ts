import { compareTable, infoTable, list, p, renderEmailHtml } from '../email-brand';
import type { EmailMessage } from './auth';

export function openShiftCoveredTemplate(args: { pickedUpBy: string; shiftLabel: string; jobTitle: string; station: string }): EmailMessage {
  const subject = 'Open shift covered';
  const text =
    `${args.pickedUpBy} picked up ${args.shiftLabel}.\n\n` +
    `${args.jobTitle} at ${args.station}\n\n` +
    `— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: `${args.pickedUpBy} picked up ${args.shiftLabel}`,
    heading: 'Open shift covered',
    bodyRows: [
      p`<strong>${args.pickedUpBy}</strong> picked up <strong>${args.shiftLabel}</strong>.`,
      infoTable([
        ['Role', args.jobTitle],
        ['Station', args.station],
      ]),
    ].join(''),
  });
  return { subject, text, html };
}

export function schedulePublishedManagerTemplate(args: {
  fullName: string;
  periodLabel: string;
  totalShifts: number;
  staffScheduled: number;
  openShifts: number;
  pendingApprovals: number;
}): EmailMessage {
  const subject = "Your schedule is live";
  const rows: Array<[string, string]> = [
    ['Schedule period', args.periodLabel],
    ['Total shifts', String(args.totalShifts)],
    ['Staff scheduled', String(args.staffScheduled)],
    ['Open shifts', String(args.openShifts)],
    ['Pending approvals', String(args.pendingApprovals)],
  ];
  const rowsText = rows.map(([k, v]) => `${k}: ${v}`).join('\n');
  const text =
    `Hi ${args.fullName},\n\n` +
    `Your schedule for ${args.periodLabel} is published. Your team's been notified and can see their shifts right now.\n\n` +
    `${rowsText}\n\n` +
    `Making changes after publishing:\n` +
    `- Edit a shift: select it and tap Edit — changes reach the employee instantly\n` +
    `- Add a shift: tap an open slot and assign someone, or post it as open\n` +
    `- Remove a shift: select it and tap Delete — the employee is notified automatically\n` +
    `- Swap requests land in your Requests & Approvals queue\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `Let's wrangle.\n— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: `Your schedule for ${args.periodLabel} is live`,
    heading: 'Your schedule is live',
    bodyRows: [
      p`Hi ${args.fullName},`,
      p`Your schedule for <strong>${args.periodLabel}</strong> is published. Your team's been notified and can see their shifts the moment they open the app.`,
      infoTable(rows),
      p`Making changes after publishing:`,
      list([
        'Edit a shift — select it and tap Edit; changes reach the employee instantly',
        'Add a shift — tap an open slot and assign someone, or post it as open',
        'Remove a shift — select it and tap Delete; the employee is notified automatically',
        "Swap requests land in your Requests & Approvals queue",
      ]),
    ].join(''),
  });
  return { subject, text, html };
}

export function schedulePublishedStaffTemplate(args: {
  fullName: string;
  periodLabel: string;
  shifts: Array<{ day: string; date: string; start: string; end: string; area: string }>;
}): EmailMessage {
  const subject = `Your schedule is live for ${args.periodLabel}`;
  const rowsText = args.shifts.map((s) => `${s.day} ${s.date}: ${s.start}–${s.end} (${s.area})`).join('\n');
  const text =
    `Hi ${args.fullName},\n\n` +
    `Your manager just published the schedule for ${args.periodLabel}. Your shifts:\n\n` +
    `${rowsText}\n\n` +
    `Need a change? Request time off or a swap right from the app, or check the Open Shifts board for extra hours.\n` +
    `Remember to clock in from the app when your shift starts — you'll always be notified if anything changes.\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `See you on the floor.\n— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: `Your schedule for ${args.periodLabel} is ready`,
    heading: 'Your schedule is live',
    bodyRows: [
      p`Hi ${args.fullName},`,
      p`Your manager just published the schedule for <strong>${args.periodLabel}</strong>. Here's what's on your plate:`,
      compareTable(
        ['Day', 'Time', 'Section'],
        args.shifts.map((s) => [`${s.day} ${s.date}`, `${s.start}–${s.end}`, s.area]),
      ),
      p`Need a change? Request time off or a swap right from the app, or check the Open Shifts board for extra hours.`,
      p`Remember to clock in from the app when your shift starts — you'll always be notified if anything changes.`,
    ].join(''),
  });
  return { subject, text, html };
}

export function newShiftsAssignedTemplate(args: { shifts: Array<{ label: string; jobTitle: string; station: string }> }): EmailMessage {
  const plural = args.shifts.length !== 1;
  const subject = plural ? 'New shifts assigned' : 'New shift assigned';
  const rowsText = args.shifts.map((s) => `${s.label} — ${s.jobTitle} at ${s.station}`).join('\n');
  const text = `You were assigned ${plural ? 'new shifts' : 'a new shift'}:\n\n${rowsText}\n\n— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: plural ? 'You have new shifts on the schedule' : 'You have a new shift on the schedule',
    heading: plural ? 'New shifts assigned' : 'New shift assigned',
    bodyRows: [
      p`You were assigned ${plural ? 'new shifts' : 'a new shift'}:`,
      compareTable(['Shift', 'Role', 'Station'], args.shifts.map((s) => [s.label, s.jobTitle, s.station])),
    ].join(''),
  });
  return { subject, text, html };
}

export function shiftSwapProposedTemplate(args: { proposerName: string; shiftLabel: string; note?: string }): EmailMessage {
  const subject = 'Shift swap proposed';
  const noteLine = args.note?.trim() ? `\n\nNote: ${args.note.trim()}` : '';
  const text = `${args.proposerName} wants to swap ${args.shiftLabel}.${noteLine}\n\n— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: `${args.proposerName} wants to swap a shift with you`,
    heading: 'Shift swap proposed',
    bodyRows: [
      p`<strong>${args.proposerName}</strong> wants to swap <strong>${args.shiftLabel}</strong> with you.`,
      ...(args.note?.trim() ? [p`<em>"${args.note.trim()}"</em>`] : []),
      p`Open the app to accept or decline.`,
    ].join(''),
  });
  return { subject, text, html };
}

export function shiftChangedTemplate(args: {
  fullName: string;
  changeType: string;
  before: { date: string; time: string; area: string };
  after: { date: string; time: string; area: string };
}): EmailMessage {
  const subject = 'A shift on your schedule changed';
  const text =
    `Hi ${args.fullName},\n\n` +
    `Your manager updated your schedule (${args.changeType}). Here's what changed:\n\n` +
    `Before — ${args.before.date}, ${args.before.time}, ${args.before.area}\n` +
    `After — ${args.after.date}, ${args.after.time}, ${args.after.area}\n\n` +
    `No action needed unless you have a conflict — reach out to your manager through the app, or submit a swap or time-off request if you need one.\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: 'A shift on your schedule was just updated',
    heading: 'Your schedule was updated',
    bodyRows: [
      p`Hi ${args.fullName},`,
      p`Your manager made a change to your schedule (<strong>${args.changeType}</strong>). Here's what changed:`,
      compareTable(
        ['', 'Before', 'After'],
        [
          ['Date', args.before.date, args.after.date],
          ['Time', args.before.time, args.after.time],
          ['Section', args.before.area, args.after.area],
        ],
      ),
      p`No action needed unless you have a conflict — reach out to your manager through the app, or submit a swap or time-off request if you need one.`,
    ].join(''),
  });
  return { subject, text, html };
}

export function shiftSwapActionRequiredTemplate(args: {
  managerName: string;
  requesterName: string;
  targetName: string;
  requesterDate: string;
  requesterTime: string;
  targetDate: string;
  targetTime: string;
  submittedAt: string;
}): EmailMessage {
  const subject = 'Shift swap needs your approval';
  const text =
    `Hi ${args.managerName},\n\n` +
    `${args.requesterName} submitted a shift swap request with ${args.targetName}, submitted ${args.submittedAt}. Please review it in the app.\n\n` +
    `${args.requesterName}: ${args.requesterDate}, ${args.requesterTime}\n` +
    `${args.targetName}: ${args.targetDate}, ${args.targetTime}\n\n` +
    `Open Requests & Approvals in the app, select the request, and tap Approve or Deny — both employees are notified instantly.\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: `${args.requesterName} submitted a shift swap request`,
    heading: 'Shift swap needs your approval',
    bodyRows: [
      p`Hi ${args.managerName},`,
      p`<strong>${args.requesterName}</strong> submitted a shift swap request with <strong>${args.targetName}</strong>, submitted ${args.submittedAt}.`,
      compareTable(
        ['Employee', 'Date', 'Time'],
        [
          [args.requesterName, args.requesterDate, args.requesterTime],
          [args.targetName, args.targetDate, args.targetTime],
        ],
      ),
      p`Open <strong>Requests &amp; Approvals</strong> in the app, select the request, and tap Approve or Deny — both employees are notified instantly.`,
    ].join(''),
  });
  return { subject, text, html };
}

export function shiftSwapDecidedTemplate(args: {
  fullName: string;
  coworkerName: string;
  approved: boolean;
  yourShift: { date: string; time: string };
  coworkerShift: { date: string; time: string };
}): EmailMessage {
  const statusText = args.approved ? 'approved' : 'denied';
  const subject = args.approved ? 'Your shift swap was approved' : 'Your shift swap was denied';
  const outcomeLines = args.approved
    ? `Your schedule has been updated automatically — you and ${args.coworkerName} will both see the new shifts in the app. Make sure to clock in for your new shift on time.`
    : `Your original shift remains on your schedule. Reach out to your manager through the app if you have questions.`;
  const text =
    `Hi ${args.fullName},\n\n` +
    `Your shift swap with ${args.coworkerName} was ${statusText} by your manager.\n\n` +
    `Your shift: ${args.yourShift.date}, ${args.yourShift.time}\n` +
    `${args.coworkerName}'s shift: ${args.coworkerShift.date}, ${args.coworkerShift.time}\n\n` +
    `${outcomeLines}\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: `Your shift swap was ${statusText}`,
    heading: args.approved ? 'Swap approved' : 'Swap denied',
    accent: args.approved ? 'primary' : 'danger',
    bodyRows: [
      p`Hi ${args.fullName},`,
      p`Your shift swap with <strong>${args.coworkerName}</strong> was <strong>${statusText}</strong> by your manager.`,
      compareTable(
        ['', 'Date', 'Time'],
        [
          ['You', args.yourShift.date, args.yourShift.time],
          [args.coworkerName, args.coworkerShift.date, args.coworkerShift.time],
        ],
      ),
      p`${outcomeLines}`,
    ].join(''),
  });
  return { subject, text, html };
}
