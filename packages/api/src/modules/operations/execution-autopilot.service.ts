import { Injectable } from '@nestjs/common';
import type { Prisma } from '@prisma/client';
import { PrismaService } from '../../prisma/prisma.service';

export type ExecutionWorkspaceInput = {
  venueId: string;
  sourceType: 'reservation' | 'beo' | 'venue-event';
  sourceId: string;
  title: string;
  startsAt: Date;
  endsAt: Date;
  setupStyle?: string | null;
  vendorNames?: string[];
};

@Injectable()
export class ExecutionAutopilotService {
  constructor(private readonly prisma: PrismaService) {}

  async ensureWorkspace(input: ExecutionWorkspaceInput, transaction?: Prisma.TransactionClient) {
    const db = transaction ?? this.prisma;
    const workspace = await db.eventExecutionWorkspace.upsert({
      where: {
        venueId_sourceType_sourceId: {
          venueId: input.venueId,
          sourceType: input.sourceType,
          sourceId: input.sourceId,
        },
      },
      update: { title: input.title },
      create: {
        venueId: input.venueId,
        sourceType: input.sourceType,
        sourceId: input.sourceId,
        title: input.title,
      },
    });
    // A late retry must not recreate actionable tasks for a cancelled event.
    // Keep the archived workspace and its history intact.
    if (workspace.isArchived) return workspace;
    const setup = input.setupStyle?.trim() || 'event space';
    const tasks = [
      { templateKey: 'event-brief', title: `Review ${input.title} event brief`, department: 'approvals', dueAt: input.startsAt },
      { templateKey: 'room-setup', title: `Complete ${setup} setup`, department: 'setup', dueAt: new Date(input.startsAt.getTime() - 2 * 60 * 60_000) },
      { templateKey: 'staffing-coverage', title: `Confirm staffing coverage for ${input.title}`, department: 'staffing', dueAt: new Date(input.startsAt.getTime() - 60 * 60_000) },
    ];
    await Promise.all(tasks.map((task) => db.eventExecutionTask.upsert({
      where: { workspaceId_templateKey: { workspaceId: workspace.id, templateKey: task.templateKey } },
      update: { title: task.title, department: task.department, dueAt: task.dueAt },
      create: { venueId: input.venueId, workspaceId: workspace.id, ...task },
    })));
    const timeline = [
      { templateKey: 'room-ready', title: 'Room setup complete', startsAt: new Date(input.startsAt.getTime() - 2 * 60 * 60_000) },
      { templateKey: 'doors', title: 'Doors / guest arrival', startsAt: input.startsAt },
      { templateKey: 'breakdown', title: 'Breakdown complete', startsAt: input.endsAt },
    ];
    await Promise.all(timeline.map((item) => db.eventExecutionTimelineItem.upsert({
      where: { workspaceId_templateKey: { workspaceId: workspace.id, templateKey: item.templateKey } },
      update: { title: item.title, startsAt: item.startsAt },
      create: { venueId: input.venueId, workspaceId: workspace.id, ...item },
    })));
    const vendorNames = [...new Set((input.vendorNames ?? []).map((name) => name.trim()).filter(Boolean))];
    if (input.vendorNames !== undefined) {
      const vendors = vendorNames.map((name, index) => ({
        templateKey: `vendor-${index}`,
        name,
        dueAt: new Date(input.startsAt.getTime() - 90 * 60_000),
      }));
      await Promise.all(vendors.map((vendor) => db.eventExecutionVendor.upsert({
        where: { workspaceId_templateKey: { workspaceId: workspace.id, templateKey: vendor.templateKey } },
        update: { name: vendor.name, dueAt: vendor.dueAt },
        create: { venueId: input.venueId, workspaceId: workspace.id, ...vendor },
      })));
      await db.eventExecutionVendor.deleteMany({
        where: { workspaceId: workspace.id, templateKey: { startsWith: 'vendor-', notIn: vendors.map((vendor) => vendor.templateKey) } },
      });
    }
    return workspace;
  }
}
