# core/security

Scaffolded in Phase 1; not implemented yet.

This folder will hold the client side of device attestation (iOS App Attest / Android Play
Integrity evidence collection) per `docs/migration/flutter-supabase-rebuild-plan.md` §3/§4/§5,
once the `verify-device-attestation` Edge Function exists in Phase 3. It begins in `observe`
mode and is enforced first for payroll connection/export, role changes, billing changes,
sensitive document downloads, and account-security actions — never added broadly.

Android/Play Integrity has no prior implementation anywhere in this codebase to port; it is
net-new work (see Phase 0 finding, migration plan §5.2).
