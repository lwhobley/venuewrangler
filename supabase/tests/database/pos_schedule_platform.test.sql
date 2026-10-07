begin;
select plan(34);

insert into auth.users(id,email) values
 ('00000000-0000-0000-0000-000000000011','pos-manager@example.com'),
 ('00000000-0000-0000-0000-000000000012','pos-staff@example.com'),
 ('00000000-0000-0000-0000-000000000013','other-manager@example.com');
insert into public.organizations(id,name) values
 ('10000000-0000-0000-0000-000000000011','POS tenant'),
 ('10000000-0000-0000-0000-000000000012','Other tenant');
insert into public.venues(id,organization_id,name) values
 ('20000000-0000-0000-0000-000000000011','10000000-0000-0000-0000-000000000011','POS venue'),
 ('20000000-0000-0000-0000-000000000012','10000000-0000-0000-0000-000000000012','Other venue');
insert into public.memberships(user_id,organization_id,venue_id,role) values
 ('00000000-0000-0000-0000-000000000011','10000000-0000-0000-0000-000000000011','20000000-0000-0000-0000-000000000011','venue_manager'),
 ('00000000-0000-0000-0000-000000000012','10000000-0000-0000-0000-000000000011','20000000-0000-0000-0000-000000000011','staff'),
 ('00000000-0000-0000-0000-000000000013','10000000-0000-0000-0000-000000000012','20000000-0000-0000-0000-000000000012','venue_manager');
insert into public.pos_connections(id,organization_id,venue_id,provider,status)
 values ('80000000-0000-0000-0000-000000000011',
 '10000000-0000-0000-0000-000000000011',
 '20000000-0000-0000-0000-000000000011','toast','active');
insert into public.pos_connection_capabilities(connection_id,capability,state)
 values ('80000000-0000-0000-0000-000000000011','scheduled_shifts_create','requires_approval');

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000011';
select results_eq(
 $$ select readiness from public.pos_connections where id = '80000000-0000-0000-0000-000000000011' $$,
 $$ values ('approval_required'::text) $$,
 'new active connection is not presented as connected');
select results_eq(
 $$ select count(*)::int from public.pos_connection_capabilities $$,
 $$ values (1) $$,
 'manager can read own capability state');
select throws_ok(
 $$ insert into public.pos_employee_mappings(connection_id,staff_id,external_employee_id)
 values ('80000000-0000-0000-0000-000000000011',
 '00000000-0000-0000-0000-000000000012','external-1') $$,
 '42501',null,'client cannot forge employee mappings');
select throws_ok(
 $$ select public.publish_pos_schedule('80000000-0000-0000-0000-000000000011') $$,
 'P0001',null,'unready connection cannot publish');

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000012';
select is_empty(
 $$ select capability from public.pos_connection_capabilities $$,
 'staff cannot read connection capability state');

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000013';
select throws_ok(
 $$ select public.publish_pos_schedule('80000000-0000-0000-0000-000000000011') $$,
 '42501',null,'other tenant manager cannot publish');

reset role;
update public.pos_connections set readiness = 'connected'
 where id = '80000000-0000-0000-0000-000000000011';
update public.pos_connection_capabilities set state = 'verified_supported',
 evidence_url = 'https://doc.toasttab.com/doc/cookbook/apiIntegrationChecklistShift.html',
 verified_at = current_date
 where connection_id = '80000000-0000-0000-0000-000000000011';
insert into public.pos_location_mappings(connection_id,venue_id,external_location_id)
 values ('80000000-0000-0000-0000-000000000011',
 '20000000-0000-0000-0000-000000000011','restaurant-1');
insert into public.pos_employee_mappings(connection_id,staff_id,external_employee_id)
 values ('80000000-0000-0000-0000-000000000011',
 '00000000-0000-0000-0000-000000000012','employee-1');
insert into public.pos_job_mappings(connection_id,role_label,external_job_id)
 values ('80000000-0000-0000-0000-000000000011','server','job-1');
insert into public.shifts(id,organization_id,venue_id,staff_id,role_label,start_time,end_time)
 values ('30000000-0000-0000-0000-000000000011',
 '10000000-0000-0000-0000-000000000011',
 '20000000-0000-0000-0000-000000000011',
 '00000000-0000-0000-0000-000000000012','server',
 now() + interval '1 day',now() + interval '1 day 8 hours');
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000011';
select results_eq(
 $$ select public.publish_pos_schedule('80000000-0000-0000-0000-000000000011') $$,
 $$ values (1::bigint) $$,
 'manager publication records version one');
select results_eq(
 $$ select operation,status from public.pos_outbound_jobs $$,
 $$ values ('create'::text,'pending'::text) $$,
 'publication atomically queues a create snapshot');
select throws_ok(
 $$ select public.publish_pos_schedule('80000000-0000-0000-0000-000000000011') $$,
 'P0001',null,'unresolved first publication blocks duplicate create');
select throws_ok(
 $$ delete from public.shifts where id = '30000000-0000-0000-0000-000000000011' $$,
 'P0001',null,'mapped shift cannot be hard deleted before cancellation');

select throws_ok(
 $$ select count(*) from public.claim_pos_outbound_jobs(1) $$,
 '42501',null,'authenticated manager cannot claim server-only jobs');
reset role;
set local role service_role;
select results_eq(
 $$ select count(*)::int from public.claim_pos_outbound_jobs(1) $$,
 $$ values (1) $$,
 'service worker claims one scheduled shift job');
reset role;
select results_eq(
 $$ select status,attempts from public.pos_outbound_jobs $$,
 $$ values ('processing'::text,1) $$,
 'claim increments attempts and leases the job');
update public.pos_outbound_jobs set lease_until = now() - interval '1 second';
set local role service_role;
select results_eq(
 $$ select count(*)::int from public.claim_pos_outbound_jobs(1) $$,
 $$ values (0) $$,
 'expired lease is held for reconciliation instead of blindly retried');

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000011';
select public.request_pos_connection(
 '20000000-0000-0000-0000-000000000011','square');
select results_eq(
 $$ select status,readiness from public.pos_connections
    where venue_id = '20000000-0000-0000-0000-000000000011' and provider = 'square' $$,
 $$ values ('inactive'::text,'approval_required'::text) $$,
 'setup request does not claim a live connection');
select results_eq(
 $$ select count(*)::int from public.pos_connection_capabilities pc
    join public.pos_connections c on c.id = pc.connection_id
    where c.provider = 'square' and pc.state = 'unverified' $$,
 $$ values (9) $$,
 'requested connection starts with nine unverified capabilities');
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000012';
select throws_ok(
 $$ select public.request_pos_connection('20000000-0000-0000-0000-000000000011','clover') $$,
 '42501',null,'staff cannot request POS connection');
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000013';
select throws_ok(
 $$ select public.request_pos_connection('20000000-0000-0000-0000-000000000011','clover') $$,
 '42501',null,'other tenant manager cannot request POS connection');

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000011';
select throws_ok(
 $$ select public.ack_pos_outbound_job(
      (select id from public.pos_outbound_jobs where version = 1),
      'external-shift-1','revision-1') $$,
 '42501',null,'manager cannot forge provider acknowledgment');
reset role;
set local role service_role;
select public.ack_pos_outbound_job(
 (select id from public.pos_outbound_jobs where version = 1),
 'external-shift-1','revision-1');
select results_eq(
 $$ select external_shift_id,sync_status from public.pos_external_shift_mappings $$,
 $$ values ('external-shift-1'::text,'synced'::text) $$,
 'provider acknowledgment persists external shift identity');
select public.ack_pos_outbound_job(
 (select id from public.pos_outbound_jobs where version = 1),
 'external-shift-1','revision-1');
reset role;
select results_eq(
 $$ select count(*)::int from public.pos_audit_events
    where event_type = 'provider_acknowledged' $$,
 $$ values (1) $$,
 'duplicate acknowledgment does not duplicate audit events');
insert into public.pos_connection_capabilities(connection_id,capability,state,
 evidence_url,verified_at) values (
 '80000000-0000-0000-0000-000000000011','scheduled_shifts_update',
 'verified_supported','https://doc.toasttab.com/doc/cookbook/apiIntegrationChecklistShift.html',
 current_date);
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000011';
select results_eq(
 $$ select public.publish_pos_schedule('80000000-0000-0000-0000-000000000011') $$,
 $$ values (2::bigint) $$,
 'acknowledged shift can be republished as version two');
select results_eq(
 $$ select operation,status from public.pos_outbound_jobs where version = 2 $$,
 $$ values ('update'::text,'pending'::text) $$,
 'republish queues an update of the same external shift');
reset role;
set local role service_role;
select results_eq(
 $$ select count(*)::int from public.claim_pos_outbound_jobs(1) $$,
 $$ values (1) $$,
 'worker claims the version two update');
select results_eq(
 $$ select public.fail_pos_outbound_job(
      (select id from public.pos_outbound_jobs where version = 2),
      'rate_limited',true,false) $$,
 $$ values ('retryable'::text) $$,
 'rate limit produces a retryable job');
reset role;
update public.pos_outbound_jobs set next_attempt_at = now() - interval '1 second'
 where version = 2;
set local role service_role;
select results_eq(
 $$ select count(*)::int from public.claim_pos_outbound_jobs(1) $$,
 $$ values (1) $$,
 'due retry reclaims the update without creating a new job');
select public.ack_pos_outbound_job(
 (select id from public.pos_outbound_jobs where version = 2),
 'external-shift-1','revision-2');
select results_eq(
 $$ select last_published_version from public.pos_external_shift_mappings $$,
 $$ values (2::bigint) $$,
 'update acknowledgment advances the retained mapping');
reset role;
insert into public.pos_connection_capabilities(connection_id,capability,state,
 evidence_url,verified_at) values (
 '80000000-0000-0000-0000-000000000011','scheduled_shifts_cancel',
 'verified_supported','https://doc.toasttab.com/doc/cookbook/apiIntegrationChecklistShift.html',
 current_date);
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000011';
select results_eq(
 $$ select public.remove_or_cancel_shift('30000000-0000-0000-0000-000000000011') $$,
 $$ values ('cancelled'::text) $$,
 'mapped shift is retained as cancelled');
select results_eq(
 $$ select public.publish_pos_schedule('80000000-0000-0000-0000-000000000011') $$,
 $$ values (3::bigint) $$,
 'cancelled local shift publishes version three');
select results_eq(
 $$ select operation,snapshot->>'external_shift_id' from public.pos_outbound_jobs
    where version = 3 $$,
 $$ values ('cancel'::text,'external-shift-1'::text) $$,
 'cancel job retains the provider shift ID');
reset role;
set local role service_role;
select count(*) from public.claim_pos_outbound_jobs(1);
select public.ack_pos_outbound_job(
 (select id from public.pos_outbound_jobs where version = 3),
 'external-shift-1','revision-3');
select results_eq(
 $$ select sync_status from public.pos_external_shift_mappings $$,
 $$ values ('cancelled'::text) $$,
 'cancellation acknowledgment remains visible on retained mapping');
reset role;
insert into public.shifts(id,organization_id,venue_id,start_time,end_time)
 values ('30000000-0000-0000-0000-000000000012',
 '10000000-0000-0000-0000-000000000011',
 '20000000-0000-0000-0000-000000000011',
 now() + interval '2 days',now() + interval '2 days 8 hours');
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000012';
select throws_ok(
 $$ select public.remove_or_cancel_shift('30000000-0000-0000-0000-000000000012') $$,
 '42501',null,'staff cannot remove a local draft');
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000011';
select results_eq(
 $$ select public.remove_or_cancel_shift('30000000-0000-0000-0000-000000000012') $$,
 $$ values ('deleted'::text) $$,
 'manager may delete an unexported local draft');
select is_empty(
 $$ select id from public.shifts where id = '30000000-0000-0000-0000-000000000012' $$,
 'unexported local draft is removed');

select * from finish();
rollback;
