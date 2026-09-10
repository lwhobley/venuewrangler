import { BadRequestException, ConflictException, Injectable, NotFoundException, Optional } from '@nestjs/common';
import { randomUUID } from 'crypto';
import { Prisma, TableShape, TableSection, TableStatus } from '@prisma/client';
import { PrismaService } from '../../prisma/prisma.service';
import { AuditService } from '../audit/audit.service';
import { withSerializableRetry } from '../../common/tx-retry';
import { ReservationNotifierService } from '../reservations/reservation-notifier.service';
import { refreshTableStates } from './table-state';

/**
 * Floor-plan / table / waitlist / assignment data logic extracted from
 * FloorController. The controller keeps routing, DTO validation, and the
 * requireManager auth assertion; this service takes the already-resolved
 * venueId and does the Prisma work. Bodies moved verbatim from the controller
 * (same pattern as BarInventoryReportsService) — no behavior change.
 */
/** Who performed a floor action, for the audit trail. */
export type FloorActor = { profileId: string; fullName: string; role: string };

@Injectable()
export class FloorService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly notifier: ReservationNotifierService,
    @Optional() private readonly audit?: AuditService,
  ) {}

  async getActiveFloorPlan(venueId: string) {
    const plan = await this.prisma.floorPlan.findFirst({
      where: { venueId, isActive: true },
      include: {
        tables: true,
        chairs: true,
      },
    });
    if (!plan) return null;

    const tableStates = await this.prisma.tableState.findMany({
      where: { venueId, tableId: { in: plan.tables.map((t) => t.id) } },
    });
    const stateByTableId = new Map(tableStates.map((s) => [s.tableId, s]));
    const tableIds = plan.tables.map((t) => t.id);
    const now = new Date();
    const assignments = tableIds.length
      ? await this.prisma.tableAssignment.findMany({
          where: {
            venueId,
            tableId: { in: tableIds },
            releasedAt: null,
            endsAt: { gt: now },
          },
          include: {
            reservation: {
              select: {
                id: true,
                guestName: true,
                partySize: true,
                source: true,
                tags: true,
                specialRequests: true,
                status: true,
              },
            },
          },
          orderBy: { startsAt: 'asc' },
        })
      : [];
    const waitlistIds = assignments.map((a) => a.waitlistId).filter((id): id is string => Boolean(id));
    const waitlistRows = waitlistIds.length
      ? await this.prisma.waitlist.findMany({
          where: { venueId, id: { in: waitlistIds } },
          select: { id: true, guestName: true, partySize: true, source: true, notes: true, status: true },
        })
      : [];
    const waitlistById = new Map(waitlistRows.map((row) => [row.id, row]));
    const assignmentsByTableId = new Map<string, typeof assignments>();
    for (const assignment of assignments) {
      const rows = assignmentsByTableId.get(assignment.tableId) ?? [];
      rows.push(assignment);
      assignmentsByTableId.set(assignment.tableId, rows);
    }

    return {
      floorPlan: {
        _id: plan.id,
        id: plan.id,
        venueId: plan.venueId,
        name: plan.name,
        width: plan.width,
        height: plan.height,
        backgroundImageUrl: plan.backgroundImageUrl ?? null,
        isActive: plan.isActive,
        createdAt: plan.createdAt.getTime(),
        updatedAt: plan.updatedAt.getTime(),
      },
      tables: plan.tables.map((table) => {
        const state = stateByTableId.get(table.id) ?? null;
        return {
          table: {
            _id: table.id,
            id: table.id,
            floorPlanId: table.floorPlanId,
            label: table.label,
            shape: table.shape,
            seats: table.seats,
            seatLabelStyle: table.seatLabelStyle ?? null,
            x: table.x,
            y: table.y,
            width: table.width,
            height: table.height,
            rotation: table.rotation,
            section: table.section,
            minSpend: table.minSpend,
            isReservable: table.isReservable,
          },
          state: state
            ? {
                _id: state.id,
                id: state.id,
                venueId: state.venueId,
                tableId: state.tableId,
                status: state.status,
                partySize: state.partySize ?? null,
                serverId: state.serverId ?? null,
                seatedAt: state.seatedAt?.getTime() ?? null,
                lastActivityAt: state.lastActivityAt.getTime(),
                notes: state.notes ?? null,
                mergeGroupId: state.mergeGroupId ?? null,
              }
            : null,
          activeAssignments: (assignmentsByTableId.get(table.id) ?? [])
            .filter((assignment) => assignment.startsAt <= now && assignment.endsAt > now)
            .map((assignment) => this.mapAssignment(assignment, waitlistById)),
          nextAssignment: (assignmentsByTableId.get(table.id) ?? [])
            .filter((assignment) => assignment.startsAt > now)
            .map((assignment) => this.mapAssignment(assignment, waitlistById))[0] ?? null,
        };
      }),
      chairs: plan.chairs.map((c) => ({
        _id: c.id,
        id: c.id,
        x: c.x,
        y: c.y,
        rotation: c.rotation,
        label: c.label ?? null,
      })),
    };
  }

  async getFloorStats(venueId: string) {
    const plan = await this.prisma.floorPlan.findFirst({
      where: { venueId, isActive: true },
      include: { tables: { select: { id: true } } },
    });
    if (!plan) return this.emptyStats();

    const tableIds = plan.tables.map((t) => t.id);
    const [states, waitlistSize] = await Promise.all([
      this.prisma.tableState.findMany({
        where: { venueId, tableId: { in: tableIds } },
      }),
      this.prisma.waitlist.count({ where: { venueId, status: 'waiting' } }),
    ]);
    const occupiedStates = states.filter((s) => s.status === 'seated');
    const occupiedTables = occupiedStates.length;
    const availableTables = states.filter((s) => s.status === 'available').length;
    const dirtyCleaning = states.filter((s) => s.status === 'dirty').length;
    const seatedDurations = occupiedStates
      .map((s) => (s.seatedAt ? Math.max(0, Math.round((Date.now() - s.seatedAt.getTime()) / 60_000)) : 0))
      .filter((minutes) => minutes > 0);
    const avgTurnTimeMinutes = seatedDurations.length
      ? Math.round(seatedDurations.reduce((sum, minutes) => sum + minutes, 0) / seatedDurations.length)
      : 0;
    const longestSeatedDurationMinutes = seatedDurations.length ? Math.max(...seatedDurations) : 0;

    return {
      totalTables: tableIds.length,
      occupiedTables,
      availableTables,
      dirtyCleaning,
      occupiedCount: occupiedTables,
      availableCount: availableTables,
      dirtyCount: dirtyCleaning,
      waitlistSize,
      avgTurnTimeMinutes,
      longestSeatedDurationMinutes,
    };
  }

  async saveFloorPlan(venueId: string, input: {
    name?: string;
    width?: number;
    height?: number;
    backgroundImageUrl?: string | null;
    tables: Array<{
      id?: string;
      label: string;
      x: number;
      y: number;
      width: number;
      height: number;
      shape: string;
      section?: string;
      capacity: number;
      seatLabelStyle?: string;
      rotation?: number;
      minSpend?: number;
      isReservable?: boolean;
      chairs?: Array<{ x: number; y: number; rotation: number; label?: string }>;
    }>;
    chairs?: Array<{ x: number; y: number; rotation: number; label?: string }>;
  }) {
    const tables = input.tables ?? [];
    await withSerializableRetry(this.prisma, async (tx) => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`floor-plan:${venueId}`}))`;
      let plan = await tx.floorPlan.findFirst({ where: { venueId, isActive: true } });
      if (plan) {
        plan = await tx.floorPlan.update({ where: { id: plan.id }, data: { name: input.name?.trim() || 'Floor Plan', width: input.width ?? plan.width, height: input.height ?? plan.height, backgroundImageUrl: input.backgroundImageUrl ?? null } });
      } else {
        plan = await tx.floorPlan.create({ data: { venueId, name: input.name?.trim() || 'Floor Plan', width: input.width ?? 800, height: input.height ?? 600, backgroundImageUrl: input.backgroundImageUrl ?? null, isActive: true } });
      }
      const existingTables = await tx.floorTable.findMany({ where: { floorPlanId: plan.id }, select: { id: true } });
      const existingIds = new Set(existingTables.map((table) => table.id));
      const submittedIds = new Set(tables.map((table) => table.id).filter((id): id is string => Boolean(id)));
      const removedIds = [...existingIds].filter((id) => !submittedIds.has(id));
      if (removedIds.length) {
        const activeAssignments = await tx.tableAssignment.count({ where: { venueId, tableId: { in: removedIds }, releasedAt: null } });
        if (activeAssignments) throw new ConflictException('Release active table assignments before removing tables from the floor plan');
        await tx.floorTable.deleteMany({ where: { id: { in: removedIds } } });
      }
      // Set-based writes instead of one round-trip per table: a floor plan can
      // carry up to MAX_FLOOR_PLAN_TABLES (500) tables, and this whole block
      // runs inside one advisory-locked transaction — a sequential loop here
      // held the lock (and one of the pool's 3 connections) for as long as
      // the largest submitted plan took to write, one row at a time.
      const rows = tables.map((table) => ({
        id: table.id && existingIds.has(table.id) ? table.id : randomUUID(),
        isNew: !(table.id && existingIds.has(table.id)),
        label: table.label,
        shape: (table.shape as TableShape) ?? 'square',
        seats: table.capacity,
        seatLabelStyle: table.seatLabelStyle ?? null,
        x: table.x,
        y: table.y,
        width: table.width,
        height: table.height,
        rotation: table.rotation ?? 0,
        section: (table.section as TableSection) ?? 'main',
        minSpend: table.minSpend ?? 0,
        isReservable: table.isReservable ?? true,
      }));
      const creates = rows.filter((row) => row.isNew);
      const updates = rows.filter((row) => !row.isNew);

      if (creates.length > 0) {
        await tx.floorTable.createMany({
          data: creates.map(({ isNew: _isNew, ...data }) => ({ ...data, venueId, floorPlanId: plan.id })),
        });
        await tx.tableState.createMany({
          data: creates.map((row) => ({ venueId, tableId: row.id, status: 'available', lastActivityAt: new Date() })),
        });
      }
      if (updates.length > 0) {
        const values = Prisma.join(
          updates.map(
            (row) => Prisma.sql`(${row.id}, ${row.label}, ${row.shape}::"TableShape", ${row.seats}, ${row.seatLabelStyle}, ${row.x}, ${row.y}, ${row.width}, ${row.height}, ${row.rotation}, ${row.section}::"TableSection", ${row.minSpend}, ${row.isReservable})`,
          ),
          ', ',
        );
        // Table-scoped by id AND floorPlanId, matching the tenant boundary the
        // preceding loop-based UPDATE relied on (an id only ever reaches this
        // branch when it's already a member of existingIds, which is itself
        // scoped to this plan).
        await tx.$executeRaw`
          UPDATE "FloorTable" AS t
          SET
            label = v.label,
            shape = v.shape,
            seats = v.seats,
            "seatLabelStyle" = v."seatLabelStyle",
            x = v.x,
            y = v.y,
            width = v.width,
            height = v.height,
            rotation = v.rotation,
            section = v.section,
            "minSpend" = v."minSpend",
            "isReservable" = v."isReservable"
          FROM (VALUES ${values}) AS v(id, label, shape, seats, "seatLabelStyle", x, y, width, height, rotation, section, "minSpend", "isReservable")
          WHERE t.id = v.id AND t."floorPlanId" = ${plan.id}
        `;
      }

      await tx.floorChair.deleteMany({ where: { floorPlanId: plan.id } });
      const allChairs = [
        ...tables.flatMap(
          (table) =>
            (table.chairs ?? []).map((chair) => ({
              venueId,
              floorPlanId: plan.id,
              x: chair.x,
              y: chair.y,
              rotation: chair.rotation,
              label: chair.label ?? null,
            })),
        ),
        ...((input.chairs ?? []).map((chair) => ({
          venueId,
          floorPlanId: plan.id,
          x: chair.x,
          y: chair.y,
          rotation: chair.rotation,
          label: chair.label ?? null,
        }))),
      ];
      if (allChairs.length > 0) {
        await tx.floorChair.createMany({ data: allChairs });
      }

      return plan;
    });

    return { ok: true };
  }

  async clearActiveFloorPlan(venueId: string) {
    const plan = await this.prisma.floorPlan.findFirst({
      where: { venueId, isActive: true },
      include: { tables: { select: { id: true } }, chairs: { select: { id: true } } },
    });
    if (!plan) return { deletedTables: 0, deletedChairs: 0 };

    const tableIds = plan.tables.map((t) => t.id);
    const chairIds = plan.chairs.map((c) => c.id);

    // Clearing the plan deletes the assignments that seat a party. The
    // reservation and waitlist rows behind them survive, and used to be left
    // reading 'seated' with nothing to seat them at — a guest who, from every
    // other screen, is sitting at a table that no longer exists. Walk them back
    // to the state they were in before the table was assigned.
    const strandedAssignments = await this.prisma.tableAssignment.findMany({
      where: { tableId: { in: tableIds }, releasedAt: null },
      select: { reservationId: true, waitlistId: true },
    });
    const reservationIds = [...new Set(strandedAssignments.map((a) => a.reservationId).filter((id): id is string => Boolean(id)))];
    const waitlistIds = [...new Set(strandedAssignments.map((a) => a.waitlistId).filter((id): id is string => Boolean(id)))];

    await this.prisma.$transaction([
      this.prisma.tableState.deleteMany({ where: { tableId: { in: tableIds } } }),
      this.prisma.tableAssignment.deleteMany({ where: { tableId: { in: tableIds } } }),
      this.prisma.floorChair.deleteMany({ where: { id: { in: chairIds } } }),
      this.prisma.floorTable.deleteMany({ where: { floorPlanId: plan.id } }),
      this.prisma.floorPlan.update({ where: { id: plan.id }, data: { isActive: false } }),
      // Scoped by venueId as well as id: these ids come from assignment rows,
      // and a tenant predicate on every write is the house rule.
      this.prisma.reservation.updateMany({
        where: { id: { in: reservationIds }, venueId, status: 'seated' },
        data: { status: 'confirmed' },
      }),
      this.prisma.waitlist.updateMany({
        where: { id: { in: waitlistIds }, venueId, status: { in: ['seated', 'assigned'] } },
        data: { status: 'waiting', readyAt: null },
      }),
    ]);

    return {
      deletedTables: tableIds.length,
      deletedChairs: chairIds.length,
      releasedReservations: reservationIds.length,
      releasedWaitlistEntries: waitlistIds.length,
    };
  }

  async getUnassignedReservations(venueId: string, withinMinutes?: string) {
    const parsed = parseInt(withinMinutes ?? '', 10);
    // Clamp to a sane window; a bad/NaN value falls back to the 120-min default
    // rather than producing an Invalid Date cutoff (which silently returns []).
    const minutes = Number.isFinite(parsed) ? Math.min(Math.max(parsed, 1), 1440) : 120;
    const now = new Date();
    const cutoff = new Date(now.getTime() + minutes * 60 * 1000);

    const reservations = await this.prisma.reservation.findMany({
      where: {
        venueId,
        reservationTime: { gte: now, lte: cutoff },
        status: { in: ['confirmed', 'requested'] },
        deletedAt: null,
      },
      orderBy: { reservationTime: 'asc' },
    });

    const assigned = await this.prisma.tableAssignment.findMany({
      where: {
        venueId,
        reservationId: { in: reservations.map((r) => r.id) },
        releasedAt: null,
      },
    });
    const assignedReservationIds = new Set(assigned.map((a) => a.reservationId).filter(Boolean));

    return reservations
      .filter((r) => !assignedReservationIds.has(r.id))
      .map((r) => ({
        _id: r.id,
        id: r.id,
        guestName: r.guestName,
        partySize: r.partySize,
        reservationTime: r.reservationTime.getTime(),
        status: r.status,
      }));
  }

  async getOpenWaitlist(venueId: string) {
    // 'assigned' means the party has been called or held at a table but is not
    // seated yet. It has to stay in this queue: this is the only list the host
    // screen offers a Seat action from, so filtering to 'waiting' made a party
    // vanish the moment it was marked Ready — the record survived, but nobody
    // could act on it. 'seated', 'completed' and 'removed' are terminal and stay
    // out.
    const rows = await this.prisma.waitlist.findMany({
      where: { venueId, status: { in: ['waiting', 'assigned'] } },
      orderBy: { requestedAt: 'asc' },
    });
    return rows.map((r) => ({
      _id: r.id,
      id: r.id,
      guestName: r.guestName,
      partySize: r.partySize,
      phone: r.guestPhone ?? null,
      notes: r.notes ?? null,
      status: r.status,
      isReady: r.status === 'assigned',
      readyAt: r.readyAt?.getTime() ?? null,
      requestedAt: r.requestedAt.getTime(),
    }));
  }

  async addToWaitlist(venueId: string, body: { guestName: string; partySize: number; phone?: string; email?: string; notes?: string }) {
    // Same gap reservations had: the party's contact details were stored as
    // loose text and the entry was never attached to the guest profile it
    // plainly belonged to, so a returning guest's history stayed empty.
    const guestId = await this.resolveGuestId(venueId, { email: body.email, phone: body.phone });
    const row = await this.prisma.waitlist.create({
      data: {
        venueId,
        guestId,
        guestName: body.guestName.trim(),
        partySize: body.partySize,
        guestPhone: body.phone?.trim() ?? null,
        guestEmail: body.email?.trim() ?? null,
        notes: body.notes?.trim() ?? null,
        source: 'walk_in',
        status: 'waiting',
        requestedAt: new Date(),
      },
    });
    return { _id: row.id, id: row.id };
  }

  /** Match a walk-in to an existing guest profile by email or phone. */
  private async resolveGuestId(venueId: string, contact: { email?: string; phone?: string }): Promise<string | null> {
    const email = contact.email?.trim().toLowerCase() || null;
    const phone = contact.phone?.replace(/[^\d+]/g, '') || null;
    if (!email && !phone) return null;
    const match = await this.prisma.guest.findFirst({
      where: {
        venueId,
        deletedAt: null,
        OR: [...(email ? [{ email }] : []), ...(phone ? [{ phone }] : [])],
      },
      select: { id: true },
    });
    return match?.id ?? null;
  }

  async removeFromWaitlist(venueId: string, id: string, actor?: FloorActor) {
    const row = await this.prisma.waitlist.findFirst({ where: { id, venueId } });
    if (!row) throw new NotFoundException('Waitlist entry not found');
    await this.prisma.waitlist.update({ where: { id: row.id }, data: { status: 'removed' } });
    // Destructive and reachable by the lowest-privilege role, so it needs to be
    // attributable — this was the only such action with no trace at all.
    void this.audit?.record({
      venueId,
      actorProfileId: actor?.profileId,
      actorName: actor?.fullName,
      actorRole: actor?.role,
      action: 'floor.waitlist.removed',
      entityType: 'Waitlist',
      entityId: row.id,
      summary: `Removed ${row.guestName ?? 'a party'} from the waitlist`,
    });
    return { ok: true };
  }

  async markWaitlistReady(venueId: string, id: string) {
    const row = await this.prisma.waitlist.findFirst({ where: { id, venueId } });
    if (!row) throw new NotFoundException('Waitlist entry not found');
    await this.prisma.waitlist.update({ where: { id: row.id }, data: { status: 'assigned', readyAt: new Date() } });
    return { ok: true };
  }

  async updateTableStatus(venueId: string, id: string, status: string, actor?: FloorActor) {
    const state = await this.prisma.tableState.findFirst({ where: { tableId: id, venueId } });
    if (!state) throw new NotFoundException('Table not found');
    const result = await this.prisma.tableState.updateMany({
      where: { id: state.id, venueId, lastActivityAt: state.lastActivityAt },
      data: { status: status as TableStatus, lastActivityAt: new Date() },
    });
    if (result.count === 0) throw new ConflictException('Table status changed. Refresh and try again.');
    void this.audit?.record({
      venueId,
      actorProfileId: actor?.profileId,
      actorName: actor?.fullName,
      actorRole: actor?.role,
      action: 'floor.table.status_changed',
      entityType: 'TableState',
      entityId: state.id,
      summary: `Table status set to ${status}`,
    });
    return { ok: true };
  }

  async mergeTablesForParty(venueId: string, tableIdsInput: string[], partySize?: number) {
    const tableIds = Array.from(new Set(tableIdsInput));
    if (tableIds.length < 2) throw new BadRequestException('Select at least two tables to merge');

    const validTableIds = await this.getActivePlanTableIds(venueId);
    const unknown = tableIds.filter((id) => !validTableIds.has(id));
    if (unknown.length) throw new BadRequestException('One or more tables are not on this venue\'s floor plan');

    const states = await this.prisma.tableState.findMany({
      where: { venueId, tableId: { in: tableIds } },
    });
    if (states.length !== tableIds.length) throw new BadRequestException('One or more tables are missing live state');
    if (states.some((state) => state.mergeGroupId)) {
      throw new ConflictException('Split already-merged tables before creating a new merge');
    }
    const seatedStates = states.filter((state) => state.status === 'seated');
    if (seatedStates.length > 0) {
      const now = new Date();
      const assignments = this.prisma.tableAssignment?.findMany
        ? await this.prisma.tableAssignment.findMany({
            where: { venueId, tableId: { in: tableIds }, releasedAt: null, startsAt: { lte: now }, endsAt: { gt: now } },
            select: { tableId: true, reservationId: true, waitlistId: true },
          })
        : [];
      const identityByTable = new Map(assignments.map((assignment) => [
        assignment.tableId,
        assignment.reservationId ? `reservation:${assignment.reservationId}` : assignment.waitlistId ? `waitlist:${assignment.waitlistId}` : null,
      ]));
      const identities = seatedStates.map((state) => identityByTable.get(state.tableId));
      if (identities.some((identity) => !identity) || new Set(identities).size !== 1) {
        throw new ConflictException('Seated tables can only be merged when they belong to the same reservation or waitlist party');
      }
    }
    const canMerge = states.every((state) => ['available', 'dirty', 'seated'].includes(state.status))
      && (seatedStates.length === 0 || new Set(seatedStates.map((state) => state.partySize)).size === 1);
    const blocked = canMerge ? undefined : states.find((state) => !['available', 'dirty', 'seated'].includes(state.status)) ?? seatedStates[0];
    if (blocked) throw new ConflictException(`Table ${blocked.tableId} is not available to merge`);

    const mergeGroupId = randomUUID();
    const seatedPartySize = seatedStates[0]?.partySize ?? partySize ?? null;
    await this.prisma.tableState.updateMany({
      where: { venueId, tableId: { in: tableIds } },
      data: {
        mergeGroupId,
        ...(seatedStates.length ? { status: 'seated' as const, partySize: seatedPartySize, seatedAt: seatedStates[0]?.seatedAt ?? new Date() } : { partySize: partySize ?? null }),
        lastActivityAt: new Date(),
      },
    });
    return { ok: true, mergeGroupId };
  }

  async splitMergedTables(venueId: string, mergeGroupId: string) {
    const states = await this.prisma.tableState.findMany({ where: { venueId, mergeGroupId } });
    if (states.length === 0) throw new NotFoundException('Merged table group not found');
    const now = new Date();
    const assignments = this.prisma.tableAssignment?.findMany
      ? await this.prisma.tableAssignment.findMany({
          where: { venueId, tableId: { in: states.map((state) => state.tableId) }, releasedAt: null, startsAt: { lte: now }, endsAt: { gt: now } },
          include: { reservation: { select: { partySize: true } }, waitlist: { select: { partySize: true } } },
        })
      : [];
    const partySizeByTable = new Map(assignments.map((assignment) => [assignment.tableId, assignment.reservation?.partySize ?? assignment.waitlist?.partySize ?? null]));
    await Promise.all(states.map((state) => this.prisma.tableState.update({
      where: { id: state.id },
      data: {
        mergeGroupId: null,
        partySize: state.status === 'seated' ? (partySizeByTable.get(state.tableId) ?? state.partySize) : null,
        lastActivityAt: now,
      },
    })));
    return { ok: true, splitTables: states.length };
  }

  async assignReservationToTables(venueId: string, reservationId: string, tableIds: string[], options: { holdType?: string; startsAt?: number; endsAt?: number } = {}) {
    if (!tableIds.length) throw new BadRequestException('No tables specified');

    const reservation = await this.prisma.reservation.findFirst({
      where: { id: reservationId, venueId, deletedAt: null },
    });
    if (!reservation) throw new NotFoundException('Reservation not found');

    // Validate every table belongs to this venue's active floor plan so a
    // caller can't attach a reservation to another venue's (or a stale) table.
    const validTableIds = await this.getActivePlanTableIds(venueId);
    const unknown = tableIds.filter((id) => !validTableIds.has(id));
    if (unknown.length) throw new BadRequestException('One or more tables are not on this venue\'s floor plan');

    const holdType = options.holdType === 'seated' ? 'seated' : 'reserved';
    const startsAt = options.startsAt ? new Date(options.startsAt) : reservation.reservationTime;
    const endsAt = options.endsAt ? new Date(options.endsAt) : new Date(reservation.reservationTime.getTime() + reservation.durationMinutes * 60 * 1000);
    if (!Number.isFinite(startsAt.getTime()) || !Number.isFinite(endsAt.getTime()) || endsAt <= startsAt) throw new BadRequestException('Invalid seating window');
    let priorTableIds: string[] = [];
    const now = new Date();
    // A 'seated' hold means a party is physically at the table right now, but
    // the host screen sends the reservation's *scheduled* window, so seating a
    // 19:00 party at 18:30 (or a very late one at 21:00) hands us a window that
    // does not cover this moment. Slide it to start now, keeping the booked
    // duration: every other consumer — merge, refreshTableStates, the floor
    // reads — selects assignments with startsAt <= now < endsAt, so persisting
    // the scheduled window would leave the row disagreeing with the seated
    // state written from it. A 'reserved' hold keeps its window and waits.
    let effectiveStartsAt = startsAt;
    let effectiveEndsAt = endsAt;
    if (holdType === 'seated' && !(startsAt <= now && endsAt > now)) {
      effectiveStartsAt = now;
      effectiveEndsAt = new Date(now.getTime() + (endsAt.getTime() - startsAt.getTime()));
    }
    const occupiesTableNow = effectiveStartsAt <= now && effectiveEndsAt > now;

    // Release prior assignments for THIS reservation, then check each requested
    // table for active overlaps from OTHER reservations, then create the new
    // holds — all inside a Serializable transaction so two managers can't
    // simultaneously assign overlapping holds to the same table.
    await withSerializableRetry(this.prisma, async (tx) => {
      const priorAssignments = await tx.tableAssignment.findMany({
        where: { venueId, reservationId, releasedAt: null },
        select: { tableId: true },
      });
      priorTableIds = priorAssignments.map((a) => a.tableId);

      await tx.tableAssignment.updateMany({
        where: { venueId, reservationId, releasedAt: null },
        data: { releasedAt: new Date(), releasedReason: 'reassigned' },
      });
      const conflict = await tx.tableAssignment.findFirst({
        where: {
          venueId,
          tableId: { in: tableIds },
          releasedAt: null,
          startsAt: { lt: effectiveEndsAt },
          endsAt: { gt: effectiveStartsAt },
          NOT: { reservationId },
        },
        select: { tableId: true },
      });
      if (conflict) {
        throw new ConflictException(`Table ${conflict.tableId} is already booked for this time window`);
      }
      for (const tableId of tableIds) {
        await tx.tableAssignment.create({
          data: {
            venueId,
            reservationId,
            tableId,
            holdType,
            startsAt: effectiveStartsAt,
            endsAt: effectiveEndsAt,
          },
        });
      }
      if (occupiesTableNow) {
        await tx.tableState.updateMany({ where: { venueId, tableId: { in: tableIds } }, data: {
          status: holdType === 'seated' ? 'seated' : 'reserved',
          partySize: reservation.partySize,
          seatedAt: holdType === 'seated' ? effectiveStartsAt : null,
          lastActivityAt: new Date(),
        } });
        if (holdType === 'seated') {
          await tx.reservation.update({ where: { id: reservation.id }, data: { status: 'seated' } });
        }
      }
    });

    const tablesToRefresh = Array.from(new Set([
      ...priorTableIds.filter((id) => !tableIds.includes(id)),
      ...(!occupiesTableNow ? tableIds : []),
    ]));
    if (tablesToRefresh.length) {
      await this.refreshTableStates(venueId, tablesToRefresh);
    }
    return { ok: true };
  }

  async assignWaitlistToTables(venueId: string, body: {
    waitlistId: string;
    tableIds: string[];
    holdType?: string;
    startsAt?: number;
    endsAt?: number;
  }) {
    if (!body.tableIds.length) throw new BadRequestException('No tables specified');

    const waitlist = await this.prisma.waitlist.findFirst({
      where: { id: body.waitlistId, venueId, status: { in: ['waiting', 'assigned'] } },
    });
    if (!waitlist) throw new NotFoundException('Waitlist entry not found');

    const validTableIds = await this.getActivePlanTableIds(venueId);
    const unknown = body.tableIds.filter((id) => !validTableIds.has(id));
    if (unknown.length) throw new BadRequestException('One or more tables are not on this venue\'s floor plan');

    const startsAt = body.startsAt ? new Date(body.startsAt) : new Date();
    const endsAt = body.endsAt ? new Date(body.endsAt) : new Date(startsAt.getTime() + 120 * 60 * 1000);
    if (!Number.isFinite(startsAt.getTime()) || !Number.isFinite(endsAt.getTime()) || endsAt <= startsAt) {
      throw new BadRequestException('Invalid seating window');
    }

    let priorTableIds: string[] = [];
    const now = new Date();
    // Same rule as reservations: anything but an explicit 'held' hold is a
    // party sitting down now, and its window is slid to match. startsAt here
    // comes from the client's clock, so a device running seconds ahead of the
    // server must not silently fail to seat.
    let effectiveStartsAt = startsAt;
    let effectiveEndsAt = endsAt;
    if (body.holdType !== 'held' && !(startsAt <= now && endsAt > now)) {
      effectiveStartsAt = now;
      effectiveEndsAt = new Date(now.getTime() + (endsAt.getTime() - startsAt.getTime()));
    }
    const occupiesTableNow = effectiveStartsAt <= now && effectiveEndsAt > now;

    await withSerializableRetry(this.prisma, async (tx) => {
      const conflict = await tx.tableAssignment.findFirst({
        where: {
          venueId,
          tableId: { in: body.tableIds },
          releasedAt: null,
          startsAt: { lt: effectiveEndsAt },
          endsAt: { gt: effectiveStartsAt },
          NOT: { waitlistId: body.waitlistId },
        },
        select: { tableId: true },
      });
      if (conflict) {
        throw new ConflictException(`Table ${conflict.tableId} is already booked for this time window`);
      }
      const priorAssignments = await tx.tableAssignment.findMany({
        where: { venueId, waitlistId: body.waitlistId, releasedAt: null },
        select: { tableId: true },
      });
      priorTableIds = priorAssignments.map((a) => a.tableId);

      await tx.tableAssignment.updateMany({
        where: { venueId, waitlistId: body.waitlistId, releasedAt: null },
        data: { releasedAt: new Date(), releasedReason: 'reassigned' },
      });
      for (const tableId of body.tableIds) {
        await tx.tableAssignment.create({
          data: {
            venueId,
            waitlistId: body.waitlistId,
            tableId,
            holdType: (body.holdType ?? 'seated') as any,
            startsAt: effectiveStartsAt,
            endsAt: effectiveEndsAt,
          },
        });
      }
      await tx.waitlist.update({
        where: { id: waitlist.id },
        data: { status: body.holdType === 'held' ? 'assigned' : 'seated', readyAt: new Date() },
      });
      if (occupiesTableNow) {
        await tx.tableState.updateMany({
          where: { venueId, tableId: { in: body.tableIds } },
          data: {
            status: body.holdType === 'held' ? 'held' : 'seated',
            partySize: waitlist.partySize,
            seatedAt: body.holdType === 'held' ? null : effectiveStartsAt,
            lastActivityAt: new Date(),
          },
        });
      }
    });

    const tablesToRefresh = Array.from(new Set([
      ...priorTableIds.filter((id) => !body.tableIds.includes(id)),
      ...(!occupiesTableNow ? body.tableIds : []),
    ]));
    if (tablesToRefresh.length) {
      await this.refreshTableStates(venueId, tablesToRefresh);
    }
    return { ok: true };
  }

  async releaseAssignment(venueId: string, id: string) {
    const assignment = await this.prisma.tableAssignment.findFirst({
      where: { venueId, id, releasedAt: null },
      select: { id: true, tableId: true, reservationId: true, waitlistId: true },
    });
    const tableIds = assignment ? [assignment.tableId] : [id];
    const released = assignment
      ? await this.prisma.tableAssignment.updateMany({
          where: { venueId, id: assignment.id, releasedAt: null },
          data: { releasedAt: new Date(), releasedReason: 'manual' },
        })
      : await this.prisma.tableAssignment.updateMany({
          where: { venueId, tableId: id, releasedAt: null },
          data: { releasedAt: new Date(), releasedReason: 'manual' },
        });
    if (released.count === 0) throw new NotFoundException('Assignment not found');
    await this.refreshTableStates(venueId, tableIds);

    if (assignment?.reservationId) {
      const activeLeft = await this.prisma.tableAssignment.count({
        where: { venueId, reservationId: assignment.reservationId, releasedAt: null },
      });
      if (activeLeft === 0) {
        const r = await this.prisma.reservation.findFirst({
          where: { id: assignment.reservationId, venueId },
          select: { status: true },
        });
        if (r && r.status === 'seated') {
          await this.prisma.reservation.update({
            where: { id: assignment.reservationId },
            data: { status: 'completed' },
          });
        }
      }
    }
    if (assignment?.waitlistId) {
      const activeLeft = await this.prisma.tableAssignment.count({
        where: { venueId, waitlistId: assignment.waitlistId, releasedAt: null },
      });
      if (activeLeft === 0) {
        const w = await this.prisma.waitlist.findFirst({
          where: { id: assignment.waitlistId, venueId },
          select: { status: true },
        });
        // A seated party leaving is done. An 'assigned' party was only held or
        // called — releasing that table cancels the hold, it does not seat and
        // finish them, so they go back in the queue. Completing them here made
        // them vanish from getOpenWaitlist, the only list with a Seat action,
        // and left re-seating throwing NotFound.
        if (w?.status === 'seated') {
          await this.prisma.waitlist.update({
            where: { id: assignment.waitlistId },
            data: { status: 'completed' },
          });
        } else if (w?.status === 'assigned') {
          await this.prisma.waitlist.update({
            where: { id: assignment.waitlistId },
            data: { status: 'waiting', readyAt: null },
          });
        }
      }
    }
    // Find seats freed up by the released table so we can match a waitlist
    // entry whose party fits. Best-effort; fire-and-forget so the manager
    // action returns immediately.
    const table = await this.prisma.floorTable.findFirst({ where: { id: tableIds[0], floorPlan: { venueId } }, select: { seats: true } });
    if (table && table.seats > 0) {
      void this.notifier.notifyNextWaitlist(venueId, table.seats);
    }
    return { ok: true };
  }

  emptyStats() {
    return {
      totalTables: 0,
      occupiedTables: 0,
      availableTables: 0,
      dirtyCleaning: 0,
      occupiedCount: 0,
      availableCount: 0,
      dirtyCount: 0,
      waitlistSize: 0,
      avgTurnTimeMinutes: 0,
      longestSeatedDurationMinutes: 0,
    };
  }

  private async getActivePlanTableIds(venueId: string) {
    const plan = await this.prisma.floorPlan.findFirst({
      where: { venueId, isActive: true },
      include: { tables: { select: { id: true } } },
    });
    return new Set((plan?.tables ?? []).map((table) => table.id));
  }

  private async refreshTableStates(venueId: string, tableIds: string[]) {
    await refreshTableStates(this.prisma, venueId, tableIds);
  }

  private mapAssignment(
    assignment: {
      id: string;
      waitlistId: string | null;
      reservationId: string | null;
      holdType: string;
      startsAt: Date;
      endsAt: Date;
      reservation?: {
        guestName: string;
        partySize: number;
        source: string;
        tags: string[];
        specialRequests: string | null;
        status: string;
      } | null;
    },
    waitlistById: Map<string, { guestName: string; partySize: number; source: string; notes: string | null; status: string }>,
  ) {
    const waitlist = assignment.waitlistId ? waitlistById.get(assignment.waitlistId) : null;
    const reservation = assignment.reservation ?? null;
    return {
      assignmentId: assignment.id,
      holdType: assignment.holdType,
      sourceType: assignment.reservationId ? 'reservation' : 'waitlist',
      guestName: reservation?.guestName ?? waitlist?.guestName ?? 'Guest',
      partySize: reservation?.partySize ?? waitlist?.partySize ?? 0,
      source: reservation?.source ?? waitlist?.source ?? 'walk_in',
      tags: reservation?.tags ?? [],
      notes: reservation?.specialRequests ?? waitlist?.notes ?? null,
      status: reservation?.status ?? waitlist?.status ?? 'assigned',
      startsAt: assignment.startsAt.getTime(),
      endsAt: assignment.endsAt.getTime(),
    };
  }
}
