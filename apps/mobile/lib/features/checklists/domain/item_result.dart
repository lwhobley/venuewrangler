/// One item's checked state within a single checklist completion submission. Serialized into
/// `checklist_completions.item_results` (a jsonb array) — see the schema migration's comment
/// on why this is a blob rather than a normalized child table for this first slice.
class ItemResult {
  const ItemResult({required this.itemId, required this.checked});

  final String itemId;
  final bool checked;

  Map<String, dynamic> toJson() => {'item_id': itemId, 'checked': checked};

  factory ItemResult.fromJson(Map<String, dynamic> json) => ItemResult(
        itemId: json['item_id'] as String,
        checked: json['checked'] as bool,
      );
}
