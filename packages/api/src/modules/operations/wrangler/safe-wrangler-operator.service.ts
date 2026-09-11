import { BadRequestException, ConflictException, ForbiddenException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { canManageVenue } from '../../../auth/roles';
import { PrismaService } from '../../../prisma/prisma.service';
import { InventoryMovementService } from '../../bar-inventory/inventory-movement.service';
import { ReservationMutationService } from '../../reservations/reservation-mutation.service';
import { SchedulingAssignmentService } from '../../scheduling/scheduling-assignment.service';
import { weekStartFor } from '../../../common/pay-period';
import { normalizedShiftEnd } from '../../../common/venue-time';
import { WranglerOperatorService, type OperatorTool } from './wrangler-operator.service';

/**
 * Which execution path each operator tool takes.
 *
 *  - 'strict' : re-validated and re-executed here through the domain services,
 *               with every argument type-checked and the venue re-resolved.
 *  - 'parser' : handled by WranglerOperatorService, which validates against
 *               ALLOWED_TOOLS and normalises through resolveWritePlan. Still
 *               guarded — ADD_STAFF blocks non-owners from minting a manager,
 *               REMOVE_STAFF enforces canManageRole — just not re-checked here.
 *
 * Typed as an exhaustive Record over OperatorTool on purpose: adding a tool to
 * ALLOWED_TOOLS without classifying it is a compile error rather than a silent
 * downgrade to the weaker path.
 */
export const SAFE_TOOL_ROUTING: Record<OperatorTool, 'strict' | 'parser'> = {
  CREATE_RESERVATION: 'strict',
  UPDATE_RESERVATION: 'strict',
  CREATE_SHIFT: 'strict',
  UPDATE_SHIFT: 'strict',
  ASSIGN_SHIFT: 'strict',
  CORRECT_PUNCH: 'strict',

  FIND_RESERVATION: 'parser',
  CANCEL_RESERVATION: 'parser',
  LIST_SCHEDULE: 'parser',
  CLEAR_TABLE: 'parser',
  UPDATE_TABLE_STATUS: 'parser',
  LIST_WAITLIST: 'parser',
  ADD_WAITLIST: 'parser',
  FIND_CRM_LEAD: 'parser',
  CREATE_CRM_LEAD: 'parser',
  UPDATE_CRM_LEAD: 'parser',
  SEARCH_CHAT: 'parser',
  POST_CHAT_ANNOUNCEMENT: 'parser',
  LIST_INVENTORY: 'parser',
  UPDATE_ITEM_86: 'parser',
  UPDATE_BAR_STOCK: 'parser',
  GET_SALES_PULSE: 'parser',
  LIST_INTEGRATIONS: 'parser',
  FIND_STAFF: 'parser',
  ADD_STAFF: 'parser',
  REMOVE_STAFF: 'parser',
  LIST_CLOCKS: 'parser',
};

@Injectable()
export class SafeWranglerOperatorService {
  private readonly parser: WranglerOperatorService;
  private readonly logger = new Logger(SafeWranglerOperatorService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly reservations: ReservationMutationService,
    private readonly scheduling: SchedulingAssignmentService,
    inventory?: InventoryMovementService,
  ) {
    this.parser = new WranglerOperatorService(prisma, inventory);
  }

  async plan(input: any): Promise<any> {
    const result: any = await this.parser.plan(input);
    if (result?.status === 'confirmation_required' && result?.tool === 'CORRECT_PUNCH') {
      const entryId = result?.plan?.args?.entryId;
      if (entryId) {
        const entry = await this.prisma.timeEntry.findFirst({ where: { id: String(entryId), venueId: input.venueId }, select: { updatedAt: true } });
        if (entry) result.plan.args.expectedUpdatedAt = entry.updatedAt.toISOString();
      }
    }
    return result;
  }

  async execute(input: any): Promise<any> {
    if (!canManageVenue(input?.actor?.role, input?.actor?.allAccess)) {
      throw new ForbiddenException('Manager access required for Wrangler operator actions');
    }
    const tool = String(input.plan?.tool ?? '');
    // Routing is an exhaustive map rather than an inline allowlist so that a
    // tool added to ALLOWED_TOOLS fails to compile until someone classifies it.
    // The previous `if (!list.includes(tool)) return this.parser.execute(...)`
    // defaulted new tools to the LESS validated path silently — nothing was
    // exploitable, but the default pointed the wrong way.
    if (SAFE_TOOL_ROUTING[tool as OperatorTool] !== 'strict') {
      return this.parser.execute(input);
    }
    const args = { ...(input.plan?.args ?? {}) };
    let result: any;

    if (tool === 'CREATE_RESERVATION') {
      const saved = await this.reservations.saveReservation({
        venueId: input.venueId,
        guestName: this.text(args.guestName, 'Guest name is required'),
        partySize: this.positiveInt(args.partySize, 'partySize'),
        reservationTime: this.date(args.reservationTime, 'Reservation time is required').toISOString(),
        durationMinutes: args.durationMinutes == null ? 90 : this.positiveInt(args.durationMinutes, 'durationMinutes'),
        notes: typeof args.notes === 'string' ? args.notes : undefined,
        status: 'confirmed', source: 'direct',
      });
      result = saved.reservation;
    } else if (tool === 'UPDATE_RESERVATION') {
      const id = this.text(args.reservationId, 'reservationId is required');
      const old = await this.prisma.reservation.findFirst({ where: { id, venueId: input.venueId, deletedAt: null } });
      if (!old) throw new NotFoundException('Reservation no longer exists');
      const status = args.status == null ? old.status : this.reservationStatus(args.status);
      const saved = await this.reservations.saveReservation({
        venueId: input.venueId, reservationId: old.id, guestName: old.guestName,
        partySize: args.partySize == null ? old.partySize : this.positiveInt(args.partySize, 'partySize'),
        reservationTime: args.reservationTime == null ? old.reservationTime.toISOString() : this.date(args.reservationTime, 'Invalid reservation time').toISOString(),
        durationMinutes: old.durationMinutes, status, notes: args.notes == null ? old.notes ?? undefined : String(args.notes), source: old.source,
        tags: old.tags, specialRequests: old.specialRequests ?? undefined, phone: old.guestPhone ?? undefined, email: old.guestEmail ?? undefined,
      });
      result = saved.reservation;
    } else if (tool === 'CREATE_SHIFT') {
      const date = this.text(args.date, 'Shift date is required (YYYY-MM-DD)');
      if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new BadRequestException('Date must be YYYY-MM-DD');
      const startMinutes = this.shiftStart(args.startMinutes);
      const endMinutes = this.shiftEnd(startMinutes, args.endMinutes);
      result = await this.scheduling.createShift({
        venueId: input.venueId,
        weekStart: weekStartFor(date),
        dayIndex: new Date(`${date}T12:00:00Z`).getUTCDay(),
        ...(args.profileId ? { profileId: this.text(args.profileId, 'profileId is required') } : {}),
        startMinutes,
        endMinutes,
        jobTitle: typeof args.jobTitle === 'string' ? args.jobTitle : 'Server',
        station: typeof args.station === 'string' ? args.station : 'Floor',
      });
    } else if (tool === 'UPDATE_SHIFT') {
      const id = this.text(args.shiftId, 'shiftId is required');
      const old = await this.prisma.scheduleShift.findFirst({ where: { id, venueId: input.venueId } });
      if (!old) throw new NotFoundException('Shift no longer exists');
      const startMinutes = args.startMinutes == null ? old.startMinutes : this.shiftStart(args.startMinutes);
      const endMinutes = args.endMinutes == null ? old.endMinutes : this.shiftEnd(startMinutes, args.endMinutes);
      await this.scheduling.updateShift({ venueId: input.venueId, shiftId: old.id, dayIndex: old.dayIndex, startMinutes, endMinutes,
        jobTitle: args.jobTitle == null ? old.jobTitle : this.text(args.jobTitle, 'jobTitle is required'), station: args.station == null ? old.station : this.text(args.station, 'station is required'), notes: old.notes ?? undefined });
      result = await this.prisma.scheduleShift.findUniqueOrThrow({ where: { id: old.id } });
    } else if (tool === 'ASSIGN_SHIFT') {
      const shiftId = this.text(args.shiftId, 'shiftId is required');
      const profileId = this.text(args.profileId, 'profileId is required');
      await this.scheduling.assignShift({ venueId: input.venueId, shiftId, profileId });
      result = await this.prisma.scheduleShift.findUniqueOrThrow({ where: { id: shiftId } });
    } else if (tool === 'CORRECT_PUNCH') {
      const entryId = this.text(args.entryId, 'entryId is required');
      const expectedUpdatedAt = this.date(args.expectedUpdatedAt, 'Punch changed since preview. Review the latest timecard before correcting it.');
      const old = await this.prisma.timeEntry.findFirst({ where: { id: entryId, venueId: input.venueId } });
      if (!old) throw new NotFoundException('Time entry no longer exists');
      const clockInAt = args.clockInAt == null ? old.clockInAt : this.date(args.clockInAt, 'Invalid clock-in');
      const clockOutAt = args.clockOutAt == null ? old.clockOutAt : this.date(args.clockOutAt, 'Invalid clock-out');
      if (clockOutAt && clockOutAt <= clockInAt) throw new BadRequestException('Clock-out must be after clock-in');
      const changed = await this.prisma.timeEntry.updateMany({ where: { id: old.id, venueId: input.venueId, updatedAt: expectedUpdatedAt }, data: { clockInAt, clockOutAt, isOpen: clockOutAt == null } });
      if (!changed.count) throw new ConflictException('Punch changed since Wrangler reviewed it. Review the latest timecard before correcting it.');
      result = await this.prisma.timeEntry.findUniqueOrThrow({ where: { id: old.id } });
    }

    try {
      await this.prisma.auditLog.create({ data: { venueId: input.venueId, actorProfileId: input.actor.profileId, actorName: input.actor.fullName,
        actorRole: input.actor.role, entityType: 'wrangler_operator', entityId: String(result?.id ?? tool), action: `wrangler_operator_${tool.toLowerCase()}`,
        summary: String(input.plan?.summary ?? tool), metadata: { tool, safeDomainService: true } as any } });
    } catch (error) {
      // Do not make a completed operation look failed and invite a retry.
      this.logger.error(`Wrangler operator audit failed for ${tool}`, error);
    }
    return { ok: true, tool, risk: tool === 'CORRECT_PUNCH' ? 'sensitive_write' : 'operational_write', result };
  }

  private text(value: unknown, message: string) { const v = typeof value === 'string' ? value.trim() : ''; if (!v) throw new BadRequestException(message); return v; }
  private positiveInt(value: unknown, field: string) { const n = Number(value); if (!Number.isInteger(n) || n < 1) throw new BadRequestException(`${field} must be a positive whole number`); return n; }
  private shiftStart(value: unknown) { const n = Number(value); if (!Number.isInteger(n) || n < 0 || n > 1439) throw new BadRequestException('startMinutes must be between 0 and 1439'); return n; }
  private shiftEnd(startMinutes: number, value: unknown) {
    const raw = Number(value);
    if (!Number.isInteger(raw) || raw < 0 || raw > 2880) throw new BadRequestException('endMinutes must be between 0 and 2880');
    const end = normalizedShiftEnd(startMinutes, raw);
    if (end <= startMinutes || end > 2880 || end - startMinutes > 1440) throw new BadRequestException('Shift must end after it starts and cannot exceed 24 hours');
    return end;
  }
  private date(value: unknown, message: string) { const d = new Date(String(value ?? '')); if (Number.isNaN(d.getTime())) throw new BadRequestException(message); return d; }
  private reservationStatus(value: unknown) {
    const status = this.text(value, 'Invalid reservation status');
    if (!['requested', 'confirmed', 'checked_in', 'seated', 'completed', 'no_show', 'cancelled'].includes(status)) {
      throw new BadRequestException('Invalid reservation status');
    }
    return status;
  }
}
