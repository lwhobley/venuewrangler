const personalHrFields = <String, String>{
  'legal_name': 'Legal name',
  'preferred_name': 'Preferred name',
  'contact_email': 'Contact email',
  'phone': 'Phone',
  'alternate_phone': 'Alternate phone',
  'address': 'Address',
  'date_of_birth': 'Date of birth',
  'emergency_contact_name': 'Emergency contact name',
  'emergency_contact_relationship': 'Relationship',
  'emergency_contact_phone': 'Emergency contact phone',
};
const employmentHrFields = <String, String>{
  'employee_number': 'Employee number',
  'job_title': 'Job title',
  'department': 'Department',
  'hire_date': 'Hire date',
  'employment_type': 'Employment type',
  'employment_status': 'Employment status',
  'hourly_rate_cents': 'Hourly rate (USD)',
  'certifications': 'Certifications',
  'pto_hours': 'PTO hours',
  'sick_hours': 'Sick hours',
};

class EmployeeHrProfile {
  EmployeeHrProfile(Map<String, dynamic> values)
      : values = Map.unmodifiable(values);
  final Map<String, dynamic> values;

  String fieldText(String key) {
    final value = values[key];
    if (value == null) return '';
    if (key == 'hourly_rate_cents') {
      return ((value as num) / 100).toStringAsFixed(2);
    }
    if (key == 'certifications') return (value as List).join(', ');
    return value.toString();
  }
}

bool canManageEmployeeDetails(String? actorRole, String targetRole) =>
    actorRole == 'organization_owner' ||
    actorRole == 'organization_admin' ||
    (actorRole == 'venue_manager' &&
        (targetRole == 'supervisor' || targetRole == 'staff'));

String? hrFieldProblem(String key, String text) {
  final value = text.trim();
  if (value.isEmpty) return null;
  if (key == 'date_of_birth' || key == 'hire_date') {
    final date = DateTime.tryParse(value);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
        date == null ||
        date.toIso8601String().substring(0, 10) != value) {
      return 'Use YYYY-MM-DD';
    }
    if (key == 'date_of_birth' && date.isAfter(DateTime.now())) {
      return 'Enter a past date';
    }
  }
  if (key == 'contact_email' &&
      !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value)) {
    return 'Enter a valid email';
  }
  if (key == 'hourly_rate_cents') {
    final rate = double.tryParse(value);
    if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(value) ||
        rate == null ||
        rate > 10000) {
      return 'Enter an amount from 0 to 10000';
    }
  }
  if (key == 'pto_hours' || key == 'sick_hours') {
    final hours = double.tryParse(value);
    if (hours == null || !hours.isFinite || hours < 0 || hours > 10000) {
      return 'Enter hours from 0 to 10000';
    }
  }
  if (key == 'certifications') {
    final parts =
        value.split(',').map((v) => v.trim()).where((v) => v.isNotEmpty);
    if (parts.length > 50 || parts.any((v) => v.length > 100)) {
      return 'Use up to 50 certifications, each under 100 characters';
    }
  }
  final max = key == 'address'
      ? 500
      : key == 'contact_email'
          ? 255
          : key.contains('phone')
              ? 50
              : key == 'employee_number'
                  ? 64
                  : key == 'emergency_contact_relationship'
                      ? 80
                      : key == 'job_title' || key == 'department'
                          ? 100
                          : 120;
  if (key != 'certifications' && value.length > max) {
    return 'Use at most $max characters';
  }
  return null;
}

Map<String, dynamic> hrUpdatePayload(
  Map<String, String> input, {
  required bool manageEmployment,
}) {
  final result = <String, dynamic>{};
  for (final key in [
    ...personalHrFields.keys,
    if (manageEmployment) ...employmentHrFields.keys,
  ]) {
    if (!input.containsKey(key)) continue;
    final text = input[key]!.trim();
    final problem = hrFieldProblem(key, text);
    if (problem != null) throw FormatException('$key: $problem');
    result[key] = switch (key) {
      'hourly_rate_cents' =>
        text.isEmpty ? null : (double.parse(text) * 100).round(),
      'pto_hours' || 'sick_hours' => text.isEmpty ? 0 : double.parse(text),
      'certifications' => text
          .split(',')
          .map((v) => v.trim())
          .where((v) => v.isNotEmpty)
          .toSet()
          .toList(),
      _ => text.isEmpty ? null : text,
    };
  }
  return result;
}

class StaffPhoto {
  const StaffPhoto({required this.url, required this.revision});
  final String url;
  final String revision;
}

typedef StaffProfileKey = ({String venueId, String userId});
