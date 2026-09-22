import { Injectable } from '@nestjs/common';
import { GUSTO_API_VERSION } from './gusto-hours';

export type GustoTokenSet = {
  accessToken: string;
  refreshToken: string;
  expiresAt: Date;
};

export type GustoTimeSheet = {
  entity_uuid: string;
  entity_type: 'Employee';
  job_uuid: string;
  time_zone: string;
  shift_started_at: string;
  shift_ended_at: string;
  entries: Array<{ hours_worked: number; pay_classification: 'Regular' | 'Overtime' }>;
};

@Injectable()
export class GustoClient {
  constructor(private readonly fetchImpl: typeof fetch = fetch) {}

  apiBase(): string {
    return (process.env.GUSTO_API_BASE?.trim() || 'https://api.gusto-demo.com').replace(/\/$/, '');
  }

  authorizeUrl(state: string): string {
    const clientId = requiredEnv('GUSTO_CLIENT_ID');
    const redirectUri = requiredEnv('GUSTO_REDIRECT_URI');
    const params = new URLSearchParams({
      client_id: clientId,
      redirect_uri: redirectUri,
      response_type: 'code',
      state,
    });
    return `${this.apiBase()}/oauth/authorize?${params.toString()}`;
  }

  exchangeCode(code: string): Promise<GustoTokenSet> {
    return this.tokenRequest({
      client_id: requiredEnv('GUSTO_CLIENT_ID'),
      client_secret: requiredEnv('GUSTO_CLIENT_SECRET'),
      redirect_uri: requiredEnv('GUSTO_REDIRECT_URI'),
      code,
      grant_type: 'authorization_code',
    });
  }

  refresh(refreshToken: string): Promise<GustoTokenSet> {
    return this.tokenRequest({
      client_id: requiredEnv('GUSTO_CLIENT_ID'),
      client_secret: requiredEnv('GUSTO_CLIENT_SECRET'),
      redirect_uri: requiredEnv('GUSTO_REDIRECT_URI'),
      refresh_token: refreshToken,
      grant_type: 'refresh_token',
    });
  }

  async companyUuid(accessToken: string): Promise<string> {
    const json = await this.getJson(accessToken, '/v1/token_info');
    const uuid = json.resource?.uuid ?? json.company_uuid ?? json.resource_owner?.uuid;
    if (!uuid) throw new Error('Gusto did not return a company id');
    return uuid;
  }

  async primaryJobUuid(accessToken: string, employeeUuid: string): Promise<string | null> {
    const json = await this.getJson(accessToken, `/v1/employees/${encodeURIComponent(employeeUuid)}`);
    const jobs = Array.isArray(json.jobs) ? json.jobs : [];
    const primary = jobs.find((job) => job.primary) ?? jobs[0];
    return primary?.uuid ?? null;
  }

  async createTimeSheet(accessToken: string, companyUuid: string, body: GustoTimeSheet): Promise<{ uuid: string }> {
    const res = await this.fetchImpl(`${this.apiBase()}/v1/companies/${encodeURIComponent(companyUuid)}/time_tracking/time_sheets`, {
      method: 'POST',
      headers: gustoHeaders(accessToken),
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) throw new Error(`Gusto time sheet failed (${res.status})`);
    const json = await res.json() as { uuid?: string };
    return { uuid: json.uuid ?? '' };
  }

  private async tokenRequest(body: Record<string, string>): Promise<GustoTokenSet> {
    const res = await this.fetchImpl(`${this.apiBase()}/oauth/token`, {
      method: 'POST',
      headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) throw new Error(`Gusto token exchange failed (${res.status})`);
    const json = await res.json() as { access_token?: string; refresh_token?: string; expires_in?: number };
    if (!json.access_token || !json.refresh_token) throw new Error('Gusto token exchange returned no token');
    return {
      accessToken: json.access_token,
      refreshToken: json.refresh_token,
      expiresAt: new Date(Date.now() + (json.expires_in ?? 7200) * 1000),
    };
  }

  private async getJson(accessToken: string, path: string): Promise<{
    resource?: { uuid?: string };
    resource_owner?: { uuid?: string };
    company_uuid?: string;
    jobs?: Array<{ uuid?: string; primary?: boolean }>;
  }> {
    const res = await this.fetchImpl(`${this.apiBase()}${path}`, {
      headers: gustoHeaders(accessToken),
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) throw new Error(`Gusto request failed (${res.status})`);
    return res.json() as Promise<{
      resource?: { uuid?: string };
      resource_owner?: { uuid?: string };
      company_uuid?: string;
      jobs?: Array<{ uuid?: string; primary?: boolean }>;
    }>;
  }
}

function gustoHeaders(accessToken: string): Record<string, string> {
  return {
    Authorization: `Bearer ${accessToken}`,
    Accept: 'application/json',
    'Content-Type': 'application/json',
    'X-Gusto-API-Version': GUSTO_API_VERSION,
  };
}

function requiredEnv(name: string): string {
  const value = process.env[name]?.trim() ?? '';
  if (!value) throw new Error(`${name} is not configured`);
  return value;
}
