import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

/// The five top-level destinations, always one tap away. Each tab keeps its own navigation
/// stack (StatefulShellRoute.indexedStack), so switching tabs and coming back returns you to
/// where you were.
class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.navigationShell,
    this.destinations = fullDestinations,
  });

  final StatefulNavigationShell navigationShell;

  /// Must match the shell's branches one-to-one, in order.
  final List<NavigationDestination> destinations;

  /// Supervisors and managers.
  static const fullDestinations = [
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

  /// Team members (staff): only their own day, the clock, the schedule, the floor and chat.
  static const employeeDestinations = [
    NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: 'Home',
    ),
    NavigationDestination(
      icon: Icon(Icons.timer_outlined),
      selectedIcon: Icon(Icons.timer),
      label: 'Clock',
    ),
    NavigationDestination(
      icon: Icon(Icons.calendar_month_outlined),
      selectedIcon: Icon(Icons.calendar_month),
      label: 'Schedule',
    ),
    NavigationDestination(
      icon: Icon(Icons.table_restaurant_outlined),
      selectedIcon: Icon(Icons.table_restaurant),
      label: 'Floor',
    ),
    NavigationDestination(
      icon: Icon(Icons.chat_bubble_outline),
      selectedIcon: Icon(Icons.chat_bubble),
      label: 'Chat',
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
