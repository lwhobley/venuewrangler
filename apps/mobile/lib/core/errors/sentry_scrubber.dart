import 'package:sentry_flutter/sentry_flutter.dart';

/// Redaction applied to everything that leaves the device through Sentry. The patterns target
/// what actually shows up in this app's errors: PostgREST/Postgres messages that echo row values
/// (`Key (email)=(a@b.com) already exists`, `Failing row contains (...)`), Supabase JWTs in
/// URLs or exception text, and email addresses typed into forms. Extend this, never remove from
/// it, as new sensitive shapes are found.
final RegExp _jwt = RegExp(r'eyJ[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]*){0,2}');
final RegExp _bearer =
    RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false);
final RegExp _email =
    RegExp(r'[A-Za-z0-9._%+-]+(?:@|%40)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+');
// Greedy to the last ")" on the line: a value may itself contain parentheses, and over-redacting
// the tail of a constraint message costs nothing.
final RegExp _keyValue = RegExp(r'Key \(([^)]*)\)=\(.*\)');
final RegExp _failingRow = RegExp(r'Failing row contains \(.*\)');

const String _redactedJwt = '[jwt]';
const String _redactedEmail = '[email]';

/// Returns [text] with tokens, emails and echoed database values replaced by placeholders.
String scrubSensitiveText(String text) {
  return text
      .replaceAllMapped(
        _keyValue,
        (m) => 'Key (${m.group(1)})=([redacted])',
      )
      .replaceAll(_failingRow, 'Failing row contains ([redacted])')
      .replaceAll(_jwt, _redactedJwt)
      .replaceAll(_bearer, 'Bearer [token]')
      .replaceAll(_email, _redactedEmail);
}

dynamic _scrubValue(dynamic value) {
  if (value is String) return scrubSensitiveText(value);
  if (value is Map) {
    return {
      for (final entry in value.entries) entry.key: _scrubValue(entry.value),
    };
  }
  if (value is List) return [for (final item in value) _scrubValue(item)];
  return value;
}

Map<String, dynamic>? _scrubMap(Map<String, dynamic>? map) {
  if (map == null) return null;
  return {
    for (final entry in map.entries) entry.key: _scrubValue(entry.value),
  };
}

/// `SentryOptions.beforeBreadcrumb`: breadcrumbs are built from log/HTTP activity, which can
/// carry the same values as an exception message.
Breadcrumb? scrubBreadcrumb(Breadcrumb? breadcrumb, Hint hint) {
  if (breadcrumb == null) return null;
  final message = breadcrumb.message;
  if (message != null) breadcrumb.message = scrubSensitiveText(message);
  breadcrumb.data = _scrubMap(breadcrumb.data);
  return breadcrumb;
}

/// `SentryOptions.beforeSend`: strips auth headers and credential query params from the request,
/// then redacts the event's message, exception values, breadcrumbs, `extra` and tags.
SentryEvent? scrubSentryEvent(SentryEvent event, Hint hint) {
  final message = event.message;
  if (message != null) {
    message.formatted = scrubSensitiveText(message.formatted);
    final template = message.template;
    if (template != null) message.template = scrubSensitiveText(template);
    final params = message.params;
    if (params != null) {
      message.params = [for (final p in params) _scrubValue(p)];
    }
  }
  for (final exception in event.exceptions ?? const <SentryException>[]) {
    final value = exception.value;
    if (value != null) exception.value = scrubSensitiveText(value);
  }
  for (final breadcrumb in event.breadcrumbs ?? const <Breadcrumb>[]) {
    scrubBreadcrumb(breadcrumb, hint);
  }
  // `extra` is deprecated for new data, but anything already attached to it still ships.
  // ignore: deprecated_member_use
  event.extra = _scrubMap(event.extra);
  final tags = event.tags;
  if (tags != null) {
    event.tags = {
      for (final entry in tags.entries)
        entry.key: scrubSensitiveText(entry.value),
    };
  }

  final request = event.request;
  if (request == null) return event;

  // Header names are case-insensitive — an exact-case remove('Authorization') would let a
  // lowercase `authorization` header through.
  const sensitiveHeaders = {'authorization', 'apikey', 'cookie'};
  final scrubbedHeaders = Map<String, String>.from(request.headers)
    ..removeWhere((key, _) => sensitiveHeaders.contains(key.toLowerCase()));

  request
    ..headers = scrubbedHeaders
    ..url = _scrubUrl(request.url);
  return event;
}

String? _scrubUrl(String? url) {
  if (url == null) return null;
  final uri = Uri.tryParse(url);
  if (uri == null) return scrubSensitiveText(url);

  const sensitiveParams = {'token', 'access_token', 'refresh_token', 'apikey'};
  var result = url;
  if (uri.queryParameters.keys
      .toSet()
      .intersection(sensitiveParams)
      .isNotEmpty) {
    final cleaned = Map<String, String>.from(uri.queryParameters)
      ..removeWhere((key, _) => sensitiveParams.contains(key));
    result = uri.replace(queryParameters: cleaned).toString();
  }
  return scrubSensitiveText(result);
}
