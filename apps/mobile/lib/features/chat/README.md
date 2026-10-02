# Team Chat Feature

Port of legacy NestJS `chat` module to native Supabase + Flutter with direct integration into the `media-cleanup` queue.

## Architecture

- **Database**:
  - `public.conversations`: venue-scoped conversations (`dm`, `group`, `all_staff`), names, and last message summary/timestamp.
  - `public.conversation_members`: members of each conversation.
  - `public.messages`: text and photo attachment paths, emoji reactions.
  - `public.conversation_reads`: per-user read receipt tracking.
- **Media Cleanup Integration**:
  - Chat attachments reside in the private Supabase Storage bucket `chat` with path convention `{organization_id}/{venue_id}/{filename}`.
  - When a message with an `attachment_path` is deleted, trigger `app_hidden.enqueue_chat_attachment_deletion` inserts an entry into `public.storage_deletion_jobs` for the `media-cleanup` worker to durably delete the file from Storage.
- **Security & RLS**:
  - `FORCE ROW LEVEL SECURITY` on all tables.
  - `app_hidden.is_conversation_member`: security definer helper that avoids recursive RLS evaluation when checking if a user belongs to a conversation.
  - Only members of a conversation (or venue members for `all_staff` channels) can view and post messages.
  - Private DM confidentiality: non-members cannot read DMs between other users.
- **Flutter UI**:
  - `ChatScreen`: displays conversation list (All Staff announcements and direct messages) with unread and last message previews, tap to open thread, message bubbles, and text input for instant messaging.
