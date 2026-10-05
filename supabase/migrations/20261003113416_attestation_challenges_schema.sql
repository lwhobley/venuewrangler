-- Server-stored, single-use App Attest challenges. Closes the replay-window gap documented in
-- device-attestation/index.ts and supabase/functions/_shared/crypto.ts: the signed challenge
-- token alone proves it was issued by us and hasn't been tampered with, but nothing previously
-- stopped a captured, still-fresh challenge+attestation pair from being replayed within its
-- 5-minute TTL. This table lets the server mark a challenge consumed exactly once, atomically,
-- on first successful verification attempt.
--
-- No client-facing policy: only the service-role key (used by the device-attestation Edge
-- Function) ever reads or writes this table, same pattern as platform_admins.
create table public.attestation_challenges (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null,
  -- sha256 of the challenge's random nonce, not the nonce itself — the nonce only needs to be
  -- looked up by exact match, and storing the hash means a leaked row (e.g. via a backup) can't
  -- be used to forge a still-valid attestation on its own.
  nonce_hash text not null,
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  constraint attestation_challenges_nonce_hash_unique unique (nonce_hash)
);

alter table public.attestation_challenges enable row level security;

create index attestation_challenges_expires_at_idx on public.attestation_challenges (expires_at);

comment on table public.attestation_challenges is
  'Single-use App Attest challenge tracking (service-role only; see device-attestation Edge Function). No client-facing RLS policy by design.';
