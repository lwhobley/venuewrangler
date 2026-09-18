import { describe, expect, it } from 'vitest';
import { dayLabel, minutesToTime, mapClockEntry, mapProfile, mapStaffRequest } from './mappers';

describe('dayLabel', () => {
  it('returns Sun for index 0', () => {
    expect(dayLabel(0)).toBe('Sun');
  });

  it('returns Mon for index 1', () => {
    expect(dayLabel(1)).toBe('Mon');
  });

  it('returns Sat for index 6', () => {
    expect(dayLabel(6)).toBe('Sat');
  });

  it('returns Day for out-of-range index', () => {
    expect(dayLabel(7)).toBe('Day');
    expect(dayLabel(-1)).toBe('Day');
  });
});

describe('minutesToTime', () => {
  it('converts 0 minutes to 12:00 AM', () => {
    expect(minutesToTime(0)).toBe('12:00 AM');
  });

  it('converts 60 minutes to 1:00 AM', () => {
    expect(minutesToTime(60)).toBe('1:00 AM');
  });

  it('converts 720 minutes to 12:00 PM (noon)', () => {
    expect(minutesToTime(720)).toBe('12:00 PM');
  });

  it('converts 780 minutes to 1:00 PM', () => {
    expect(minutesToTime(780)).toBe('1:00 PM');
  });

  it('converts 1439 minutes to 11:59 PM', () => {
    expect(minutesToTime(1439)).toBe('11:59 PM');
  });

  it('pads single-digit minutes with zero', () => {
    expect(minutesToTime(65)).toBe('1:05 AM');
  });

  it('handles wrapping past 24 hours', () => {
    // 1440 minutes = 24 hours, wraps to 12:00 AM
    expect(minutesToTime(1440)).toBe('12:00 AM');
  });
});

describe('mapClockEntry', () => {
  const entry = {
    id: 'entry-1',
    clockInAt: new Date('2024-01-15T09:00:00Z'),
    clockOutAt: new Date('2024-01-15T17:00:00Z'),
    clockInLat: 37.7749,
    clockInLng: -122.4194,
    clockInAccuracyM: 10,
    clockInMocked: false,
    clockOutLat: 37.775,
    clockOutLng: -122.42,
    clockOutAccuracyM: 12,
    clockOutMocked: false,
    isOpen: false,
    breaks: [{ start: 1705316400000, end: 1705320000000 }],
  };

  const profile = { id: 'p-1', fullName: 'Jane Doe', role: 'staff', jobTitle: 'Bartender' };
  const venue = { id: 'v-1', name: 'The Lounge' };

  it('maps all fields correctly', () => {
    const result = mapClockEntry(entry, profile, venue);
    expect(result._id).toBe('entry-1');
    expect(result.memberId).toBe('p-1');
    expect(result.memberName).toBe('Jane Doe');
    expect(result.role).toBe('staff');
    expect(result.jobTitle).toBe('Bartender');
    expect(result.venueId).toBe('v-1');
    expect(result.venueName).toBe('The Lounge');
    expect(result.clockInAt).toBe(entry.clockInAt.getTime());
    expect(result.clockOutAt).toBe(entry.clockOutAt.getTime());
    expect(result.clockInLat).toBe(37.7749);
    expect(result.clockInLng).toBe(-122.4194);
    expect(result.clockInAccuracyM).toBe(10);
    expect(result.clockInMocked).toBe(false);
    expect(result.clockOutLat).toBe(37.775);
    expect(result.clockOutLng).toBe(-122.42);
    expect(result.clockOutAccuracyM).toBe(12);
    expect(result.clockOutMocked).toBe(false);
    expect(result.isOpen).toBe(false);
    expect(result.breaks).toEqual([{ start: 1705316400000, end: 1705320000000 }]);
  });

  it('returns null for clockOutAt and clock-out fields when entry is open', () => {
    const openEntry = {
      ...entry,
      clockOutAt: null,
      clockOutLat: null,
      clockOutLng: null,
      clockOutAccuracyM: null,
      clockOutMocked: null,
      isOpen: true,
      breaks: null,
    };
    const result = mapClockEntry(openEntry, profile, venue);
    expect(result.clockOutAt).toBeNull();
    expect(result.clockOutLat).toBeNull();
    expect(result.clockOutLng).toBeNull();
    expect(result.clockOutAccuracyM).toBeNull();
    expect(result.clockOutMocked).toBeNull();
    expect(result.isOpen).toBe(true);
    expect(result.breaks).toBeNull();
  });
});

describe('mapProfile', () => {
  const fullProfile = {
    id: 'p-1',
    email: 'jane@example.com',
    fullName: 'Jane Doe',
    role: 'manager',
    jobTitle: 'Floor Manager',
    phone: '555-1234',
    altPhone: '555-5678',
    address: '123 Main St',
    dateOfBirth: new Date('1990-06-15T00:00:00Z'),
    certifications: ['ServSafe', 'TIPS'],
    venueId: 'v-1',
    allAccess: false,
    sickHoursAccrued: 8,
    ptoHoursAccrued: 40,
  };

  it('maps all fields correctly', () => {
    const result = mapProfile(fullProfile);
    expect(result._id).toBe('p-1');
    expect(result.email).toBe('jane@example.com');
    expect(result.fullName).toBe('Jane Doe');
    expect(result.role).toBe('manager');
    expect(result.jobTitle).toBe('Floor Manager');
    expect(result.phone).toBe('555-1234');
    expect(result.altPhone).toBe('555-5678');
    expect(result.address).toBe('123 Main St');
    expect(result.dateOfBirth).toBe('1990-06-15');
    expect(result.certifications).toEqual(['ServSafe', 'TIPS']);
    expect(result.venueId).toBe('v-1');
    expect(result.allAccess).toBe(false);
    expect(result.sickHoursAccrued).toBe(8);
    expect(result.ptoHoursAccrued).toBe(40);
  });

  it('returns null for optional fields when they are null', () => {
    const sparseProfile = {
      ...fullProfile,
      phone: null,
      altPhone: null,
      address: null,
      dateOfBirth: null,
      certifications: [],
      venueId: null,
    };
    const result = mapProfile(sparseProfile);
    expect(result.phone).toBeNull();
    expect(result.altPhone).toBeNull();
    expect(result.address).toBeNull();
    expect(result.dateOfBirth).toBeNull();
    expect(result.certifications).toEqual([]);
    expect(result.venueId).toBeNull();
  });
});

describe('mapStaffRequest', () => {
  const request = {
    id: 'req-1',
    venueId: 'v-1',
    profileId: 'p-1',
    kind: 'time_off',
    status: 'pending',
    title: 'Vacation request',
    details: 'Taking a week off',
    requestedForDate: '2024-03-01',
    requestedShiftId: 'shift-1',
    requestedRangeStart: '2024-03-01',
    requestedRangeEnd: '2024-03-07',
    availability: { monday: true, tuesday: false },
    reviewerId: 'rev-1',
    reviewedAt: new Date('2024-02-20T10:00:00Z'),
    responseNotes: 'Approved, enjoy!',
    createdAt: new Date('2024-02-15T08:00:00Z'),
    updatedAt: new Date('2024-02-20T10:00:00Z'),
  };

  it('maps all fields correctly', () => {
    const result = mapStaffRequest(request);
    expect(result._id).toBe('req-1');
    expect(result.venueId).toBe('v-1');
    expect(result.profileId).toBe('p-1');
    expect(result.kind).toBe('time_off');
    expect(result.status).toBe('pending');
    expect(result.title).toBe('Vacation request');
    expect(result.details).toBe('Taking a week off');
    expect(result.requestedForDate).toBe('2024-03-01');
    expect(result.requestedShiftId).toBe('shift-1');
    expect(result.requestedRangeStart).toBe('2024-03-01');
    expect(result.requestedRangeEnd).toBe('2024-03-07');
    expect(result.availability).toEqual({ monday: true, tuesday: false });
    expect(result.reviewerId).toBe('rev-1');
    expect(result.reviewedAt).toBe(request.reviewedAt.getTime());
    expect(result.responseNotes).toBe('Approved, enjoy!');
    expect(result.createdAt).toBe(request.createdAt.getTime());
    expect(result.updatedAt).toBe(request.updatedAt.getTime());
  });

  it('returns null for optional fields when they are null', () => {
    const minimalRequest = {
      ...request,
      requestedForDate: null,
      requestedShiftId: null,
      requestedRangeStart: null,
      requestedRangeEnd: null,
      availability: null,
      reviewerId: null,
      reviewedAt: null,
      responseNotes: null,
    };
    const result = mapStaffRequest(minimalRequest);
    expect(result.requestedForDate).toBeNull();
    expect(result.requestedShiftId).toBeNull();
    expect(result.requestedRangeStart).toBeNull();
    expect(result.requestedRangeEnd).toBeNull();
    expect(result.availability).toBeNull();
    expect(result.reviewerId).toBeNull();
    expect(result.reviewedAt).toBeNull();
    expect(result.responseNotes).toBeNull();
  });
});

describe('profile response safety', () => {
  it('never returns hourly rates to staff clients', () => {
    const mapped = mapProfile({
      id: 'profile-1', email: 'staff@example.com', fullName: 'Staff', role: 'staff',
      jobTitle: 'Server', venueId: 'venue-1', allAccess: false, hourlyRateCents: 2200,
      phone: null, altPhone: null, address: null, dateOfBirth: null,
      certifications: [], sickHoursAccrued: 0, ptoHoursAccrued: 0,
    });
    expect(mapped).not.toHaveProperty('hourlyRateCents');
    expect(mapped).not.toHaveProperty('wage');
  });
});
