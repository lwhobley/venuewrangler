import type { ApiProfile, ApiVenue } from './api-client';
import type { UserSummary, Venue } from './types';

export function isUsableVenueMembership(profile: Pick<ApiProfile, 'emailVerified' | 'membershipStatus'>): boolean {
  if (!profile.emailVerified) return false;
  return profile.membershipStatus == null || profile.membershipStatus === 'active';
}

export function userFromProfile(profile: ApiProfile): UserSummary {
  return {
    id: profile._id,
    email: profile.email,
    full_name: profile.fullName,
    email_verified: profile.emailVerified === true,
    role: profile.role,
    job_title: profile.jobTitle,
    venue_id: isUsableVenueMembership(profile) ? profile.venueId ?? null : null,
    all_access: profile.allAccess === true,
  };
}

export function venueFromApi(venue: {
  _id?: string;
  id?: string;
  name: string;
  latitude: number;
  longitude: number;
  geofenceRadiusM?: number;
  geofence_radius_m?: number;
  timezone?: string | null;
  earlyClockInWindowMin?: number;
  early_clock_in_window_min?: number;
  clockTabletModeEnabled?: boolean;
  clock_tablet_mode_enabled?: boolean;
}): Venue {
  return {
    id: venue._id ?? venue.id ?? '',
    name: venue.name,
    latitude: venue.latitude,
    longitude: venue.longitude,
    geofenceRadiusM: venue.geofenceRadiusM ?? venue.geofence_radius_m ?? 0,
    geofence_radius_m: venue.geofenceRadiusM ?? venue.geofence_radius_m ?? 0,
    timezone: venue.timezone ?? null,
    earlyClockInWindowMin: venue.earlyClockInWindowMin ?? venue.early_clock_in_window_min ?? 10,
    early_clock_in_window_min: venue.earlyClockInWindowMin ?? venue.early_clock_in_window_min ?? 10,
    clockTabletModeEnabled: venue.clockTabletModeEnabled ?? venue.clock_tablet_mode_enabled ?? false,
    clock_tablet_mode_enabled: venue.clockTabletModeEnabled ?? venue.clock_tablet_mode_enabled ?? false,
  };
}

export function venueFromAuth(profile: ApiProfile, venue: ApiVenue | null | undefined): Venue | null {
  if (!venue || !isUsableVenueMembership(profile)) return null;
  return venueFromApi(venue);
}
