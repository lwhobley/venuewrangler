import 'package:flutter/material.dart';

import '../theme/ops_colors.dart';

/// A purposeful operational panel: thin border, compact header, optional trailing action.
/// Use instead of oversized empty cards.
class OpsPanel extends StatelessWidget {
  const OpsPanel({
    super.key,
    required this.child,
    this.title,
    this.trailing,
    this.padding = const EdgeInsets.all(14),
  });

  final Widget child;
  final String? title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.ops.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title!.toUpperCase(),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(letterSpacing: 0.8),
                    ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
            ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}
