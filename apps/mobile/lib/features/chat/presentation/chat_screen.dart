import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/auth/auth_providers.dart';
import '../../../core/theme/app_radii.dart';
import '../application/chat_providers.dart';
import '../domain/chat_contact.dart';
import '../domain/chat_message.dart';
import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/state_views.dart';
import '../../venues/application/venues_providers.dart';

class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeConvId = ref.watch(activeConversationIdProvider);

    if (activeConvId != null) {
      return _ChatThreadView(conversationId: activeConvId);
    }

    return const _ConversationListView();
  }
}

class _ConversationListView extends ConsumerWidget {
  const _ConversationListView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversationsAsync = ref.watch(conversationsListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Team Chat'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(conversationsListProvider),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _startDirectMessage(context, ref),
        icon: const Icon(Icons.edit_outlined),
        label: const Text('New message'),
      ),
      body: conversationsAsync.when(
        data: (conversations) {
          if (conversations.isEmpty) {
            return const EmptyState(
              icon: Icons.chat_bubble_outline,
              message: 'No conversations yet. Tap New message to start one.',
            );
          }

          return RefreshIndicator(
            onRefresh: () async =>
                ref.refresh(conversationsListProvider.future),
            child: ListView.separated(
              itemCount: conversations.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final conv = conversations[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                        Theme.of(context).colorScheme.primaryContainer,
                    child: Icon(
                      conv.type == 'all_staff' ? Icons.groups : Icons.person,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                  title: Text(
                    conv.displayName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  subtitle: Text(
                    conv.lastMessageText ?? 'No messages yet',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    ref.read(activeConversationIdProvider.notifier).state =
                        conv.id;
                  },
                );
              },
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) =>
            ErrorState(message: 'Failed to load conversations: $err'),
      ),
    );
  }
}

Future<void> _startDirectMessage(BuildContext context, WidgetRef ref) async {
  final venue = ref.read(activeVenueProvider);
  if (venue == null) return;
  // Captured before any await: this widget may be gone by the time the sheet or the server
  // call returns, and the container outlives it.
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.of(context);
  final contact = await showModalBottomSheet<ChatContact>(
    context: context,
    showDragHandle: true,
    builder: (_) => const _ContactPicker(),
  );
  if (contact == null) return;
  try {
    final id = await container.read(chatRepositoryProvider).createOrGetDm(
          venueId: venue.id,
          targetUserId: contact.userId,
        );
    container.invalidate(conversationsListProvider);
    container.read(activeConversationIdProvider.notifier).state = id;
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text("Couldn't start the conversation. Please try again."),
      ),
    );
  }
}

class _ContactPicker extends ConsumerWidget {
  const _ContactPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contactsAsync = ref.watch(chatContactsProvider);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'New message',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Expanded(
              child: contactsAsync.when(
                data: (contacts) {
                  if (contacts.isEmpty) {
                    return const EmptyState(
                      icon: Icons.people_outline,
                      message: 'No one else is in this venue yet.',
                    );
                  }
                  return ListView.builder(
                    itemCount: contacts.length,
                    itemBuilder: (context, index) {
                      final contact = contacts[index];
                      return ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.person)),
                        title: Text(contact.label),
                        onTap: () => Navigator.of(context).pop(contact),
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, __) => ErrorState(
                  message: "Couldn't load your team.",
                  onRetry: () => ref.invalidate(chatContactsProvider),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatThreadView extends ConsumerStatefulWidget {
  const _ChatThreadView({required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<_ChatThreadView> createState() => _ChatThreadViewState();
}

class _ChatThreadViewState extends ConsumerState<_ChatThreadView> {
  final _textCtrl = TextEditingController();
  bool _sending = false;
  StreamSubscription<void>? _messageChanges;

  @override
  void initState() {
    super.initState();
    _messageChanges = ref
        .read(chatRepositoryProvider)
        .watchMessages(widget.conversationId)
        .listen((_) {
      ref.invalidate(conversationMessagesProvider(widget.conversationId));
      ref.invalidate(conversationsListProvider);
    });
  }

  @override
  void dispose() {
    _messageChanges?.cancel();
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messagesAsync =
        ref.watch(conversationMessagesProvider(widget.conversationId));
    final me = ref.watch(currentUserIdProvider);
    final conversation = ref
        .watch(conversationsListProvider)
        .valueOrNull
        ?.where((c) => c.id == widget.conversationId)
        .firstOrNull;
    // A DM has only one other person, so their name is already the title; group threads
    // (or one we can't identify yet) label each run of messages with its sender.
    final showSenderNames = conversation?.type != 'dm';
    // Null until the team has loaded (or if it can't be): senders then read "Team member".
    final senderNames = ref.watch(chatSenderNamesProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            ref.read(activeConversationIdProvider.notifier).state = null;
          },
        ),
        title: Text(conversation?.displayName ?? 'Conversation'),
      ),
      body: Column(
        children: [
          Expanded(
            child: messagesAsync.when(
              data: (messages) {
                if (messages.isEmpty) {
                  return const Center(child: Text('Say hello!'));
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final msg = messages[index];
                    final previous = index > 0 ? messages[index - 1] : null;
                    final newDay = previous == null ||
                        !_sameDay(previous.createdAt, msg.createdAt);
                    final isMine = me != null && msg.senderId == me;
                    final startsRun =
                        newDay || previous.senderId != msg.senderId;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (newDay) _DaySeparator(day: msg.createdAt),
                        _MessageBubble(
                          message: msg,
                          isMine: isMine,
                          senderName: !isMine && showSenderNames && startsRun
                              ? _senderLabel(msg.senderId, senderNames)
                              : null,
                        ),
                      ],
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) =>
                  Center(child: Text('Error loading messages: $err')),
            ),
          ),
          const Divider(height: 1),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      enabled: !_sending,
                      decoration: const InputDecoration(
                        hintText: 'Type a message...',
                        border: InputBorder.none,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    color: Theme.of(context).colorScheme.primary,
                    onPressed: _sending ? null : _sendMessage,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sendMessage() async {
    if (_sending) return;
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      await ref.read(chatRepositoryProvider).sendMessage(
            conversationId: widget.conversationId,
            text: text,
          );
      if (!mounted) return;
      _textCtrl.clear();
      ref.invalidate(conversationMessagesProvider(widget.conversationId));
      ref.invalidate(conversationsListProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message not sent. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }
}

bool _sameDay(DateTime a, DateTime b) {
  final x = a.toLocal();
  final y = b.toLocal();
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

String _senderLabel(String? senderId, Map<String, String>? names) {
  if (names == null || senderId == null) return 'Team member';
  // The team list covers current members only, so anyone missing from it has left the venue.
  return names[senderId] ?? 'Former team member';
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final localizations = MaterialLocalizations.of(context);
    final local = day.toLocal();
    final now = DateTime.now();
    final String label;
    if (_sameDay(local, now)) {
      label = 'Today';
    } else if (_sameDay(local, now.subtract(const Duration(days: 1)))) {
      label = 'Yesterday';
    } else if (local.year == now.year) {
      label = localizations.formatMediumDate(local);
    } else {
      label = localizations.formatFullDate(local);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

/// One message. The signed-in user's own messages sit on the right in the primary container
/// colour; everyone else's sit on the left, headed by the sender's name in group threads.
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.isMine,
    this.senderName,
  });

  final ChatMessage message;
  final bool isMine;
  final String? senderName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background =
        isMine ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final foreground = isMine ? scheme.onPrimaryContainer : scheme.onSurface;
    final time = MaterialLocalizations.of(context)
        .formatTimeOfDay(TimeOfDay.fromDateTime(message.createdAt.toLocal()));
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        child: Column(
          crossAxisAlignment:
              isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (senderName != null)
              Padding(
                padding: const EdgeInsets.only(left: 14, top: 8, bottom: 2),
                child: Text(
                  senderName!,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.primary,
                  ),
                ),
              ),
            Semantics(
              label: isMine ? 'You' : senderName,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 3),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(AppRadii.tile),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.text != null && message.text!.isNotEmpty)
                      Text(
                        message.text!,
                        style: theme.textTheme.bodyLarge
                            ?.copyWith(color: foreground),
                      ),
                    if (message.hasAttachment)
                      Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.image,
                              size: 16,
                              color: context.ops.info.fg,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Photo Attachment',
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: context.ops.info.fg),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 2),
                    Text(
                      time,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: foreground.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
