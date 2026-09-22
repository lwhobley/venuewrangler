export const HOURS_PUSH_PROVIDERS = ['gusto', 'quickbooks_payroll', 'square_payroll'] as const;
export type HoursPushProvider = (typeof HOURS_PUSH_PROVIDERS)[number];

const LABELS: Record<string, string> = {
  gusto: 'Gusto',
  square_payroll: 'Square Payroll',
  toast_payroll: 'Toast Payroll',
  adp: 'ADP',
  paychex: 'Paychex',
  rippling: 'Rippling',
  paylocity: 'Paylocity',
  justworks: 'Justworks',
  onpay: 'OnPay',
  quickbooks_payroll: 'QuickBooks Payroll',
  wave_payroll: 'Wave Payroll',
  patriot: 'Patriot Software',
  homebase_payroll: 'Homebase Payroll',
  deel: 'Deel',
  csv: 'Other / generic CSV',
};

export function isHoursPushProvider(provider: string): provider is HoursPushProvider {
  return (HOURS_PUSH_PROVIDERS as readonly string[]).includes(provider);
}

export function providerLabel(provider: string): string {
  return LABELS[provider] ?? provider;
}

export function hoursPushUnavailable(provider: string): string | null {
  if (isHoursPushProvider(provider)) return null;
  const name = providerLabel(provider);
  if (provider === 'csv') return 'This provider has no hours API. Use the payroll CSV. No hours were sent.';
  return `${name} has no customer hours-push API. Use the payroll CSV. No hours were sent.`;
}

export function externalIdPattern(provider: HoursPushProvider): RegExp {
  if (provider === 'gusto') return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (provider === 'quickbooks_payroll') return /^[0-9]{1,20}$/;
  return /^[A-Za-z0-9_-]{1,64}$/;
}
