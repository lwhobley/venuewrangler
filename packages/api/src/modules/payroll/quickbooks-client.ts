import { Injectable } from '@nestjs/common';

export type ProviderTokenSet = {
  accessToken: string;
  refreshToken: string;
  expiresAt: Date;
};

@Injectable()
export class QuickBooksClient {
  private readonly fetchImpl: typeof fetch = fetch;

  apiBase(): string {
    return (process.env.QUICKBOOKS_API_BASE?.trim() || 'https://sandbox-quickbooks.api.intuit.com').replace(/\/$/, '');
  }

  authorizeUrl(state: string): string {
    const params = new URLSearchParams({
      client_id: requiredEnv('QUICKBOOKS_CLIENT_ID'),
      redirect_uri: requiredEnv('QUICKBOOKS_REDIRECT_URI'),
      response_type: 'code',
      scope: 'com.intuit.quickbooks.accounting',
      state,
    });
    return `https://appcenter.intuit.com/connect/oauth2?${params.toString()}`;
  }

  exchangeCode(code: string): Promise<ProviderTokenSet> {
    return this.tokenRequest({ grant_type: 'authorization_code', code, redirect_uri: requiredEnv('QUICKBOOKS_REDIRECT_URI') });
  }

  refresh(refreshToken: string): Promise<ProviderTokenSet> {
    return this.tokenRequest({ grant_type: 'refresh_token', refresh_token: refreshToken });
  }

  async createTimeActivity(accessToken: string, realmId: string, body: {
    TxnDate: string;
    EmployeeRef: { value: string };
    StartTime: string;
    EndTime: string;
  }): Promise<{ id: string }> {
    const res = await this.fetchImpl(`${this.apiBase()}/v3/company/${encodeURIComponent(realmId)}/timeactivity?minorversion=75`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        Accept: 'application/json',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        NameOf: 'Employee',
        BillableStatus: 'NotBillable',
        ...body,
      }),
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) throw new Error(`QuickBooks time activity failed (${res.status})`);
    const json = await res.json() as { TimeActivity?: { Id?: string } };
    return { id: json.TimeActivity?.Id ?? '' };
  }

  private async tokenRequest(fields: Record<string, string>): Promise<ProviderTokenSet> {
    const id = requiredEnv('QUICKBOOKS_CLIENT_ID');
    const secret = requiredEnv('QUICKBOOKS_CLIENT_SECRET');
    const res = await this.fetchImpl('https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer', {
      method: 'POST',
      headers: {
        Authorization: `Basic ${Buffer.from(`${id}:${secret}`).toString('base64')}`,
        Accept: 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: new URLSearchParams(fields).toString(),
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) throw new Error(`QuickBooks token exchange failed (${res.status})`);
    const json = await res.json() as { access_token?: string; refresh_token?: string; expires_in?: number };
    if (!json.access_token || !json.refresh_token) throw new Error('QuickBooks token exchange returned no token');
    return {
      accessToken: json.access_token,
      refreshToken: json.refresh_token,
      expiresAt: new Date(Date.now() + (json.expires_in ?? 3600) * 1000),
    };
  }
}

function requiredEnv(name: string): string {
  const value = process.env[name]?.trim() ?? '';
  if (!value) throw new Error(`${name} is not configured`);
  return value;
}
