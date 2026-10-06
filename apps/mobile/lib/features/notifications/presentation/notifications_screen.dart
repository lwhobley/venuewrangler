import '../../../core/widgets/home_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/widgets/state_views.dart';

import '../../venues/application/venues_providers.dart';
import '../application/notification_routing.dart';
import '../application/notifications_providers.dart';
import '../domain/notification_event.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notificationsAsync = ref.watch(notificationsFeedProvider);
    final currentVenue = ref.watch(activeVenueProvider);

    return Scaffold(
      appBar: AppBar(
        leading: const HomeButton(),
        title: const Text('Notifications'),
        actions: [
          if (currentVenue != null)
            IconButton(
              icon: const Icon(Icons.done_all),
              tooltip: 'Mark all as read',
              onPressed: () async {
                await ref
                    .read(notificationsRepositoryProvider)
                    .markAllAsRead(venueId: currentVenue.id);
                ref.invalidate(notificationsFeedProvider);
              },
            ),
        ],
      ),
      body: notificationsAsync.when(
        data: (notifications) {
          if (notifications.isEmpty) {
            return const EmptyState(
              icon: Icons.notifications_none,
              message: 'No notifications yet',
            );
          }

          return RefreshIndicator(
            onRefresh: () async =>
                ref.refresh(notificationsFeedProvider.future),
            child: ListView.separated(
              itemCount: notifications.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = notifications[index];
                return _NotificationListTile(item: item);
              },
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => ErrorState(
          message: 'Failed to load notifications: $err',
          onRetry: () => ref.invalidate(notificationsFeedProvider),
        ),
      ),
    );
  }
}

class _NotificationListTile extends ConsumerWidget {
  const _NotificationListTile({required this.item});

  final NotificationEvent item;

  IconData _iconForKind(String kind) {
    switch (kind) {
      case 'shift_assigned':
      case 'shift_swap':
        return Icons.calendar_today;
      case 'late_clock_in':
        return Icons.timer_off;
      case 'staff_request':
        return Icons.assignment;
      case 'announcement':
        return Icons.campaign;
      default:
        return Icons.notifications;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: item.isRead
            ? Theme.of(context).colorScheme.surfaceContainerHighest
            : Theme.of(context).colorScheme.primaryContainer,
        child: Icon(
          _iconForKind(item.kind),
          color: item.isRead
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : Theme.of(context).colorScheme.primary,
        ),
      ),
      title: Text(
        item.title,
        style: TextStyle(
          fontWeight: item.isRead ? FontWeight.normal : FontWeight.bold,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(item.body),
          const SizedBox(height: 4),
          Text(
            _formatDate(item.createdAt),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
      trailing: item.isRead
          ? null
          : Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
      onTap: () async {
        if (!item.isRead) {
          await ref
              .read(notificationsRepositoryProvider)
              .markAsRead(notificationId: item.id);
          ref.invalidate(notificationsFeedProvider);
        }
        final route = routeForNotificationKind(item.kind);
        // maybeOf, not of: a plain MaterialApp test host (no GoRouter ancestor) should still
        // mark the notification read without crashing on navigation it can't perform.
        if (route != null && context.mounted) {
          GoRouter.maybeOf(context)?.go(route);
        }
      },
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else {
      return '${dt.month}/${dt.day}/${dt.year}';
    }
  }
}
