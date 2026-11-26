import 'package:supabase_flutter/supabase_flutter.dart';

import '../../venues/application/venues_providers.dart' show managerShellRoles;

/// Roles that may merge or split tables: supervisor and above, matching the role check in
/// `merge_floor_tables` / `split_floor_tables`. Staff can still change a table's status and
/// assign tables to a reservation. Unknown or missing roles are refused (fail closed); the
/// database enforces the rule either way.
bool canMergeOrSplitTables(String? role) => managerShellRoles.contains(role);

/// Message for a failed floor action. [mergeOrSplit] marks the merge/split calls, whose 42501
/// means the role is below supervisor.
String floorActionErrorMessage(Object error, {bool mergeOrSplit = false}) {
  if (error is PostgrestException && error.code == '42501') {
    return mergeOrSplit
        ? 'Only supervisors and managers can merge or split tables.'
        : "You don't have permission to change this table.";
  }
  return 'Could not update the floor. Please try again.';
}
