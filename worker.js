// Cloudflare Worker - Static Site Host
// 用于托管 PWA 静态文件

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
};

export default {
  async fetch(request, env, ctx) {
    let url = new URL(request.url);
    let path = url.pathname;

    // 默认返回 index.html
    if (path === '/' || path.endsWith('/')) {
      path = '/index.html';
    }

    // 获取文件
    const asset = await env.ASSETS.fetch(
      new Request(new URL(path, request.url))
    );

    if (asset.ok) {
      const response = new Response(asset.body, asset);
      
      // 设置正确的 Content-Type
      const ext = path.split('.').pop().toLowerCase();
      const contentType = MIME_TYPES[ext] || 'application/octet-stream';
      response.headers.set('Content-Type', contentType);

      // PWA 相关 headers
      if (path.endsWith('.html') || path === '/manifest.webmanifest') {
        response.headers.set('Cache-Control', 'no-cache');
      } else {
        response.headers.set('Cache-Control', 'public, max-age=31536000');
      }

      // CORS headers (PWA 需要)
      response.headers.set('Access-Control-Allow-Origin', '*');

      return response;
    }

    // 404 fallback
    return new Response('404 Not Found', { status: 404 });
  }
};
