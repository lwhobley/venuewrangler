import { BadRequestException } from '@nestjs/common';

type Unit = { dimension: 'volume' | 'weight' | 'count'; toBase: number };

// Canonical units are millilitres, grams, and individual pieces. Item-level
// pack sizes (e.g. one 750 ml bottle) are kept separately from recipe units.
const UNITS: Record<string, Unit> = {
  ml: { dimension: 'volume', toBase: 1 }, milliliter: { dimension: 'volume', toBase: 1 }, milliliters: { dimension: 'volume', toBase: 1 },
  l: { dimension: 'volume', toBase: 1000 }, liter: { dimension: 'volume', toBase: 1000 }, liters: { dimension: 'volume', toBase: 1000 },
  floz: { dimension: 'volume', toBase: 29.5735295625 }, 'fl oz': { dimension: 'volume', toBase: 29.5735295625 }, 'fluid ounce': { dimension: 'volume', toBase: 29.5735295625 }, 'fluid ounces': { dimension: 'volume', toBase: 29.5735295625 },
  tsp: { dimension: 'volume', toBase: 4.92892159375 }, teaspoon: { dimension: 'volume', toBase: 4.92892159375 }, teaspoons: { dimension: 'volume', toBase: 4.92892159375 },
  tbsp: { dimension: 'volume', toBase: 14.78676478125 }, tablespoon: { dimension: 'volume', toBase: 14.78676478125 }, tablespoons: { dimension: 'volume', toBase: 14.78676478125 },
  cup: { dimension: 'volume', toBase: 236.5882365 }, cups: { dimension: 'volume', toBase: 236.5882365 },
  pt: { dimension: 'volume', toBase: 473.176473 }, pint: { dimension: 'volume', toBase: 473.176473 }, pints: { dimension: 'volume', toBase: 473.176473 },
  qt: { dimension: 'volume', toBase: 946.352946 }, quart: { dimension: 'volume', toBase: 946.352946 }, quarts: { dimension: 'volume', toBase: 946.352946 },
  gal: { dimension: 'volume', toBase: 3785.411784 }, gallon: { dimension: 'volume', toBase: 3785.411784 }, gallons: { dimension: 'volume', toBase: 3785.411784 },
  g: { dimension: 'weight', toBase: 1 }, gram: { dimension: 'weight', toBase: 1 }, grams: { dimension: 'weight', toBase: 1 },
  kg: { dimension: 'weight', toBase: 1000 }, kilogram: { dimension: 'weight', toBase: 1000 }, kilograms: { dimension: 'weight', toBase: 1000 },
  mg: { dimension: 'weight', toBase: 0.001 }, milligram: { dimension: 'weight', toBase: 0.001 }, milligrams: { dimension: 'weight', toBase: 0.001 },
  oz: { dimension: 'weight', toBase: 28.349523125 }, 'ounce weight': { dimension: 'weight', toBase: 28.349523125 },
  lb: { dimension: 'weight', toBase: 453.59237 }, lbs: { dimension: 'weight', toBase: 453.59237 }, pound: { dimension: 'weight', toBase: 453.59237 }, pounds: { dimension: 'weight', toBase: 453.59237 },
  each: { dimension: 'count', toBase: 1 }, ea: { dimension: 'count', toBase: 1 }, piece: { dimension: 'count', toBase: 1 }, pieces: { dimension: 'count', toBase: 1 },
};

export function normalizeUnit(unit: string): string {
  const normalized = unit.trim().toLowerCase().replace(/\./g, '').replace(/\s+/g, ' ');
  return normalized === 'fl. oz' ? 'fl oz' : normalized;
}

export function unitDefinition(unit: string): Unit {
  const key = normalizeUnit(unit);
  const found = UNITS[key];
  if (!found) throw new BadRequestException(`Unsupported inventory unit: ${unit}`);
  return found;
}

export function convertQuantity(quantity: number, fromUnit: string, toUnit: string): number {
  if (!Number.isFinite(quantity) || quantity < 0) throw new BadRequestException('Quantity must be a finite non-negative number');
  const from = unitDefinition(fromUnit);
  const to = unitDefinition(toUnit);
  if (from.dimension !== to.dimension) throw new BadRequestException(`Cannot convert ${fromUnit} to ${toUnit}`);
  const converted = quantity * from.toBase / to.toBase;
  if (!Number.isFinite(converted)) throw new BadRequestException('Converted quantity is outside the supported range');
  return converted;
}

export const CANONICAL_UNIT: Record<Unit['dimension'], string> = { volume: 'ml', weight: 'g', count: 'each' };
