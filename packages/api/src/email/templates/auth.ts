import { codeBlock, list, p, renderEmailHtml } from '../email-brand';

export type EmailMessage = { subject: string; text: string; html: string };

export function verifyEmailTemplate(args: { fullName?: string; code: string }): EmailMessage {
  const name = args.fullName?.trim() || 'there';
  const subject = 'Verify your email to finish setting up Venue Wrangler';
  const text =
    `Hi ${name},\n\n` +
    `Thanks for signing up for Venue Wrangler. One more step and you're in — enter this code in the app to verify your email address:\n\n` +
    `   ${args.code}\n\n` +
    `This code is valid for 24 hours. If you didn't create a Venue Wrangler account, you can safely ignore this email.\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: `Your verification code is ${args.code}`,
    heading: 'Verify your email',
    bodyRows: [
      p`Hi ${name},`,
      p`Thanks for signing up for Venue Wrangler. One more step and you're in — enter this code in the app to verify your email address:`,
      codeBlock(args.code),
      p`This code is valid for <strong>24 hours</strong>. If you didn't create a Venue Wrangler account, you can safely ignore this email.`,
    ].join(''),
  });
  return { subject, text, html };
}

export function resetPasswordTemplate(args: { fullName?: string; code: string }): EmailMessage {
  const name = args.fullName?.trim() || 'there';
  const subject = 'Reset your Venue Wrangler password';
  const text =
    `Hi ${name},\n\n` +
    `We received a request to reset the password for your Venue Wrangler account. Enter this code in the app to continue:\n\n` +
    `   ${args.code}\n\n` +
    `This code is valid for 60 minutes. If you didn't request a password reset, you can safely ignore this email — your account is still secure.\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: `Your password reset code is ${args.code}`,
    heading: 'Reset your password',
    bodyRows: [
      p`Hi ${name},`,
      p`We received a request to reset the password for your Venue Wrangler account. Enter this code in the app to continue:`,
      codeBlock(args.code),
      p`This code is valid for <strong>60 minutes</strong>. If you didn't request a password reset, you can safely ignore this email — your account is still secure.`,
    ].join(''),
  });
  return { subject, text, html };
}

export function passwordChangedTemplate(): EmailMessage {
  const subject = 'Your Venue Wrangler password was changed';
  const text =
    `Hi there,\n\n` +
    `Your Venue Wrangler account password was just changed. If this was you, no action is needed.\n\n` +
    `If you didn't make this change, reset your password immediately in the app and contact support@venuewrangler.com so we can help secure your account.\n\n` +
    `Questions? support@venuewrangler.com\n\n` +
    `— The Venue Wrangler Team`;
  const html = renderEmailHtml({
    preheader: 'Your password was just changed — was this you?',
    heading: 'Your password was changed',
    accent: 'danger',
    bodyRows: [
      p`Hi there,`,
      p`Your Venue Wrangler account password was just changed. If this was you, no action is needed.`,
      p`If you <strong>didn't</strong> make this change:`,
      list(['Reset your password immediately in the app', 'Contact support@venuewrangler.com so we can help secure your account']),
    ].join(''),
  });
  return { subject, text, html };
}
