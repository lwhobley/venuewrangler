// Response mappers keep API payloads stable so the Expo client can share one
// data shape across screens.

type ClockProfile = { id: string; fullName: string; role: string; jobTitle: string };
type ClockVenue = { id: string; name: string };
type TimeEntryRow = {
  id: string;
  clockInAt: Date;
  clockOutAt: Date | null;
  clockInLat: number | null;
  clockInLng: number | null;
  clockInAccuracyM: number | null;
  clockInMocked: boolean | null;
  clockOutLat: number | null;
  clockOutLng: number | null;
  clockOutAccuracyM: number | null;
  clockOutMocked: boolean | null;
  isOpen: boolean;
  breaks: unknown;
};

export function dayLabel(index: number): string {
  return ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][index] ?? 'Day';
}

export function minutesToTime(minutes: number): string {
  const hours = Math.floor(minutes / 60) % 24;
  const mins = minutes % 60;
  const suffix = hours >= 12 ? 'PM' : 'AM';
  const displayHour = hours % 12 === 0 ? 12 : hours % 12;
  return `${displayHour}:${mins.toString().padStart(2, '0')} ${suffix}`;
}

export function mapClockEntry(
  entry: TimeEntryRow,
  profile: ClockProfile,
  venue: ClockVenue,
  options?: { includeLocation?: boolean },
) {
  const includeLocation = options?.includeLocation !== false;
  return {
    _id: entry.id,
    memberId: profile.id,
    memberName: profile.fullName,
    role: profile.role,
    jobTitle: profile.jobTitle,
    venueId: venue.id,
    venueName: venue.name,
    clockInAt: entry.clockInAt.getTime(),
    clockOutAt: entry.clockOutAt?.getTime() ?? null,
    clockInLat: includeLocation ? entry.clockInLat : null,
    clockInLng: includeLocation ? entry.clockInLng : null,
    clockInAccuracyM: includeLocation ? entry.clockInAccuracyM : null,
    clockInMocked: includeLocation ? entry.clockInMocked : null,
    clockOutLat: includeLocation ? (entry.clockOutLat ?? null) : null,
    clockOutLng: includeLocation ? (entry.clockOutLng ?? null) : null,
    clockOutAccuracyM: includeLocation ? (entry.clockOutAccuracyM ?? null) : null,
    clockOutMocked: includeLocation ? (entry.clockOutMocked ?? null) : null,
    isOpen: entry.isOpen,
    breaks: entry.breaks ?? null,
  };
}

type ProfileRow = {
  id: string;
  email: string;
  fullName: string;
  role: string;
  jobTitle: string;
  hourlyRateCents?: number | null;
  phone: string | null;
  altPhone: string | null;
  address: string | null;
  dateOfBirth: Date | null;
  certifications: string[];
  venueId: string | null;
  allAccess: boolean;
  sickHoursAccrued: number;
  ptoHoursAccrued: number;
};

export function mapProfile(profile: ProfileRow) {
  return {
    _id: profile.id,
    email: profile.email,
    fullName: profile.fullName,
    role: profile.role,
    jobTitle: profile.jobTitle,
    phone: profile.phone ?? null,
    altPhone: profile.altPhone ?? null,
    address: profile.address ?? null,
    dateOfBirth: profile.dateOfBirth?.toISOString().slice(0, 10) ?? null,
    certifications: profile.certifications ?? [],
    venueId: profile.venueId,
    allAccess: profile.allAccess,
    sickHoursAccrued: profile.sickHoursAccrued,
    ptoHoursAccrued: profile.ptoHoursAccrued,
  };
}

type StaffRequestRow = {
  id: string;
  venueId: string;
  profileId: string;
  kind: string;
  status: string;
  title: string;
  details: string;
  requestedForDate: string | null;
  requestedShiftId: string | null;
  requestedRangeStart: string | null;
  requestedRangeEnd: string | null;
  availability: unknown;
  reviewerId: string | null;
  reviewedAt: Date | null;
  responseNotes: string | null;
  createdAt: Date;
  updatedAt: Date;
};

export function mapStaffRequest(request: StaffRequestRow) {
  return {
    _id: request.id,
    venueId: request.venueId,
    profileId: request.profileId,
    kind: request.kind,
    status: request.status,
    title: request.title,
    details: request.details,
    requestedForDate: request.requestedForDate ?? null,
    requestedShiftId: request.requestedShiftId ?? null,
    requestedRangeStart: request.requestedRangeStart ?? null,
    requestedRangeEnd: request.requestedRangeEnd ?? null,
    availability: request.availability ?? null,
    reviewerId: request.reviewerId ?? null,
    reviewedAt: request.reviewedAt?.getTime() ?? null,
    responseNotes: request.responseNotes ?? null,
    createdAt: request.createdAt.getTime(),
    updatedAt: request.updatedAt.getTime(),
  };
}
