/// Mirrors legacy's DOCUMENT_CATEGORIES exactly — 'form' and 'other' are manager-only on the
/// server (supabase/migrations/20261003003000), everything else is staff-readable.
class VenueDocument {
  const VenueDocument({
    required this.id,
    required this.title,
    required this.fileName,
    required this.category,
    required this.mimeType,
    required this.sizeBytes,
    required this.storagePath,
    required this.createdAt,
  });

  factory VenueDocument.fromJson(Map<String, dynamic> json) {
    return VenueDocument(
      id: json['id'] as String,
      title: json['title'] as String,
      fileName: json['file_name'] as String,
      category: json['category'] as String,
      mimeType: json['mime_type'] as String,
      sizeBytes: json['size_bytes'] as int,
      storagePath: json['storage_path'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  final String id;
  final String title;
  final String fileName;
  final String category;
  final String mimeType;
  final int sizeBytes;
  final String storagePath;
  final DateTime createdAt;

  static const categories = [
    'sop',
    'manual',
    'recipe',
    'menu',
    'training',
    'form',
    'other',
  ];
  static const managerOnlyCategories = {'form', 'other'};

  bool get isManagerOnly => managerOnlyCategories.contains(category);

  bool get isInlineViewable =>
      mimeType == 'application/pdf' ||
      (mimeType.startsWith('image/') && mimeType != 'image/svg+xml');

  String get readableSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
