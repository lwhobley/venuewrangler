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
    const isAsset = url.pathname.startsWith('/app/_expo/') || url.pathname.startsWith('/app/assets/') || /\.[^/]+$/.test(url.pathname);
    if (isAsset) return env.ASSETS.fetch(request);

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
    response.headers.set('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src 'self' data: blob: https://venue-wrangler-api-c57mm72zpa-ue.a.run.app; connect-src 'self' https://venue-wrangler-api-c57mm72zpa-ue.a.run.app; media-src 'self' blob:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");
    return response;
  },
};
