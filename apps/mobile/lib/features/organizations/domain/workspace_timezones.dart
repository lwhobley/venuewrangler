/// Time zones a new workspace can be created in. Every id must be a real IANA name:
/// `venues.timezone` is read server-side with `at time zone` (the time clock's anti-replay
/// day boundary), which raises on an unknown name — and `public.create_workspace` rejects one
/// up front. Deliberately a short, curated list rather than all ~600 IANA zones; extend it as
/// needed.
const kWorkspaceTimezones = <({String id, String label})>[
  (id: 'America/New_York', label: 'Eastern (New York)'),
  (id: 'America/Chicago', label: 'Central (Chicago)'),
  (id: 'America/Denver', label: 'Mountain (Denver)'),
  (id: 'America/Phoenix', label: 'Arizona (Phoenix, no daylight saving)'),
  (id: 'America/Los_Angeles', label: 'Pacific (Los Angeles)'),
  (id: 'America/Anchorage', label: 'Alaska (Anchorage)'),
  (id: 'Pacific/Honolulu', label: 'Hawaii (Honolulu)'),
  (id: 'Europe/London', label: 'United Kingdom (London)'),
  (id: 'Europe/Paris', label: 'Central Europe (Paris)'),
  (id: 'Australia/Sydney', label: 'Eastern Australia (Sydney)'),
];

const _byAbbreviation = {
  'EST': 'America/New_York',
  'EDT': 'America/New_York',
  'CDT': 'America/Chicago',
  'MDT': 'America/Denver',
  'PST': 'America/Los_Angeles',
  'PDT': 'America/Los_Angeles',
  'AKST': 'America/Anchorage',
  'AKDT': 'America/Anchorage',
  'HST': 'Pacific/Honolulu',
  'GMT': 'Europe/London',
  'BST': 'Europe/London',
  'CET': 'Europe/Paris',
  'CEST': 'Europe/Paris',
  'AEST': 'Australia/Sydney',
  'AEDT': 'Australia/Sydney',
};

// Prefix matches only: "Australian Eastern Daylight Time" and "Central European Standard
// Time" must not be mistaken for US zones by a substring match.
const _byLongName = {
  'EASTERN STANDARD': 'America/New_York',
  'EASTERN DAYLIGHT': 'America/New_York',
  'CENTRAL STANDARD': 'America/Chicago',
  'CENTRAL DAYLIGHT': 'America/Chicago',
  'MOUNTAIN STANDARD': 'America/Denver',
  'MOUNTAIN DAYLIGHT': 'America/Denver',
  'PACIFIC STANDARD': 'America/Los_Angeles',
  'PACIFIC DAYLIGHT': 'America/Los_Angeles',
};

/// Best guess at the device's zone, to pre-select in the picker — or null when it can't be
/// told apart (Dart exposes only an abbreviation, not an IANA id, and browsers report a long
/// name), in which case the person chooses. Never guess wrong silently: it's only a default
/// the person can see and change.
String? guessWorkspaceTimezone([DateTime? now]) {
  final name = (now ?? DateTime.now()).timeZoneName.toUpperCase();
  final byAbbreviation = _byAbbreviation[name];
  if (byAbbreviation != null) return byAbbreviation;
  for (final entry in _byLongName.entries) {
    if (name.startsWith(entry.key)) return entry.value;
  }
  return null;
}
