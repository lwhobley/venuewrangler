import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/org_ai_providers.dart';

/// Owner/admin switch for AI features across the organization. The caller decides who sees it;
/// the server only lets owners and admins change it.
class OrgAiToggleTile extends ConsumerStatefulWidget {
  const OrgAiToggleTile({super.key, required this.organizationId});

  final String organizationId;

  @override
  ConsumerState<OrgAiToggleTile> createState() => _OrgAiToggleTileState();
}

class _OrgAiToggleTileState extends ConsumerState<OrgAiToggleTile> {
  bool _saving = false;

  Future<void> _set(bool enabled) async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(orgAiSettingsRepositoryProvider)
          .setEnabled(widget.organizationId, enabled);
    } on PostgrestException catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.code == '42501'
                ? 'Only owners and admins can change this.'
                : 'Could not update the setting. Please try again.',
          ),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not update the setting. Please try again.'),
        ),
      );
    } finally {
      if (mounted) {
        ref.invalidate(orgAiEnabledProvider(widget.organizationId));
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabledAsync = ref.watch(orgAiEnabledProvider(widget.organizationId));
    return SwitchListTile(
      secondary: const Icon(Icons.auto_awesome_outlined),
      title: const Text('AI features for this organization'),
      subtitle: Text(
        enabledAsync.hasError
            ? 'Could not load this setting.'
            : 'When on, staff import, scheduling suggestions, inventory '
                'parsing, shift insights and Ask Wrangler send the text you '
                'provide to Groq.',
      ),
      value: enabledAsync.valueOrNull ?? false,
      onChanged: _saving || !enabledAsync.hasValue ? null : _set,
    );
  }
}
