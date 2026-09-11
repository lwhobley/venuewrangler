import * as FileSystem from 'expo-file-system/legacy';
import * as SecureStore from 'expo-secure-store';
import { Platform } from 'react-native';
import { create } from 'zustand';
import { createJSONStorage, persist } from 'zustand/middleware';
import type { UserSummary, Venue, VenueSummary } from './types';

type SessionState = {
  user: UserSummary | null;
  venue: Venue | null;
  venues: VenueSummary[];
  token: string | null;
};

export type AuthState = SessionState & {
  authEpoch: number;
  hydrated: boolean;
  setHydrated: (hydrated: boolean) => void;
  setSession: (session: {
    user: UserSummary;
    venue: Venue | null;
    venues?: VenueSummary[];
    token?: string | null;
  }) => void;
  /**
   * Refresh the signed-in person's own details (name, role, job title,
   * verification) without touching authEpoch.
   *
   * authEpoch keys every cached query and clearing it wipes the cache, so
   * routing a /me refresh through setSession made the app clear its cache,
   * refetch /me, apply the response, clear again — a reload loop that ran until
   * the API rate-limited it and the screen showed an error. Identity detail is
   * not a cache scope: the account and the venue are the same ones the cached
   * data belongs to. A genuine scope change (a different account or venue) is
   * still setSession's job and still bumps the epoch.
   */
  syncProfile: (profile: { user: UserSummary; venue: Venue | null }) => void;
  setVenue: (venue: Venue) => void;
  setVenues: (venues: VenueSummary[]) => void;
  switchVenue: (venue: Venue) => void;
  clearSession: () => Promise<void>;
};

const AUTH_PERSIST_NAME = 'venuewrangler-auth';
const TOKEN_KEY = 'venuewrangler-auth-token';
const REST_FILENAME = 'venuewrangler-auth-rest.json';

const memoryStorage = {
  getItem: async (key: string) => {
    return memoryStorage.values.get(key) ?? null;
  },
  setItem: async (key: string, value: string) => {
    memoryStorage.values.set(key, value);
  },
  removeItem: async (key: string) => {
    memoryStorage.values.delete(key);
  },
  values: new Map<string, string>(),
};

/**
 * Web session storage.
 *
 * The session used to live only in memory, so a page refresh — or anything that
 * remounts the app — dropped the token and signed the person out mid-task. That
 * is what made the reviewed web build unusable rather than merely inconvenient.
 *
 * sessionStorage, not localStorage: the bearer token survives a reload of the
 * tab the person is working in, and still never persists past the tab closing
 * or leaks into another one. Keeping a long-lived token in localStorage is a
 * security decision (any XSS then reads it) that belongs to the venue's own
 * risk posture, not to this fix. A second tab therefore still signs in
 * separately.
 *
 * Every accessor is guarded: Safari's private mode and "block site data" throw
 * on access rather than returning null, and a throw here would take the whole
 * app down at startup.
 */
const webSessionStorage = {
  getItem: async (key: string) => {
    try {
      return window.sessionStorage?.getItem(key) ?? null;
    } catch {
      return memoryStorage.getItem(key);
    }
  },
  setItem: async (key: string, value: string) => {
    try {
      window.sessionStorage?.setItem(key, value);
    } catch {
      await memoryStorage.setItem(key, value);
    }
  },
  removeItem: async (key: string) => {
    try {
      window.sessionStorage?.removeItem(key);
    } catch {
      // Fall through to the memory copy below.
    }
    await memoryStorage.removeItem(key);
  },
};

type PersistBlob = {
  state?: Partial<SessionState> & Record<string, unknown>;
  version?: number;
};

function parseBlob(raw: string | null): PersistBlob | null {
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as PersistBlob;
    if (parsed && typeof parsed === 'object') return parsed;
  } catch {
    // Ignore corrupt blobs and fall through to a fresh session.
  }
  return null;
}

function restFileUri(): string | null {
  const dir = FileSystem.documentDirectory;
  if (!dir) return null;
  return `${dir}${REST_FILENAME}`;
}

async function readRestFile(): Promise<string | null> {
  const uri = restFileUri();
  if (!uri) return null;
  try {
    return await FileSystem.readAsStringAsync(uri);
  } catch {
    return null;
  }
}

async function writeRestFile(value: string): Promise<void> {
  const uri = restFileUri();
  if (!uri) return;
  await FileSystem.writeAsStringAsync(uri, value);
}

async function deleteRestFile(): Promise<void> {
  const uri = restFileUri();
  if (!uri) return;
  await FileSystem.deleteAsync(uri, { idempotent: true }).catch(() => {});
}

/**
 * Split the persisted session so the bearer token stays inside iOS Keychain
 * (SecureStore's 2048-byte cap) while the larger user/venue JSON lives on disk.
 * Existing combined blobs under `venuewrangler-auth` are migrated on first read.
 */
const splitNativeStorage = {
  getItem: async (_key: string) => {
    const restRaw = await readRestFile();
    const token = await SecureStore.getItemAsync(TOKEN_KEY).catch(() => null);

    if (restRaw || token) {
      const blob = parseBlob(restRaw) ?? { state: {}, version: 0 };
      blob.state = { ...(blob.state ?? {}), token: token ?? null };
      return JSON.stringify(blob);
    }

    const legacy = await SecureStore.getItemAsync(AUTH_PERSIST_NAME).catch(() => null);
    if (!legacy) return null;
    const blob = parseBlob(legacy);
    if (!blob?.state) {
      await SecureStore.deleteItemAsync(AUTH_PERSIST_NAME).catch(() => {});
      return legacy;
    }
    const migratedToken = typeof blob.state.token === 'string' ? blob.state.token : null;
    const restState = { ...blob.state, token: null };
    await writeRestFile(JSON.stringify({ ...blob, state: restState })).catch(() => {});
    if (migratedToken) {
      await SecureStore.setItemAsync(TOKEN_KEY, migratedToken).catch(() => {});
    }
    await SecureStore.deleteItemAsync(AUTH_PERSIST_NAME).catch(() => {});
    return JSON.stringify({ ...blob, state: { ...restState, token: migratedToken } });
  },
  setItem: async (_key: string, value: string) => {
    const blob = parseBlob(value) ?? { state: {}, version: 0 };
    const token = typeof blob.state?.token === 'string' ? blob.state.token : null;
    const restState = { ...(blob.state ?? {}), token: null };
    await writeRestFile(JSON.stringify({ ...blob, state: restState }));
    if (token) {
      await SecureStore.setItemAsync(TOKEN_KEY, token);
    } else {
      await SecureStore.deleteItemAsync(TOKEN_KEY).catch(() => {});
    }
    await SecureStore.deleteItemAsync(AUTH_PERSIST_NAME).catch(() => {});
  },
  removeItem: async (_key: string) => {
    await deleteRestFile();
    await SecureStore.deleteItemAsync(TOKEN_KEY).catch(() => {});
    await SecureStore.deleteItemAsync(AUTH_PERSIST_NAME).catch(() => {});
  },
};

if (Platform.OS === 'web' && typeof window !== 'undefined') {
  try {
    window.localStorage?.removeItem(AUTH_PERSIST_NAME);
  } catch {}
}

const storage =
  Platform.OS === 'web'
    ? typeof window !== 'undefined' && typeof window.sessionStorage !== 'undefined'
      ? webSessionStorage
      : memoryStorage
    : splitNativeStorage;

const createAuthStore = (set: any): AuthState => ({
  authEpoch: 0,
  hydrated: false,
  user: null,
  venue: null,
  venues: [],
  token: null,
  setHydrated: (hydrated: boolean) => set({ hydrated }),
  setSession: (session: { user: UserSummary; venue: Venue | null; venues?: VenueSummary[]; token?: string | null }) =>
    set((state: AuthState) => {
      // Attestation cache records are account-scoped and are synchronously
      // rejected by attestation.ts when user ids differ. Do not launch a
      // fire-and-forget delete here: it could race a new account's enrolment
      // and erase the newly stored key after registration completes.
      return {
        user: session.user,
        venue: session.venue,
        venues: session.venues ?? state.venues,
        ...(session.token !== undefined ? { token: session.token } : {}),
        authEpoch: state.authEpoch + 1,
      };
    }),
  syncProfile: (profile: { user: UserSummary; venue: Venue | null }) =>
    set((state: AuthState) => {
      const scopeChanged =
        state.user?.id !== profile.user.id || (state.venue?.id ?? null) !== (profile.venue?.id ?? null);
      return {
        user: profile.user,
        venue: profile.venue,
        // A different account or venue really is a new cache scope; only then
        // does the epoch move.
        ...(scopeChanged ? { authEpoch: state.authEpoch + 1 } : {}),
      };
    }),
  // Same trap as the /me refresh above, via a different door: auth-readiness's
  // effect calls this on every getMe response with a freshly-built venue
  // object (session-from-auth's venueFromApi always returns a new reference),
  // so an unconditional epoch bump here reran that same query, produced
  // another new venue object, and bumped again -- an infinite refetch loop
  // across every mounted screen, not just the one query. Only a real identity
  // change (a different venue) is a cache-scope change.
  setVenue: (venue: Venue) =>
    set((state: AuthState) => ({
      venue,
      ...(state.venue?.id !== venue.id ? { authEpoch: state.authEpoch + 1 } : {}),
    })),
  setVenues: (venues: VenueSummary[]) => set({ venues }),
  switchVenue: (venue: Venue) =>
    set((state: AuthState) => ({
      venue,
      authEpoch: state.authEpoch + 1,
    })),
  clearSession: async () => {
    // Clear in-memory authorization synchronously, then let callers await the
    // device-key removal before another account is established.
    set((state: AuthState) => ({
      user: null,
      venue: null,
      venues: [],
      token: null,
      authEpoch: state.authEpoch + 1,
    }));
    await SecureStore.deleteItemAsync('venuewrangler.appattest.keyId').catch(() => {});
  },
});

export const useAuthStore = create<AuthState>()(
  persist(createAuthStore, {
    name: AUTH_PERSIST_NAME,
    storage: createJSONStorage(() => storage),
    partialize: (state: AuthState): SessionState => ({
      user: state.user,
      venue: state.venue,
      venues: state.venues,
      token: state.token,
    }),
    onRehydrateStorage: () => (state: AuthState | undefined) => {
      if (state) state.setHydrated(true);
      else useAuthStore.getState().setHydrated(true);
    },
  }),
);
