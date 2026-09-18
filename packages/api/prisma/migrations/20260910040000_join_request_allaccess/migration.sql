-- approve_join_request and reject_join_request both gated on
-- role IN ('admin','owner','manager'), which does not recognize a support
-- profile with allAccess = TRUE (the same capability canManageVenue grants
-- in application code). A support/all-access profile could not review join
-- requests for a venue it otherwise fully manages. Bring the SQL check in
-- line with canManageVenue's role-OR-allAccess rule.
--
-- proconfig (search_path) set via prior ALTER FUNCTION statements survives
-- CREATE OR REPLACE FUNCTION as long as this statement does not itself
-- include a SET clause — see the 20260902120000 migration's VW-A16 note.

CREATE OR REPLACE FUNCTION approve_join_request(
  p_request_id TEXT,
  p_actor_id TEXT
) RETURNS void AS $$
DECLARE
  v_request RECORD;
  v_is_manager BOOLEAN;
  v_has_active_membership BOOLEAN;
  v_email_verified BOOLEAN;
  v_claimed_profile TEXT;
  v_user RECORD;
BEGIN
  SELECT * INTO v_request FROM "WorkplaceJoinRequest" WHERE "id" = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'request_not_found' USING ERRCODE = 'P0003'; END IF;
  IF v_request.status <> 'pending' THEN RAISE EXCEPTION 'request_not_pending' USING ERRCODE = 'P0004'; END IF;

  SELECT EXISTS (
    SELECT 1 FROM "Profile"
    WHERE "userId" = p_actor_id
      AND "venueId" = v_request."venueId"
      AND ("role" IN ('admin', 'owner', 'manager') OR "allAccess" = TRUE)
      AND ("membershipStatus" IS NULL OR "membershipStatus" = 'active')
  ) INTO v_is_manager;
  IF NOT v_is_manager THEN RAISE EXCEPTION 'not_authorized' USING ERRCODE = 'P0005'; END IF;

  PERFORM pg_advisory_xact_lock(hashtext('workforce-user:' || v_request."userId"));

  SELECT ("emailVerifiedAt" IS NOT NULL) INTO v_email_verified
  FROM "User" WHERE "id" = v_request."userId";
  IF NOT COALESCE(v_email_verified, FALSE) THEN
    RAISE EXCEPTION 'email_not_verified' USING ERRCODE = 'P0006';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM "Profile"
    WHERE "userId" = v_request."userId"
      AND "venueId" IS NOT NULL
      AND ("membershipStatus" IS NULL OR "membershipStatus" = 'active')
  ) INTO v_has_active_membership;
  IF v_has_active_membership THEN RAISE EXCEPTION 'already_member' USING ERRCODE = 'P0001'; END IF;

  UPDATE "WorkplaceJoinRequest"
  SET "status" = 'approved', "decidedAt" = NOW(), "decidedById" = p_actor_id, "updatedAt" = NOW()
  WHERE "id" = p_request_id;

  -- A previously-revoked row at THIS venue must be reactivated in place, never
  -- duplicated: Profile has @@unique([userId, venueId]), so inserting a second
  -- row for the same pair would abort the approval. Rejoining your old
  -- workplace is the ordinary way to reach this branch. Accruals reset — the
  -- balance from the prior employment period is not carried into a new one.
  UPDATE "Profile"
  SET "role" = 'staff',
      "membershipStatus" = 'active',
      "sickHoursAccrued" = 0,
      "ptoHoursAccrued" = 0,
      "updatedAt" = NOW()
  WHERE "userId" = v_request."userId" AND "venueId" = v_request."venueId"
  RETURNING "id" INTO v_claimed_profile;

  -- Otherwise claim a venueless profile if the user has one (normal signup shape).
  IF v_claimed_profile IS NULL THEN
    UPDATE "Profile"
    SET "venueId" = v_request."venueId",
        "role" = 'staff',
        "membershipStatus" = 'active',
        "sickHoursAccrued" = 0,
        "ptoHoursAccrued" = 0,
        "updatedAt" = NOW()
    WHERE "id" = (
      SELECT "id" FROM "Profile"
      WHERE "userId" = v_request."userId" AND "venueId" IS NULL
      ORDER BY "createdAt" ASC
      LIMIT 1
    )
    RETURNING "id" INTO v_claimed_profile;
  END IF;

  -- Otherwise every row the user owns belongs to some other venue. Leave those
  -- untouched and create a new membership from the account's own identity.
  IF v_claimed_profile IS NULL THEN
    -- User has no name column; fall back to any existing profile's name, then
    -- to the local-part of the email.
    SELECT u."email" AS email,
           (SELECT p2."fullName" FROM "Profile" p2
             WHERE p2."userId" = v_request."userId"
             ORDER BY p2."createdAt" ASC LIMIT 1) AS "fullName"
      INTO v_user
      FROM "User" u WHERE u."id" = v_request."userId";
    INSERT INTO "Profile" (
      "id", "userId", "email", "fullName", "role", "jobTitle",
      "venueId", "membershipStatus", "allAccess",
      "sickHoursAccrued", "ptoHoursAccrued", "createdAt", "updatedAt"
    )
    VALUES (
      gen_random_uuid()::text,
      v_request."userId",
      COALESCE(v_user."email", v_request."userId" || '@venuewrangler.local'),
      COALESCE(NULLIF(v_user."fullName", ''), NULLIF(split_part(COALESCE(v_user."email", ''), '@', 1), ''), 'Team Member'),
      'staff',
      'Team Member',
      v_request."venueId",
      'active',
      FALSE,
      0, 0, NOW(), NOW()
    );
  END IF;

  INSERT INTO "WorkplaceJoinRequestEvent" ("id", "requestId", "actorId", "eventType", "payload", "createdAt")
  VALUES (gen_random_uuid()::text, p_request_id, p_actor_id, 'approved', jsonb_build_object('decidedById', p_actor_id), NOW());
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION reject_join_request(
  p_request_id TEXT,
  p_actor_id   TEXT,
  p_note       TEXT DEFAULT NULL
) RETURNS void AS $$
DECLARE
  v_request    RECORD;
  v_is_manager BOOLEAN;
BEGIN
  SELECT * INTO v_request
  FROM "WorkplaceJoinRequest"
  WHERE "id" = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'request_not_found' USING ERRCODE = 'P0003';
  END IF;

  IF v_request.status <> 'pending' THEN
    RAISE EXCEPTION 'request_not_pending' USING ERRCODE = 'P0004';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM "Profile"
    WHERE "userId" = p_actor_id
      AND "venueId" = v_request."venueId"
      AND ("role" IN ('admin', 'owner', 'manager') OR "allAccess" = TRUE)
      AND ("membershipStatus" IS NULL OR "membershipStatus" = 'active')
  ) INTO v_is_manager;

  IF NOT v_is_manager THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = 'P0005';
  END IF;

  UPDATE "WorkplaceJoinRequest"
  SET "status"       = 'rejected',
      "decidedAt"    = NOW(),
      "decidedById"  = p_actor_id,
      "decisionNote" = p_note,
      "updatedAt"    = NOW()
  WHERE "id" = p_request_id;

  INSERT INTO "WorkplaceJoinRequestEvent" (
    "id", "requestId", "actorId", "eventType", "payload", "createdAt"
  ) VALUES (
    gen_random_uuid()::text,
    p_request_id,
    p_actor_id,
    'rejected',
    jsonb_build_object('decidedById', p_actor_id, 'note', p_note),
    NOW()
  );
END;
$$ LANGUAGE plpgsql;
