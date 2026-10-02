-- pgTAP authorization tests for checklists (supabase/migrations/20261002020000). Reuses the
-- same org/venue/membership roster shape as the other test files; see foundation_rls.test.sql
-- for the full cast if these ids look unfamiliar.

begin;
select plan(16);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000002', 'org-a-owner@example.com'),
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b', 'Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- ---------------------------------------------------------------------------
-- templates
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select throws_ok(
  $$ insert into public.checklist_templates (venue_id, title) values ('20000000-0000-0000-0000-0000000000a1', 'Rogue checklist') $$,
  '42501',
  null,
  'staff cannot create a checklist template'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ insert into public.checklist_templates (id, venue_id, title)
     values ('40000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', 'Opening checklist') $$,
  'venue_manager can create a checklist template'
);

select lives_ok(
  $$ insert into public.checklist_template_items (id, template_id, label, position)
     values ('41000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 'Unlock front door', 1) $$,
  'venue_manager can add an item to the template'
);

select is(
  (select venue_id from public.checklist_template_items where id = '41000000-0000-0000-0000-000000000001'),
  '20000000-0000-0000-0000-0000000000a1'::uuid,
  'the item''s venue_id is auto-derived from its parent template'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select throws_ok(
  $$ insert into public.checklist_template_items (template_id, label) values ('40000000-0000-0000-0000-000000000001', 'Rogue item') $$,
  '42501',
  null,
  'staff cannot add an item to a template'
);

select is(
  (select count(*)::int from public.checklist_templates),
  1,
  'a venue member can see their venue''s checklist template'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::int from public.checklist_templates),
  0,
  'org_b_owner cannot see org_a''s checklist templates (cross-tenant)'
);

select throws_ok(
  $$ insert into public.checklist_completions (template_id) values ('40000000-0000-0000-0000-000000000001') $$,
  '42501',
  null,
  'a user outside the venue cannot submit a completion for its template'
);

-- ---------------------------------------------------------------------------
-- completions
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ insert into public.checklist_completions (id, template_id, item_results)
     values ('42000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', '[{"item_id": "41000000-0000-0000-0000-000000000001", "checked": true}]'::jsonb) $$,
  'a staff member can submit a checklist completion'
);

select is(
  (select completed_by from public.checklist_completions where id = '42000000-0000-0000-0000-000000000001'),
  '00000000-0000-0000-0000-000000000005'::uuid,
  'completed_by is always the calling user'
);

select is(
  (select venue_id from public.checklist_completions where id = '42000000-0000-0000-0000-000000000001'),
  '20000000-0000-0000-0000-0000000000a1'::uuid,
  'venue_id/organization_id are auto-derived from the template'
);

select is(
  (select count(*)::int from public.checklist_completions),
  1,
  'a venue member can see completions recorded in their venue'
);

select lives_ok(
  $$ update public.checklist_completions set notes = 'trying to edit my own submission' where id = '42000000-0000-0000-0000-000000000001' $$,
  'the submitter''s own update attempt executes without error but matches no rows'
);

select is(
  (select notes from public.checklist_completions where id = '42000000-0000-0000-0000-000000000001'),
  null,
  'a completion is immutable to the person who submitted it'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select lives_ok(
  $$ update public.checklist_completions set notes = 'reviewed by manager' where id = '42000000-0000-0000-0000-000000000001' $$,
  'venue_manager can amend a completion record'
);

select lives_ok(
  $$ delete from public.checklist_completions where id = '42000000-0000-0000-0000-000000000001' $$,
  'venue_manager can delete a completion record'
);

select * from finish();
rollback;
