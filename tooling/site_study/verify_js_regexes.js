// Verifies the dual-form script regexes as stored in headless_resniffer.dart:
// each slash optionally preceded by one backslash — matches plain AND
// JSON-escaped forms; the replace() + https: prefix normalizes all to https://.
const re = /(?:https?:)?\\?\/\\?\/[^"'\s]+?\.(m3u8|mpd|mp4)(?!\w)/gi;
const unescape = /\\\//g;
const cases = [
  '"https://cdn.com/x/y.mp4"',             // plain absolute
  '"https://cdn.com\\/x\\/y.mp4"',         // plain scheme, escaped path
  '"//cdn.com/x.m3u8"',                    // plain protocol-relative
  '"\\/\\/cdn.com\\/x.m3u8"',              // fully escaped protocol-relative
  '"https:\\/\\/cdn.com\\/x.m3u8"',        // fully escaped absolute
  'https://cdn.com/w.m3u8x',               // must NOT match (lookahead)
  'http://cdn.com/plain.m3u8',             // http scheme
];
let ok = true;
for (const c of cases) {
  const hits = [];
  let m;
  while ((m = re.exec(c)) !== null) {
    let u = m[0].replace(unescape, '/');
    if (u.indexOf('//') === 0) u = 'https:' + u;
    hits.push(u);
  }
  console.log(JSON.stringify(c), '->', JSON.stringify(hits));
  if (c.includes('m3u8x') && hits.length !== 0) ok = false;
  const expected = c.includes('m3u8x') ? 0 : 1;
  if (hits.length !== expected) ok = false;
}
// single-URL resniff regex
const re1 = /(?:https?:)?\\?\/\\?\/[^"\s]+\.m3u8[^"\s]*/;
const m2 = '"\\/\\/cdn.com\\/a\\/b.m3u8?t=1"'.match(re1);
console.log('single escaped rel:', m2 ? m2[0] : null);
if (!m2) ok = false;
const m3 = '"https://cdn.com/a.m3u8"'.match(re1);
console.log('single abs:', m3 ? m3[0] : null);
if (!m3) ok = false;
console.log(ok ? 'ALL OK' : 'FAILURES');
