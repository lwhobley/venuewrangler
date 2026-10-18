import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/organizations/application/workspace_provisioning.dart';

void main() {
  test('create_workspace limits read as friendly messages', () {
    final controller = WorkspaceProvisioningController.friendlyWorkspaceError;

    expect(controller('workspace_rate_limited'), contains('short time'));
    expect(controller('workspace_limit_reached'), contains('maximum'));
    expect(controller(''), isNotEmpty);
    expect(controller('Unknown time zone'), 'Unknown time zone');
  });
}
