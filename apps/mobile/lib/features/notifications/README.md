# Notifications Feature

This feature ports the legacy NestJS `notifications` and `push` modules to Supabase and native Flutter.

## Architecture

1. **Direct FCM + APNs**:
   - Instead of the legacy Expo-push-service proprietary protocol (which required an Expo-managed app), push notifications are dispatched directly via Firebase Cloud Messaging (FCM HTTP v1) and Apple Push Notification service (APNs).
   - The Flutter mobile client registers its native device token with the server via the `public.register_push_token` RPC function.

2. **Concurrency Safety & Advisory Locks**:
   - `public.register_push_token` serializes registration using `pg_advisory_xact_lock(hashtext('push-token:' || venue_id || ':' || token))`.
   - Prevents race conditions and stops an active token from being hijacked by a different profile within the same venue.

3. **In-App Notification Feed**:
   - In-app notification events are stored in `public.notification_events`.
   - Written first and independent of push delivery status, matching the legacy contract where push failure is swallowed and logged, never bubbling up to interrupt business transactions.
   - Enforced by RLS: users can only see notifications targeted to them or broadcast to their venue role (`venue_staff`, `venue_managers`, `organization_owners`).

4. **Dead-Token Handling**:
   - When FCM reports `UNREGISTERED` or APNs returns `410 BadDeviceToken`, `app_hidden.disable_push_tokens` automatically disables the dead token (`enabled = false`, `disabled_at = now()`), stopping wasteful delivery retries.

## Gaps & Unverified Controls

- **Live FCM Service Account**: `FIREBASE_SERVICE_ACCOUNT` is loaded from Edge Function environment secrets. In local/mock testing without live Firebase credentials, in-app notifications are stored and logged, but remote device pushes are not dispatched.
