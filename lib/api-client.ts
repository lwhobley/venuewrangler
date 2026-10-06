import { useMutation, useQuery, useQueryClient, type QueryKey } from '@tanstack/react-query';
import Constants from 'expo-constants';
import { useAuthStore } from './auth-store';
import type { Role } from './types';

const configuredApiBaseUrl =
  process.env.EXPO_PUBLIC_API_URL ??
  (Constants.expoConfig?.extra?.EXPO_PUBLIC_API_URL as string | undefined) ??
  null;

export class ApiError extends Error {
  constructor(
    message: string,
    public status: number,
  ) {
    super(message);
    this.name = status === 402 ? 'SubscriptionRequiredError' : 'ApiError';
  }
}

export type ApiProfile = {
  _id: string;
  email: string;
  fullName: string;
  emailVerified: boolean;
  role: Role;
  jobTitle: string;
  venueId: string | null;
  allAccess: boolean;
  membershipStatus?: string | null;
  trialEndsAt?: number | null;
};

export type ApiVenue = {
  _id: string;
  name: string;
  latitude: number;
  longitude: number;
  geofenceRadiusM: number;
  timezone?: string | null;
};

export type AuthSessionResponse = {
  token: string;
  profile: ApiProfile;
  venue: ApiVenue | null;
};

/** One entry of MeResponse.venues — mirrors ProfileService.listUserVenues(). */
export type ApiVenueMembership = {
  id: string;
  name: string;
  role: Role;
  profileId: string;
};

/**
 * GET /v1/app/me (and POST /v1/app/switch-venue, which returns the same shape).
 * `venues` lists every active membership and is what the venue switcher reads;
 * it was missing from the previous inline type, which is why callers reaching
 * for it had to fall back to `any`.
 */
export type MeResponse = {
  profile: ApiProfile;
  venue: ApiVenue | null;
  venues: ApiVenueMembership[];
};

/** GET /v1/app/notifications — mirrors app.controller getNotifications(). */
export type ApiNotification = {
  _id: string;
  kind: string;
  title: string;
  body: string;
  createdAt: number;
  read: boolean;
};

/**
 * A time-clock punch — mirrors mappers.mapClockEntry(). Location fields are
 * null when the server omits them (includeLocation: false).
 */
export type ApiClockEntry = {
  _id: string;
  memberId: string;
  memberName: string;
  role: Role;
  jobTitle: string;
  venueId: string;
  venueName: string;
  clockInAt: number;
  clockOutAt: number | null;
  clockInLat: number | null;
  clockInLng: number | null;
  clockInAccuracyM: number | null;
  clockInMocked: boolean | null;
  clockOutLat: number | null;
  clockOutLng: number | null;
  clockOutAccuracyM: number | null;
  clockOutMocked: boolean | null;
  isOpen: boolean;
  breaks: ApiClockBreak[] | null;
};

export type ApiClockBreak = { type: 'paid' | 'unpaid'; startAt: number; endAt: number | null };

/** GET /v1/workforce/join-requests — mirrors workforce.controller. */
export type ApiJoinRequest = {
  id: string;
  venueId: string;
  venueName: string;
  venueAddress: string | null;
  status: string;
  decidedAt: number | null;
  decisionNote: string | null;
  createdAt: number;
};

/** GET /v1/app/staff — mirrors mappers.mapProfile(). */
export type ApiStaffMember = {
  _id: string;
  email: string;
  fullName: string;
  role: Role;
  jobTitle: string;
  phone: string | null;
  altPhone: string | null;
  address: string | null;
  dateOfBirth: string | null;
  certifications: string[];
  venueId: string | null;
  allAccess: boolean;
  sickHoursAccrued: number;
  ptoHoursAccrued: number;
};

function getApiBaseUrl() {
  if (!configuredApiBaseUrl) {
    throw new ApiError('The app is missing EXPO_PUBLIC_API_URL. Set it before signing in.', 500);
  }
  return configuredApiBaseUrl;
}

/**
 * Resolve a media reference to an absolute URL for <Image>. Server-stored chat
 * photos come back as relative paths (e.g. /v1/chat/images/<id>); legacy or
 * external URLs are already absolute and pass through unchanged.
 */
export function resolveMediaUrl(path: string): string {
  if (/^https?:\/\//.test(path)) return path;
  return `${getApiBaseUrl()}${path}`;
}

type RequestOptions = {
  expectedProfileId?: string;
  expectedVenueId?: string;
  method?: 'GET' | 'POST' | 'PATCH' | 'DELETE';
  body?: unknown;
  signal?: AbortSignal;
  timeoutMs?: number;
};

export async function apiRequest<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const current = useAuthStore.getState();
  if ((options.expectedProfileId && current.user?.id !== options.expectedProfileId) ||
      (options.expectedVenueId && current.venue?.id !== options.expectedVenueId)) {
    throw new ApiError('The inventory operation belongs to a different account or workplace.', 409);
  }
  const token = useAuthStore.getState().token;
  const venueId = useAuthStore.getState().venue?.id;
  const timeout = options.timeoutMs ?? 30_000;
  const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
  const signal = controller?.signal ?? options.signal;
  let timedOut = false;
  const abortFromCaller = () => controller?.abort();
  if (options.signal?.aborted) abortFromCaller();
  else options.signal?.addEventListener('abort', abortFromCaller);
  const timer =
    controller && timeout > 0
      ? setTimeout(() => {
          timedOut = true;
          controller.abort();
        }, timeout)
      : null;

  let response: Response;
  try {
    response = await fetch(`${getApiBaseUrl()}${path}`, {
      method: options.method ?? 'GET',
      headers: {
        Accept: 'application/json, text/csv;q=0.9, text/plain;q=0.8',
        ...(options.body !== undefined ? { 'Content-Type': 'application/json' } : {}),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(venueId ? { 'X-Venue-Id': venueId } : {}),
      },
      body: options.body !== undefined ? JSON.stringify(options.body) : undefined,
      ...(signal ? { signal } : {}),
    });
  } catch (error) {
    if (error instanceof Error && error.name === 'AbortError' && timedOut) {
      throw new ApiError('Request timed out. Check your connection and try again.', 408);
    }
    throw error;
  } finally {
    options.signal?.removeEventListener('abort', abortFromCaller);
    if (timer) clearTimeout(timer);
  }

  if (!response.ok) {
    const errorText = await response.text().catch(() => '');
    let errorBody: { message?: string | string[] } | null = null;
    if (errorText) {
      try {
        errorBody = JSON.parse(errorText) as { message?: string | string[] };
      } catch {
        errorBody = { message: errorText };
      }
    }
    const message =
      typeof errorBody?.message === 'string'
        ? errorBody.message
        : Array.isArray(errorBody?.message)
          ? errorBody.message.join(', ')
          : `Request failed (${response.status})`;

    if (token && (response.status === 401 || (response.status === 403 && message.toLowerCase().includes('active membership')))) {
      void useAuthStore.getState().clearSession();
    }
    throw new ApiError(message, response.status);
  }

  if (response.status === 204) return null as T;
  const contentType = response.headers.get('content-type') ?? '';
  if (contentType.includes('application/json')) {
    return response.json() as Promise<T>;
  }
  return response.text() as Promise<T>;
}

export function useApiQuery<T>(queryKey: QueryKey, path: string, enabled = true) {
  const authEpoch = useAuthStore((state) => state.authEpoch);
  const userId = useAuthStore((state) => state.user?.id ?? null);
  const venueId = useAuthStore((state) => state.venue?.id ?? null);
  const token = useAuthStore((state) => state.token);
  return useQuery({
    queryKey: [...queryKey, authEpoch, userId, venueId],
    queryFn: ({ signal }) => apiRequest<T>(path, { signal }),
    enabled: enabled && Boolean(token),
  });
}

export function useApiMutation<TArgs, TResult>(
  mutationFn: (args: TArgs) => Promise<TResult>,
  invalidate: QueryKey[] = [],
) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn,
    onSuccess: async () => {
      await Promise.all(invalidate.map((queryKey) => queryClient.invalidateQueries({ queryKey })));
    },
  });
}

export type InviteCheckResult = { status: 'ok' };

/**
 * A time-clock punch. `attestation` is optional while the server has
 * ATTESTATION_ENFORCED=false, so devices that cannot attest keep working during
 * the staged rollout.
 */
export type ClockPunchBody = {
  lat: number;
  lng: number;
  accuracy: number;
  mocked: boolean;
  attestation?: { keyId: string; assertion: string; challenge: string };
};

export type JoinRequestResult = { requestId: string; status: 'pending'; venueName: string };
export type VenueSearchResult = { id: string; name: string; address: string | null };

export const appApi = {
  passwordAuth: (body: {
    email: string;
    phone?: string;
    password: string;
    flow: 'signIn' | 'signUp';
    firstName?: string;
    fullName?: string;
    lastName?: string;
    inviteToken?: string;
    termsAccepted?: boolean;
  }) =>
    apiRequest<AuthSessionResponse>('/v1/auth/password', { method: 'POST', body }),
  resendVerification: () => apiRequest<{ ok: true; alreadyVerified?: boolean }>('/v1/auth/verify-email/send', { method: 'POST' }),
  verifyEmail: (body: { code: string }) => apiRequest<{ ok: true; alreadyVerified?: boolean }>('/v1/auth/verify-email', { method: 'POST', body }),
  forgotPassword: (body: { email: string }) => apiRequest<{ ok: true }>('/v1/auth/forgot-password', { method: 'POST', body }),
  resetPassword: (body: { email: string; code: string; newPassword: string }) =>
    apiRequest<{ ok: true }>('/v1/auth/reset-password', { method: 'POST', body }),
  // Public: preview which team an invite code belongs to before signing up.
  previewInvite: (code: string) =>
    apiRequest<{ valid: boolean; venueName: string }>(
      '/v1/app/invite/' + encodeURIComponent(code.trim()),
    ),
  // Solo user joins an existing team later by code.
  joinByCode: (code: string) =>
    apiRequest<{ profile: ApiProfile; venue: ApiVenue | null }>('/v1/app/join', { method: 'POST', body: { code } }),
  redeemInvite: (codeOrToken: string) =>
    apiRequest<{ redeemed: boolean; profile?: ApiProfile; venue?: ApiVenue | null }>('/v1/app/redeem-invite', { method: 'POST', body: { codeOrToken } }),
  redeemMyInvite: () =>
    apiRequest<{ redeemed: boolean; profile?: ApiProfile; venue?: ApiVenue | null }>('/v1/app/redeem-my-invite', { method: 'POST' }),
  getMe: () => apiRequest<MeResponse | null>('/v1/app/me'),
  getBilling: () => apiRequest<any | null>('/v1/app/billing'),
  syncAppleSubscription: (body: { productId: string; entitlementId?: string }) =>
    apiRequest<any>('/v1/app/billing/apple/sync', { method: 'POST', body }),
  createStripeCheckout: (body?: { plan?: 'single' | 'multi_venue' }) =>
    apiRequest<{ url: string }>('/v1/app/billing/stripe/checkout', { method: 'POST', body }),
  createStripePortal: () =>
    apiRequest<{ url: string }>('/v1/app/billing/stripe/portal', { method: 'POST' }),
  getDashboard: () => apiRequest<any | null>('/v1/app/dashboard'),
  getNotifications: () => apiRequest<ApiNotification[]>('/v1/app/notifications'),
  markNotificationRead: (notificationId: string) => apiRequest(`/v1/app/notifications/${encodeURIComponent(notificationId)}/read`, { method: 'POST' }),
  getClockBoard: () => apiRequest<any | null>('/v1/time-clock/board'),
  getMyTimeClock: () => apiRequest<any | null>('/v1/time-clock/me'),
  clockIn: (body: ClockPunchBody) => apiRequest('/v1/time-clock/clock-in', { method: 'POST', body }),
  clockOut: (body: ClockPunchBody) => apiRequest('/v1/time-clock/clock-out', { method: 'POST', body }),
  breakStart: (body: { type: 'paid' | 'unpaid' }) => apiRequest('/v1/time-clock/break-start', { method: 'POST', body }),
  breakEnd: () => apiRequest('/v1/time-clock/break-end', { method: 'POST' }),
  listVenueStaff: () => apiRequest<ApiStaffMember[]>('/v1/app/staff'),
  upsertVenueStaff: (body: { venueId: string; email: string; fullName: string; role: string; jobTitle: string; phone?: string; altPhone?: string; address?: string; dateOfBirth?: string; certifications?: string[] }) =>
    apiRequest('/v1/app/staff', { method: 'POST', body }),
  deactivateVenueStaff: (staffId: string) => apiRequest(`/v1/app/staff/${encodeURIComponent(staffId)}`, { method: 'DELETE' }),
  createStaffRequest: (body: { kind: string; title: string; details: string; availability?: any; timeCorrection?: { timeEntryId?: string | null; clockInAt: number; clockOutAt?: number | null; reason?: string } }) =>
    apiRequest('/v1/staff-requests', { method: 'POST', body }),
  updateVenue: (body: { name?: string; latitude?: number; longitude?: number; geofenceRadiusM?: number; timezone?: string }) =>
    apiRequest<ApiVenue>('/v1/app/venue', { method: 'PATCH', body }),
  deleteMyAccount: (deleteOwnedVenues = false) =>
    apiRequest('/v1/app/me', { method: 'DELETE', body: { deleteOwnedVenues } }),

  // ─── Workforce ───────────────────────────────────────────────────────────────
  inviteCheck: (body: { email?: string; phone?: string }) =>
    apiRequest<InviteCheckResult>('/v1/workforce/invite-check', { method: 'POST', body }),
  searchVenues: (q: string) =>
    apiRequest<{ venues: VenueSearchResult[] }>(`/v1/workforce/venues/search?q=${encodeURIComponent(q)}`),
  submitJoinRequest: (body: { venueId: string; code: string }) =>
    apiRequest<JoinRequestResult>('/v1/workforce/join-request', { method: 'POST', body }),
  listMyJoinRequests: () =>
    apiRequest<{ requests: ApiJoinRequest[] }>('/v1/workforce/join-requests'),
  cancelJoinRequest: (id: string) =>
    apiRequest(`/v1/workforce/join-request/${encodeURIComponent(id)}`, { method: 'DELETE' }),
  listManagerJoinRequests: () =>
    apiRequest<{ requests: any[] }>('/v1/workforce/manager/join-requests'),
  approveJoinRequest: (id: string) =>
    apiRequest(`/v1/workforce/manager/join-request/${encodeURIComponent(id)}/approve`, { method: 'POST', body: {} }),
  rejectJoinRequest: (id: string, note?: string) =>
    apiRequest(`/v1/workforce/manager/join-request/${encodeURIComponent(id)}/reject`, { method: 'POST', body: { note } }),
};
