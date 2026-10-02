-- The ai-assistant Edge Function's per-user rate limit queries ai_usage_events by
-- (user_id, created_at) on every call; without this index that's a sequential scan once the
-- table has any meaningful volume.
create index ai_usage_events_user_id_created_at_idx on public.ai_usage_events (user_id, created_at);
