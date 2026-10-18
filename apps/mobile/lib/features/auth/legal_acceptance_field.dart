import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../settings/domain/legal_links.dart';

/// "I agree to the Terms and Privacy Policy" checkbox for sign-up. Validates false until
/// ticked, so the surrounding [Form] blocks submission without an explicit acceptance.
class LegalAcceptanceField extends StatefulWidget {
  const LegalAcceptanceField({super.key});

  @override
  State<LegalAcceptanceField> createState() => _LegalAcceptanceFieldState();
}

class _LegalAcceptanceFieldState extends State<LegalAcceptanceField> {
  late final TapGestureRecognizer _terms = TapGestureRecognizer()
    ..onTap = () => openLegalLink(context, termsUri);
  late final TapGestureRecognizer _privacy = TapGestureRecognizer()
    ..onTap = () => openLegalLink(context, privacyPolicyUri);

  @override
  void dispose() {
    _terms.dispose();
    _privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = TextStyle(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    return FormField<bool>(
      initialValue: false,
      validator: (accepted) =>
          accepted == true ? null : 'Accept the terms and privacy policy',
      builder: (field) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: field.value ?? false,
                onChanged: (value) => field.didChange(value ?? false),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text.rich(
                    TextSpan(
                      style: theme.textTheme.bodySmall,
                      children: [
                        const TextSpan(text: 'I agree to the '),
                        TextSpan(
                          text: 'Terms of Service',
                          style: link,
                          recognizer: _terms,
                        ),
                        const TextSpan(text: ' and the '),
                        TextSpan(
                          text: 'Privacy Policy',
                          style: link,
                          recognizer: _privacy,
                        ),
                        const TextSpan(text: '.'),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (field.hasError)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                field.errorText!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

/// Plain-language notice that clock punches record where the device is.
class LocationPunchNotice extends StatelessWidget {
  const LocationPunchNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.location_on_outlined,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Clock punches store the device location at the moment of the '
            'punch, so a venue can confirm staff are on site.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
