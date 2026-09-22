export const POS_PROVIDERS = [
  'toast',
  'square',
  'clover',
  'shopify_pos',
  'lightspeed_restaurant',
  'spoton',
  'generic',
] as const;

export type PosProviderId = (typeof POS_PROVIDERS)[number];

export type Capability =
  | 'implemented'
  | 'ingest_only'
  | 'provider_only'
  | 'unavailable'
  | 'unknown';

export type PosProviderCapabilities = {
  provider: PosProviderId;
  oauth: Capability;
  webhook: Capability;
  historicalSync: Capability;
  orders: Capability;
  payments: Capability;
  refunds: Capability;
  employees: Capability;
  tips: Capability;
  serviceCharges: Capability;
  menuModifiers: Capability;
  realtime: Capability;
  rateLimit: string;
  regions: string;
};

const ADAPTER_RATE_LIMIT = 'This app accepts 120 ingest requests per minute per venue and client IP. Vendor rate limits are not called and are not enforced here.';

const INGEST_NOTE = 'ingest_only means a caller can POST a normalized check. The vendor does not push to this app.';

export const POS_PROVIDER_CAPABILITIES: readonly PosProviderCapabilities[] = [
  {
    provider: 'square',
    oauth: 'provider_only',
    webhook: 'ingest_only',
    historicalSync: 'provider_only',
    orders: 'ingest_only',
    payments: 'ingest_only',
    refunds: 'provider_only',
    employees: 'ingest_only',
    tips: 'implemented',
    serviceCharges: 'provider_only',
    menuModifiers: 'provider_only',
    realtime: 'unavailable',
    rateLimit: ADAPTER_RATE_LIMIT,
    regions: 'Square merchant countries. This app does not enforce Square account country.',
  },
  {
    provider: 'toast',
    oauth: 'unavailable',
    webhook: 'ingest_only',
    historicalSync: 'provider_only',
    orders: 'ingest_only',
    payments: 'ingest_only',
    refunds: 'provider_only',
    employees: 'ingest_only',
    tips: 'implemented',
    serviceCharges: 'provider_only',
    menuModifiers: 'provider_only',
    realtime: 'unavailable',
    rateLimit: ADAPTER_RATE_LIMIT,
    regions: 'Toast merchant countries. A restaurant cannot connect Toast from this app.',
  },
  {
    provider: 'clover',
    oauth: 'provider_only',
    webhook: 'ingest_only',
    historicalSync: 'provider_only',
    orders: 'ingest_only',
    payments: 'ingest_only',
    refunds: 'provider_only',
    employees: 'ingest_only',
    tips: 'implemented',
    serviceCharges: 'provider_only',
    menuModifiers: 'provider_only',
    realtime: 'unavailable',
    rateLimit: ADAPTER_RATE_LIMIT,
    regions: 'Clover merchant countries. This app does not enforce them.',
  },
  {
    provider: 'shopify_pos',
    oauth: 'provider_only',
    webhook: 'ingest_only',
    historicalSync: 'provider_only',
    orders: 'ingest_only',
    payments: 'ingest_only',
    refunds: 'provider_only',
    employees: 'ingest_only',
    tips: 'implemented',
    serviceCharges: 'unknown',
    menuModifiers: 'provider_only',
    realtime: 'unavailable',
    rateLimit: ADAPTER_RATE_LIMIT,
    regions: 'Shopify store countries. Shopify Payments is a smaller set. This app does not enforce either.',
  },
  {
    provider: 'lightspeed_restaurant',
    oauth: 'unavailable',
    webhook: 'ingest_only',
    historicalSync: 'unknown',
    orders: 'ingest_only',
    payments: 'ingest_only',
    refunds: 'unknown',
    employees: 'ingest_only',
    tips: 'implemented',
    serviceCharges: 'unknown',
    menuModifiers: 'unknown',
    realtime: 'unavailable',
    rateLimit: ADAPTER_RATE_LIMIT,
    regions: 'Unknown. A restaurant cannot connect Lightspeed from this app.',
  },
  {
    provider: 'spoton',
    oauth: 'unavailable',
    webhook: 'ingest_only',
    historicalSync: 'unknown',
    orders: 'ingest_only',
    payments: 'ingest_only',
    refunds: 'unknown',
    employees: 'ingest_only',
    tips: 'implemented',
    serviceCharges: 'unknown',
    menuModifiers: 'unknown',
    realtime: 'unavailable',
    rateLimit: ADAPTER_RATE_LIMIT,
    regions: 'Unknown. A restaurant cannot connect SpotOn from this app.',
  },
  {
    provider: 'generic',
    oauth: 'unavailable',
    webhook: 'implemented',
    historicalSync: 'unavailable',
    orders: 'implemented',
    payments: 'implemented',
    refunds: 'unavailable',
    employees: 'ingest_only',
    tips: 'implemented',
    serviceCharges: 'unavailable',
    menuModifiers: 'unavailable',
    realtime: 'unavailable',
    rateLimit: ADAPTER_RATE_LIMIT,
    regions: 'Any venue that can POST the ingest contract.',
  },
];

export function capabilitiesFor(provider: string): PosProviderCapabilities | undefined {
  return POS_PROVIDER_CAPABILITIES.find((row) => row.provider === provider);
}

export const POS_CAPABILITY_LEGEND = {
  implemented: 'This app stores or calls this today.',
  ingest_only: INGEST_NOTE,
  provider_only: 'The vendor API can do this. This app does not call it.',
  unavailable: 'Not available through this app, including as a customer connect.',
  unknown: 'Not declared. This app does not guess.',
} as const;
