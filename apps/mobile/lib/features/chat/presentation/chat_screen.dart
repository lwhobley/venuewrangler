import 'dart:async';
import '../../../core/auth/auth_providers.dart';
import '../../venues/application/venue_clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
                    style: const TextStyle(fontWeight: FontWeight.bold),
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

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            ref.read(activeConversationIdProvider.notifier).state = null;
          },
        ),
        title: const Text('Conversation'),
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
                    return _MessageBubble(message: msg);
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

class _MessageBubble extends ConsumerWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = message.senderId == ref.watch(currentUserIdProvider);
    final contacts =
        ref.watch(chatContactsProvider).valueOrNull ?? const <ChatContact>[];
    final names = {for (final c in contacts) c.userId: c.label};
    final clock = ref.watch(venueClockProvider);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              mine ? 'You' : names[message.senderId] ?? 'Former team member',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              clock.formatDateTime(message.createdAt),
              style: Theme.of(context).textTheme.labelSmall,
            ),
            if (message.text != null && message.text!.isNotEmpty)
              Text(
                message.text!,
                style: const TextStyle(fontSize: 15),
              ),
            if (message.hasAttachment)
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.image, size: 16, color: context.ops.info.fg),
                    const SizedBox(width: 4),
                    Text(
                      'Photo Attachment',
                      style:
                          TextStyle(fontSize: 12, color: context.ops.info.fg),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
