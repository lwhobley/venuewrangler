import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

function source(relativePath: string): string {
  return readFileSync(join(process.cwd(), relativePath), 'utf8');
}

describe('production readiness regressions', () => {
  it('keeps Supabase Vault out of the portable restore-drill archive', () => {
    expect(source('.github/workflows/database-backup.yml')).toContain('--exclude-extension=supabase_vault');
  });

  it('repairs the restore drill so the backup job can finish', () => {
    const backup = source('.github/workflows/database-backup.yml');
    // The dump is --schema=public, so btree_gist (which the two GiST exclusion
    // constraints depend on) has to be created on the drill target or every
    // restore fails on those constraints and the whole job fails with it.
    expect(backup).toContain('CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions');
    expect(backup).toContain('--exit-on-error');
    expect(backup).toContain('TableAssignment_no_overlap_excl');
  });

  it('publishes crawler directives and a preferred URL for every public page', () => {
    expect(source('site/robots.txt')).toContain('Sitemap: https://venuewrangler.com/sitemap.xml');
    const sitemap = source('site/sitemap.xml');
    for (const page of ['/', '/faq/', '/billing/', '/support/', '/privacy/', '/terms/']) {
      expect(sitemap).toContain(`<loc>https://venuewrangler.com${page}</loc>`);
    }
    for (const page of ['site/index.html', 'site/faq/index.html', 'site/billing/index.html', 'site/support/index.html', 'site/privacy/index.html', 'site/terms/index.html']) {
      expect(source(page)).toContain('rel="canonical"');
      expect(source(page)).toContain('og:url');
    }
  });

  it('keeps destructive and icon-only venue controls accessible', () => {
    const chat = source('app/chat/[id].tsx');
    const venueSettings = source('app/venue/settings.tsx');

    expect(chat).toContain("accessibilityLabel={t('chatThread.backLabel')}");
    expect(chat).toContain("accessibilityLabel={t('chatThread.deleteLabel')}");
    expect(venueSettings).toContain("accessibilityLabel={t('venueSettings.decreaseGeofenceRadius')}");
    expect(venueSettings).toContain("accessibilityLabel={t('venueSettings.increaseGeofenceRadius')}");
  });
});
