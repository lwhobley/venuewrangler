-- Phase 3 feature: device attestation, in observe mode per the migration plan's hard
-- requirement ("begin in observe", see supabase/.env.example's DEVICE_ATTESTATION_MODE) —
-- this table only ever records a verdict, it never gates anything. There is no separate
-- challenge table: the `device-attestation` Edge Function's own nonce freshness is enough for
-- a telemetry-only feature that is not yet used for any access decision; a real anti-replay
-- challenge/response table is a reasonable addition when this moves toward `enforce`.
create table public.device_attestations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  platform text not null check (platform in ('ios', 'android')),
  device_id text not null,
  -- 'observed' = recorded but not cryptographically verified (today's iOS App Attest path —
  -- see the Edge Function's header comment for why); 'valid'/'invalid' = an Android Play
  -- Integrity verdict was actually checked against Google.
  status text not null check (status in ('observed', 'valid', 'invalid')),
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index device_attestations_user_id_idx on public.device_attestations (user_id);
create index device_attestations_created_at_idx on public.device_attestations (created_at);

alter table public.device_attestations enable row level security;
alter table public.device_attestations force row level security;

-- A user can see their own device-trust history (useful for a future "trusted devices"
-- settings screen); no insert/update/delete policy exists for `authenticated` — every row is
-- written by the `device-attestation` Edge Function using the service role, so a client can
-- never forge its own attestation result.
create policy device_attestations_select_self on public.device_attestations
  for select to authenticated
  using (user_id = auth.uid());
