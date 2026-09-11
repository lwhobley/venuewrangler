/**
 * Seed Enish Houston under admin@venuewrangler.com (all-access).
 *
 * Usage (from packages/api):
 *   ALLOW_PRODUCTION_DB=true CONFIRM_ENISH_SEED=true npx tsx prisma/seed-enish-houston.ts
 */
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomInt } from 'node:crypto';
import {
  Prisma,
  PrismaClient,
  type Profile,
  type FloorTable,
  ReservationSource,
  ReservationStatus,
  WaitlistStatus,
  HoldType,
  TableStatus,
} from '@prisma/client';
import { assertAllowedHost, assertNotProduction } from '../scripts/database-target.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const API_DIR = resolve(HERE, '..');
const REPO_ROOT = resolve(API_DIR, '..', '..');
const URL_ENV_FILES = [
  join(REPO_ROOT, '.env.local'),
  join(API_DIR, '.env.local'),
  join(API_DIR, '.env'),
  join(REPO_ROOT, '.env'),
];

const ADMIN_EMAIL = 'admin@venuewrangler.com';
const VENUE_NAME = 'Enish Houston';
const TZ = 'America/Chicago';
const DEMO_NOTE = 'enish-demo-seed';
const STAFF_EMAIL_SUFFIX = '@enish.demo';
const GUEST_EMAIL_SUFFIX = '@guest.enish.demo';
const POS_PREFIX = 'enish-demo-';
const TAX_RATE = 0.0825;

const START_DATE = '2026-09-01';
const LAST_SALES_DATE = '2026-09-11';
const LAST_RESERVATION_DATE = '2026-09-19';
const WEEK_STARTS = ['2026-08-30', '2026-09-06', '2026-09-13'] as const;

function fromEnvFiles(key: string): string | undefined {
  for (const file of URL_ENV_FILES) {
    try {
      const line = readFileSync(file, 'utf8')
        .split(/\r?\n/)
        .find((candidate) => candidate.startsWith(`${key}=`));
      if (!line) continue;
      const value = line.slice(key.length + 1).trim().replace(/^"|"$/g, '');
      if (value) return value;
    } catch {
      // missing file
    }
  }
  return undefined;
}

function loadDatabaseUrl(): string {
  const databaseUrl = fromEnvFiles('DATABASE_URL') ?? process.env.DATABASE_URL;
  if (!databaseUrl) throw new Error('DATABASE_URL is required.');
  const guardEnv = {
    PRODUCTION_DB_FINGERPRINT:
      process.env.PRODUCTION_DB_FINGERPRINT ?? fromEnvFiles('PRODUCTION_DB_FINGERPRINT'),
    ALLOW_PRODUCTION_DB: process.env.ALLOW_PRODUCTION_DB ?? fromEnvFiles('ALLOW_PRODUCTION_DB'),
  };
  assertAllowedHost('DATABASE_URL', databaseUrl);
  assertNotProduction('DATABASE_URL', databaseUrl, guardEnv);
  return databaseUrl;
}

function mulberry32(seed: number) {
  let a = seed >>> 0;
  return () => {
    a += 0x6d2b79f5;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const rng = mulberry32(20260911);
function pick<T>(items: T[]): T {
  return items[Math.floor(rng() * items.length)]!;
}
function randInt(min: number, max: number): number {
  return min + Math.floor(rng() * (max - min + 1));
}
function jitter(base: number, pct: number): number {
  return Math.round(base * (1 + (rng() * 2 - 1) * pct));
}

function addDays(iso: string, days: number): string {
  const ms = Date.parse(`${iso}T00:00:00Z`) + days * 86400000;
  return new Date(ms).toISOString().slice(0, 10);
}
function eachDate(from: string, to: string): string[] {
  const out: string[] = [];
  for (let d = from; d <= to; d = addDays(d, 1)) out.push(d);
  return out;
}
function dayIndex(iso: string): number {
  return new Date(`${iso}T12:00:00Z`).getUTCDay();
}
function isLateNight(iso: string): boolean {
  const di = dayIndex(iso);
  return di === 4 || di === 5 || di === 6;
}
function zonedDate(date: string, hhmm: string): Date {
  const [h, m] = hhmm.split(':').map(Number);
  const utcGuess = Date.parse(`${date}T${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:00Z`);
  const dtf = new Intl.DateTimeFormat('en-US', {
    timeZone: TZ,
    hour12: false,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  });
  const asUtcWall = (ms: number) => {
    const parts = Object.fromEntries(
      dtf.formatToParts(new Date(ms)).filter((p) => p.type !== 'literal').map((p) => [p.type, p.value]),
    );
    return Date.UTC(
      Number(parts.year),
      Number(parts.month) - 1,
      Number(parts.day),
      Number(parts.hour) % 24,
      Number(parts.minute),
      Number(parts.second),
    );
  };
  let candidate = utcGuess;
  for (let i = 0; i < 3; i += 1) {
    const diff = asUtcWall(candidate) - utcGuess;
    if (diff === 0) break;
    candidate -= diff;
  }
  return new Date(candidate);
}

function makeVenueCode(): string {
  const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  let body = '';
  for (let i = 0; i < 10; i += 1) body += alphabet[randomInt(alphabet.length)];
  return `VW-${body}`;
}

type StaffSpec = { fullName: string; jobTitle: string; role: 'manager' | 'server' | 'staff'; gender: 'F' | 'M' };

const STAFF: StaffSpec[] = [
  { fullName: 'Aaliyah Washington', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Jasmine Robinson', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Imani Brooks', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Destiny Jackson', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Keisha Coleman', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Nia Freeman', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Shanice Bryant', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Tiana Simmons', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Amara Holloway', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Gabriela Garcia', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Sofia Martinez', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Camila Hernandez', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Valentina Lopez', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Lucia Gonzalez', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Mariana Perez', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Alejandra Ramirez', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Paloma Torres', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Marisol Flores', jobTitle: 'Server', role: 'server', gender: 'F' },
  { fullName: 'Simone Banks', jobTitle: 'Bartender', role: 'staff', gender: 'F' },
  { fullName: 'Dominique Booker', jobTitle: 'Bartender', role: 'staff', gender: 'F' },
  { fullName: 'Yesenia Diaz', jobTitle: 'Bartender', role: 'staff', gender: 'F' },
  { fullName: 'Daniela Reyes', jobTitle: 'Bartender', role: 'staff', gender: 'F' },
  { fullName: 'Marcus Jefferson', jobTitle: 'Bartender', role: 'staff', gender: 'M' },
  { fullName: 'Jamal Patterson', jobTitle: 'Bartender', role: 'staff', gender: 'M' },
  { fullName: 'Carlos Rivera', jobTitle: 'Bartender', role: 'staff', gender: 'M' },
  { fullName: 'Miguel Gomez', jobTitle: 'Bartender', role: 'staff', gender: 'M' },
  { fullName: 'Kenya Whitfield', jobTitle: 'Supervisor', role: 'manager', gender: 'F' },
  { fullName: 'Carmen Sanchez', jobTitle: 'Supervisor', role: 'manager', gender: 'F' },
  { fullName: 'Darius Griffin', jobTitle: 'Supervisor', role: 'manager', gender: 'M' },
  { fullName: 'Alejandro Morales', jobTitle: 'Supervisor', role: 'manager', gender: 'M' },
  { fullName: 'Bianca Ortiz', jobTitle: 'Barback', role: 'staff', gender: 'F' },
  { fullName: 'Malik Jenkins', jobTitle: 'Barback', role: 'staff', gender: 'M' },
  { fullName: 'Luis Gutierrez', jobTitle: 'Barback', role: 'staff', gender: 'M' },
  { fullName: 'Terrell Porter', jobTitle: 'Barback', role: 'staff', gender: 'M' },
  { fullName: 'Ashanti Dixon', jobTitle: 'Line Cook', role: 'staff', gender: 'F' },
  { fullName: 'Rosa Chavez', jobTitle: 'Line Cook', role: 'staff', gender: 'F' },
  { fullName: 'Elena Cruz', jobTitle: 'Line Cook', role: 'staff', gender: 'F' },
  { fullName: 'DeShawn Washington', jobTitle: 'Line Cook', role: 'staff', gender: 'M' },
  { fullName: 'Tyrone Jackson', jobTitle: 'Line Cook', role: 'staff', gender: 'M' },
  { fullName: 'Andre Coleman', jobTitle: 'Line Cook', role: 'staff', gender: 'M' },
  { fullName: 'Xavier Bryant', jobTitle: 'Line Cook', role: 'staff', gender: 'M' },
  { fullName: 'Jose Martinez', jobTitle: 'Line Cook', role: 'staff', gender: 'M' },
  { fullName: 'Diego Hernandez', jobTitle: 'Line Cook', role: 'staff', gender: 'M' },
  { fullName: 'Fernando Lopez', jobTitle: 'Line Cook', role: 'staff', gender: 'M' },
  { fullName: 'Tamika Patterson', jobTitle: 'Prep', role: 'staff', gender: 'F' },
  { fullName: 'Natalia Mendoza', jobTitle: 'Prep', role: 'staff', gender: 'F' },
  { fullName: 'Omari Freeman', jobTitle: 'Prep', role: 'staff', gender: 'M' },
  { fullName: 'Rafael Aguilar', jobTitle: 'Prep', role: 'staff', gender: 'M' },
  { fullName: 'Layla Jefferson', jobTitle: 'Host', role: 'staff', gender: 'F' },
  { fullName: 'Brianna Griffin', jobTitle: 'Host', role: 'staff', gender: 'F' },
  { fullName: 'Zaria Booker', jobTitle: 'Host', role: 'staff', gender: 'F' },
  { fullName: 'Isabella Rodriguez', jobTitle: 'Host', role: 'staff', gender: 'F' },
  { fullName: 'Esperanza Castillo', jobTitle: 'Host', role: 'staff', gender: 'F' },
  { fullName: 'Kendrick Simmons', jobTitle: 'Host', role: 'staff', gender: 'M' },
  { fullName: 'Andrea Ramos', jobTitle: 'Busser', role: 'staff', gender: 'F' },
  { fullName: 'Xiomara Mendoza', jobTitle: 'Busser', role: 'staff', gender: 'F' },
  { fullName: 'Jabari Holloway', jobTitle: 'Busser', role: 'staff', gender: 'M' },
  { fullName: 'Demetrius Banks', jobTitle: 'Busser', role: 'staff', gender: 'M' },
  { fullName: 'Hector Flores', jobTitle: 'Busser', role: 'staff', gender: 'M' },
  { fullName: 'Mateo Castillo', jobTitle: 'Busser', role: 'staff', gender: 'M' },
];

const STATIONS: Record<string, string> = {
  Server: 'Floor',
  Bartender: 'Bar',
  Supervisor: 'Floor',
  Barback: 'Bar',
  'Line Cook': 'Kitchen',
  Prep: 'Kitchen',
  Host: 'Host Stand',
  Busser: 'Floor',
};

const GUEST_FIRST = [
  'Aaliyah', 'Jasmine', 'Keisha', 'Imani', 'Nia', 'Destiny', 'Monique', 'Tiana', 'Amara', 'Simone',
  'Marcus', 'Jamal', 'Darius', 'Malik', 'Andre', 'Xavier', 'Kendrick', 'Omari', 'Terrell', 'Jabari',
  'Gabriela', 'Sofia', 'Camila', 'Valentina', 'Lucia', 'Mariana', 'Alejandra', 'Paloma', 'Marisol', 'Carmen',
  'Carlos', 'Miguel', 'Jose', 'Luis', 'Diego', 'Alejandro', 'Javier', 'Ricardo', 'Fernando', 'Santiago',
  'Rosa', 'Elena', 'Bianca', 'Natalia', 'Yesenia', 'Daniela', 'Esperanza', 'Xiomara', 'Andrea', 'Isabella',
];
const GUEST_LAST = [
  'Washington', 'Jefferson', 'Jackson', 'Robinson', 'Brooks', 'Coleman', 'Jenkins', 'Bryant', 'Griffin', 'Banks',
  'Garcia', 'Rodriguez', 'Martinez', 'Hernandez', 'Lopez', 'Gonzalez', 'Perez', 'Sanchez', 'Ramirez', 'Torres',
  'Flores', 'Rivera', 'Gomez', 'Diaz', 'Reyes', 'Morales', 'Ortiz', 'Gutierrez', 'Chavez', 'Ramos',
  'Cruz', 'Mendoza', 'Aguilar', 'Castillo', 'Freeman', 'Dixon', 'Porter', 'Holloway', 'Booker', 'Whitfield',
];

export const MENU = [
  { name: 'Puff Puff', category: 'starter', priceCents: 800 },
  { name: 'Meat Pie', category: 'starter', priceCents: 700 },
  { name: 'Beef Suya', category: 'starter', priceCents: 1600 },
  { name: 'Asun', category: 'starter', priceCents: 1800 },
  { name: 'Gizdodo', category: 'starter', priceCents: 1500 },
  { name: 'Moi Moi', category: 'side', priceCents: 800 },
  { name: 'Akara', category: 'brunch', priceCents: 900 },
  { name: 'Goat Pepper Soup', category: 'starter', priceCents: 1400 },
  { name: 'Catfish Pepper Soup', category: 'starter', priceCents: 1600 },
  { name: 'Nkwobi', category: 'starter', priceCents: 1800 },
  { name: 'Jollof Rice', category: 'entree', priceCents: 1800 },
  { name: 'Coconut Fried Rice', category: 'entree', priceCents: 1800 },
  { name: 'Ofada Rice & Ayamase', category: 'entree', priceCents: 2600 },
  { name: 'Egusi & Pounded Yam', category: 'entree', priceCents: 2400 },
  { name: 'Efo Riro & Eba', category: 'entree', priceCents: 2200 },
  { name: 'Okra Soup & Semo', category: 'entree', priceCents: 2200 },
  { name: 'Ogbono & Fufu', category: 'entree', priceCents: 2200 },
  { name: 'Whole Grilled Tilapia', category: 'entree', priceCents: 2800 },
  { name: 'Grilled Catfish', category: 'entree', priceCents: 2600 },
  { name: 'Grilled Chicken', category: 'entree', priceCents: 2200 },
  { name: 'Goat Meat Plate', category: 'entree', priceCents: 2400 },
  { name: 'Fried Plantain', category: 'side', priceCents: 700 },
  { name: 'Jollof & Fried Egg', category: 'brunch', priceCents: 1600 },
  { name: 'Akara & Pap', category: 'brunch', priceCents: 1400 },
  { name: 'Chapman', category: 'beverage', priceCents: 800 },
  { name: 'Zobo', category: 'beverage', priceCents: 600 },
  { name: 'Palm Wine', category: 'beverage', priceCents: 1000 },
  { name: 'Malta Guinness', category: 'beverage', priceCents: 500 },
  { name: 'Guinness Foreign Extra', category: 'bar', priceCents: 700 },
  { name: 'Heineken', category: 'bar', priceCents: 600 },
  { name: 'Hennessy & Coke', category: 'bar', priceCents: 1600 },
  { name: 'D\'USSÉ Sidecar', category: 'bar', priceCents: 1800 },
  { name: 'House Red', category: 'bar', priceCents: 1200 },
  { name: 'Moët Brut', category: 'bar', priceCents: 2200 },
];

type StockSpec = {
  name: string;
  category: 'spirit' | 'wine' | 'beer' | 'mixer' | 'garnish' | 'supply' | 'protein' | 'produce' | 'dairy' | 'dry_goods' | 'bakery' | 'frozen';
  area: string;
  unit: string;
  parLevel: number;
  onHand: number;
  unitCostCents: number;
  supplier: string;
};

export function inventoryCatalog(): StockSpec[] {
  return [
    { name: 'Hennessy VS', category: 'spirit', area: 'Bar', unit: 'bottle', parLevel: 6, onHand: 8, unitCostCents: 4200, supplier: 'Spec\'s' },
    { name: 'Hennessy VSOP', category: 'spirit', area: 'Bar', unit: 'bottle', parLevel: 3, onHand: 3, unitCostCents: 6800, supplier: 'Spec\'s' },
    { name: 'Rémy Martin VSOP', category: 'spirit', area: 'Bar', unit: 'bottle', parLevel: 3, onHand: 4, unitCostCents: 5400, supplier: 'Spec\'s' },
    { name: 'D\'USSÉ VSOP', category: 'spirit', area: 'Bar', unit: 'bottle', parLevel: 3, onHand: 2, unitCostCents: 6200, supplier: 'Spec\'s' },
    { name: 'Jameson', category: 'spirit', area: 'Bar', unit: 'bottle', parLevel: 4, onHand: 5, unitCostCents: 2800, supplier: 'Spec\'s' },
    { name: 'Tito\'s Handmade Vodka', category: 'spirit', area: 'Bar', unit: 'bottle', parLevel: 6, onHand: 7, unitCostCents: 2200, supplier: 'Spec\'s' },
    { name: 'Cîroc', category: 'spirit', area: 'Bar', unit: 'bottle', parLevel: 4, onHand: 4, unitCostCents: 3200, supplier: 'Spec\'s' },
    { name: 'Casamigos Blanco', category: 'spirit', area: 'Bar', unit: 'bottle', parLevel: 4, onHand: 5, unitCostCents: 4800, supplier: 'Spec\'s' },
    { name: 'Patrón Silver', category: 'spirit', area: 'Bar', unit: 'bottle', parLevel: 3, onHand: 3, unitCostCents: 4500, supplier: 'Spec\'s' },
    { name: 'Bombay Sapphire', category: 'spirit', area: 'Bar', unit: 'bottle', parLevel: 3, onHand: 4, unitCostCents: 2600, supplier: 'Spec\'s' },
    { name: 'Moët & Chandon Brut', category: 'wine', area: 'Bar', unit: 'bottle', parLevel: 6, onHand: 8, unitCostCents: 4800, supplier: 'Spec\'s' },
    { name: 'Veuve Clicquot Yellow Label', category: 'wine', area: 'Bar', unit: 'bottle', parLevel: 4, onHand: 3, unitCostCents: 6200, supplier: 'Spec\'s' },
    { name: 'House Cabernet', category: 'wine', area: 'Bar', unit: 'bottle', parLevel: 8, onHand: 10, unitCostCents: 1100, supplier: 'Spec\'s' },
    { name: 'House Sauvignon Blanc', category: 'wine', area: 'Bar', unit: 'bottle', parLevel: 8, onHand: 9, unitCostCents: 1100, supplier: 'Spec\'s' },
    { name: 'Guinness Foreign Extra Stout', category: 'beer', area: 'Bar', unit: 'bottle', parLevel: 48, onHand: 60, unitCostCents: 220, supplier: 'Houston Distributing' },
    { name: 'Heineken', category: 'beer', area: 'Bar', unit: 'bottle', parLevel: 36, onHand: 28, unitCostCents: 180, supplier: 'Houston Distributing' },
    { name: 'Bud Light', category: 'beer', area: 'Bar', unit: 'bottle', parLevel: 24, onHand: 30, unitCostCents: 120, supplier: 'Houston Distributing' },
    { name: 'Modelo Especial', category: 'beer', area: 'Bar', unit: 'bottle', parLevel: 24, onHand: 24, unitCostCents: 160, supplier: 'Houston Distributing' },
    { name: 'Malta Guinness', category: 'mixer', area: 'Bar', unit: 'bottle', parLevel: 24, onHand: 30, unitCostCents: 150, supplier: 'AFRI-GROCERS' },
    { name: 'Chapman Mix', category: 'mixer', area: 'Bar', unit: 'bottle', parLevel: 12, onHand: 14, unitCostCents: 400, supplier: 'AFRI-GROCERS' },
    { name: 'Coca-Cola', category: 'mixer', area: 'Bar', unit: 'case', parLevel: 6, onHand: 8, unitCostCents: 900, supplier: 'Houston Distributing' },
    { name: 'Angostura Bitters', category: 'mixer', area: 'Bar', unit: 'bottle', parLevel: 2, onHand: 2, unitCostCents: 1200, supplier: 'Spec\'s' },
    { name: 'Lime Juice', category: 'mixer', area: 'Bar', unit: 'bottle', parLevel: 6, onHand: 5, unitCostCents: 350, supplier: 'Restaurant Depot' },
    { name: 'Orange Wheels', category: 'garnish', area: 'Bar', unit: 'each', parLevel: 40, onHand: 48, unitCostCents: 25, supplier: 'Restaurant Depot' },
    { name: 'Cucumber', category: 'garnish', area: 'Bar', unit: 'each', parLevel: 12, onHand: 10, unitCostCents: 80, supplier: 'Restaurant Depot' },
    { name: 'Bar Straws', category: 'supply', area: 'Bar', unit: 'box', parLevel: 4, onHand: 6, unitCostCents: 600, supplier: 'Restaurant Depot' },
    { name: 'Goat Meat', category: 'protein', area: 'Walk-in', unit: 'lb', parLevel: 40, onHand: 46, unitCostCents: 620, supplier: 'Halal Houston Meats' },
    { name: 'Beef (suya / stew)', category: 'protein', area: 'Walk-in', unit: 'lb', parLevel: 25, onHand: 28, unitCostCents: 540, supplier: 'Halal Houston Meats' },
    { name: 'Chicken', category: 'protein', area: 'Walk-in', unit: 'lb', parLevel: 30, onHand: 32, unitCostCents: 280, supplier: 'Halal Houston Meats' },
    { name: 'Turkey Wings', category: 'protein', area: 'Walk-in', unit: 'lb', parLevel: 12, onHand: 10, unitCostCents: 320, supplier: 'Halal Houston Meats' },
    { name: 'Whole Tilapia', category: 'protein', area: 'Walk-in', unit: 'each', parLevel: 24, onHand: 18, unitCostCents: 750, supplier: 'Gulf Seafood' },
    { name: 'Catfish', category: 'protein', area: 'Walk-in', unit: 'lb', parLevel: 16, onHand: 18, unitCostCents: 680, supplier: 'Gulf Seafood' },
    { name: 'Assorted Offal', category: 'protein', area: 'Walk-in', unit: 'lb', parLevel: 8, onHand: 9, unitCostCents: 400, supplier: 'Halal Houston Meats' },
    { name: 'Gizzard', category: 'protein', area: 'Walk-in', unit: 'lb', parLevel: 8, onHand: 8, unitCostCents: 260, supplier: 'Halal Houston Meats' },
    { name: 'Long-grain Rice', category: 'dry_goods', area: 'Dry store', unit: 'lb', parLevel: 50, onHand: 55, unitCostCents: 90, supplier: 'Restaurant Depot' },
    { name: 'Ofada Rice', category: 'dry_goods', area: 'Dry store', unit: 'lb', parLevel: 15, onHand: 16, unitCostCents: 220, supplier: 'AFRI-GROCERS' },
    { name: 'Pounded Yam Flour', category: 'dry_goods', area: 'Dry store', unit: 'bag', parLevel: 12, onHand: 14, unitCostCents: 1800, supplier: 'AFRI-GROCERS' },
    { name: 'Garri (Eba)', category: 'dry_goods', area: 'Dry store', unit: 'bag', parLevel: 8, onHand: 9, unitCostCents: 1400, supplier: 'AFRI-GROCERS' },
    { name: 'Semolina', category: 'dry_goods', area: 'Dry store', unit: 'bag', parLevel: 6, onHand: 6, unitCostCents: 1200, supplier: 'AFRI-GROCERS' },
    { name: 'Egusi Seeds', category: 'dry_goods', area: 'Dry store', unit: 'lb', parLevel: 8, onHand: 9, unitCostCents: 450, supplier: 'AFRI-GROCERS' },
    { name: 'Ogbono Seeds', category: 'dry_goods', area: 'Dry store', unit: 'lb', parLevel: 4, onHand: 3, unitCostCents: 520, supplier: 'AFRI-GROCERS' },
    { name: 'Palm Oil', category: 'dry_goods', area: 'Dry store', unit: 'jug', parLevel: 6, onHand: 8, unitCostCents: 1600, supplier: 'AFRI-GROCERS' },
    { name: 'Crayfish', category: 'dry_goods', area: 'Dry store', unit: 'lb', parLevel: 4, onHand: 5, unitCostCents: 900, supplier: 'AFRI-GROCERS' },
    { name: 'Stockfish', category: 'dry_goods', area: 'Dry store', unit: 'lb', parLevel: 5, onHand: 6, unitCostCents: 1400, supplier: 'AFRI-GROCERS' },
    { name: 'Cameroon Pepper', category: 'dry_goods', area: 'Dry store', unit: 'lb', parLevel: 3, onHand: 3, unitCostCents: 800, supplier: 'AFRI-GROCERS' },
    { name: 'Locust Beans (Iru)', category: 'dry_goods', area: 'Dry store', unit: 'lb', parLevel: 2, onHand: 2, unitCostCents: 1100, supplier: 'AFRI-GROCERS' },
    { name: 'Roma Tomatoes', category: 'produce', area: 'Walk-in', unit: 'lb', parLevel: 25, onHand: 22, unitCostCents: 120, supplier: 'Restaurant Depot' },
    { name: 'Red Bell Pepper', category: 'produce', area: 'Walk-in', unit: 'lb', parLevel: 12, onHand: 14, unitCostCents: 180, supplier: 'Restaurant Depot' },
    { name: 'Habanero / Scotch Bonnet', category: 'produce', area: 'Walk-in', unit: 'lb', parLevel: 6, onHand: 7, unitCostCents: 350, supplier: 'Restaurant Depot' },
    { name: 'Yellow Onion', category: 'produce', area: 'Walk-in', unit: 'lb', parLevel: 20, onHand: 24, unitCostCents: 80, supplier: 'Restaurant Depot' },
    { name: 'Ugu / Spinach', category: 'produce', area: 'Walk-in', unit: 'lb', parLevel: 12, onHand: 10, unitCostCents: 250, supplier: 'AFRI-GROCERS' },
    { name: 'Okra', category: 'produce', area: 'Walk-in', unit: 'lb', parLevel: 8, onHand: 9, unitCostCents: 200, supplier: 'Restaurant Depot' },
    { name: 'Ripe Plantain', category: 'produce', area: 'Walk-in', unit: 'each', parLevel: 40, onHand: 48, unitCostCents: 75, supplier: 'Restaurant Depot' },
    { name: 'Ginger', category: 'produce', area: 'Walk-in', unit: 'lb', parLevel: 4, onHand: 5, unitCostCents: 220, supplier: 'Restaurant Depot' },
    { name: 'Garlic', category: 'produce', area: 'Walk-in', unit: 'lb', parLevel: 3, onHand: 3, unitCostCents: 180, supplier: 'Restaurant Depot' },
    { name: 'Hibiscus (Zobo)', category: 'produce', area: 'Dry store', unit: 'lb', parLevel: 4, onHand: 5, unitCostCents: 600, supplier: 'AFRI-GROCERS' },
    { name: 'Eggs', category: 'dairy', area: 'Walk-in', unit: 'dozen', parLevel: 8, onHand: 10, unitCostCents: 280, supplier: 'Restaurant Depot' },
    { name: 'Heavy Cream', category: 'dairy', area: 'Walk-in', unit: 'quart', parLevel: 4, onHand: 4, unitCostCents: 450, supplier: 'Restaurant Depot' },
    { name: 'Meat Pie Dough', category: 'bakery', area: 'Walk-in', unit: 'sheet', parLevel: 10, onHand: 12, unitCostCents: 350, supplier: 'House prep' },
    { name: 'Puff Puff Mix', category: 'bakery', area: 'Dry store', unit: 'lb', parLevel: 8, onHand: 9, unitCostCents: 180, supplier: 'House prep' },
    { name: 'Frozen Snail', category: 'frozen', area: 'Freezer', unit: 'lb', parLevel: 4, onHand: 5, unitCostCents: 1600, supplier: 'AFRI-GROCERS' },
    { name: 'Palm Wine', category: 'beer', area: 'Walk-in', unit: 'jug', parLevel: 6, onHand: 8, unitCostCents: 900, supplier: 'AFRI-GROCERS' },
  ].map((item) => ({
    ...item,
    parLevel: item.parLevel * 3,
    onHand: item.onHand * 3,
  }));
}

const DAY_SALES_WEIGHT = [0.21, 0.055, 0.062, 0.076, 0.124, 0.221, 0.252];
const WEEK_MULT: Record<string, number> = {
  '2026-08-30': 0.94,
  '2026-09-06': 1.07,
  '2026-09-13': 0.99,
};

function weekStartFor(iso: string): string {
  return addDays(iso, -dayIndex(iso));
}

type Need = { jobTitle: string; start: number; end: number; count: number; station?: string };

function coverage(iso: string): Need[] {
  const di = dayIndex(iso);
  const weekend = di === 5 || di === 6;
  const sunday = di === 0;
  const thu = di === 4;
  const late = isLateNight(iso);
  const brunchBoost = sunday || weekend ? 1 : 0;
  return [
    { jobTitle: 'Prep', start: 660, end: 960, count: sunday || weekend ? 3 : 2 },
    { jobTitle: 'Line Cook', start: 660, end: 960, count: 3 + brunchBoost },
    { jobTitle: 'Line Cook', start: 960, end: 1320, count: weekend || thu ? 6 : sunday ? 5 : 4 },
    { jobTitle: 'Server', start: 660, end: 960, count: sunday ? 8 : weekend ? 6 : thu ? 5 : 4, station: di === 0 || di === 6 ? 'Patio' : 'Floor' },
    { jobTitle: 'Server', start: 960, end: 1320, count: weekend ? 8 : thu ? 7 : sunday ? 6 : 5 },
    { jobTitle: 'Bartender', start: 660, end: 960, count: sunday || weekend ? 2 : 1 },
    { jobTitle: 'Bartender', start: 960, end: 1320, count: weekend || thu ? 4 : 2 },
    { jobTitle: 'Host', start: 660, end: 960, count: sunday || weekend ? 2 : 1 },
    { jobTitle: 'Host', start: 960, end: 1320, count: sunday || weekend || thu ? 2 : 1 },
    { jobTitle: 'Busser', start: 660, end: 960, count: sunday || weekend ? 3 : 2 },
    { jobTitle: 'Busser', start: 960, end: 1320, count: weekend ? 4 : thu || sunday ? 3 : 2 },
    { jobTitle: 'Barback', start: 960, end: 1320, count: weekend || thu ? 2 : 1 },
    { jobTitle: 'Supervisor', start: 660, end: 960, count: 1 },
    { jobTitle: 'Supervisor', start: 960, end: 1320, count: weekend || thu ? 2 : 1 },
    ...(late
      ? [
          { jobTitle: 'Server', start: 1260, end: 1560, count: weekend ? 4 : 3 },
          { jobTitle: 'Bartender', start: 1260, end: 1560, count: weekend ? 3 : 2 },
          { jobTitle: 'Barback', start: 1260, end: 1560, count: 2 },
          { jobTitle: 'Busser', start: 1260, end: 1560, count: 2 },
          { jobTitle: 'Line Cook', start: 1260, end: 1560, count: weekend ? 3 : 2 },
          { jobTitle: 'Supervisor', start: 1260, end: 1560, count: 1 },
          { jobTitle: 'Host', start: 1260, end: 1500, count: 1 },
        ]
      : []),
  ];
}

function layoutTables(): Array<{
  label: string;
  shape: 'round' | 'square' | 'rect' | 'booth';
  seats: number;
  x: number;
  y: number;
  width: number;
  height: number;
  section: 'main' | 'patio' | 'bar' | 'vip';
  minSpend: number;
  isReservable: boolean;
}> {
  const tables: ReturnType<typeof layoutTables> = [];
  let n = 1;
  for (let r = 0; r < 4; r += 1) {
    for (let c = 0; c < 6; c += 1) {
      const sixTop = n % 5 === 0;
      tables.push({
        label: String(n),
        shape: sixTop ? 'rect' : 'round',
        seats: sixTop ? 6 : 4,
        x: 70 + c * 145,
        y: 70 + r * 135,
        width: sixTop ? 150 : 90,
        height: sixTop ? 80 : 90,
        section: 'main',
        minSpend: 0,
        isReservable: true,
      });
      n += 1;
    }
  }
  for (let i = 0; i < 8; i += 1) {
    tables.push({
      label: `B${i + 1}`,
      shape: 'square',
      seats: 2,
      x: 980,
      y: 60 + i * 85,
      width: 70,
      height: 70,
      section: 'bar',
      minSpend: 0,
      isReservable: false,
    });
  }
  for (let i = 0; i < 8; i += 1) {
    tables.push({
      label: `P${i + 1}`,
      shape: 'round',
      seats: 4,
      x: 70 + (i % 4) * 145,
      y: 640 + Math.floor(i / 4) * 130,
      width: 90,
      height: 90,
      section: 'patio',
      minSpend: 0,
      isReservable: true,
    });
  }
  for (let i = 0; i < 4; i += 1) {
    tables.push({
      label: `V${i + 1}`,
      shape: 'booth',
      seats: 6,
      x: 700 + (i % 2) * 170,
      y: 640 + Math.floor(i / 2) * 120,
      width: 130,
      height: 90,
      section: 'vip',
      minSpend: 15000,
      isReservable: true,
    });
  }
  return tables;
}

async function wipePreviousDemo(prisma: PrismaClient, venueId: string) {
  await prisma.tableAssignment.deleteMany({
    where: { venueId, OR: [{ reservation: { tags: { has: DEMO_NOTE } } }, { waitlist: { notes: DEMO_NOTE } }] },
  });
  await prisma.waitlist.deleteMany({ where: { venueId, notes: DEMO_NOTE } });
  await prisma.reservation.deleteMany({ where: { venueId, tags: { has: DEMO_NOTE } } });
  await prisma.guest.deleteMany({ where: { venueId, email: { endsWith: GUEST_EMAIL_SUFFIX } } });
  await prisma.posCheck.deleteMany({ where: { venueId, externalCheckId: { startsWith: POS_PREFIX } } });
  await prisma.barInventoryItem.deleteMany({ where: { venueId, notes: DEMO_NOTE } });
  await prisma.scheduleShift.deleteMany({ where: { venueId, notes: DEMO_NOTE } });
  await prisma.profile.deleteMany({ where: { venueId, email: { endsWith: STAFF_EMAIL_SUFFIX } } });
}

function staffEmail(index: number): string {
  return `staff${String(index + 1).padStart(2, '0')}${STAFF_EMAIL_SUFFIX}`;
}

function buildShifts(staff: Profile[]) {
  const byTitle = new Map<string, Profile[]>();
  for (const p of staff) {
    const list = byTitle.get(p.jobTitle) ?? [];
    list.push(p);
    byTitle.set(p.jobTitle, list);
  }
  const cursor = new Map<string, number>();
  const shifts: Prisma.ScheduleShiftCreateManyInput[] = [];
  const worked = new Map<string, Set<string>>();

  const take = (title: string, date: string, start: number, end: number): Profile | null => {
    const pool = byTitle.get(title) ?? [];
    if (!pool.length) return null;
    const startAt = cursor.get(title) ?? 0;
    for (let i = 0; i < pool.length; i += 1) {
      const person = pool[(startAt + i) % pool.length]!;
      const key = `${person.id}:${date}`;
      const blocks = worked.get(key);
      if (blocks && [...blocks].some((b) => {
        const [s, e] = b.split('-').map(Number);
        return start < e && end > s;
      })) continue;
      cursor.set(title, (startAt + i + 1) % pool.length);
      const set = worked.get(key) ?? new Set<string>();
      set.add(`${start}-${end}`);
      worked.set(key, set);
      return person;
    }
    return null;
  };

  for (const weekStart of WEEK_STARTS) {
    for (let di = 0; di < 7; di += 1) {
      const iso = addDays(weekStart, di);
      if (iso < START_DATE || iso > LAST_RESERVATION_DATE) continue;
      for (const need of coverage(iso)) {
        for (let n = 0; n < need.count; n += 1) {
          const person = take(need.jobTitle, iso, need.start, need.end);
          if (!person) continue;
          let station = need.station ?? STATIONS[need.jobTitle] ?? 'Floor';
          if (need.jobTitle === 'Server' && n % 4 === 3) station = 'VIP';
          if (need.jobTitle === 'Server' && n % 4 === 2) station = 'Patio';
          shifts.push({
            venueId: person.venueId!,
            profileId: person.id,
            weekStart,
            dayIndex: di,
            startMinutes: need.start,
            endMinutes: need.end,
            jobTitle: need.jobTitle,
            station,
            notes: DEMO_NOTE,
            status: 'scheduled',
          });
        }
      }
    }
  }
  return shifts;
}

function guestSpecs(): Prisma.GuestCreateManyInput[] {
  const out: Prisma.GuestCreateManyInput[] = [];
  const used = new Set<string>();
  const stages = ['regular', 'regular', 'vip', 'lead', 'lapsed'];
  while (out.length < 90) {
    const fullName = `${pick(GUEST_FIRST)} ${pick(GUEST_LAST)}`;
    if (used.has(fullName)) continue;
    used.add(fullName);
    const i = out.length;
    const vip = i % 11 === 0;
    const allergy = i % 13 === 0;
    out.push({
      venueId: 'pending',
      fullName,
      nameLower: fullName.toLowerCase(),
      phone: `713555${String(2000 + i).padStart(4, '0')}`,
      email: `g${String(i + 1).padStart(2, '0')}${GUEST_EMAIL_SUFFIX}`,
      lifecycleStage: vip ? 'vip' : pick(stages),
      source: pick(['direct', 'opentable', 'walk_in', 'phone', 'instagram']),
      marketingOptIn: i % 3 !== 1,
      dietaryNotes: allergy ? 'Peanut allergy — hard stop. Chef sign-off required.' : i % 7 === 0 ? 'No pork' : i % 9 === 0 ? 'Halal' : null,
      favoriteTable: i % 10 === 0 ? `V${(i % 4) + 1}` : i % 8 === 0 ? String((i % 24) + 1) : null,
      preferredServer: i % 12 === 0 ? 'Aaliyah Washington' : null,
      tags: vip ? ['vip', DEMO_NOTE] : [DEMO_NOTE],
      notes: vip
        ? 'Hospitality profile — recognize on arrival.'
        : i % 5 === 0
          ? 'Prefers Chapman, no ice.'
          : i % 6 === 0
            ? 'Prefers booth seating.'
            : null,
    });
  }
  return out;
}

function menuItemsFor(period: 'brunch' | 'dinner' | 'late', guests: number) {
  const pool = MENU.filter((item) => {
    if (period === 'brunch') return item.category === 'brunch' || item.category === 'beverage' || item.category === 'side' || item.category === 'starter';
    if (period === 'late') return item.category === 'bar' || item.category === 'starter' || item.category === 'side';
    return true;
  });
  const count = randInt(Math.max(1, guests), guests + 2);
  const items = [];
  for (let i = 0; i < count; i += 1) {
    const item = pick(pool);
    items.push({ name: item.name, category: item.category, quantity: 1, priceCents: item.priceCents });
  }
  return items;
}

async function main() {
  if (process.env.CONFIRM_ENISH_SEED !== 'true') {
    throw new Error('Refusing to seed. Re-run with CONFIRM_ENISH_SEED=true ALLOW_PRODUCTION_DB=true');
  }
  const databaseUrl = loadDatabaseUrl();
  const host = new URL(databaseUrl).hostname;
  console.log(`Seeding Enish Houston on host ${host}`);

  const prisma = new PrismaClient({ datasources: { db: { url: databaseUrl } } });
  try {
    const adminUser = await prisma.user.findUnique({
      where: { email: ADMIN_EMAIL },
      include: { profiles: true },
    });
    if (!adminUser) throw new Error(`${ADMIN_EMAIL} does not exist — will not create a password for it.`);

    let venue = await prisma.venue.findFirst({
      where: { name: { equals: VENUE_NAME, mode: 'insensitive' } },
    });
    if (!venue) {
      venue = await prisma.venue.create({
        data: {
          name: VENUE_NAME,
          latitude: 29.7419,
          longitude: -95.4622,
          geofenceRadiusM: 150,
          timezone: TZ,
          code: makeVenueCode(),
          phone: '7135551800',
          address: 'Houston, TX',
          venueType: 'restaurant',
          staffRange: '50-100',
          weeklyLaborBudgetHours: 1800,
          subscriptionStatus: 'active',
        },
      });
      console.log(`Created venue ${venue.name}`);
    } else {
      venue = await prisma.venue.update({
        where: { id: venue.id },
        data: {
          name: VENUE_NAME,
          timezone: TZ,
          latitude: venue.latitude || 29.7419,
          longitude: venue.longitude || -95.4622,
          address: venue.address || 'Houston, TX',
          venueType: venue.venueType || 'restaurant',
          staffRange: '50-100',
          weeklyLaborBudgetHours: venue.weeklyLaborBudgetHours ?? 1800,
        },
      });
      console.log(`Using existing venue ${venue.name}`);
    }

    await prisma.$executeRaw`
      INSERT INTO "Subscription" ("id","venueId","status","planId","priceCents","currency","cancelAtPeriodEnd","currentPeriodStart","currentPeriodEnd","createdAt","updatedAt")
      SELECT gen_random_uuid()::text, ${venue.id}, 'active'::"SubscriptionStatus", 'venueflow_monthly', 9999, 'USD', false,
        TIMESTAMPTZ '2026-09-01 00:00:00+00', TIMESTAMPTZ '2026-10-01 00:00:00+00', NOW(), NOW()
      WHERE NOT EXISTS (SELECT 1 FROM "Subscription" WHERE "venueId" = ${venue.id})
    `;
    await prisma.venue.update({
      where: { id: venue.id },
      data: { subscriptionStatus: 'active' },
    });

    const adminProfile = adminUser.profiles.find((p) => p.venueId === venue.id)
      ?? adminUser.profiles.find((p) => p.email === ADMIN_EMAIL && !p.venueId);
    if (adminProfile && adminProfile.venueId === venue.id) {
      await prisma.profile.update({
        where: { id: adminProfile.id },
        data: {
          allAccess: true,
          membershipStatus: 'active',
          role: 'admin',
          jobTitle: 'Owner',
          fullName: adminProfile.fullName || 'Venue Wrangler Admin',
        },
      });
    } else if (adminProfile && !adminProfile.venueId) {
      await prisma.profile.update({
        where: { id: adminProfile.id },
        data: {
          venueId: venue.id,
          allAccess: true,
          membershipStatus: 'active',
          role: 'admin',
          jobTitle: 'Owner',
        },
      });
    } else {
      await prisma.profile.create({
        data: {
          userId: adminUser.id,
          email: ADMIN_EMAIL,
          fullName: 'Venue Wrangler Admin',
          role: 'admin',
          jobTitle: 'Owner',
          venueId: venue.id,
          allAccess: true,
          membershipStatus: 'active',
        },
      });
    }
    const owner = await prisma.profile.findFirstOrThrow({
      where: { userId: adminUser.id, venueId: venue.id },
    });
    console.log(`Admin ${ADMIN_EMAIL} assigned to ${VENUE_NAME} (allAccess)`);

    await wipePreviousDemo(prisma, venue.id);

    const roleNames = ['Supervisor', 'Server', 'Bartender', 'Host', 'Line Cook', 'Prep', 'Busser', 'Barback'];
    for (const name of roleNames) {
      const existing = await prisma.venueRole.findFirst({ where: { venueId: venue.id, name } });
      if (!existing) await prisma.venueRole.create({ data: { venueId: venue.id, name } });
    }

    await prisma.reservationSetting.upsert({
      where: { venueId: venue.id },
      create: {
        venueId: venue.id,
        defaultDiningMinutes: 90,
        defaultTurnMinutes: 20,
        bookingWindowDays: 30,
        minLeadHours: 1,
      },
      update: {
        defaultDiningMinutes: 90,
        defaultTurnMinutes: 20,
        bookingWindowDays: 30,
        minLeadHours: 1,
      },
    });

    let plan = await prisma.floorPlan.findFirst({ where: { venueId: venue.id, isActive: true } });
    if (!plan) {
      plan = await prisma.floorPlan.create({
        data: {
          venueId: venue.id,
          name: 'Main Floor',
          width: 1200,
          height: 900,
          isActive: true,
        },
      });
    }
    let tables: FloorTable[] = await prisma.floorTable.findMany({ where: { venueId: venue.id } });
    if (tables.length === 0) {
      for (const spec of layoutTables()) {
        const table = await prisma.floorTable.create({
          data: {
            venueId: venue.id,
            floorPlanId: plan.id,
            ...spec,
            rotation: 0,
          },
        });
        await prisma.tableState.create({
          data: {
            venueId: venue.id,
            tableId: table.id,
            status: 'available',
            lastActivityAt: new Date(),
          },
        });
        tables.push(table);
      }
    }
    const reservable = tables.filter((t) => t.isReservable);

    const createdStaff: Profile[] = [];
    for (let i = 0; i < STAFF.length; i += 1) {
      const spec = STAFF[i]!;
      const profile = await prisma.profile.create({
        data: {
          email: staffEmail(i),
          fullName: spec.fullName,
          role: spec.role,
          jobTitle: spec.jobTitle,
          venueId: venue.id,
          membershipStatus: 'active',
          phone: `713555${String(3100 + i).padStart(4, '0')}`,
          allAccess: false,
        },
      });
      createdStaff.push(profile);
    }
    await prisma.team.upsert({
      where: { venueId: venue.id },
      create: { venueId: venue.id, name: 'Default Team', memberCount: createdStaff.length + 1 },
      update: { memberCount: createdStaff.length + 1 },
    });
    console.log(`Created ${createdStaff.length} employees`);

    const shiftRows = buildShifts(createdStaff);
    for (let i = 0; i < shiftRows.length; i += 500) {
      await prisma.scheduleShift.createMany({ data: shiftRows.slice(i, i + 500) });
    }
    for (const weekStart of WEEK_STARTS) {
      await prisma.schedulePublication.upsert({
        where: { venueId_weekStart: { venueId: venue.id, weekStart } },
        create: { venueId: venue.id, weekStart, publishedAt: new Date(), publishedById: owner.id },
        update: { publishedAt: new Date(), publishedById: owner.id },
      });
    }
    console.log(`Created ${shiftRows.length} shifts across ${WEEK_STARTS.length} weeks`);

    const guestRows = guestSpecs().map((g) => ({ ...g, venueId: venue.id }));
    await prisma.guest.createMany({ data: guestRows });
    const guests = await prisma.guest.findMany({
      where: { venueId: venue.id, email: { endsWith: GUEST_EMAIL_SUFFIX } },
      select: {
        id: true,
        fullName: true,
        phone: true,
        email: true,
        dietaryNotes: true,
        notes: true,
      },
      orderBy: { email: 'asc' },
    });
    console.log(`Created ${guests.length} guest profiles`);

    const servers = createdStaff.filter((p) => p.jobTitle === 'Server');
    const sources: ReservationSource[] = ['direct', 'opentable', 'resy', 'phone', 'walk_in', 'google'];
    const brunchSlots = ['11:00', '11:30', '12:00', '12:30', '13:00', '13:30', '14:00', '14:30'];
    const dinnerSlots = ['17:00', '17:30', '18:00', '18:30', '19:00', '19:30', '20:00', '20:30', '21:00'];

    let reservationCount = 0;
    let waitlistCount = 0;
    let tableCursor = 0;
    const nextTable = () => {
      const table = reservable[tableCursor % reservable.length]!;
      tableCursor += 1;
      return table;
    };

    for (const iso of eachDate(START_DATE, LAST_RESERVATION_DATE)) {
      const di = dayIndex(iso);
      const busy = di === 0 || di === 5 || di === 6;
      const past = iso < LAST_SALES_DATE;
      const today = iso === LAST_SALES_DATE;
      const brunchN = busy ? 18 : di === 4 ? 12 : 7;
      const dinnerN = busy ? 28 : di === 4 ? 20 : 10;
      const makeRes = async (slot: string, period: 'brunch' | 'dinner', index: number) => {
        const guest = guests[(dayIndex(iso) * 13 + index * 3) % guests.length]!;
        const partySize = randInt(2, period === 'dinner' && busy ? 6 : 4);
        const durationMinutes = period === 'brunch' ? 75 : 105;
        const start = zonedDate(iso, slot);
        const end = new Date(start.getTime() + durationMinutes * 60000);
        let status: ReservationStatus = 'confirmed';
        let checkInAt: Date | null = null;
        let seatedAt: Date | null = null;
        let completedAt: Date | null = null;
        if (past) {
          const roll = rng();
          if (roll < 0.07) status = 'cancelled';
          else if (roll < 0.11) status = 'no_show';
          else {
            status = 'completed';
            checkInAt = new Date(start.getTime() - randInt(5, 18) * 60000);
            seatedAt = new Date(start.getTime() + randInt(0, 12) * 60000);
            completedAt = new Date(seatedAt.getTime() + (durationMinutes + randInt(0, 20)) * 60000);
          }
        } else if (today) {
          if (period === 'brunch') {
            status = 'completed';
            checkInAt = new Date(start.getTime() - 10 * 60000);
            seatedAt = start;
            completedAt = end;
          } else if (index < 4) {
            status = 'seated';
            checkInAt = new Date(start.getTime() - 8 * 60000);
            seatedAt = new Date(Date.now() - randInt(20, 70) * 60000);
          } else if (index < 8) status = 'checked_in';
          else status = 'confirmed';
        }
        const table = nextTable();
        const reservation = await prisma.reservation.create({
          data: {
            venueId: venue.id,
            guestId: guest.id,
            guestName: guest.fullName,
            guestPhone: guest.phone,
            guestEmail: guest.email,
            partySize,
            reservationTime: start,
            durationMinutes,
            source: pick(sources),
            status,
            specialRequests: guest.dietaryNotes?.includes('allergy') || guest.dietaryNotes?.includes('Allergy')
              ? `ALLERGY HARD STOP: ${guest.dietaryNotes}`
              : guest.notes?.startsWith('Prefers')
                ? guest.notes
                : null,
            tags: [DEMO_NOTE, period],
            estimatedValueCents: partySize * (period === 'dinner' ? 8500 : 5500),
            checkInAt,
            seatedAt,
            completedAt,
            notes: DEMO_NOTE,
          },
        });
        reservationCount += 1;
        if (status !== 'cancelled' && status !== 'no_show') {
          await prisma.tableAssignment.create({
            data: {
              venueId: venue.id,
              reservationId: reservation.id,
              tableId: table.id,
              holdType: status === 'seated' ? HoldType.seated : status === 'completed' ? HoldType.seated : HoldType.reserved,
              startsAt: start,
              endsAt: end,
              releasedAt: status === 'completed' ? completedAt : null,
              releasedReason: status === 'completed' ? 'completed' : null,
            },
          });
        }
        if (status === 'seated') {
          await prisma.tableState.update({
            where: { tableId: table.id },
            data: {
              status: TableStatus.seated,
              partySize,
              serverId: pick(servers).id,
              seatedAt: seatedAt ?? new Date(),
              lastActivityAt: new Date(),
            },
          });
        }
      };

      for (let i = 0; i < brunchN; i += 1) await makeRes(brunchSlots[i % brunchSlots.length]!, 'brunch', i);
      for (let i = 0; i < dinnerN; i += 1) await makeRes(dinnerSlots[i % dinnerSlots.length]!, 'dinner', i + 50);

      const waitN = busy ? 8 : di === 4 ? 5 : 2;
      for (let i = 0; i < waitN; i += 1) {
        const guest = guests[(i * 5 + di) % guests.length]!;
        const requestedAt = zonedDate(iso, busy ? '18:30' : '19:00');
        requestedAt.setMinutes(requestedAt.getMinutes() + i * 7);
        const pastWait = iso < LAST_SALES_DATE;
        const status: WaitlistStatus = pastWait ? (rng() < 0.85 ? 'completed' : 'removed') : today && i < 3 ? 'waiting' : 'completed';
        await prisma.waitlist.create({
          data: {
            venueId: venue.id,
            guestId: guest.id,
            guestName: guest.fullName,
            guestPhone: guest.phone,
            guestEmail: guest.email,
            partySize: randInt(2, 5),
            source: 'walk_in',
            status,
            requestedAt,
            readyAt: status === 'waiting' ? null : new Date(requestedAt.getTime() + randInt(15, 45) * 60000),
            notes: DEMO_NOTE,
          },
        });
        waitlistCount += 1;
      }
    }
    console.log(`Created ${reservationCount} reservations and ${waitlistCount} waitlist entries`);

    const checks: Prisma.PosCheckCreateManyInput[] = [];
    let checkN = 0;
    for (const iso of eachDate(START_DATE, LAST_SALES_DATE)) {
      const week = weekStartFor(iso);
      const target = Math.round(145000_00 * (DAY_SALES_WEIGHT[dayIndex(iso)] ?? 0.07) * (WEEK_MULT[week] ?? 1));
      const lateShare = isLateNight(iso) ? 0.12 : 0;
      const brunchShare = dayIndex(iso) === 0 || dayIndex(iso) === 6 ? 0.38 : 0.28;
      const dinnerShare = 1 - lateShare - brunchShare;
      const buckets: Array<{ period: 'brunch' | 'dinner' | 'late'; share: number; slots: string[] }> = [
        { period: 'brunch', share: brunchShare, slots: brunchSlots },
        { period: 'dinner', share: dinnerShare, slots: dinnerSlots },
      ];
      if (lateShare) buckets.push({ period: 'late', share: lateShare, slots: ['21:30', '22:00', '22:30', '23:00', '23:30', '00:15', '00:45', '01:15'] });

      for (const bucket of buckets) {
        let remaining = Math.round(target * bucket.share);
        let guard = 0;
        while (remaining > 1500 && guard < 400) {
          guard += 1;
          const slot = pick(bucket.slots);
          const dateForSlot = slot < '05:00' ? addDays(iso, 1) : iso;
          if (slot < '05:00' && dateForSlot > addDays(LAST_SALES_DATE, 1)) continue;
          const openedAt = zonedDate(dateForSlot, slot);
          openedAt.setMinutes(openedAt.getMinutes() + randInt(0, 25));
          const guestCount = randInt(1, bucket.period === 'dinner' ? 6 : 4);
          const items = menuItemsFor(bucket.period, guestCount);
          const subtotalCents = items.reduce((s, it) => s + it.priceCents * it.quantity, 0);
          const taxCents = Math.round(subtotalCents * TAX_RATE);
          const tipCents = Math.round(subtotalCents * (0.18 + rng() * 0.07));
          const totalCents = subtotalCents + taxCents + tipCents;
          const guest = rng() < 0.55 ? pick(guests) : null;
          const server = pick(servers);
          const table = pick(tables);
          const closedAt = new Date(openedAt.getTime() + randInt(35, 110) * 60000);
          checkN += 1;
          checks.push({
            venueId: venue.id,
            provider: 'generic',
            externalCheckId: `${POS_PREFIX}${iso}-${String(checkN).padStart(4, '0')}`,
            tableLabel: table.label,
            tableId: table.id,
            serverName: server.fullName,
            serverId: server.id,
            guestName: guest?.fullName ?? null,
            guestId: guest?.id ?? null,
            openedAt,
            closedAt,
            subtotalCents,
            taxCents,
            tipCents,
            totalCents,
            guestCount,
            revenueCenter: bucket.period === 'late' ? 'bar' : table.section === 'bar' ? 'bar' : 'dining',
            tenderType: pick(['card', 'card', 'card', 'cash', 'split']),
            menuItems: items as Prisma.InputJsonValue,
            status: 'paid',
          });
          remaining -= totalCents;
        }
      }
    }
    for (let i = 0; i < checks.length; i += 400) {
      await prisma.posCheck.createMany({ data: checks.slice(i, i + 400) });
    }
    const salesCents = checks.reduce((s, c) => s + (c.totalCents as number), 0);
    console.log(`Created ${checks.length} paid checks totaling $${(salesCents / 100).toFixed(0)}`);

    await prisma.barInventoryItem.deleteMany({ where: { venueId: venue.id, notes: DEMO_NOTE } });
    await prisma.barInventoryItem.createMany({
      data: inventoryCatalog().map((item) => ({
        venueId: venue.id,
        name: item.name,
        normalizedName: item.name.trim().toLowerCase(),
        category: item.category,
        area: item.area,
        unit: item.unit,
        parLevel: item.parLevel,
        onHand: item.onHand,
        unitCostCents: item.unitCostCents,
        supplier: item.supplier,
        notes: DEMO_NOTE,
        lastCountedAt: zonedDate(LAST_SALES_DATE, '10:00'),
      })),
    });
    console.log(`Created ${inventoryCatalog().length} inventory items`);

    await prisma.posConnection.upsert({
      where: { venueId_provider: { venueId: venue.id, provider: 'generic' } },
      create: { venueId: venue.id, provider: 'generic', status: 'connected' },
      update: { status: 'connected' },
    });

    const summary = await prisma.posCheck.aggregate({
      where: { venueId: venue.id, status: { not: 'void' }, externalCheckId: { startsWith: POS_PREFIX } },
      _sum: { totalCents: true },
      _count: true,
    });
    console.log(JSON.stringify({
      venue: venue.name,
      venueId: venue.id,
      admin: ADMIN_EMAIL,
      staff: createdStaff.length,
      shifts: shiftRows.length,
      guests: guests.length,
      reservations: reservationCount,
      waitlist: waitlistCount,
      checks: summary._count,
      salesDollars: Math.round((summary._sum.totalCents ?? 0) / 100),
    }, null, 2));
  } finally {
    await prisma.$disconnect();
  }
}

const isDirect = process.argv[1]?.replace(/\\/g, '/').includes('seed-enish-houston');
if (isDirect) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
