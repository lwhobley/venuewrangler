// Pages normalizes *.html URLs before serving assets. Fetch the canonical
// directory URL, never rewrite /app/sign-in to /app/sign-in.html (a loop).
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== '/app' && !url.pathname.startsWith('/app/')) {
      return env.ASSETS.fetch(request);
    }
    if (!['GET', 'HEAD'].includes(request.method)) {
      return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    const isAsset = url.pathname.startsWith('/app/assets/') || url.pathname.startsWith('/app/canvaskit/') || /\.[^/]+$/.test(url.pathname);
    if (isAsset) {
      const asset = await env.ASSETS.fetch(request);
      const response = new Response(asset.body, asset);
      // Flutter reuses engine and bootstrap file names across releases. Keep
      // one release's shell from loading another release's cached assets.
      response.headers.set('Cache-Control', 'no-store');
      if (url.pathname === '/app/assets/assets/three/scene.html' || url.pathname === '/app/assets/assets/three/scene') {
        // This one asset is deliberately embedded by the operator app. Override
        // the static catch-all anti-framing headers only for its same-origin host.
        response.headers.set('X-Frame-Options', 'SAMEORIGIN');
        response.headers.set('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'self'; form-action 'none'");
      }
      return response;
    }

    const shellUrl = new URL('/app/', url.origin);
    const asset = await env.ASSETS.fetch(new Request(shellUrl, { method: request.method }));
    const response = new Response(asset.body, asset);
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('X-Robots-Tag', 'noindex, nofollow');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('X-Frame-Options', 'DENY');
    response.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
    response.headers.set('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
    response.headers.set('Permissions-Policy', 'camera=(self), microphone=(), geolocation=(self)');
    // Popups stay allowed so provider/checkout tabs can open; the opener link is isolated.
    response.headers.set('Cross-Origin-Opener-Policy', 'same-origin-allow-popups');
    response.headers.set('Cross-Origin-Resource-Policy', 'same-site');
    // /app/ is the Flutter web build (scripts/build-site.mjs). script-src still
    // has no 'unsafe-inline': web/index.html only loads flutter_bootstrap.js via
    // src, and the build uses --no-web-resources-cdn so CanvasKit/skwasm come
    // from 'self' rather than gstatic. 'wasm-unsafe-eval' is required to
    // instantiate that wasm renderer; it does not permit JS eval. sentry_flutter
    // loads its browser SDK from browser.sentry-cdn.com (version-pinned path).
    // style-src keeps 'unsafe-inline' -- the Flutter engine injects <style>
    // elements at runtime. fonts.gstatic.com is the engine's fallback-font
    // source (fetched, so it is in connect-src too). Supabase covers REST/Auth/
    // Storage/Edge Functions (https) and Realtime (wss), pinned to the one production
    // project host (the SUPABASE_URL in codemagic.yaml / FLUTTER_PRODUCTION_ENV_JSON) rather
    // than *.supabase.co, so a script-injection bug cannot exfiltrate to an attacker's own
    // Supabase project (audit F-06). If the project is ever migrated, update the host in this
    // CSP and in tests/studio-headers.spec.ts together. sentry.io is crash reporting.
    response.headers.set('Content-Security-Policy', "default-src 'self'; script-src 'self' 'wasm-unsafe-eval' https://browser.sentry-cdn.com; worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; font-src 'self' data: https://fonts.gstatic.com; img-src 'self' data: blob: https://puttwjwmwrzmhpsjykuj.supabase.co; connect-src 'self' https://puttwjwmwrzmhpsjykuj.supabase.co wss://puttwjwmwrzmhpsjykuj.supabase.co https://*.sentry.io https://fonts.gstatic.com; media-src 'self' blob: https://puttwjwmwrzmhpsjykuj.supabase.co; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'");
    return response;
  },
};
