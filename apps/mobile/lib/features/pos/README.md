# POS integrations

The management screen reads venue-scoped connection readiness, capability evidence, recent outbound jobs, and ingested checks from Supabase. Managers can request provider setup without entering credentials. The repository calls `publish_pos_schedule` to atomically snapshot the existing venue schedule into a versioned outbox after server-side manager, mapping, and capability checks. The mobile app never contacts a POS provider.

See `docs/pos-integration-platform.md` for the repository audit, official provider documentation, capability matrix, and rollout gates.

**Operational status:** the schedule outbox has no deployed worker or provider adapter. Existing `toast-pos` only queues legacy menu commands and accepts a custom gateway webhook; it is not a native Toast webhook or verified delivery path. The mobile 86 action is withheld. No outbound schedule operation is claimed synced until a worker records provider acknowledgment.
