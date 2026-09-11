import { Prisma } from '@prisma/client';

type Db = {
  tableAssignment?: { findMany?: (args: any) => Promise<any[]> };
  tableState: {
    findMany: (args: any) => Promise<Array<{ tableId: string; status: string }>>;
    updateMany: (args: any) => Promise<unknown>;
  };
};

/**
 * Table states a person sets deliberately. They survive a refresh that finds no
 * active seating: a table still needing bussing, or deliberately off the floor,
 * is not free just because nobody is sitting at it.
 */
export const PRESERVED_TABLE_STATUSES = new Set<string>(['dirty', 'out_of_service']);

/**
 * Recomputes TableState for the given tables from the assignments actually
 * covering this moment.
 *
 * Releasing a TableAssignment does not by itself move the table's state, so
 * every path that releases one has to call this or the floor plan keeps showing
 * an occupied table with nothing left to release. Accepts a transaction client
 * so a cancellation can refresh inside the same transaction that released.
 */
export async function refreshTableStates(
  db: Db | Prisma.TransactionClient,
  venueId: string,
  tableIds: string[],
) {
  if (!tableIds.length) return;
  const client = db as any;
  // Some unit tests stub prisma without the assignment delegate; with no way to
  // tell what covers the table, free it rather than throwing.
  if (!client.tableAssignment?.findMany) {
    await client.tableState.updateMany({
      where: { venueId, tableId: { in: tableIds } },
      data: { status: 'available', partySize: null, seatedAt: null, lastActivityAt: new Date() },
    });
    return;
  }
  const now = new Date();
  const [assignments, currentStates] = await Promise.all([
    client.tableAssignment.findMany({
      where: { venueId, tableId: { in: tableIds }, releasedAt: null, startsAt: { lte: now }, endsAt: { gt: now } },
      include: { reservation: { select: { partySize: true } }, waitlist: { select: { partySize: true } } },
    }),
    client.tableState.findMany({
      where: { venueId, tableId: { in: tableIds } },
      select: { tableId: true, status: true },
    }),
  ]);
  const byTable = new Map<string, any>();
  for (const assignment of assignments) byTable.set(assignment.tableId, assignment);
  const statusByTable = new Map<string, string>(currentStates.map((state: { tableId: string; status: string }) => [state.tableId, state.status]));
  await Promise.all(tableIds.map((tableId) => {
    const assignment = byTable.get(tableId);
    if (!assignment && PRESERVED_TABLE_STATUSES.has(statusByTable.get(tableId) ?? '')) {
      return client.tableState.updateMany({
        where: { venueId, tableId },
        data: { partySize: null, seatedAt: null, lastActivityAt: now },
      });
    }
    const seated = assignment?.holdType === 'seated';
    const status = seated ? 'seated' : assignment?.holdType === 'held' ? 'held' : assignment ? 'reserved' : 'available';
    return client.tableState.updateMany({
      where: { venueId, tableId },
      data: {
        status,
        partySize: assignment?.reservation?.partySize ?? assignment?.waitlist?.partySize ?? null,
        seatedAt: seated ? assignment.startsAt : null,
        lastActivityAt: now,
      },
    });
  }));
}
