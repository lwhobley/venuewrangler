import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// AppBar leading action that returns to the dashboard. Screens are reached with `context.go`,
/// so there's no back stack to pop — this is the way home.
class HomeButton extends StatelessWidget {
  const HomeButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.home_outlined),
      tooltip: 'Home',
      onPressed: () => context.go('/'),
    );
  }
}
