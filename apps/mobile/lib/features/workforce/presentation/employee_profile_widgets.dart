import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/auth/auth_providers.dart';
import '../../media/application/image_picker_service.dart';
import '../../venues/application/venues_providers.dart';
import '../application/employee_profiles_providers.dart';
import '../domain/employee_hr_profile.dart';

class StaffAvatar extends ConsumerWidget {
  const StaffAvatar({
    super.key,
    required this.profileKey,
    required this.name,
    this.radius = 24,
  });
  final StaffProfileKey profileKey;
  final String name;
  final double radius;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photo = ref.watch(staffPhotoProvider(profileKey)).valueOrNull;
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .take(2)
        .map((p) => p[0].toUpperCase())
        .join();
    final fallback = Center(
      child: Text(
        initials.isEmpty ? '?' : initials,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    return Semantics(
      label: 'Profile photo for $name',
      image: true,
      child: ClipOval(
        child: SizedBox(
          width: radius * 2,
          height: radius * 2,
          child: ColoredBox(
            color: Theme.of(context).colorScheme.primary,
            child: photo == null
                ? fallback
                : Image.network(
                    photo.url,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => fallback,
                  ),
          ),
        ),
      ),
    );
  }
}

class ProfilePhotoButton extends ConsumerStatefulWidget {
  const ProfilePhotoButton({
    super.key,
    required this.profileKey,
    required this.organizationId,
  });
  final StaffProfileKey profileKey;
  final String organizationId;
  @override
  ConsumerState<ProfilePhotoButton> createState() => _ProfilePhotoButtonState();
}

class _ProfilePhotoButtonState extends ConsumerState<ProfilePhotoButton> {
  bool _busy = false;
  Future<void> _pick() async {
    if (_busy) return;
    final actor = ref.read(currentUserIdProvider);
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from photos'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final path =
          await ref.read(imagePickerServiceProvider).pickImage(source: source);
      if (path == null || !mounted) return;
      if (ref.read(currentUserIdProvider) != actor ||
          ref.read(activeVenueProvider)?.id != widget.profileKey.venueId) {
        throw StateError('Your workplace changed. Open the profile again.');
      }
      await ref
          .read(employeeProfilesRepositoryProvider)
          .uploadPhoto(widget.profileKey, widget.organizationId, path);
      if (!mounted) return;
      ref.invalidate(staffPhotoProvider(widget.profileKey));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile photo updated.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is FormatException
                ? error.message.toString()
                : 'Could not update this photo. Please try again.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: _busy ? null : _pick,
        icon: _busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add_a_photo_outlined),
        label: Text(_busy ? 'Uploading photo…' : 'Add or change photo'),
      );
}

class EmployeeHrCard extends ConsumerWidget {
  const EmployeeHrCard({
    super.key,
    required this.profileKey,
    required this.name,
    required this.manageEmployment,
  });
  final StaffProfileKey profileKey;
  final String name;
  final bool manageEmployment;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(employeeHrProvider(profileKey));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: data.when(
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          ),
          error: (_, __) => Column(
            children: [
              const Text('Could not load HR details.'),
              TextButton(
                onPressed: () => ref.invalidate(employeeHrProvider(profileKey)),
                child: const Text('Retry'),
              ),
            ],
          ),
          data: (profile) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Contact & emergency details',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              for (final key in [
                'legal_name',
                'preferred_name',
                'contact_email',
                'phone',
                'alternate_phone',
                'address',
                'date_of_birth',
                'emergency_contact_name',
                'emergency_contact_relationship',
                'emergency_contact_phone',
              ])
                if (profile.fieldText(key).isNotEmpty)
                  _Detail(personalHrFields[key]!, profile.fieldText(key)),
              if (personalHrFields.keys
                  .every((k) => profile.fieldText(k).isEmpty))
                const Text('Add your contact and emergency information.'),
              const SizedBox(height: 16),
              Text(
                'Employment',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              for (final key in employmentHrFields.keys)
                if (profile.fieldText(key).isNotEmpty)
                  _Detail(
                    employmentHrFields[key]!,
                    key == 'hourly_rate_cents'
                        ? '\$${profile.fieldText(key)}'
                        : profile.fieldText(key).replaceAll('_', ' '),
                  ),
              if (employmentHrFields.keys
                  .every((k) => profile.fieldText(k).isEmpty))
                const Text('Your manager can add employment details.'),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  builder: (_) => _HrEditor(
                    profileKey: profileKey,
                    name: name,
                    initial: profile,
                    manageEmployment: manageEmployment,
                  ),
                ),
                icon: const Icon(Icons.edit_outlined),
                label: Text(
                  manageEmployment
                      ? 'Edit employee profile'
                      : 'Edit my details',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            Text(value),
          ],
        ),
      );
}

class _HrEditor extends ConsumerStatefulWidget {
  const _HrEditor({
    required this.profileKey,
    required this.name,
    required this.initial,
    required this.manageEmployment,
  });
  final StaffProfileKey profileKey;
  final String name;
  final EmployeeHrProfile initial;
  final bool manageEmployment;
  @override
  ConsumerState<_HrEditor> createState() => _HrEditorState();
}

class _HrEditorState extends ConsumerState<_HrEditor> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _fields;
  late final String? _actor;
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _actor = ref.read(currentUserIdProvider);
    _fields = {
      for (final key in [
        ...personalHrFields.keys,
        if (widget.manageEmployment) ...employmentHrFields.keys,
      ])
        key: TextEditingController(text: widget.initial.fieldText(key)),
    };
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    if (ref.read(currentUserIdProvider) != _actor ||
        ref.read(activeVenueProvider)?.id != widget.profileKey.venueId) {
      setState(
        () => _error =
            'Your workplace changed. Close this form and open the profile again.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(employeeProfilesRepositoryProvider).saveHr(
            widget.profileKey,
            hrUpdatePayload(
              {for (final e in _fields.entries) e.key: e.value.text},
              manageEmployment: widget.manageEmployment,
            ),
          );
      if (!mounted) return;
      ref.invalidate(employeeHrProvider(widget.profileKey));
      Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not save these details. Check your connection and permissions, then try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(String key, String label) {
    if (key == 'employment_type' || key == 'employment_status') {
      final choices = key == 'employment_type'
          ? ['full_time', 'part_time', 'seasonal', 'contractor', 'temporary']
          : ['active', 'on_leave', 'inactive'];
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          initialValue:
              choices.contains(_fields[key]!.text) ? _fields[key]!.text : null,
          decoration: InputDecoration(labelText: label),
          items: [
            const DropdownMenuItem(value: '', child: Text('Not set')),
            for (final value in choices)
              DropdownMenuItem(
                value: value,
                child: Text(value.replaceAll('_', ' ')),
              ),
          ],
          onChanged: _saving ? null : (v) => _fields[key]!.text = v ?? '',
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: _fields[key],
        enabled: !_saving,
        decoration: InputDecoration(
          labelText: label,
          hintText: key.endsWith('date') || key == 'date_of_birth'
              ? 'YYYY-MM-DD'
              : key == 'certifications'
                  ? 'Separate with commas'
                  : null,
        ),
        keyboardType: key.contains('phone')
            ? TextInputType.phone
            : key == 'contact_email'
                ? TextInputType.emailAddress
                : ['hourly_rate_cents', 'pto_hours', 'sick_hours'].contains(key)
                    ? const TextInputType.numberWithOptions(decimal: true)
                    : TextInputType.text,
        textInputAction: TextInputAction.next,
        maxLines: key == 'address' ? 2 : 1,
        validator: (v) => hrFieldProblem(key, v ?? ''),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .85 -
              MediaQuery.viewInsetsOf(context).bottom,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Form(
                  key: _form,
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    children: [
                      Text(
                        'Personal information',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      for (final e in personalHrFields.entries)
                        _field(e.key, e.value),
                      if (widget.manageEmployment) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Employment information',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        for (final e in employmentHrFields.entries)
                          _field(e.key, e.value),
                      ],
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? 'Saving…' : 'Save details'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
