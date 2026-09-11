import { describe, expect, it, vi } from 'vitest';
import { ExecutionAutopilotService } from './execution-autopilot.service';

describe('ExecutionAutopilotService', () => {
  it('does not regenerate operational work for an archived workspace', async () => {
    const workspace = { id: 'workspace-cancelled', isArchived: true };
    const prisma = {
      eventExecutionWorkspace: { upsert: vi.fn().mockResolvedValue(workspace) },
      eventExecutionTask: { upsert: vi.fn() },
      eventExecutionTimelineItem: { upsert: vi.fn() },
      eventExecutionVendor: { upsert: vi.fn(), deleteMany: vi.fn() },
    } as any;

    const result = await new ExecutionAutopilotService(prisma).ensureWorkspace({
      venueId: 'venue-1', sourceType: 'reservation', sourceId: 'reservation-1', title: 'Cancelled event',
      startsAt: new Date('2026-09-03T18:00:00Z'), endsAt: new Date('2026-09-03T22:00:00Z'),
    });

    expect(result).toBe(workspace);
    expect(prisma.eventExecutionTask.upsert).not.toHaveBeenCalled();
    expect(prisma.eventExecutionTimelineItem.upsert).not.toHaveBeenCalled();
    expect(prisma.eventExecutionVendor.upsert).not.toHaveBeenCalled();
  });

  it('reconciles stable template rows without resetting user state', async () => {
    const prisma = {
      eventExecutionWorkspace: { upsert: vi.fn().mockResolvedValue({ id: 'workspace-1' }) },
      eventExecutionTask: { upsert: vi.fn().mockResolvedValue({}) },
      eventExecutionTimelineItem: { upsert: vi.fn().mockResolvedValue({}) },
      eventExecutionVendor: { upsert: vi.fn().mockResolvedValue({}), deleteMany: vi.fn().mockResolvedValue({ count: 0 }) },
    } as any;
    const service = new ExecutionAutopilotService(prisma);
    const input = {
      venueId: 'venue-1',
      sourceType: 'reservation' as const,
      sourceId: 'reservation-1',
      title: 'Launch Party',
      startsAt: new Date('2026-08-01T18:00:00Z'),
      endsAt: new Date('2026-08-01T22:00:00Z'),
      setupStyle: 'cocktail',
      vendorNames: ['Production Co', 'Production Co'],
    };

    await service.ensureWorkspace(input);

    expect(prisma.eventExecutionTask.upsert).toHaveBeenCalledTimes(3);
    expect(prisma.eventExecutionTask.upsert).toHaveBeenCalledWith(expect.objectContaining({
      where: { workspaceId_templateKey: { workspaceId: 'workspace-1', templateKey: 'event-brief' } },
      update: { title: 'Review Launch Party event brief', department: 'approvals', dueAt: input.startsAt },
    }));
    expect(prisma.eventExecutionTimelineItem.upsert).toHaveBeenCalledTimes(3);
    expect(prisma.eventExecutionVendor.upsert).toHaveBeenCalledWith(expect.objectContaining({
      where: { workspaceId_templateKey: { workspaceId: 'workspace-1', templateKey: 'vendor-0' } },
      update: expect.objectContaining({ name: 'Production Co' }),
    }));
    expect(prisma.eventExecutionVendor.deleteMany).toHaveBeenCalledWith({
      where: { workspaceId: 'workspace-1', templateKey: { startsWith: 'vendor-', notIn: ['vendor-0'] } },
    });
  });

  it('does not create a synthetic vendor when no vendor data exists', async () => {
    const prisma = {
      eventExecutionWorkspace: { upsert: vi.fn().mockResolvedValue({ id: 'workspace-1' }) },
      eventExecutionTask: { upsert: vi.fn().mockResolvedValue({}) },
      eventExecutionTimelineItem: { upsert: vi.fn().mockResolvedValue({}) },
      eventExecutionVendor: { upsert: vi.fn(), deleteMany: vi.fn() },
    } as any;
    const service = new ExecutionAutopilotService(prisma);

    await service.ensureWorkspace({
      venueId: 'venue-1', sourceType: 'beo', sourceId: 'beo-1', title: 'Gala',
      startsAt: new Date('2026-08-01T18:00:00Z'), endsAt: new Date('2026-08-01T22:00:00Z'),
    });

    expect(prisma.eventExecutionVendor.upsert).not.toHaveBeenCalled();
    expect(prisma.eventExecutionVendor.deleteMany).not.toHaveBeenCalled();
  });
});
