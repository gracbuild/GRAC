// Paste into the browser DevTools Console (F12 -> Console) on the
// Control Statements page and send the output. Read-only: it only
// measures. Lists what makes the page taller than its content.
(() => {
  const docH = document.documentElement.scrollHeight;
  const cw = document.querySelector('.content-wrapper');
  const cwBottom = cw ? Math.round(cw.getBoundingClientRect().bottom + scrollY) : null;
  const rows = [];
  document.querySelectorAll('body *').forEach(e => {
    const r = e.getBoundingClientRect();
    if (!r.height && !r.width) return;
    const bottom = Math.round(r.bottom + scrollY);
    if (cwBottom != null && bottom <= cwBottom + 5) return;
    const cs = getComputedStyle(e);
    rows.push({ tag: e.tagName.toLowerCase(), id: e.id, cls: String(e.className).slice(0, 80),
                top: Math.round(r.top + scrollY), bottom, height: Math.round(r.height),
                position: cs.position, display: cs.display, visibility: cs.visibility,
                minHeight: cs.minHeight });
  });
  rows.sort((a, b) => b.bottom - a.bottom);
  console.log('documentHeight', docH, 'contentWrapperBottom', cwBottom, 'window', innerHeight);
  console.table(rows.slice(0, 15));
  const sw = document.querySelector('.content-wrapper');
  if (sw) console.log('content-wrapper min-height', getComputedStyle(sw).minHeight, 'inline', sw.style.cssText);
})();
