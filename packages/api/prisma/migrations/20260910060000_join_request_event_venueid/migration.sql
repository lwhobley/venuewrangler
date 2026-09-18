-- WorkplaceJoinRequestEvent had no venueId, so it was not (and could not be)
-- listed in VENUE_SCOPED_MODELS — any future direct query on this table
-- (rather than through the WorkplaceJoinRequest relation, which IS
-- tenant-scoped today) would be fully unscoped. Add venueId, backfill from
-- the parent request, and have every function that inserts these rows
-- populate it going forward.

ALTER TABLE "WorkplaceJoinRequestEvent" ADD COLUMN "venueId" TEXT;

UPDATE "WorkplaceJoinRequestEvent" e
SET "venueId" = r."venueId"
FROM "WorkplaceJoinRequest" r
WHERE r."id" = e."requestId" AND e."venueId" IS NULL;

ALTER TABLE "WorkplaceJoinRequestEvent"
  ADD CONSTRAINT "WorkplaceJoinRequestEvent_venueId_fkey"
  FOREIGN KEY ("venueId") REFERENCES "Venue"("id") ON DELETE SET NULL ON UPDATE CASCADE;

CREATE INDEX "WorkplaceJoinRequestEvent_venueId_idx" ON "WorkplaceJoinRequestEvent"("venueId");

-- request_join_workplace: p_venue_id is already a parameter.
CREATE OR REPLACE FUNCTION request_join_workplace(
  p_user_id TEXT,
  p_venue_id TEXT
) RETURNS TEXT AS $$
DECLARE
  v_has_active_membership BOOLEAN;
  v_request_id TEXT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('workforce-user:' || p_user_id));
  SELECT EXISTS (
    SELECT 1 FROM "Profile"
    WHERE "userId" = p_user_id
      AND "venueId" IS NOT NULL
      AND ("membershipStatus" IS NULL OR "membershipStatus" = 'active')
  ) INTO v_has_active_membership;

  IF v_has_active_membership THEN
    RAISE EXCEPTION 'already_member' USING ERRCODE = 'P0001';
  END IF;

  v_request_id := gen_random_uuid()::text;
  INSERT INTO "WorkplaceJoinRequest" ("id", "venueId", "userId", "status", "createdAt", "updatedAt")
  VALUES (v_request_id, p_venue_id, p_user_id, 'pending', NOW(), NOW());
  INSERT INTO "WorkplaceJoinRequestEvent" ("id", "requestId", "venueId", "actorId", "eventType", "createdAt")
  VALUES (gen_random_uuid()::text, v_request_id, p_venue_id, p_user_id, 'requested', NOW());
  RETURN v_request_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'duplicate_pending_request' USING ERRCODE = 'P0002';
END;
$$ LANGUAGE plpgsql;

-- cancel_join_request: venueId comes from the already-loaded v_request record.
CREATE OR REPLACE FUNCTION cancel_join_request(
  p_request_id TEXT,
  p_user_id    TEXT
) RETURNS void AS $$
DECLARE
  v_request RECORD;
BEGIN
  SELECT * INTO v_request
  FROM "WorkplaceJoinRequest"
  WHERE "id" = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'request_not_found' USING ERRCODE = 'P0003';
  END IF;

  IF v_request."userId" <> p_user_id THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = 'P0005';
  END IF;

  IF v_request.status <> 'pending' THEN
    RAISE EXCEPTION 'request_not_pending' USING ERRCODE = 'P0004';
  END IF;

  UPDATE "WorkplaceJoinRequest"
  SET "status"    = 'cancelled',
      "decidedAt" = NOW(),
      "updatedAt" = NOW()
  WHERE "id" = p_request_id;

  INSERT INTO "WorkplaceJoinRequestEvent" (
    "id", "requestId", "venueId", "actorId", "eventType", "createdAt"
  ) VALUES (
    gen_random_uuid()::text, p_request_id, v_request."venueId", p_user_id, 'cancelled', NOW()
  );
END;
$$ LANGUAGE plpgsql;

-- approve_join_request / reject_join_request: venueId comes from v_request,
-- same as cancel_join_request. Carries forward the allAccess check added in
-- the 20260910040000 migration.
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

  UPDATE "Profile"
  SET "role" = 'staff',
      "membershipStatus" = 'active',
      "sickHoursAccrued" = 0,
      "ptoHoursAccrued" = 0,
      "updatedAt" = NOW()
  WHERE "userId" = v_request."userId" AND "venueId" = v_request."venueId"
  RETURNING "id" INTO v_claimed_profile;

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

  IF v_claimed_profile IS NULL THEN
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

  INSERT INTO "WorkplaceJoinRequestEvent" ("id", "requestId", "venueId", "actorId", "eventType", "payload", "createdAt")
  VALUES (gen_random_uuid()::text, p_request_id, v_request."venueId", p_actor_id, 'approved', jsonb_build_object('decidedById', p_actor_id), NOW());
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
    "id", "requestId", "venueId", "actorId", "eventType", "payload", "createdAt"
  ) VALUES (
    gen_random_uuid()::text,
    p_request_id,
    v_request."venueId",
    p_actor_id,
    'rejected',
    jsonb_build_object('decidedById', p_actor_id, 'note', p_note),
    NOW()
  );
END;
$$ LANGUAGE plpgsql;
