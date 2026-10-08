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
    // /app/ is the Flutter web build (scripts/build-site.mjs). script-src still
    // has no 'unsafe-inline': web/index.html only loads flutter_bootstrap.js via
    // src, and the build uses --no-web-resources-cdn so CanvasKit/skwasm come
    // from 'self' rather than gstatic. 'wasm-unsafe-eval' is required to
    // instantiate that wasm renderer; it does not permit JS eval. sentry_flutter
    // loads its browser SDK from browser.sentry-cdn.com (version-pinned path).
    // style-src keeps 'unsafe-inline' -- the Flutter engine injects <style>
    // elements at runtime. fonts.gstatic.com is the engine's fallback-font
    // source (fetched, so it is in connect-src too). Supabase covers REST/Auth/
    // Storage (https) and Realtime (wss); sentry.io is crash reporting.
    response.headers.set('Content-Security-Policy', "default-src 'self'; script-src 'self' 'wasm-unsafe-eval' https://browser.sentry-cdn.com; worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; font-src 'self' data: https://fonts.gstatic.com; img-src 'self' data: blob: https://*.supabase.co; connect-src 'self' https://*.supabase.co wss://*.supabase.co https://*.sentry.io https://fonts.gstatic.com; media-src 'self' blob: https://*.supabase.co; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'");
    return response;
  },
};
