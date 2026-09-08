// Крупный план элементов после правки: node zoom.js "<селектор>" [scrollTo-селектор] ...
const { chromium } = require('playwright');
(async () => {
  const sels = process.argv.slice(2); const b = await chromium.launch();
  const c = await b.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 }); const p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.goto('http://localhost:8765/', { waitUntil: 'networkidle' }); await p.evaluate(() => document.fonts.ready); await p.waitForTimeout(1500);
  await p.evaluate(() => document.querySelectorAll('.marquee__track').forEach(t => { t.style.animation = 'none'; t.style.transform = 'translateX(0)'; }));
  let i = 0;
  for (const sel of sels) {
    const y = await p.evaluate(s => { const el = document.querySelector(s); if (!el) return null; return el.getBoundingClientRect().top + scrollY - 120; }, sel);
    if (y === null) { console.log('нет элемента', sel); continue; }
    await p.evaluate(y => window.__lenis ? window.__lenis.scrollTo(y, { immediate: true }) : scrollTo(0, y), y); await p.waitForTimeout(900);
    const r = await p.evaluate(s => { const r = document.querySelector(s).getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height }; }, sel);
    const x0 = Math.max(0, r.x - 24), y0 = Math.max(0, r.y - 24); const w = Math.min(1440 - x0, r.w + 48), h = Math.min(900 - y0, r.h + 48); if (w <= 0 || h <= 0) { console.log('вне экрана', sel); continue; }
    await p.screenshot({ path: `zoom-${i++}.png`, clip: { x: x0, y: y0, width: w, height: h } });
  }
  console.log(JSON.stringify({ errs, shots: i })); await b.close();
})();
