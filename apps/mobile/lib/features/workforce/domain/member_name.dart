/// The label for a team member in any list.
///
/// The name itself is resolved once, server-side, by `app_hidden.member_display_name`
/// (supabase/migrations/20261022100000_venue_location_and_hours.sql): the person's own display
/// name, else the name a manager entered in their staff profile, else one recorded on their
/// invite or at sign-up. Every roster-style RPC (`venue_roster`, `venue_schedule_roster`,
/// `team_members`, `chat_contacts`, `venue_clock_board`, `venue_timesheet`) returns that as
/// `display_name`, so screens only need this fallback for someone nobody has named yet.
String memberDisplayName(String? displayName, String userId) {
  final name = displayName?.trim();
  if (name != null && name.isNotEmpty) return name;
  final short = userId.length > 4 ? userId.substring(0, 4) : userId;
  return 'Team member $short';
}
