import { Injectable } from '@nestjs/common';
import type { ProviderTokenSet } from './quickbooks-client';

const SQUARE_VERSION = '2026-09-16';

@Injectable()
export class SquareClient {
  constructor(private readonly fetchImpl: typeof fetch = fetch) {}

  apiBase(): string {
    return (process.env.SQUARE_API_BASE?.trim() || 'https://connect.squareupsandbox.com').replace(/\/$/, '');
  }

  authorizeUrl(state: string): string {
    const params = new URLSearchParams({
      client_id: requiredEnv('SQUARE_APPLICATION_ID'),
      scope: 'TIMECARDS_WRITE MERCHANT_PROFILE_READ',
      session: 'false',
      state,
    });
    const redirect = process.env.SQUARE_REDIRECT_URI?.trim();
    if (redirect) params.set('redirect_uri', redirect);
    return `${this.apiBase()}/oauth2/authorize?${params.toString()}`;
  }

  exchangeCode(code: string): Promise<ProviderTokenSet> {
    const redirect = process.env.SQUARE_REDIRECT_URI?.trim();
    return this.tokenRequest({
      client_id: requiredEnv('SQUARE_APPLICATION_ID'),
      client_secret: requiredEnv('SQUARE_APPLICATION_SECRET'),
      grant_type: 'authorization_code',
      code,
      ...(redirect ? { redirect_uri: redirect } : {}),
    });
  }

  refresh(refreshToken: string): Promise<ProviderTokenSet> {
    return this.tokenRequest({
      client_id: requiredEnv('SQUARE_APPLICATION_ID'),
      client_secret: requiredEnv('SQUARE_APPLICATION_SECRET'),
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
    });
  }

  async primaryLocationId(accessToken: string): Promise<string | null> {
    const res = await this.fetchImpl(`${this.apiBase()}/v2/locations`, {
      headers: squareHeaders(accessToken),
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) throw new Error(`Square locations failed (${res.status})`);
    const json = await res.json() as { locations?: Array<{ id?: string; status?: string }> };
    const locations = json.locations ?? [];
    return locations.find((location) => location.status === 'ACTIVE')?.id ?? locations[0]?.id ?? null;
  }

  async createTimecard(accessToken: string, body: {
    idempotencyKey: string;
    teamMemberId: string;
    locationId: string;
    startAt: string;
    endAt: string;
  }): Promise<{ id: string }> {
    const res = await this.fetchImpl(`${this.apiBase()}/v2/labor/timecards`, {
      method: 'POST',
      headers: squareHeaders(accessToken),
      body: JSON.stringify({
        idempotency_key: body.idempotencyKey,
        timecard: {
          team_member_id: body.teamMemberId,
          location_id: body.locationId,
          start_at: body.startAt,
          end_at: body.endAt,
        },
      }),
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) throw new Error(`Square timecard failed (${res.status})`);
    const json = await res.json() as { timecard?: { id?: string } };
    return { id: json.timecard?.id ?? '' };
  }

  private async tokenRequest(body: Record<string, string>): Promise<ProviderTokenSet> {
    const res = await this.fetchImpl(`${this.apiBase()}/oauth2/token`, {
      method: 'POST',
      headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) throw new Error(`Square token exchange failed (${res.status})`);
    const json = await res.json() as { access_token?: string; refresh_token?: string; expires_at?: string; expires_in?: number };
    if (!json.access_token || !json.refresh_token) throw new Error('Square token exchange returned no token');
    return {
      accessToken: json.access_token,
      refreshToken: json.refresh_token,
      expiresAt: json.expires_at ? new Date(json.expires_at) : new Date(Date.now() + (json.expires_in ?? 3600) * 1000),
    };
  }
}

function squareHeaders(accessToken: string): Record<string, string> {
  return {
    Authorization: `Bearer ${accessToken}`,
    Accept: 'application/json',
    'Content-Type': 'application/json',
    'Square-Version': SQUARE_VERSION,
  };
}

function requiredEnv(name: string): string {
  const value = process.env[name]?.trim() ?? '';
  if (!value) throw new Error(`${name} is not configured`);
  return value;
}
