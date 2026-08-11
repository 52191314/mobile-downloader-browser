// Site-compatibility study harness for Aurora Downloader's sniffer pipeline.
//
// Mirrors the app's THREE generic extraction tiers on a live site:
//   T1 (static)   : NativeHtmlMediaExtractor.parseHtmlForMedia port — direct
//                   .m3u8/.mp4/.mpd URLs, escaped-JSON URLs, base64 URLs,
//                   plus iframe-src recursion (fetch + re-parse, depth<=2).
//   T2 (rendered) : HeadlessPageResniffer.resniffAll port — rendered-DOM
//                   harvest (source/video/audio/meta/scripts/iframes) and
//                   performance.getEntriesByType('resource').
//   T3 (network)  : ground truth — every response the real browser fetched
//                   that looks like media (.m3u8/.mpd/.mp4/.ts/.m4s/seg).
//
// Verdict per site: PASS if T1 or T2 yields a media URL; else FAIL with the
// observed blocker (age gate / WAF / JS-only / geo block / dead link).
//
// Usage: node probe_sites.js [--sites=pornhub,xvideos] [--json out.json]
// (site keys are the object keys in SITES below; default: all 20)
const { chromium } = require('playwright');
const https = require('https');
const http = require('http');

const UA_MOBILE =
  'Mozilla/5.0 (Linux; Android 14; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.6778.135 Mobile Safari/537.36';

const SITES = {
  // --- Top 10 free tubes (ThePornDude 2026) ---
  pornhub:       { url: 'https://www.pornhub.com',       kind: 'tube' },
  xvideos:       { url: 'https://www.xvideos.com',       kind: 'tube' },
  xhamster:      { url: 'https://xhamster.com',          kind: 'tube' },
  xnxx:          { url: 'https://www.xnxx.com',          kind: 'tube' },
  eporner:       { url: 'https://www.eporner.com',       kind: 'tube' },
  hqporner:      { url: 'https://hqporner.com',          kind: 'tube' },
  beeg:          { url: 'https://beeg.com',              kind: 'tube' },
  yourporn:      { url: 'https://yourporn.sexy',         kind: 'tube' },
  spankbang:     { url: 'https://spankbang.com',         kind: 'tube' },
  xmoviesforyou: { url: 'https://xmoviesforyou.com',     kind: 'tube' },
  // --- Top 10 aggregators (ThePornDude 2026) ---
  ixxx:          { url: 'https://ixxx.com',              kind: 'aggregator' },
  tubesafari:    { url: 'https://www.tubesafari.com',    kind: 'aggregator' },
  thumbzilla:    { url: 'https://www.thumbzilla.com',    kind: 'aggregator' },
  fuq:           { url: 'https://www.fuq.com',           kind: 'aggregator' },
  pornkai:       { url: 'https://www.pornkai.com',       kind: 'aggregator' },
  tubegalore:    { url: 'https://www.tubegalore.com',    kind: 'aggregator' },
  hdroom:        { url: 'https://hdroom.xxx',            kind: 'aggregator' },
  xxxshame:      { url: 'https://xxxshame.com',          kind: 'aggregator' },
  alohatube:     { url: 'https://www.alohatube.com',     kind: 'aggregator' },
  iwank:         { url: 'https://iwank.tv',              kind: 'aggregator' },
};

// ---------- T1: exact port of NativeHtmlMediaExtractor.parseHtmlForMedia ----------
const RE_DIRECT = /https?:\/\/[^\s"<>]+?\.(?:m3u8|mp4|mpd)(?:\?[^\s"<>]+)?/gi;
const RE_ESCAPED = /https?:\\\/\\\/[^\s"<>]+?\.(?:m3u8|mp4|mpd)(?:\?[^\s"<>]+)?/gi;
const RE_B64 = /aHR0c[a-zA-Z0-9+/=]{20,}/g;
const RE_IFRAME_DQ = /<iframe[^>]+src="([^">]+)"/gi;
const RE_IFRAME_SQ = /<iframe[^>]+src='([^'>]+)'/gi;

function cleanUrl(raw) {
  let c = raw.trim();
  while (c.length && ["'", '"', ';', ',', ')'].includes(c[c.length - 1])) c = c.slice(0, -1);
  return c;
}
function validStream(u) {
  if (!u.startsWith('http')) return false;
  if (u.includes('ping.m3u8') || u.includes('/ping')) return false;
  return u.includes('.m3u8') || u.includes('.mp4') || u.includes('.mpd');
}
function parseHtmlForMedia(html) {
  const out = new Set();
  for (const m of html.matchAll(RE_DIRECT)) {
    const c = cleanUrl(m[0]);
    if (validStream(c)) out.add(c);
  }
  for (const m of html.matchAll(RE_ESCAPED)) {
    const c = cleanUrl(m[0].replace(/\\\//g, '/'));
    if (validStream(c)) out.add(c);
  }
  for (const m of html.matchAll(RE_B64)) {
    try {
      const dec = Buffer.from(m[0], 'base64').toString('utf8');
      const c = cleanUrl(dec);
      if (validStream(c)) out.add(c);
    } catch (_) {}
  }
  return [...out];
}
function iframeSrcs(html) {
  const out = [];
  for (const m of html.matchAll(RE_IFRAME_DQ)) out.push(m[1]);
  for (const m of html.matchAll(RE_IFRAME_SQ)) out.push(m[1]);
  return out;
}

// ---------- native fetch (T1 transport, like NetworkBindingService) ----------
function fetchHtml(url, referer) {
  return new Promise((resolve) => {
    const u = new URL(url);
    const mod = u.protocol === 'http:' ? http : https;
    const req = mod.get(
      u,
      {
        headers: {
          'User-Agent': UA_MOBILE,
          'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.9',
          ...(referer ? { Referer: referer } : {}),
        },
        timeout: 12000,
      },
      (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (d) => (body += d));
        res.on('end', () => resolve({ status: res.statusCode, body, finalUrl: res.url || url, headers: res.headers }));
      }
    );
    req.on('error', () => resolve({ status: 0, body: '', finalUrl: url, headers: {} }));
    req.on('timeout', () => { req.destroy(); resolve({ status: 0, body: '', finalUrl: url, headers: {} }); });
  });
}

async function tier1Static(pageUrl) {
  const found = { media: [], iframes: [], errors: [] };
  const r1 = await fetchHtml(pageUrl);
  if (r1.status === 0) { found.errors.push('fetch failed (network/timeout)'); return found; }
  if (r1.status >= 400) { found.errors.push(`HTTP ${r1.status}`); return found; }
  found.media = parseHtmlForMedia(r1.body);
  const frames = iframeSrcs(r1.body).slice(0, 3);
  found.iframes = frames;
  // depth-1 iframe recursion (app does depth<=2)
  for (const f of frames) {
    let abs;
    try { abs = new URL(f, pageUrl).href; } catch (_) { continue; }
    if (!abs.startsWith('http')) continue;
    const r2 = await fetchHtml(abs, pageUrl);
    if (r2.status >= 200 && r2.status < 400 && r2.body) {
      for (const u of parseHtmlForMedia(r2.body)) found.media.push(u);
    }
  }
  found.media = [...new Set(found.media)];
  return found;
}

// ---------- T2: exact port of HeadlessPageResniffer DOM queries ----------
const DOM_QUERY_JS = `(() => {
  const out = new Set();
  function scan(root) {
    if (!root || !root.querySelectorAll) return;
    const sources = root.querySelectorAll('source[src]');
    for (const s of sources) {
      const src = s.src || s.getAttribute('src') || '';
      if (src && /\\.(m3u8|mpd|mp4)(?!\\w)/i.test(src)) out.add(src);
    }
    const medias = root.querySelectorAll('video, audio');
    for (const m of medias) {
      const src = m.currentSrc || m.src || '';
      if (src && /\\.(m3u8|mpd|mp4)(?!\\w)/i.test(src)) out.add(src);
    }
    const metas = root.querySelectorAll('meta[property="og:video"], meta[property="twitter:player:stream"], meta[itemprop="contentURL"]');
    for (const mt of metas) {
      const c = mt.content || '';
      if (c && /\\.(m3u8|mpd|mp4)(?!\\w)/i.test(c)) out.add(c);
    }
    const scripts = root.querySelectorAll('script');
    for (const sc of scripts) {
      const text = sc.textContent || '';
      const re = /https?:\\/\\/[^"'\\s]+?\\.(m3u8|mpd|mp4)(?!\\w)/gi;
      let m;
      while ((m = re.exec(text)) !== null) {
        const u = m[0].replace(/\\\\\\//g, '/');
        if (u.indexOf('ping.m3u8') === -1 && u.indexOf('/ping') === -1) out.add(u);
      }
    }
  }
  scan(document);
  const iframes = document.querySelectorAll('iframe');
  for (const f of iframes) {
    try { const fr = f.contentDocument; if (fr) scan(fr); } catch (_) {}
  }
  return JSON.stringify(Array.from(out));
})();`;

const PERF_QUERY_JS = `(() => {
  try {
    const out = new Set();
    const entries = performance.getEntriesByType('resource');
    for (const e of entries) {
      const u = e.name;
      if (/\\.(m3u8|mpd|mp4)(?!\\w)/i.test(u) &&
          u.indexOf('ping.m3u8') === -1 && u.indexOf('/ping') === -1) {
        out.add(u);
      }
    }
    return JSON.stringify(Array.from(out));
  } catch(e) { return '[]'; }
})();`;

const MEDIA_RESPONSE_RE = /\.(m3u8|mpd|mp4|m4s|ts)(\?|#|$)/i;

const CHALLENGE_RE = /(just a moment|attention required|checking your browser|verify you are human|ddos|cf-browser|cloudflare|access denied|forbidden)/i;
const AGE_GATE_RE = /(18\+|adults? only|age verif|you must be|i am 18|enter site|confirm|restricted)/i;

async function waitOutChallenge(page, maxMs = 16000) {
  // Cloudflare managed challenges auto-pass in a real browser once JS runs;
  // poll until the challenge title clears or we give up.
  const deadline = Date.now() + maxMs;
  let lastTitle = '';
  while (Date.now() < deadline) {
    lastTitle = await page.title().catch(() => '');
    if (lastTitle && !CHALLENGE_RE.test(lastTitle)) return true;
    await page.waitForTimeout(1500);
  }
  return false;
}

// ---------- video-link heuristics (mirrors ListingPageCrawler's generic spirit) ----------
const VIDEO_LINK_RE = /\/(video|videos?|watch|view|embed|play|v|e|show|hd-porn)(\/|\?|$)|view_video|\.php\?viewkey|\/videos\/\d+/;
const REDIRECT_PATH_RE = /\/(ff\/out|out|away|go|redirect|exit|click|adclick|banner|track|_xa|ads)/;
function looksLikeVideoLink(href, pageHost) {
  if (!href || href.startsWith('javascript:') || href.startsWith('mailto:')) return false;
  let u;
  try { u = new URL(href, `https://${pageHost}/`); } catch (_) { return false; }
  if (u.host !== pageHost && !u.host.endsWith('.' + pageHost)) return false; // same-site only
  const p = u.pathname;
  if (REDIRECT_PATH_RE.test(p)) return false;
  if (/\.(css|js|png|jpe?g|gif|webp|svg|ico|woff2?|json|xml)(\?|$)/i.test(p)) return false;
  if (/(about|contact|privacy|terms|faq|login|signup|register|join|premium|upgrade|dmca|takedown|category|categories|pornstar|channels?|models?|tags?|search|upload|settings|help|support|blog|news|tour|photo|pictures|images|gallery)/i.test(p)) return false;
  return VIDEO_LINK_RE.test(p) || /\b\d{5,}\b/.test(p);
}

// ---------- main probe ----------
async function findFirstVideoLink(browser, site) {
  const ctx = await browser.newContext({
    userAgent: UA_MOBILE,
    viewport: { width: 412, height: 915 },
    isMobile: true,
    hasTouch: true,
    locale: 'en-US',
  });
  const page = await ctx.newPage();
  let videoUrl = null;
  let pageTitle = '';
  let blocked = null;
  try {
    page.on('response', (r) => { if (r.status() >= 400 && r.request().isNavigationRequest()) blocked = `nav HTTP ${r.status()}`; });
    await page.goto(site.url, { waitUntil: 'domcontentloaded', timeout: 25000 });
    await page.waitForTimeout(5000);
    pageTitle = await page.title().catch(() => '');
    if (pageTitle && CHALLENGE_RE.test(pageTitle)) {
      await waitOutChallenge(page);
      await page.waitForTimeout(2000);
      pageTitle = await page.title().catch(() => '');
    }
    // Host may have changed after redirects (e.g. yourporn.sexy -> youporn.com).
    const pageHost = new URL(page.url()).host;
    for (let attempt = 0; attempt < 3 && !videoUrl; attempt++) {
      const hrefs = await page.evaluate(() =>
        Array.from(document.querySelectorAll('a[href]')).map((a) => a.href).slice(0, 600)
      );
      for (const h of hrefs) {
        if (looksLikeVideoLink(h, pageHost)) { videoUrl = h; break; }
      }
      if (!videoUrl) {
        // lazy grids: scroll once to trigger card injection (e.g. iwank)
        await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight)).catch(() => {});
        await page.waitForTimeout(3000);
      }
    }
    if (!videoUrl) {
      const t = pageTitle.toLowerCase();
      if (AGE_GATE_RE.test(t)) {
        blocked = 'age gate on homepage title';
      } else if (CHALLENGE_RE.test(t)) {
        blocked = 'WAF/challenge did not auto-pass';
      }
    }
  } catch (e) {
    blocked = `goto error: ${String(e).slice(0, 120)}`;
  } finally {
    await ctx.close();
  }
  return { videoUrl, pageTitle, blocked };
}

async function probeSite(browser, key, site, videoUrlOverride) {
  const report = { site: key, kind: site.kind, url: site.url, verdict: 'FAIL', tier: null, videoUrl: null, t1: null, t2: null, t3: [], notes: [] };
  let found;
  if (videoUrlOverride) {
    found = { videoUrl: videoUrlOverride, pageTitle: '(override)', blocked: null };
  } else {
    found = await findFirstVideoLink(browser, site);
    report.pageTitle = found.pageTitle;
    if (found.blocked) report.notes.push(`homepage: ${found.blocked}`);
  }
  if (!found.videoUrl) {
    report.notes.push('no video link found on homepage');
    return report;
  }
  report.videoUrl = found.videoUrl;

  // T1: static extraction (native fetch + regex + iframe recursion)
  report.t1 = await tier1Static(found.videoUrl);
  if (report.t1.errors.length) report.notes.push(`T1: ${report.t1.errors.join('; ')}`);

  // T2 + T3: rendered browser on the video page
  const ctx = await browser.newContext({
    userAgent: UA_MOBILE,
    viewport: { width: 412, height: 915 },
    isMobile: true,
    hasTouch: true,
    locale: 'en-US',
  });
  const page = await ctx.newPage();
  const netMedia = new Set();
  let navStatus = null;
  page.on('response', (r) => {
    if (MEDIA_RESPONSE_RE.test(r.url())) netMedia.add(r.url().split('#')[0]);
    if (r.request().isNavigationRequest() && r.status() >= 400) navStatus = r.status();
  });
  try {
    await page.goto(found.videoUrl, { waitUntil: 'domcontentloaded', timeout: 25000 });
    await page.waitForTimeout(2500);
    const title0 = await page.title().catch(() => '');
    if (title0 && CHALLENGE_RE.test(title0)) {
      await waitOutChallenge(page);
      await page.waitForTimeout(2000);
    }
    await page.waitForTimeout(8000); // player boot + fetch window
    const dom = await page.evaluate(DOM_QUERY_JS).catch(() => '[]');
    const perf = await page.evaluate(PERF_QUERY_JS).catch(() => '[]');
    let domList = [], perfList = [];
    try { domList = JSON.parse(dom); } catch (_) {}
    try { perfList = JSON.parse(perf); } catch (_) {}
    report.t2 = { dom: domList, perf: perfList };
    report.t3 = [...netMedia];
    const title = await page.title().catch(() => '');
    if (navStatus) report.notes.push(`video page nav HTTP ${navStatus}`);
    if (!domList.length && !perfList.length && !netMedia.size) {
      const t = title.toLowerCase();
      if (AGE_GATE_RE.test(t)) report.notes.push('age gate on video page');
      else if (CHALLENGE_RE.test(t)) report.notes.push('WAF/challenge did not auto-pass on video page');
      else if (/(404|not found|error)/.test(t)) report.notes.push(`video page title: "${title.slice(0, 60)}"`);
      else if (t) report.notes.push(`video page title: "${title.slice(0, 60)}"`);
      else report.notes.push('empty title — likely JS-blocked or blank shell');
    }
  } catch (e) {
    report.notes.push(`render error: ${String(e).slice(0, 120)}`);
  } finally {
    await ctx.close();
  }

  const t1hits = report.t1 ? report.t1.media.length : 0;
  const t2hits = report.t2 ? report.t2.dom.length + report.t2.perf.length : 0;
  if (t1hits > 0) { report.verdict = 'PASS'; report.tier = 'T1-static'; }
  else if (t2hits > 0) { report.verdict = 'PASS'; report.tier = 'T2-rendered'; }
  else if (report.t3.length > 0) { report.verdict = 'PARTIAL'; report.tier = 'T3-network-only'; }
  return report;
}

async function main() {
  const args = process.argv.slice(2);
  const sitesArg = args.find((a) => a.startsWith('--sites='));
  const jsonArg = args.find((a) => a.startsWith('--json='));
  const videoArg = args.find((a) => a.startsWith('--video-url='));
  const keys = sitesArg ? sitesArg.split('=')[1].split(',') : Object.keys(SITES);
  const browser = await chromium.launch({ headless: true });
  const reports = [];
  for (const key of keys) {
    const site = SITES[key];
    if (!site) { console.log(`SKIP unknown site: ${key}`); continue; }
    const t0 = Date.now();
    const r = await probeSite(browser, key, site, videoArg ? videoArg.split('=')[1] : null);
    r.ms = Date.now() - t0;
    reports.push(r);
    const hits = r.tier || (r.verdict === 'PARTIAL' ? 'T3-only' : 'NONE');
    console.log(`[${r.verdict.padEnd(7)}] ${key.padEnd(14)} ${hits.padEnd(9)} ${r.videoUrl || '(no video link)'} ${r.ms}ms`);
    if (r.t1 && r.t1.media.length) console.log(`         T1 media: ${r.t1.media.slice(0, 2).join('  |  ')}`);
    if (r.t2 && (r.t2.dom.length || r.t2.perf.length)) console.log(`         T2 dom: ${r.t2.dom.slice(0, 2).join('  |  ')}${r.t2.perf.length ? '  [perf: ' + r.t2.perf.slice(0, 1).join('') + ']' : ''}`);
    if (r.notes.length) console.log(`         notes: ${r.notes.join('; ')}`);
    if (jsonArg) require('fs').writeFileSync(jsonArg.split('=')[1], JSON.stringify(reports, null, 2));
  }
  await browser.close();
  console.log('\n=== SUMMARY ===');
  for (const r of reports) {
    console.log(`${r.verdict.padEnd(7)} ${r.site.padEnd(14)} ${(r.tier || '-').padEnd(11)} ${(r.videoUrl || '(no video link)')}`);
  }
}

main().catch((e) => { console.error('FATAL', e); process.exit(1); });
