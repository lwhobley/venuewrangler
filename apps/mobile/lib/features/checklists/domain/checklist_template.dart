/// See the note in features/organizations/domain/organization.dart about why this is a
/// hand-written model rather than `freezed` for now.
class ChecklistTemplate {
  const ChecklistTemplate({required this.id, required this.venueId, required this.title});

  final String id;
  final String venueId;
  final String title;

  factory ChecklistTemplate.fromJson(Map<String, dynamic> json) => ChecklistTemplate(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        title: json['title'] as String,
      );

  @override
  bool operator ==(Object other) => other is ChecklistTemplate && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class ChecklistTemplateItem {
  const ChecklistTemplateItem({
    required this.id,
    required this.templateId,
    required this.label,
    required this.position,
  });

  final String id;
  final String templateId;
  final String label;
  final int position;

  factory ChecklistTemplateItem.fromJson(Map<String, dynamic> json) => ChecklistTemplateItem(
        id: json['id'] as String,
        templateId: json['template_id'] as String,
        label: json['label'] as String,
        position: json['position'] as int,
      );

  @override
  bool operator ==(Object other) => other is ChecklistTemplateItem && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
