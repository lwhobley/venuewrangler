import React, { act } from 'react';
import { createRoot } from 'test-renderer';
import { describe, expect, it, vi } from 'vitest';
import {
  AgingCard,
  MovementTimeline,
  PurchaseOrderCard,
  ShrinkageCard,
  VelocityCard,
} from '../../components/bar-stock/InventoryCards';

const state = vi.hoisted(() => ({
  movementsData: {
    itemName: 'Gin',
    movements: [
      {
        _id: 'm1',
        movementType: 'received',
        quantity: 12,
        previousOnHand: 2,
        nextOnHand: 14,
        createdAt: 1725800000000,
        createdBy: 'Alex',
        notes: 'Delivery #44',
      },
      {
        _id: 'm2',
        movementType: 'waste',
        quantity: 1,
        previousOnHand: 14,
        nextOnHand: 13,
        createdAt: 1725805000000,
        createdBy: 'Sam',
        notes: 'Broken bottle',
      },
    ],
  } as any,
}));

vi.mock('react-native', () => {
  const R = require('react');
  return {
    View: ({ children, style }: any) => R.createElement('View', { style }, children),
  };
});

vi.mock('react-native-paper', () => {
  const R = require('react');
  const element = (type: string) => ({ children, ...props }: any) =>
    R.createElement(type, props, children);
  const Card = Object.assign(element('Card'), { Content: element('Card.Content') });
  return {
    Button: ({ children, onPress, ...props }: any) =>
      R.createElement('button', { onClick: onPress, ...props }, children),
    Card,
    Chip: element('Chip'),
    Text: element('Text'),
  };
});

vi.mock('../../lib/railway-api', () => ({
  api: {
    barInventory: {
      getItemMovements: 'getItemMovements',
    },
  },
}));

vi.mock('../../lib/railway-hooks', () => ({
  useQuery: (ref: string) => (ref === 'getItemMovements' ? state.movementsData : undefined),
}));

vi.mock('../../lib/theme', () => ({
  accents: [
    { bg: '#e0f2fe', fg: '#0369a1' },
    { bg: '#fef3c7', fg: '#b45309' },
    { bg: '#dcfce7', fg: '#15803d' },
  ],
  colors: {
    primary: '#007aff',
    surface: '#fff',
    background: '#f9f9f9',
    muted: '#777',
    border: '#eee',
    charcoal: '#222',
    danger: '#ff3b30',
    warning: '#ff9500',
    success: '#34c759',
  },
  spacing: { sm: 8, md: 16 },
}));

function output(r: ReturnType<typeof createRoot>) {
  return JSON.stringify(r.container.toJSON());
}

describe('Bar Stock Inventory Cards', () => {
  describe('MovementTimeline', () => {
    it('renders loading state when movements are pending', async () => {
      state.movementsData = null;
      const r = createRoot();
      await act(async () => r.render(<MovementTimeline itemId="item-1" />));
      expect(output(r)).toContain('Loading history...');
    });

    it('renders empty notice when no movements exist', async () => {
      state.movementsData = { itemName: 'Gin', movements: [] };
      const r = createRoot();
      await act(async () => r.render(<MovementTimeline itemId="item-1" />));
      expect(output(r)).toContain('No movements recorded yet.');
    });

    it('renders list of movement rows with notes and users', async () => {
      state.movementsData = {
        itemName: 'Gin',
        movements: [
          {
            _id: 'm1',
            movementType: 'received',
            quantity: 12,
            previousOnHand: 2,
            nextOnHand: 14,
            createdAt: 1725800000000,
            createdBy: 'Alex',
            notes: 'Delivery #44',
          },
        ],
      };
      const r = createRoot();
      await act(async () => r.render(<MovementTimeline itemId="item-1" />));
      const json = output(r);
      expect(json).toContain('Received');
      expect(json).toContain('+12');
      expect(json).toContain('Delivery #44');
      expect(json).toContain('Alex');
    });
  });

  describe('VelocityCard', () => {
    it('returns null when velocity array is empty or zero', async () => {
      const r = createRoot();
      await act(async () => r.render(<VelocityCard velocity={[]} />));
      expect(r.container.toJSON()?.children).toEqual([]);
    });

    it('renders items with urgency pills based on daysUntilEmpty', async () => {
      const velocity = [
        {
          _id: 'v1',
          name: 'Vodka',
          category: 'spirits',
          onHand: 8,
          parLevel: 12,
          perWeek: 14,
          unit: 'btl',
          usageLast4Weeks: 56,
          daysUntilEmpty: 4, // urgent
        },
        {
          _id: 'v2',
          name: 'Tequila',
          category: 'spirits',
          onHand: 12,
          parLevel: 10,
          perWeek: 7,
          unit: 'btl',
          usageLast4Weeks: 28,
          daysUntilEmpty: 12, // warning
        },
      ];

      const r = createRoot();
      await act(async () => r.render(<VelocityCard velocity={velocity} />));
      const json = output(r);
      expect(json).toContain('Usage velocity');
      expect(json).toContain('Vodka');
      expect(json).toContain('4d left');
      expect(json).toContain('Tequila');
      expect(json).toContain('12d left');
    });
  });

  describe('ShrinkageCard', () => {
    it('renders loading when data is null', async () => {
      const r = createRoot();
      await act(async () => r.render(<ShrinkageCard data={null} />));
      expect(output(r)).toContain('Loading...');
    });

    it('renders empty notice when rows are empty', async () => {
      const r = createRoot();
      await act(async () =>
        r.render(<ShrinkageCard data={{ rows: [], totals: { totalShrinkageCents: 0 } } as any} />),
      );
      expect(output(r)).toContain('No waste or comp movements recorded');
    });

    it('renders shrinkage rows and total cost', async () => {
      const data: any = {
        rows: [
          {
            category: 'liquor',
            totalShrinkageCents: 4500,
            shrinkagePct: 18,
            wasteUnits: 2,
            compUnits: 1,
            receivedUnits: 20,
          },
        ],
        totals: { totalShrinkageCents: 4500 },
      };
      const r = createRoot();
      await act(async () => r.render(<ShrinkageCard data={data} />));
      const json = output(r);
      expect(json).toContain('liquor');
      expect(json).toContain('"18"');
      expect(json).toContain('"%"');
      expect(json).toContain('Total shrinkage cost');
    });
  });

  describe('PurchaseOrderCard', () => {
    it('renders items below par, supports CSV toggle, and triggers email callback', async () => {
      const onToggleCsv = vi.fn();
      const onEmail = vi.fn();
      const po: any = {
        itemCount: 1,
        groups: [
          {
            supplier: 'Allied Beverage',
            lines: [
              {
                _id: 'l1',
                name: 'Tequila Blanco',
                isPredictive: true,
                sku: 'TB-100',
                onHand: 1,
                parLevel: 5,
                dailyVelocity: 1,
                predictedDemand: 7,
                qtyToOrder: 4,
                unit: 'case',
                lineTotalCents: 12000,
              },
            ],
            groupTotalCents: 12000,
          },
        ],
        grandTotalCents: 12000,
      };

      const r = createRoot();
      await act(async () => {
        r.render(
          <PurchaseOrderCard
            purchaseOrder={po}
            csv="Item,Qty\nTequila,4"
            showCsv={true}
            busy={false}
            onToggleCsv={onToggleCsv}
            onEmail={onEmail}
          />,
        );
      });

      const json = output(r);
      expect(json).toContain('SMART BOOST');
      expect(json).toContain('Allied Beverage');
      expect(json).toContain('Tequila,4');

      const buttons = r.container.queryAll((n) => n.type === 'button');
      const csvBtn = buttons.find((b) => JSON.stringify(b.children).includes('Hide CSV'));
      const emailBtn = buttons.find((b) => JSON.stringify(b.children).includes('Email PO'));

      await act(async () => csvBtn?.props.onClick());
      expect(onToggleCsv).toHaveBeenCalled();

      await act(async () => emailBtn?.props.onClick());
      expect(onEmail).toHaveBeenCalled();
    });
  });

  describe('AgingCard', () => {
    it('renders uncounted and stagnant inventory items', async () => {
      const report: any = {
        uncountedItems: [
          { _id: 'i1', name: 'Rare Whiskey', daysSinceCount: 14 },
        ],
        noActivityItems: [
          { _id: 'i2', name: 'Bitters', onHand: 10 },
        ],
        staleCostItems: [
          { _id: 'i3', name: 'Triple Sec' },
        ],
      };

      const r = createRoot();
      await act(async () => r.render(<AgingCard report={report} />));
      const json = output(r);
      expect(json).toContain('not counted in 7+ days');
      expect(json).toContain('Rare Whiskey');
      expect(json).toContain('Bitters');
      expect(json).toContain('10');
      expect(json).toContain('on hand');
      expect(json).toContain('Triple Sec');
    });
  });
});
