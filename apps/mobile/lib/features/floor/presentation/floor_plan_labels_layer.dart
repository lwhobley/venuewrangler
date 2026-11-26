import 'package:flutter/material.dart';

import '../domain/floor_plan.dart';

/// Draws a floor plan's labelled areas (stage, bars, ...) as outlined, captioned regions.
/// Purely visual: it ignores pointer input so taps and drags reach the tables above it.
class FloorPlanLabelsLayer extends StatelessWidget {
  const FloorPlanLabelsLayer({super.key, required this.labels});

  final List<FloorPlanLabel> labels;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final label in labels)
            Positioned(
              left: label.x,
              top: label.y,
              width: label.width,
              height: label.height,
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: scheme.outline.withValues(alpha: 0.6),
                    width: 1.5,
                  ),
                ),
                alignment: Alignment.center,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(
                      label.text,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
