import { afterEach, describe, expect, it, vi } from 'vitest';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import worker from '../site/_worker';
import { shouldCopySiteSource } from '../scripts/site-build-files.mjs';

const root = resolve(__dirname, '..');
const read = (path: string) => readFileSync(resolve(root, path), 'utf8');

describe('hosted Expo routing', () => {
  it('allows authenticated API images without allowing arbitrary image hosts', async () => {
    const fetch = vi.fn().mockResolvedValue(new Response('<html>app</html>'));
    const response = await worker.fetch(new Request('https://venuewrangler.com/app/chat/1'), { ASSETS: { fetch } });
    const directive = response.headers.get('Content-Security-Policy')!.split(';').find((part: string) => part.trim().startsWith('img-src'))!;
    expect(directive).toContain('https://venue-wrangler-api-c57mm72zpa-ue.a.run.app');
    expect(directive).not.toContain('*');
  });
  afterEach(() => { vi.unstubAllEnvs(); });

  it('does not rewrite a clean URL to its own canonical HTML file', () => {
    const rules = read('site/_redirects').split('\n').filter((line) => line.trim() && !line.startsWith('#'));
    for (const rule of rules) {
      const [from, to, status] = rule.trim().split(/\s+/);
      if (status === '200' && to.endsWith('.html')) {
        expect(to.replace(/\/index\.html$/, '/').replace(/\.html$/, '')).not.toBe(from);
      }
    }
  });

  it('configures /app only for the hosted build, leaving native URLs unchanged', () => {
    expect(existsSync(resolve(root, 'app.config.js'))).toBe(true);
    const configure = createRequire(import.meta.url)(resolve(root, 'app.config.js'));
    const config = JSON.parse(read('app.json')).expo;
    vi.stubEnv('EXPO_WEB_BASE_PATH', '');
    expect(configure({ config })).toEqual(config);
    vi.stubEnv('EXPO_WEB_BASE_PATH', '/app');
    expect(configure({ config })).toMatchObject({ experiments: { baseUrl: '/app' }, web: { output: 'single' } });
  });

  it('builds the current client before uploading the Pages site', () => {
    const workflow = read('.github/workflows/deploy-cloudflare-pages.yml');
    expect(workflow).toContain('npm run build:site');
    expect(workflow).toContain('pages deploy dist-site');
    expect(workflow.indexOf('npm run build:site')).toBeLessThan(workflow.indexOf('pages deploy dist-site'));
  });

  it('never publishes test source or a stale checked-in client bundle', () => {
    expect(shouldCopySiteSource(resolve(root, 'site/onboarding.spec.ts'), root)).toBe(false);
    expect(shouldCopySiteSource(resolve(root, 'site/app'), root)).toBe(false);
    expect(shouldCopySiteSource(resolve(root, 'site/_worker.js'), root)).toBe(true);
    expect(shouldCopySiteSource(resolve(root, 'site/index.html'), root)).toBe(true);
  });

  it.each(['/app', '/app/', '/app/sign-in', '/app/chat/conversation-123', '/app/event-command-center?eventId=event-123'])(
    'serves %s without a redirect, preserving the URL for the client router', async (path) => {
      const fetch = vi.fn().mockResolvedValue(new Response('<html>app shell</html>', { headers: { 'Content-Type': 'text/html' } }));
      const response = await worker.fetch(new Request(`https://venuewrangler.com${path}`), { ASSETS: { fetch } });
      expect(response.status).toBe(200);
      expect(response.headers.get('Location')).toBeNull();
      expect(fetch.mock.calls[0][0].url).toBe('https://venuewrangler.com/app/');
      expect(response.headers.get('X-Robots-Tag')).toBe('noindex, nofollow');
      expect(response.headers.get('Cache-Control')).toBe('no-store');
      expect(response.headers.get('Content-Security-Policy')).toContain("font-src 'self'");
      expect(response.headers.get('Permissions-Policy')).toContain('geolocation=(self)');
    },
  );

  it.each(['/not-a-real-page', '/app/_expo/missing.js', '/app/assets/missing.ttf'])(
    'does not turn a missing public page or asset into a successful app document: %s', async (path) => {
      const fetch = vi.fn().mockResolvedValue(new Response('not found', { status: 404 }));
      const request = new Request(`https://venuewrangler.com${path}`);
      const response = await worker.fetch(request, { ASSETS: { fetch } });
      expect(response.status).toBe(404);
      expect(fetch).toHaveBeenCalledExactlyOnceWith(request);
    },
  );

  it('does not accept form submissions at app document routes', async () => {
    const fetch = vi.fn();
    const response = await worker.fetch(new Request('https://venuewrangler.com/app/sign-in', { method: 'POST' }), { ASSETS: { fetch } });
    expect(response.status).toBe(405);
    expect(fetch).not.toHaveBeenCalled();
  });
});
