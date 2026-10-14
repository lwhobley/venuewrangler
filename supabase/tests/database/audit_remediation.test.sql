begin;
select no_plan();

insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-00000000af01', 'audit-a@example.test'),
 ('00000000-0000-0000-0000-00000000af02', 'audit-b@example.test');
insert into public.organizations (id, name) values
 ('10000000-0000-0000-0000-00000000af01', 'Audit org');
insert into public.venues (id, organization_id, name) values
 ('20000000-0000-0000-0000-00000000af01', '10000000-0000-0000-0000-00000000af01', 'Audit venue');
insert into public.memberships (user_id, organization_id, venue_id, role) values
 ('00000000-0000-0000-0000-00000000af01', '10000000-0000-0000-0000-00000000af01', '20000000-0000-0000-0000-00000000af01', 'venue_manager'),
 ('00000000-0000-0000-0000-00000000af02', '10000000-0000-0000-0000-00000000af01', '20000000-0000-0000-0000-00000000af01', 'staff');

create temporary table audit_expired_key as
 select * from public.claim_subscription_checkout_attempt('10000000-0000-0000-0000-00000000af01');
select public.record_subscription_checkout_session('10000000-0000-0000-0000-00000000af01',
 (select idempotency_key from audit_expired_key), 'cs_expired_audit', now() - interval '1 minute');
create temporary table audit_replacement as
 select * from public.claim_subscription_checkout_attempt('10000000-0000-0000-0000-00000000af01', true,
 (select idempotency_key from audit_expired_key));
select public.record_subscription_checkout_session('10000000-0000-0000-0000-00000000af01',
 (select idempotency_key from audit_replacement), 'cs_replacement_audit', now() + interval '1 day');
-- An arbitrarily delayed stale caller must reuse the replacement, even after ten seconds.
update public.subscription_checkout_attempts set updated_at = now() - interval '1 hour';
select is((select idempotency_key from public.claim_subscription_checkout_attempt(
 '10000000-0000-0000-0000-00000000af01', true, (select idempotency_key from audit_expired_key))),
 (select idempotency_key from audit_replacement), 'stale checkout claim cannot rotate a replacement');
select ok(not has_function_privilege('authenticated',
 'public.claim_subscription_checkout_attempt(uuid,boolean,uuid)', 'execute'), 'checkout claims remain service-only');

insert into public.pos_checks (organization_id, venue_id, provider, external_check_id,
 opened_at, closed_at, status, total_cents) values
 ('10000000-0000-0000-0000-00000000af01', '20000000-0000-0000-0000-00000000af01',
 'toast', 'audit-check', now() - interval '1 hour', now(), 'closed', 5000);
update public.pos_checks set status = 'open', closed_at = null, total_cents = 1000
 where external_check_id = 'audit-check';
select is((select status from public.pos_checks where external_check_id = 'audit-check'), 'closed', 'closed check cannot reopen');
select is((select total_cents from public.pos_checks where external_check_id = 'audit-check'), 5000, 'closed revenue cannot be rolled back');
update public.pos_checks set status = 'voided' where external_check_id = 'audit-check';
select is((select status from public.pos_checks where external_check_id = 'audit-check'), 'voided', 'closed check can be voided');
update public.pos_checks set status = 'closed' where external_check_id = 'audit-check';
select is((select status from public.pos_checks where external_check_id = 'audit-check'), 'voided', 'voided check cannot reopen');

set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-00000000af01';
select public.register_push_token_for_device('20000000-0000-0000-0000-00000000af01',
 'audit-device-token-123', 'ios', repeat('a',64));
set local "request.jwt.claim.sub" = '00000000-0000-0000-0000-00000000af02';
select is(public.revoke_device_push_token('audit-device-token-123', repeat('b',64)), false,
 'another account cannot revoke a guessed device token');
select throws_ok($$ select public.register_push_token_for_device('20000000-0000-0000-0000-00000000af01',
 'audit-device-token-123', 'ios', repeat('b',64)) $$, '42501', null, 'wrong installation secret cannot take over a token');
select is(public.revoke_device_push_token('audit-device-token-123', repeat('a',64)), true,
 'device possession permits deferred revocation after account switch');
select lives_ok($$ select public.register_push_token_for_device('20000000-0000-0000-0000-00000000af01',
 'audit-device-token-123', 'ios', repeat('a',64)) $$, 'same installation can register the new account');
select is((select user_id from public.push_tokens where token = 'audit-device-token-123'),
 '00000000-0000-0000-0000-00000000af02'::uuid, 'token now belongs to the current account');
insert into public.push_tokens (organization_id, venue_id, user_id, token, platform, enabled)
 values ('10000000-0000-0000-0000-00000000af01', '20000000-0000-0000-0000-00000000af01',
 '00000000-0000-0000-0000-00000000af01', 'audit-disabled-legacy-token', 'ios', false);
select is(public.revoke_device_push_token('audit-disabled-legacy-token', repeat('c',64)), true,
 'already-disabled legacy registrations do not trap the retry marker');

select ok(app_hidden.valid_studio_tables('[{"x":10,"y":10}]'), 'valid saved tables accepted');
select ok(not app_hidden.valid_studio_tables('[{}]'), 'missing table coordinates rejected');
select ok(not app_hidden.valid_studio_tables('{}'), 'non-array layouts rejected');
select ok(not app_hidden.valid_studio_tables('[{"x":"Infinity","y":10}]'), 'nonnumeric coordinates rejected');
select * from finish();
rollback;
