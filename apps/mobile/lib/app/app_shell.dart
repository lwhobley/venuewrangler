import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

/// The five top-level destinations, always one tap away. Each tab keeps its own navigation
/// stack (StatefulShellRoute.indexedStack), so switching tabs and coming back returns you to
/// where you were.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const destinations = [
    NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: 'Home',
    ),
    NavigationDestination(
      icon: Icon(Icons.table_restaurant_outlined),
      selectedIcon: Icon(Icons.table_restaurant),
      label: 'Floor',
    ),
    NavigationDestination(
      icon: Icon(Icons.calendar_month_outlined),
      selectedIcon: Icon(Icons.calendar_month),
      label: 'Schedule',
    ),
    NavigationDestination(
      icon: Icon(Icons.view_kanban_outlined),
      selectedIcon: Icon(Icons.view_kanban),
      label: 'Tasks',
    ),
    NavigationDestination(
      icon: Icon(Icons.apps_outlined),
      selectedIcon: Icon(Icons.apps),
      label: 'More',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        destinations: destinations,
        onDestinationSelected: (index) {
          HapticFeedback.selectionClick();
          // Re-tapping the current tab pops it back to its first screen.
          navigationShell.goBranch(
            index,
            initialLocation: index == navigationShell.currentIndex,
          );
        },
      ),
    );
  }
}
