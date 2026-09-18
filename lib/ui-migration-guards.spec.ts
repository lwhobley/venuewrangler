import { readdirSync, readFileSync } from 'node:fs';
import { extname, join } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * Two one-way migrations, enforced as shrinking allowlists.
 *
 * Both replace a pattern that is invisible until a user hits it, so a code
 * review will not reliably catch a new instance. Each list may only get
 * shorter: a new screen cannot join it, and a migrated screen deletes its own
 * entry. Deleting the last entry should delete the list.
 */

const CLIENT_ROOTS = ['app', 'components'];

/**
 * Screens still using the data-only `useQuery`, which returns `.data` and
 * nothing else — so `undefined` means "not started", "in flight", "failed" and
 * "refused" indistinguishably. Migrate to `useQueryState` + `QueryBoundary`,
 * which renders loading, error-with-retry, empty and 402 states properly.
 */
const LEGACY_USE_QUERY = new Set([
  'app/(tabs)/bar-stock.tsx',
  'app/(tabs)/chat.tsx',
  'app/(tabs)/clock.tsx',
  'app/(tabs)/floor.tsx',
  'app/(tabs)/guests.tsx',
  'app/(tabs)/integrations.tsx',
  'app/(tabs)/profile.tsx',
  'app/(tabs)/reports.tsx',
  'app/(tabs)/sales.tsx',
  'app/(tabs)/schedule.tsx',
  'app/(tabs)/staff.tsx',
  'app/chat/[id].tsx',
  'app/checklist.tsx',
  'app/floor/editor.tsx',
  'app/host.tsx',
  'app/logbook.tsx',
  'app/reservations.tsx',
  'app/settings/billing.tsx',
  'app/venue/settings.tsx',
  'components/CrmSalesWorkspace.tsx',
  'components/bar-stock/InventoryCards.tsx',
  'components/schedule/AutoScheduleModal.tsx',
  'components/schedule/BlackoutManager.tsx',
  'components/schedule/LaborForecastPanel.tsx',
  'components/schedule/ManagerCalendar.tsx',
  'components/schedule/MyShifts.tsx',
  'components/schedule/ScheduleMemoryPanel.tsx',
]);

/**
 * Screens rendering a TextInput without keyboard handling. On iOS the keyboard
 * covers fields in the lower half of the form, and the first tap on any control
 * is consumed dismissing it instead of pressing the button. Fixed by wrapping
 * in `FormScreen` (or setting `keyboardShouldPersistTaps` +
 * `automaticallyAdjustKeyboardInsets` directly).
 */
const KEYBOARD_UNHANDLED = new Set([
  'app/(tabs)/bar-stock.tsx',
  'app/(tabs)/chat.tsx',
  'app/(tabs)/clock.tsx',
  'app/(tabs)/documents.tsx',
  'app/(tabs)/guests.tsx',
  'app/(tabs)/integrations.tsx',
  'app/(tabs)/staff.tsx',
  'app/event-command-center.tsx',
  'app/floor/editor.tsx',
  'app/help.tsx',
  'app/reservations.tsx',
  'components/CrmSalesWorkspace.tsx',
  'components/HomeWranglerSurface.tsx',
  'components/VenueSwitcher.tsx',
  'components/WranglerIntelligencePanel.tsx',
  'components/schedule/BlackoutManager.tsx',
  'components/schedule/ManagerCalendar.tsx',
  'components/schedule/MyShifts.tsx',
  'components/schedule/ScheduleMemoryPanel.tsx',
]);

describe('UI migration guards', () => {
  it('adds no new screen to the data-only useQuery list', () => {
    const offenders = clientFiles().filter((file) => /\buseQuery\(/.test(readFileSync(file, 'utf8')));
    const added = offenders.map(normalize).filter((file) => !LEGACY_USE_QUERY.has(file));
    expect(added).toEqual([]);
  });

  it('adds no new screen with an unhandled keyboard', () => {
    const offenders = clientFiles().filter((file) => {
      const source = readFileSync(file, 'utf8');
      if (!/\bTextInput\b/.test(source)) return false;
      return !/FormScreen|KeyboardAvoidingView|keyboardShouldPersistTaps/.test(source);
    });
    const added = offenders.map(normalize).filter((file) => !KEYBOARD_UNHANDLED.has(file));
    expect(added).toEqual([]);
  });

  it('keeps both lists free of entries that are already migrated', () => {
    // Without this the lists never shrink in practice — a migrated screen's
    // entry would linger and quietly re-permit a regression.
    const present = new Set(clientFiles().map(normalize));

    const staleUseQuery = [...LEGACY_USE_QUERY].filter((file) => {
      if (!present.has(file)) return true;
      return !/\buseQuery\(/.test(readFileSync(file, 'utf8'));
    });
    const staleKeyboard = [...KEYBOARD_UNHANDLED].filter((file) => {
      if (!present.has(file)) return true;
      const source = readFileSync(file, 'utf8');
      if (!/\bTextInput\b/.test(source)) return true;
      return /FormScreen|KeyboardAvoidingView|keyboardShouldPersistTaps/.test(source);
    });

    expect({ staleUseQuery, staleKeyboard }).toEqual({ staleUseQuery: [], staleKeyboard: [] });
  });
});

describe('Accessibility guards', () => {
  it('gives every interactive control a role', () => {
    // Pressable carries no implicit role on either platform, so without this a
    // control is announced by VoiceOver/TalkBack as plain text — reachable, but
    // not identifiable as actionable. This is workforce software employees are
    // required to use to record paid time, so the bar is higher than usual.
    const offenders = clientFiles()
      .map((file) => {
        const source = readFileSync(file, 'utf8');
        return {
          file: normalize(file),
          controls: (source.match(/<Pressable/g) ?? []).length,
          roles: (source.match(/accessibilityRole/g) ?? []).length,
        };
      })
      .filter((row) => row.controls > 0 && row.roles < row.controls)
      .map((row) => `${row.file}: only ${row.roles} of ${row.controls} controls have a role`);

    expect(offenders).toEqual([]);
  });

  it('announces the disabled state of the punch control', () => {
    // The clock's primary action is disabled outside the geofence. Greying it
    // out conveys nothing to a screen reader; the state and the reason both
    // have to be exposed or the screen is unusable non-visually.
    const source = readFileSync('app/(tabs)/clock.tsx', 'utf8');
    expect(source).toMatch(/accessibilityState=\{\{[^}]*disabled: !canClock/);
    expect(source).toContain('accessibilityHint');
  });
});

function clientFiles(): string[] {
  return CLIENT_ROOTS.flatMap((root) => walk(root)).filter((file) => !file.includes('.spec.'));
}

function walk(root: string): string[] {
  return readdirSync(root, { withFileTypes: true }).flatMap((entry) => {
    const path = join(root, entry.name);
    if (entry.isDirectory()) return walk(path);
    return ['.ts', '.tsx'].includes(extname(path)) ? [path] : [];
  });
}

/** Normalize Windows separators so the allowlists read the same everywhere. */
function normalize(file: string): string {
  return file.split('\\').join('/');
}
