// Diagnostic: what does each failing site's homepage actually serve?
// Dumps title, status, video-ish hrefs (top 8), and any media URL in raw HTML.
const { chromium } = require('playwright');
const https = require('https');
const http = require('http');

const UA_MOBILE =
  'Mozilla/5.0 (Linux; Android 14; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.6778.135 Mobile Safari/537.36';

const SITES = {
  beeg: 'https://beeg.com',
  yourporn: 'https://yourporn.sexy',
  ixxx: 'https://ixxx.com',
  tubesafari: 'https://www.tubesafari.com',
  fuq: 'https://www.fuq.com',
  pornkai: 'https://www.pornkai.com',
  tubegalore: 'https://www.tubegalore.com',
  hdroom: 'https://hdroom.com',
  xxxshame: 'https://xxxshame.com',
  alohatube: 'https://www.alohatube.com',
  iwank: 'https://iwank.tv',
  eporner: 'https://www.eporner.com',
  thumbzilla: 'https://www.thumbzilla.com',
  xhamster: 'https://xhamster.com',
  xmoviesforyou: 'https://xmoviesforyou.com',
};

function fetchHtml(url) {
  return new Promise((resolve) => {
    const u = new URL(url);
    const mod = u.protocol === 'http:' ? http : https;
    const req = mod.get(u, { headers: { 'User-Agent': UA_MOBILE, 'Accept': 'text/html,*/*;q=0.8' }, timeout: 12000 }, (res) => {
      let b = ''; res.setEncoding('utf8'); res.on('data', (d) => (b += d));
      res.on('end', () => resolve({ status: res.statusCode, body: b, finalUrl: res.url || url, headers: res.headers }));
    });
    req.on('error', () => resolve({ status: 0, body: '', finalUrl: url, headers: {} }));
    req.on('timeout', () => { req.destroy(); resolve({ status: 0, body: '', finalUrl: url, headers: {} }); });
  });
}

async function main() {
  const keys = process.argv[2] ? process.argv[2].split(',') : Object.keys(SITES);
  const browser = await chromium.launch({ headless: true });
  for (const key of keys) {
    const url = SITES[key];
    if (!url) continue;
    console.log(`\n########## ${key} — ${url}`);
    // raw fetch
    const r = await fetchHtml(url);
    console.log(`raw fetch: status=${r.status} len=${r.body.length} finalUrl=${r.finalUrl.slice(0, 80)}`);
    if (r.body) {
      const title = (r.body.match(/<title[^>]*>([^<]*)<\/title>/i) || [])[1] || '';
      console.log(`raw title: ${title.trim().slice(0, 70)}`);
      const media = r.body.match(/https?:\/\/[^"'\s<>]+?\.(?:m3u8|mp4|mpd)(?:[^"'\s<>]*)/gi) || [];
      if (media.length) console.log(`raw media: ${[...new Set(media)].slice(0, 3).join('  |  ')}`);
      const frames = [...r.body.matchAll(/<iframe[^>]+src="([^">]+)"/gi)].map((m) => m[1]);
      if (frames.length) console.log(`raw iframes: ${frames.slice(0, 4).join('  |  ')}`);
      if (/cloudflare|cf-browser|cf-challenge|just a moment/i.test(r.body)) console.log('raw: CLOUDFLARE CHALLENGE');
      if (/(18\+|are you 18|age verification|i am 18)/i.test(r.body)) console.log('raw: AGE GATE');
    }
    // browser
    const ctx = await browser.newContext({ userAgent: UA_MOBILE, viewport: { width: 412, height: 915 }, isMobile: true, hasTouch: true });
    const page = await ctx.newPage();
    try {
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 20000 });
      await page.waitForTimeout(5000);
      const title = await page.title().catch(() => '');
      console.log(`browser title: ${title.slice(0, 70)}`);
      const info = await page.evaluate(() => {
        const hrefs = Array.from(document.querySelectorAll('a[href]')).map((a) => a.href);
        const videoish = hrefs.filter((h) => /\/(video|videos?|watch|view|embed|play)(\/|\?|$)|\/videos\/\d+|\b\d{5,}\b/.test(new URL(h, location.href).pathname + new URL(h, location.href).search)).slice(0, 8);
        return { total: hrefs.length, videoish, hasVideoTag: !!document.querySelector('video'), sourceCount: document.querySelectorAll('video source, video').length };
      });
      console.log(`links total=${info.total} videoTags=${info.hasVideoTag} sources=${info.sourceCount}`);
      if (info.videoish.length) console.log(`video-ish: ${info.videoish.join('\n           ')}`);
      const domMedia = await page.evaluate(() => {
        const out = [];
        document.querySelectorAll('source[src], video').forEach((e) => { const s = e.src || e.currentSrc; if (s) out.push(s); });
        document.querySelectorAll('script').forEach((s) => {
          const m = (s.textContent || '').match(/https?:\/\/[^"'\s]+?\.(?:m3u8|mp4|mpd)[^"'\s]*/gi);
          if (m) out.push(...m);
        });
        return [...new Set(out)].slice(0, 4);
      });
      if (domMedia.length) console.log(`dom media: ${domMedia.join('  |  ')}`);
    } catch (e) {
      console.log(`browser error: ${String(e).slice(0, 100)}`);
    } finally {
      await ctx.close();
    }
  }
  await browser.close();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
