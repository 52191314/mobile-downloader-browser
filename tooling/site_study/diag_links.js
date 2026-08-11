// Deep-dive: link/video structures of specific pages.
const { chromium } = require('playwright');
const UA = 'Mozilla/5.0 (Linux; Android 14; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.6778.135 Mobile Safari/537.36';

async function main() {
  const browser = await chromium.launch({ headless: true });
  const cases = [
    ['eporner', 'https://www.eporner.com/'],
    ['iwank', 'https://iwank.tv/en/104355/japanese_mom/'],
    ['xmoviesforyou', 'https://xmoviesforyou.com/myfriendshotgirl-jojo-austin-33944'],
    ['alohatube', 'https://www.alohatube.com/'],
    ['xxxshame', 'https://xxxshame.com/'],
  ];
  for (const [name, url] of cases) {
    const ctx = await browser.newContext({ userAgent: UA, viewport: { width: 412, height: 915 }, isMobile: true, hasTouch: true });
    const page = await ctx.newPage();
    try {
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 25000 });
      await page.waitForTimeout(6000);
      const info = await page.evaluate(() => {
        const host = location.host;
        const anchors = Array.from(document.querySelectorAll('a[href]')).map((a) => a.href);
        const internal = [...new Set(anchors)].filter((h) => { try { return new URL(h).host === host || new URL(h).host.endsWith('.' + host); } catch { return false; } });
        const external = [...new Set(anchors)].filter((h) => { try { return new URL(h).host !== host && !new URL(h).host.endsWith('.' + host) && /^https?:/.test(h); } catch { return false; } });
        const videos = Array.from(document.querySelectorAll('video')).map((v) => ({ src: v.src || v.currentSrc, hasSource: v.querySelectorAll('source[src]').length }));
        const sources = Array.from(document.querySelectorAll('source[src]')).map((s) => s.src);
        return {
          title: document.title.slice(0, 60),
          internal: internal.slice(0, 12),
          external: external.slice(0, 6),
          videos, sources: sources.slice(0, 4),
        };
      });
      console.log(`\n===== ${name} — ${url}`);
      console.log('title:', info.title);
      console.log('internal:', JSON.stringify(info.internal));
      console.log('external:', JSON.stringify(info.external));
      console.log('videos:', JSON.stringify(info.videos), 'sources:', JSON.stringify(info.sources));
    } catch (e) {
      console.log(`\n===== ${name} — ERROR ${String(e).slice(0, 120)}`);
    } finally {
      await ctx.close();
    }
  }
  await browser.close();
}
main().catch((e) => { console.error('FATAL', e); process.exit(1); });
