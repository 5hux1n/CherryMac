// Serve only the generated product page and allowlisted public assets.
// Configuration, USB reports and logs are processed in the user's browser.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!['GET', 'HEAD'].includes(request.method)) {
      return new Response('Method not allowed', {status: 405, headers: {Allow: 'GET, HEAD'}});
    }
    if (url.pathname === '/app') {
      url.pathname = '/app/';
      return new Response(null, {status: 308, headers: {Location: url.toString(), 'Cache-Control': 'no-store'}});
    }
    if (url.pathname === '/') {
      url.pathname = '/index.html';
    } else if (['/index.php', '/app/', '/app/index.php'].includes(url.pathname)) {
      url.pathname = '/app/index.html';
    } else if (url.pathname.startsWith('/assets/')) {
      // Compatibility with tabs opened before the /app/ deployment layout.
      url.pathname = '/app' + url.pathname;
    } else if (url.pathname === '/app/release.json') {
      url.pathname = '/release.json';
    }
    if (!['/index.html', '/app/index.html', '/release.json',
           '/site-assets/style.css', '/site-assets/keyboard.png'].includes(url.pathname) &&
        !/^\/app\/assets\/[a-z0-9-]+\.(js|css)$/.test(url.pathname)) {
      return new Response('Not found', {status: 404});
    }
    const asset = await env.ASSETS.fetch(new Request(url, request));
    const headers = new Headers(asset.headers);
    headers.set('Cache-Control', 'no-store');
    headers.set('X-Content-Type-Options', 'nosniff');
    headers.set('Referrer-Policy', 'no-referrer');
    headers.set('Permissions-Policy', 'hid=(self)');
    headers.set('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' http://127.0.0.1:32247; object-src 'none'; base-uri 'none'; frame-ancestors 'none'");
    headers.set('X-Frame-Options', 'DENY');
    return new Response(asset.body, {status: asset.status, headers});
  }
};
