import { describe, expect, it } from 'vitest';
import { formatOperatorResult } from './wrangler-result-format';

describe('formatOperatorResult', () => {
  it('describes a shaped result instead of collapsing to Done', () => {
    // Regression (E10): LIST_INVENTORY answers with named collections and no
    // name of its own, so the old formatter fell through to "Done." — Wrangler
    // found the records and the manager was shown nothing.
    const result = formatOperatorResult({
      inventory: [
        { id: 'i1', name: 'Rye', onHand: 4, isLow: true },
        { id: 'i2', name: 'Gin', onHand: 11, isLow: false },
      ],
      eightySixItems: [{ id: 'p1', title: 'Oysters', station: 'Raw bar' }],
    });

    expect(result).toContain('Inventory (2)');
    expect(result).toContain('• Rye — on hand: 4');
    expect(result).toContain('Eighty Six Items (1)');
    expect(result).toContain('• Oysters');
    expect(result).not.toBe('Done.');
  });

  it('names an empty collection rather than staying silent about it', () => {
    expect(formatOperatorResult({ inventory: [] })).toContain('No matching records found.');
  });

  it('says how many rows were not shown', () => {
    const rows = Array.from({ length: 12 }, (_, i) => ({ name: `Item ${i}` }));
    expect(formatOperatorResult(rows)).toContain('…and 4 more');
  });

  it('still renders a single named record and an empty list', () => {
    expect(formatOperatorResult({ guestName: 'Ana', partySize: 4 })).toBe('• Ana — party 4');
    expect(formatOperatorResult([])).toBe('No matching records found.');
  });

  it('falls back to Done only when there is genuinely nothing to report', () => {
    expect(formatOperatorResult(null)).toBe('Done.');
    expect(formatOperatorResult({})).toBe('Done.');
  });
});
