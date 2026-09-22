import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes, timingSafeEqual } from 'crypto';

const VERSION = 'v1';

export function payrollTokenKey(): Buffer {
  const raw = process.env.PAYROLL_TOKEN_KEY?.trim() ?? '';
  if (raw.length < 32) {
    throw new Error('PAYROLL_TOKEN_KEY must be at least 32 characters');
  }
  return createHash('sha256').update(raw).digest();
}

export function encryptPayrollSecret(plain: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', payrollTokenKey(), iv);
  const ciphertext = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return [VERSION, iv.toString('base64url'), tag.toString('base64url'), ciphertext.toString('base64url')].join('.');
}

export function decryptPayrollSecret(payload: string): string {
  const [version, iv, tag, ciphertext] = payload.split('.');
  if (version !== VERSION || !iv || !tag || !ciphertext) throw new Error('Payroll token cipher is invalid');
  const decipher = createDecipheriv('aes-256-gcm', payrollTokenKey(), Buffer.from(iv, 'base64url'));
  decipher.setAuthTag(Buffer.from(tag, 'base64url'));
  return Buffer.concat([decipher.update(Buffer.from(ciphertext, 'base64url')), decipher.final()]).toString('utf8');
}

export function signPayrollState(payload: { venueId: string; exp: number; provider?: string }): string {
  const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const sig = createHmac('sha256', payrollTokenKey()).update(body).digest('base64url');
  return `${body}.${sig}`;
}

export function readPayrollState(state: string): { venueId: string; exp: number; provider: string } {
  const [body, sig] = state.split('.');
  if (!body || !sig) throw new Error('Gusto state is invalid');
  const expected = createHmac('sha256', payrollTokenKey()).update(body).digest('base64url');
  const left = Buffer.from(sig);
  const right = Buffer.from(expected);
  if (left.length !== right.length || !timingSafeEqual(left, right)) throw new Error('Gusto state is invalid');
  const parsed = JSON.parse(Buffer.from(body, 'base64url').toString('utf8')) as { venueId?: string; exp?: number; provider?: string };
  if (!parsed.venueId || !parsed.exp || parsed.exp < Date.now()) throw new Error('Payroll state is invalid');
  return { venueId: parsed.venueId, exp: parsed.exp, provider: parsed.provider || 'gusto' };
}
