/// Plain, hand-written immutable model rather than `freezed` for this first Phase 2 slice:
/// `freezed`/`json_serializable` need `build_runner` codegen (`*.freezed.dart`/`*.g.dart`),
/// which was not available in the sandbox this was authored in (see apps/mobile/README.md).
/// Migrate this to `freezed` once that tooling is actually run, per the architecture
/// requirements — do not hand-maintain this pattern indefinitely as the model surface grows.
class Organization {
  const Organization({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  final String id;
  final String name;
  final DateTime createdAt;

  factory Organization.fromJson(Map<String, dynamic> json) => Organization(
        id: json['id'] as String,
        name: json['name'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  @override
  bool operator ==(Object other) => other is Organization && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
