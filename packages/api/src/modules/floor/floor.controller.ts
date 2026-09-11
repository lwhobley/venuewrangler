import {
  Body,
  Controller,
  Delete,
  ForbiddenException,
  Get,
  Param,
  Patch,
  Post,
  Query,
} from '@nestjs/common';
import {
  ArrayMaxSize,
  IsArray,
  IsIn,
  IsInt,
  IsNumber,
  IsOptional,
  IsString,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';
import { Type } from 'class-transformer';
import { canManageVenue } from '../../auth/roles';
import { RequireSubscription } from '../../billing/require-subscription.decorator';
import { VenueScope } from '../../venue/venue-scope.decorator';
import type { VenueScopedRequest } from '../../venue/venue-scope.interceptor';
import { FloorService } from './floor.service';

type Scope = VenueScopedRequest['venueScope'];

const TABLE_SHAPES = ['round', 'square', 'rect', 'booth'] as const;
const TABLE_STATUSES = ['available', 'seated', 'dirty', 'reserved', 'held', 'out_of_service'] as const;
const HOLD_TYPES = ['reserved', 'held', 'seated'] as const;

class TableChairDto {
  @IsNumber()
  x!: number;

  @IsNumber()
  y!: number;

  @IsNumber()
  rotation!: number;

  @IsString()
  @IsOptional()
  @MaxLength(50)
  label?: string;
}

class TableDto {
  @IsString()
  @IsOptional()
  @MaxLength(64)
  id?: string;

  @IsString()
  @MaxLength(50)
  label!: string;

  @IsNumber()
  x!: number;

  @IsNumber()
  y!: number;

  @IsNumber()
  width!: number;

  @IsNumber()
  height!: number;

  @IsString()
  @IsIn(TABLE_SHAPES)
  shape!: string;

  @IsString()
  @IsOptional()
  @MaxLength(100)
  section?: string;

  @IsInt()
  @Min(1)
  capacity!: number;

  @IsString()
  @IsOptional()
  @MaxLength(50)
  seatLabelStyle?: string;

  @IsNumber()
  @IsOptional()
  rotation?: number;

  @IsInt()
  @IsOptional()
  minSpend?: number;

  @IsOptional()
  isReservable?: boolean;

  @IsArray()
  @ArrayMaxSize(20)
  @ValidateNested({ each: true })
  @Type(() => TableChairDto)
  @IsOptional()
  chairs?: TableChairDto[];
}

// Generous ceiling on the number of tables/chairs a single floor plan save can
// carry — real venues top out in the low hundreds. Without this a payload
// under the 1mb body limit could still hold thousands of tables, each driving
// its own sequential write inside one locked transaction (see floor.service).
const MAX_FLOOR_PLAN_TABLES = 500;

class SaveFloorPlanDto {
  @IsString()
  @IsOptional()
  @MaxLength(100)
  name?: string;

  @IsNumber()
  @IsOptional()
  width?: number;

  @IsNumber()
  @IsOptional()
  height?: number;

  @IsString()
  @IsOptional()
  @MaxLength(2000)
  backgroundImageUrl?: string | null;

  @IsArray()
  @ArrayMaxSize(MAX_FLOOR_PLAN_TABLES)
  @ValidateNested({ each: true })
  @Type(() => TableDto)
  tables!: TableDto[];

  @IsArray()
  @ArrayMaxSize(MAX_FLOOR_PLAN_TABLES * 20)
  @ValidateNested({ each: true })
  @Type(() => TableChairDto)
  @IsOptional()
  chairs?: TableChairDto[];
}

class AddWaitlistDto {
  @IsString()
  @MaxLength(200)
  guestName!: string;

  @IsInt()
  @Min(1)
  partySize!: number;

  @IsString()
  @IsOptional()
  @MaxLength(50)
  phone?: string;

  @IsString()
  @IsOptional()
  @MaxLength(255)
  email?: string;

  @IsString()
  @IsOptional()
  @MaxLength(1000)
  notes?: string;
}

class TableStatusDto {
  @IsString()
  @IsIn(TABLE_STATUSES)
  status!: string;
}

class AssignReservationDto {
  @IsString()
  @MaxLength(64)
  reservationId!: string;

  @IsArray()
  @ArrayMaxSize(20)
  @IsString({ each: true })
  @MaxLength(64, { each: true })
  tableIds!: string[];

  @IsString()
  @IsIn(HOLD_TYPES)
  @IsOptional()
  holdType?: string;

  @IsNumber()
  @IsOptional()
  startsAt?: number;

  @IsNumber()
  @IsOptional()
  endsAt?: number;
}

class AssignWaitlistDto {
  @IsString()
  @MaxLength(64)
  waitlistId!: string;

  @IsArray()
  @ArrayMaxSize(20)
  @IsString({ each: true })
  @MaxLength(64, { each: true })
  tableIds!: string[];

  @IsString()
  @IsIn(HOLD_TYPES)
  @IsOptional()
  holdType?: string;

  @IsNumber()
  @IsOptional()
  startsAt?: number;

  @IsNumber()
  @IsOptional()
  endsAt?: number;
}

class MergeTablesDto {
  @IsArray()
  @ArrayMaxSize(20)
  @IsString({ each: true })
  @MaxLength(64, { each: true })
  tableIds!: string[];

  @IsInt()
  @Min(1)
  @IsOptional()
  partySize?: number;
}

/** Attribution for the two destructive floor actions any member can perform. */
function actorOf(scope: NonNullable<Scope>) {
  return { profileId: scope.profileId, fullName: scope.fullName, role: scope.role };
}

// Table states a non-manager may set from the floor screen. Seating, holds and
// out-of-service are manager decisions or come from the assignment flows.
const STAFF_TABLE_STATUSES = new Set<string>(['available', 'dirty']);

function requireManager(scope: Scope): asserts scope is NonNullable<Scope> {
  if (!scope || !canManageVenue(scope.role, scope.allAccess)) throw new ForbiddenException('Not authorized');
}

@Controller('v1/floor')
export class FloorController {
  constructor(private readonly floor: FloorService) {}

  @RequireSubscription('active')
  @Get('active')
  async getActiveFloorPlan(@VenueScope() scope: Scope) {
    if (!scope) return null;
    return this.floor.getActiveFloorPlan(scope.venueId);
  }

  @RequireSubscription('active')
  @Get('stats')
  async getFloorStats(@VenueScope() scope: Scope) {
    if (!scope) return this.floor.emptyStats();
    return this.floor.getFloorStats(scope.venueId);
  }

  @RequireSubscription('active')
  @Post()
  async saveFloorPlan(@VenueScope() scope: Scope, @Body() body: SaveFloorPlanDto) {
    requireManager(scope);
    return this.floor.saveFloorPlan(scope.venueId, body);
  }

  @RequireSubscription('active')
  @Delete()
  async clearActiveFloorPlan(@VenueScope() scope: Scope) {
    requireManager(scope);
    return this.floor.clearActiveFloorPlan(scope.venueId);
  }

  @RequireSubscription('active')
  @Get('unassigned-reservations')
  async getUnassignedReservations(@VenueScope() scope: Scope, @Query('withinMinutes') withinMinutes?: string) {
    if (!scope) return [];
    return this.floor.getUnassignedReservations(scope.venueId, withinMinutes);
  }

  @RequireSubscription('active')
  @Get('waitlist')
  async getOpenWaitlist(@VenueScope() scope: Scope) {
    if (!scope) return [];
    const entries = await this.floor.getOpenWaitlist(scope.venueId);
    // Any member can see who's on the list to seat them, but guest phone and
    // free-text notes are only for managers -- not every host/server shift.
    if (canManageVenue(scope.role, scope.allAccess)) return entries;
    return entries.map((e) => ({ ...e, phone: null, notes: null }));
  }

  @RequireSubscription('active')
  @Post('waitlist')
  async addToWaitlist(@VenueScope() scope: Scope, @Body() body: AddWaitlistDto) {
    if (!scope) throw new ForbiddenException('No venue profile found');
    return this.floor.addToWaitlist(scope.venueId, body);
  }

  @RequireSubscription('active')
  @Delete('waitlist/:id')
  async removeFromWaitlist(@VenueScope() scope: Scope, @Param('id') id: string) {
    if (!scope) throw new ForbiddenException('No venue profile found');
    return this.floor.removeFromWaitlist(scope.venueId, id, actorOf(scope));
  }

  @RequireSubscription('active')
  @Patch('waitlist/:id/ready')
  async markWaitlistReady(@VenueScope() scope: Scope, @Param('id') id: string) {
    if (!scope) throw new ForbiddenException('No venue profile found');
    return this.floor.markWaitlistReady(scope.venueId, id);
  }

  @RequireSubscription('active')
  @Patch('tables/:id/status')
  async updateTableStatus(@VenueScope() scope: Scope, @Param('id') id: string, @Body() body: TableStatusDto) {
    if (!scope) throw new ForbiddenException('No venue profile found');
    // Staff run the floor during service, so bussing states stay open to them.
    // Everything else on this route (out_of_service in particular) is a
    // manager-only control the staff screen hides, and the hide was the only
    // thing enforcing it — an altered request reached the service directly.
    if (!STAFF_TABLE_STATUSES.has(body.status)) requireManager(scope);
    return this.floor.updateTableStatus(scope.venueId, id, body.status, actorOf(scope));
  }

  @RequireSubscription('active')
  @Post('tables/merge')
  async mergeTablesForParty(@VenueScope() scope: Scope, @Body() body: MergeTablesDto) {
    requireManager(scope);
    return this.floor.mergeTablesForParty(scope.venueId, body.tableIds, body.partySize);
  }

  @RequireSubscription('active')
  @Post('tables/merge-groups/:id/split')
  async splitMergedTables(@VenueScope() scope: Scope, @Param('id') mergeGroupId: string) {
    requireManager(scope);
    return this.floor.splitMergedTables(scope.venueId, mergeGroupId);
  }

  @RequireSubscription('active')
  @Post('assign-reservation')
  async assignReservationToTables(@VenueScope() scope: Scope, @Body() body: AssignReservationDto) {
    requireManager(scope);
    return this.floor.assignReservationToTables(scope.venueId, body.reservationId, body.tableIds, body);
  }

  @RequireSubscription('active')
  @Post('assign-waitlist')
  async assignWaitlistToTables(@VenueScope() scope: Scope, @Body() body: AssignWaitlistDto) {
    requireManager(scope);
    return this.floor.assignWaitlistToTables(scope.venueId, body);
  }

  @RequireSubscription('active')
  @Delete('assignments/:id')
  async releaseAssignment(@VenueScope() scope: Scope, @Param('id') id: string) {
    requireManager(scope);
    return this.floor.releaseAssignment(scope.venueId, id);
  }
}
