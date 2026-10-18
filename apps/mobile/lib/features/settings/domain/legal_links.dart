import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Hosted legal documents (served by the marketing site, `site/privacy` and `site/terms`).
final privacyPolicyUri = Uri.parse('https://venuewrangler.com/privacy/');
final termsUri = Uri.parse('https://venuewrangler.com/terms/');

/// Opens [uri] in the browser; shows a snackbar if nothing can handle it.
Future<void> openLegalLink(BuildContext context, Uri uri) async {
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    opened = false;
  }
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not open $uri')),
    );
  }
}
