import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

const worker = new Function(`return (${readFileSync('site/_worker.js', 'utf8').replace('export default', '').replace(/;\s*$/, '')});`)() as {
  fetch(request: Request, env: { ASSETS: { fetch(request: Request): Promise<Response> } }): Promise<Response>;
};
const env = { ASSETS: { async fetch() {
  return new Response('<html></html>', { headers: {
    'Content-Security-Policy': "default-src 'self'; frame-ancestors 'none'",
    'X-Frame-Options': 'DENY',
  } });
} } };

describe('3D scene embedding policy', () => {
  it('permits only same-origin framing of the actual scene asset', async () => {
    const response = await worker.fetch(new Request('https://example.test/app/assets/assets/three/scene.html?frame=1'), env);
    expect(response.headers.get('X-Frame-Options')).toBe('SAMEORIGIN');
    expect(response.headers.get('Content-Security-Policy')).toContain("frame-ancestors 'self'");
    expect(response.headers.get('Content-Security-Policy')).toContain("script-src 'self' 'unsafe-inline'");
  });
  it('keeps anti-framing protection on other assets and the app shell', async () => {
    for (const path of ['/app/', '/app/assets/other.html']) {
      const response = await worker.fetch(new Request(`https://example.test${path}`), env);
      expect(response.headers.get('X-Frame-Options')).toBe('DENY');
      expect(response.headers.get('Content-Security-Policy')).toContain("frame-ancestors 'none'");
    }
  });
});
