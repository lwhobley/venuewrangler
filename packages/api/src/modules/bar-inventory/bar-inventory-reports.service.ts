import { Injectable } from '@nestjs/common';
import { PrismaService } from '../../prisma/prisma.service';
import { csvCell, csvDocument } from '../../common/csv';

/** Escapes a POS/inventory name so it can be embedded in a RegExp literally. */
function escapeRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Matches `name` as a whole phrase inside a larger string.
 *
 * \b only asserts a boundary next to a word character, so it never matches a
 * name that starts or ends with punctuation — "#9 Gin" or "Amaro (Nonino)"
 * would score zero velocity forever. Asserting "no word character adjacent"
 * instead behaves the same for ordinary names and works for these too.
 */
function wholePhraseRegExp(name: string) {
  return new RegExp(`(?<!\\w)${escapeRegExp(name)}(?!\\w)`, 'i');
}

/** Word tokens used to pre-filter match candidates. */
function nameTokens(value: string) {
  return value.match(/[a-z0-9]+/gi)?.map((token) => token.toLowerCase()) ?? [];
}

/**
 * Read-only bar-inventory analytics extracted from BarInventoryController.
 *
 * Demonstrates the controller -> service decomposition pattern (review item #5):
 * the controller stays responsible for routing + auth (it resolves venueId via
 * requireManagerProfile), and passes that venueId into these pure data methods.
 * Behaviour is unchanged — bodies are moved verbatim, only the venueId resolution
 * is lifted out.
 */
@Injectable()
export class BarInventoryReportsService {
  constructor(private readonly prisma: PrismaService) {}

  // ── Shrinkage / variance report (30-day waste+comp by category) ──────
  async shrinkageReport(venueId: string) {
    const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
    const [movements, items] = await Promise.all([
      this.prisma.barInventoryMovement.findMany({
        where: { venueId, createdAt: { gte: thirtyDaysAgo } },
        select: { itemId: true, movementType: true, quantity: true, createdAt: true },
      }),
      this.prisma.barInventoryItem.findMany({
        where: { venueId },
        select: { id: true, category: true, name: true, unitCostCents: true },
      }),
    ]);
    const itemMap = new Map(items.map((i) => [i.id, i]));

    const byCategory = new Map<string, { received: number; waste: number; comp: number; wasteCents: number; compCents: number }>();
    const initCat = () => ({ received: 0, waste: 0, comp: 0, wasteCents: 0, compCents: 0 });

    for (const m of movements) {
      const item = itemMap.get(m.itemId);
      if (!item) continue;
      const cat = item.category;
      const entry = byCategory.get(cat) ?? initCat();
      const costCents = item.unitCostCents ?? 0;
      if (m.movementType === 'received') {
        entry.received += Math.abs(m.quantity);
      } else if (m.movementType === 'waste') {
        entry.waste += Math.abs(m.quantity);
        entry.wasteCents += Math.abs(m.quantity) * costCents;
      } else if (m.movementType === 'comp') {
        entry.comp += Math.abs(m.quantity);
        entry.compCents += Math.abs(m.quantity) * costCents;
      }
      byCategory.set(cat, entry);
    }

    const rows = Array.from(byCategory.entries()).map(([category, data]) => {
      const totalShrinkage = data.waste + data.comp;
      const shrinkagePct = data.received > 0 ? Math.round((totalShrinkage / data.received) * 1000) / 10 : null;
      return {
        category,
        receivedUnits: Math.round(data.received * 10) / 10,
        wasteUnits: Math.round(data.waste * 10) / 10,
        compUnits: Math.round(data.comp * 10) / 10,
        totalShrinkageUnits: Math.round(totalShrinkage * 10) / 10,
        shrinkagePct,
        wasteCents: Math.round(data.wasteCents),
        compCents: Math.round(data.compCents),
        totalShrinkageCents: Math.round(data.wasteCents + data.compCents),
      };
    }).sort((a, b) => (b.totalShrinkageCents) - (a.totalShrinkageCents));

    const totals = rows.reduce((acc, r) => ({
      receivedUnits: acc.receivedUnits + r.receivedUnits,
      totalShrinkageUnits: acc.totalShrinkageUnits + r.totalShrinkageUnits,
      totalShrinkageCents: acc.totalShrinkageCents + r.totalShrinkageCents,
    }), { receivedUnits: 0, totalShrinkageUnits: 0, totalShrinkageCents: 0 });

    return { rows, totals, windowDays: 30 };
  }

  // ── Purchase order draft (below-par items grouped by supplier with AI POS Sync velocity) ──
  async purchaseOrder(venueId: string) {
    const [items, posChecks] = await Promise.all([
      this.prisma.barInventoryItem.findMany({
        where: { venueId },
        orderBy: [{ supplier: 'asc' }, { name: 'asc' }],
      }),
      this.prisma.posCheck.findMany({
        where: { venueId, openedAt: { gte: new Date(Date.now() - 30 * 24 * 60 * 60 * 1000) } },
        select: { menuItems: true },
      }),
    ]);

    // Parse POS sales
    const salesMap = new Map<string, number>();
    for (const check of posChecks) {
      if (!check.menuItems) continue;
      try {
        const checkItems = typeof check.menuItems === 'string' ? JSON.parse(check.menuItems) : check.menuItems;
        if (Array.isArray(checkItems)) {
          for (const ci of checkItems) {
            const name = String(ci.name ?? '').toLowerCase().trim();
            const qty = Number(ci.quantity ?? 1);
            salesMap.set(name, (salesMap.get(name) ?? 0) + qty);
          }
        }
      } catch (e) {
        // ignore JSON parse error
      }
    }

    // Single-attribution: each sold POS item credits AT MOST ONE best-matching inventory item.
    // Loose substring matching (like .includes()) could erroneously credit "Gin" to "Ginger Ale", "Ginger Beer", etc.
    const inventoryVelocityMap = new Map<string, number>();
    // Each item's word-boundary pattern is compiled once here, not once per
    // (sold name x item) pair: this runs over the venue's whole item list and
    // 30 days of check lines, neither of which is row-capped.
    const normalizedItems = items.map((item, index) => {
      const lower = item.name.toLowerCase().trim();
      return { item, index, lower, wordRegex: wholePhraseRegExp(lower), tokens: nameTokens(lower) };
    });
    const itemsByExactName = new Map(normalizedItems.map((ni) => [ni.lower, ni]));
    // Any phrase match in either direction shares at least one word with the
    // sold name, so this index narrows the scan from the whole item list to a
    // handful per check line.
    const itemsByToken = new Map<string, typeof normalizedItems>();
    // A name with no word characters at all indexes under no token, so it has
    // to stay in every candidate set or it could never match.
    const tokenlessItems = normalizedItems.filter((ni) => ni.tokens.length === 0);
    for (const ni of normalizedItems) {
      for (const token of new Set(ni.tokens)) {
        const bucket = itemsByToken.get(token);
        if (bucket) bucket.push(ni);
        else itemsByToken.set(token, [ni]);
      }
    }

    for (const [soldName, qty] of salesMap.entries()) {
      if (!soldName || qty <= 0) continue;
      // 1. Exact match
      let bestItem = itemsByExactName.get(soldName);
      // 2. If no exact match, try matching by word boundary
      if (!bestItem) {
        const soldRegex = wholePhraseRegExp(soldName);
        const nearby = new Set<(typeof normalizedItems)[number]>(tokenlessItems);
        for (const token of new Set(nameTokens(soldName))) {
          for (const ni of itemsByToken.get(token) ?? []) nearby.add(ni);
        }
        const candidates = [...nearby]
          .filter((ni) => ni.wordRegex.test(soldName) || soldRegex.test(ni.lower))
          // Restore item order so an equal-length tie resolves the same way it
          // would have when this scanned the item list directly.
          .sort((a, b) => a.index - b.index);
        if (candidates.length === 1) {
          bestItem = candidates[0];
        } else if (candidates.length > 1) {
          // Longest name wins: "gin" and "gin fizz" both match a "Gin Fizz"
          // sale, and the more specific item is the one actually poured.
          bestItem = candidates.reduce((a, b) => (b.lower.length > a.lower.length ? b : a));
        }
      }
      if (bestItem) {
        inventoryVelocityMap.set(bestItem.item.id, (inventoryVelocityMap.get(bestItem.item.id) ?? 0) + qty);
      }
    }

    const getVelocity = (idOrName: string) => {
      const byId = inventoryVelocityMap.get(idOrName);
      if (byId !== undefined) return Number((byId / 30).toFixed(2));
      const found = itemsByExactName.get(idOrName.toLowerCase().trim());
      if (found) {
        return Number(((inventoryVelocityMap.get(found.item.id) ?? 0) / 30).toFixed(2));
      }
      return 0;
    };

    const belowPar = items.filter((i) => i.onHand < i.parLevel || getVelocity(i.id) > 0);

    const bySupplier = new Map<string, typeof belowPar>();
    for (const item of belowPar) {
      const supplier = item.supplier?.trim() || 'Unspecified';
      const group = bySupplier.get(supplier) ?? [];
      group.push(item);
      bySupplier.set(supplier, group);
    }

    const groups = Array.from(bySupplier.entries()).map(([supplier, groupItems]) => {
      const lines = groupItems.map((item) => {
        const velocity = getVelocity(item.id);
        const predictedDemand = Math.ceil(velocity * 7);
        const baseQty = Math.max(0, Math.ceil(item.parLevel - item.onHand));
        const smartQty = Math.max(0, Math.ceil(item.parLevel - (item.onHand - predictedDemand)));
        const qtyToOrder = Math.max(baseQty, smartQty);
        
        return {
          _id: item.id,
          name: item.name,
          sku: item.sku,
          unit: item.unit,
          onHand: item.onHand,
          parLevel: item.parLevel,
          dailyVelocity: velocity,
          predictedDemand,
          qtyToOrder,
          unitCostCents: item.unitCostCents,
          lineTotalCents: item.unitCostCents != null ? Math.round(qtyToOrder * item.unitCostCents) : null,
          isPredictive: smartQty > baseQty,
        };
      });
      const groupTotalCents = lines.reduce((sum, l) => sum + (l.lineTotalCents ?? 0), 0);
      return { supplier, lines, groupTotalCents };
    });

    const grandTotalCents = groups.reduce((sum, g) => sum + g.groupTotalCents, 0);
    return { groups, grandTotalCents, itemCount: belowPar.length };
  }

  // ── Purchase order CSV ───────────────────────────────────────────────
  async purchaseOrderCsv(venueId: string) {
    const po = await this.purchaseOrder(venueId);
    const headers = [
      'Supplier', 'Item', 'SKU', 'Unit', 'On Hand', 'Par',
      'Daily Velocity (units/day)', 'Predicted 7-Day Demand', 'Suggested Order Qty',
      'Unit Cost ($)', 'Line Total ($)', 'Predictive Boost'
    ];
    const rows = [headers.map(csvCell).join(',')];
    
    for (const group of po.groups) {
      for (const line of group.lines) {
        const unitCost = line.unitCostCents != null ? (line.unitCostCents / 100).toFixed(2) : '';
        const lineTotal = line.lineTotalCents != null ? (line.lineTotalCents / 100).toFixed(2) : '';
        rows.push([
          csvCell(group.supplier),
          csvCell(line.name),
          csvCell(line.sku ?? ''),
          csvCell(line.unit),
          csvCell(line.onHand),
          csvCell(line.parLevel),
          csvCell(line.dailyVelocity),
          csvCell(line.predictedDemand),
          csvCell(line.qtyToOrder),
          csvCell(unitCost),
          csvCell(lineTotal),
          csvCell(line.isPredictive ? 'YES' : 'NO'),
        ].join(','));
      }
    }
    return csvDocument(rows);
  }

  // ── Stock aging report ───────────────────────────────────────────────
  async agingReport(venueId: string) {
    const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);
    const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);

    const [items, recentMovements] = await Promise.all([
      this.prisma.barInventoryItem.findMany({ where: { venueId } }),
      this.prisma.barInventoryMovement.findMany({
        where: { venueId, createdAt: { gte: thirtyDaysAgo } },
        select: { itemId: true, movementType: true, createdAt: true },
      }),
    ]);

    const lastMovedAt = new Map<string, Date>();
    for (const m of recentMovements) {
      const prev = lastMovedAt.get(m.itemId);
      if (!prev || m.createdAt > prev) lastMovedAt.set(m.itemId, m.createdAt);
    }

    const uncounted = items.filter((i) => !i.lastCountedAt || i.lastCountedAt < sevenDaysAgo);
    const noActivity = items.filter((i) => !lastMovedAt.get(i.id));
    const staleCost = items.filter((i) => i.unitCostCents == null && i.onHand > 0);

    return {
      uncountedItems: uncounted.map((i) => ({
        _id: i.id,
        name: i.name,
        category: i.category,
        lastCountedAt: i.lastCountedAt?.getTime() ?? null,
        daysSinceCount: i.lastCountedAt ? Math.floor((Date.now() - i.lastCountedAt.getTime()) / 86400000) : null,
      })),
      noActivityItems: noActivity.map((i) => ({ _id: i.id, name: i.name, category: i.category, onHand: i.onHand })),
      staleCostItems: staleCost.map((i) => ({ _id: i.id, name: i.name, category: i.category, onHand: i.onHand })),
    };
  }
}
