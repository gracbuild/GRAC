// =====================================================================
// dashboard-components.js  (migration 503 -- Dashboard UI specification v2)
//
// Presentation-only building blocks for the module dashboards, shared so
// every dashboard moved onto the v2 layout renders with ONE set of rules
// (spec section 13.2: page header, KPI card, exception panel, chart
// container, data table, empty state, last-refreshed label). Nothing here
// fetches, counts or decides what a number means: a module passes values
// it already received from the server and the link (if any) that opens
// the matching filtered list. Styles: practice-management.css 11c
// (.pm-dx-*).
//
//   window.gracDash = {
//     esc, fmt, pct,
//     kpiCard(o)        executive KPI card (value, label, qualifier, meter, href, title)
//     attention(items)  "Needs attention" panel; zero items listed as clear checks
//     distCard(o)       chart container: stacked bar + legend, or ranked bars
//     ageing(o)         ageing bands, one bar per series on a shared scale
//     table(o)          watchlist / data table with an empty state
//     card(o)           plain titled container
//     snapshot(o)       Home module card: 2-3 figures, links to the module dashboard
//     balance(row)      evens out a two-column .pm-dx-row-2 after render
//     skeleton()        loading placeholder with the final layout's shape
//     errorCard(o)      recoverable error with a Retry button
//   }
//
// Rules the components enforce (spec 3.3 / 3.4 / 3.6):
//   * an element is a link only when the caller passes a real href (or,
//     505, { attr } for a page's in-page drill);
//   * colour comes from the caller's semantic tone, never from the value;
//   * every chart has its numbers as text beside it (legend / counts);
//   * a group with no data says so instead of drawing an empty chart.
// =====================================================================
(function () {
  "use strict";

  const esc = v => String(v ?? "").replace(/[&<>"']/g, ch =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#039;" })[ch]);
  // Tabular numbers; thousands separator only from 10,000 (design guide).
  const fmt = n => {
    const v = Number(n) || 0;
    return Math.abs(v) >= 10000 ? v.toLocaleString("en-IN") : String(v);
  };
  // Whole-number percentage; null when there is no denominator, so the
  // caller can say "no data" rather than show 0%.
  const pct = (part, whole) => {
    const w = Number(whole) || 0;
    return w > 0 ? Math.round((Number(part) || 0) / w * 100) : null;
  };

  // Semantic tones -> token colours (grac-tokens.css). Only these names
  // are accepted, so a module cannot colour by count.
  const TONE = {
    success:  "var(--success-500)",
    danger:   "var(--danger-500)",
    critical: "var(--danger-700)",
    warning:  "var(--warning-500)",
    info:     "var(--primary-500)",
    info2:    "var(--primary-300)",
    info3:    "var(--primary-700)",
    neutral:  "var(--neutral-400)",
    muted:    "var(--neutral-300)",
    faint:    "var(--neutral-200)"
  };
  const tone = t => TONE[t] || TONE.info;
  // 505: an item may carry its own configured colour (e.g. the
  // organisation's risk-matrix rating colour) instead of a tone.
  const fill = i => (i && i.colour && /^#[0-9a-f]{3,8}$/i.test(String(i.colour))) ? i.colour : tone(i && i.tone);

  // A link target is either an href (another page) or, 505, { attr }: an
  // attribute string a page's own click handler acts on (Risk Centre's
  // in-page drill, data-dash-drill="n"). Rendered as a focusable button.
  const linkOrDiv = (target, cls, inner, title) => {
    const t = title ? ` title="${esc(title)}"` : "";
    if (target && typeof target === "object" && target.attr)
      return `<div class="${cls} is-link" role="button" tabindex="0"${target.attr}${t}>${inner}</div>`;
    return target
      ? `<a class="${cls} is-link" href="${esc(target)}"${t}>${inner}</a>`
      : `<div class="${cls}"${t}>${inner}</div>`;
  };

  // ---- KPI card ------------------------------------------------------
  // o = { label, value, suffix?, qualifier?, meter? (0-100), meterTone?,
  //       segments? (2026-11-10: [{ count, tone, label }] of segTotal,
  //       drawn side by side in one meter instead of meter/meterTone),
  //       segTotal?,
  //       tone? ('danger'|'warning'|...: colours the value only),
  //       href?, title? (definition tooltip), scope? }
  // 509: value null = not available (e.g. no governance snapshot yet):
  // shown as a dash, never as 0, so it reads differently from a zero
  // count (spec 3.4).
  function kpiCard(o) {
    // 2026-11-10: a split meter -- each segment's share of segTotal, in
    // its own tone, one after another (e.g. implemented, then the rest of
    // the applicable ones, on the track of all statements).
    const segTotal = Number(o.segTotal) || 0;
    const segs = Array.isArray(o.segments) && segTotal > 0
      ? o.segments.filter(sg => Number(sg.count) > 0) : null;
    const meter = segs
      ? `<span class="pm-dx-meter is-split" role="img" aria-label="${esc(segs.map(sg => `${sg.label} ${fmt(sg.count)}`).join(", "))} of ${esc(fmt(segTotal))}">`
        + segs.map(sg => `<span style="width:${Math.max(0, Math.min(100, Number(sg.count) / segTotal * 100))}%;background:${tone(sg.tone)}" title="${esc(sg.label)}: ${esc(fmt(sg.count))}"></span>`).join("")
        + `</span>`
      : o.meter === null || o.meter === undefined ? "" :
      `<span class="pm-dx-meter" role="img" aria-label="${esc(o.meter)}%"><span style="width:${Math.max(0, Math.min(100, o.meter))}%;background:${tone(o.meterTone)}"></span></span>`;
    const inner =
      `<span class="pm-dx-kpi-label">${esc(o.label)}</span>`
      + `<span class="pm-dx-kpi-value${o.tone ? " tone-" + esc(o.tone) : ""}">${o.value === null ? "&mdash;" : esc(fmt(o.value))}${o.suffix ? `<small>${esc(o.suffix)}</small>` : ""}</span>`
      + meter
      + (o.qualifier || o.scope
          ? `<span class="pm-dx-kpi-q">${o.qualifier ? `<span>${o.qualifier}</span>` : ""}${o.scope ? `<span class="pm-dx-scope">${esc(o.scope)}</span>` : ""}</span>` : "");
    return linkOrDiv(o.href, "pm-dx-kpi", inner, o.title);
  }

  // ---- Needs attention -----------------------------------------------
  // items = [{ title, detail, count, severity ('High'|'Medium'), href? }]
  // Rows with count > 0 are listed High first, then by count; the rest
  // are named underneath as checks that are clear (spec 3.4: a configured
  // zero is shown as zero, not hidden).
  function attention(items, o) {
    o = o || {};
    const rank = s => (s === "High" ? 0 : s === "Medium" ? 1 : 2);
    const open = items.filter(i => Number(i.count) > 0)
      .sort((a, b) => rank(a.severity) - rank(b.severity) || b.count - a.count);
    const clear = items.filter(i => !(Number(i.count) > 0));
    const rows = open.map(i => {
      const sev = i.severity === "High" ? "danger" : i.severity === "Medium" ? "warning" : "info";
      const inner = `<span class="pm-dx-att-sev sev-${sev}">${esc(i.severity || "Info")}</span>`
        + `<span class="pm-dx-att-text"><strong>${esc(i.title)}</strong><span>${esc(i.detail || "")}</span></span>`
        + `<span class="pm-dx-att-count">${esc(fmt(i.count))}</span>`
        + `<span class="pm-dx-att-go" aria-hidden="true">${i.href ? '<i class="fa-solid fa-chevron-right"></i>' : ""}</span>`;
      return linkOrDiv(i.href, "pm-dx-att-row", inner, i.href ? "Open the list" : "");
    }).join("");
    const body = open.length
      ? `<div class="pm-dx-att-list">${rows}</div>`
      : `<div class="pm-dx-empty">Nothing needs attention for this scope.</div>`;
    const clearHtml = clear.length
      ? `<p class="pm-dx-att-clear"><i class="fa-solid fa-circle-check" aria-hidden="true"></i> Clear: ${clear.map(c => esc(c.title)).join(" &middot; ")}</p>`
      : "";
    return card({
      title: o.title || "Needs attention",
      meta: open.length ? `${open.length} of ${items.length} checks` : `${items.length} checks`,
      body: body + clearHtml, cls: "pm-dx-attention"
    });
  }

  // ---- Distribution card ---------------------------------------------
  // o = { title, scope?, total?, totalLabel?, items: [{ label, count, tone, href?, title? }],
  //       mode: 'stack' (parts of one whole) | 'bars' (ranked comparison),
  //       footer?, emptyText? }
  function distCard(o) {
    const items = (o.items || []).filter(i => i && i.label !== undefined);
    const sum = items.reduce((s, i) => s + (Number(i.count) || 0), 0);
    const total = o.total !== undefined && o.total !== null ? Number(o.total) : sum;
    let chart;
    if (!sum) {
      chart = `<div class="pm-dx-empty">${esc(o.emptyText || "No records in this scope.")}</div>`;
    } else if (o.mode === "bars") {
      const max = Math.max(1, ...items.map(i => Number(i.count) || 0));
      chart = `<div class="pm-dx-rank">${items.map(i => {
        const w = Math.round((Number(i.count) || 0) / max * 100);
        const inner = `<span class="lbl">${esc(i.label)}</span>`
          + `<span class="trk"><span style="width:${w}%;background:${fill(i)}"></span></span>`
          + `<span class="num">${esc(fmt(i.count))}</span>`;
        return linkOrDiv(i.href && i.count > 0 ? i.href : null, "pm-dx-rank-row", inner, i.title);
      }).join("")}</div>`;
    } else {
      const segs = items.filter(i => Number(i.count) > 0).map(i =>
        `<span style="flex:${Number(i.count)} 1 0;background:${fill(i)}" title="${esc(i.label)}: ${esc(fmt(i.count))} (${pct(i.count, sum)}%)"></span>`).join("");
      const legend = items.map(i => {
        const p = pct(i.count, sum);
        const inner = `<span class="pm-dx-dot" style="background:${fill(i)}"></span>`
          + `<span class="lbl">${esc(i.label)}</span>`
          + `<span class="num">${esc(fmt(i.count))}</span>`
          + `<span class="pc">${p === null ? "" : p + "%"}</span>`;
        return linkOrDiv(i.href && i.count > 0 ? i.href : null, "pm-dx-leg-row", inner, i.title);
      }).join("");
      chart = `<div class="pm-dx-stack" role="img" aria-label="${esc(o.title)}">${segs}</div><div class="pm-dx-legend">${legend}</div>`;
    }
    const head = `<span class="pm-dx-total">${esc(fmt(total))}<small>${esc(o.totalLabel || "")}</small></span>`;
    return card({ title: o.title, scope: o.scope, aside: head, body: chart + (o.footer || ""), cls: o.cls });
  }

  // ---- Ageing (grouped bars) ----------------------------------------------
  // o = { title, meta?, series: [{ key, label, tone }],
  //       bands: [{ label, values: { <seriesKey>: { count, href? } } }], note? }
  // One row per ageing band, one thin bar per series, all on one scale so
  // the series compare (spec 7.3: issues, tasks and exception requests as
  // separate series). A bar with a count and an href is a link.
  function ageing(o) {
    const series = o.series || [];
    const max = Math.max(1, ...(o.bands || []).flatMap(b => series.map(s => Number(b.values?.[s.key]?.count) || 0)));
    const total = (o.bands || []).reduce((sum, b) => sum + series.reduce((x, s) => x + (Number(b.values?.[s.key]?.count) || 0), 0), 0);
    const legend = `<div class="pm-dx-age-legend">${series.map(s =>
      `<span><span class="pm-dx-dot" style="background:${tone(s.tone)}"></span>${esc(s.label)}</span>`).join("")}</div>`;
    const rows = (o.bands || []).map(b => {
      const bars = series.map(s => {
        const v = b.values?.[s.key];
        if (!v) return "";
        const n = Number(v.count) || 0;
        const inner = `<span class="trk"><span style="width:${Math.round(n / max * 100)}%;background:${tone(s.tone)}"></span></span><span class="num">${esc(fmt(n))}</span>`;
        return linkOrDiv(v.href && n > 0 ? v.href : null, "pm-dx-age-bar", inner, `${s.label}, ${b.label}: ${n}`);
      }).join("");
      return `<div class="pm-dx-age-row"><span class="lbl">${esc(b.label)}</span><span class="bars">${bars}</span></div>`;
    }).join("");
    const body = total ? legend + `<div class="pm-dx-age">${rows}</div>` : `<div class="pm-dx-empty">Nothing open in this scope.</div>`;
    return card({ title: o.title, meta: o.meta, body: body + (o.note ? `<p class="pm-dx-note">${esc(o.note)}</p>` : ""), cls: o.cls });
  }

  // ---- Table -----------------------------------------------------------
  // o = { title, scope?, meta?, columns: [{ label, cls? }], rows: [[cellHtml...]], emptyText, footer? }
  function table(o) {
    const body = (o.rows || []).length
      ? `<div class="pm-table-wrap pm-dx-table"><table><thead><tr>${o.columns.map(c => `<th${c.cls ? ` class="${esc(c.cls)}"` : ""}>${esc(c.label)}</th>`).join("")}</tr></thead>`
        + `<tbody>${o.rows.map(r => `<tr>${r.map((cell, ix) => `<td${o.columns[ix] && o.columns[ix].cls ? ` class="${esc(o.columns[ix].cls)}"` : ""}>${cell}</td>`).join("")}</tr>`).join("")}</tbody></table></div>`
      : `<div class="pm-dx-empty">${esc(o.emptyText || "No records.")}</div>`;
    return card({ title: o.title, scope: o.scope, meta: o.meta, body: body + (o.footer || ""), cls: o.cls, id: o.id });
  }

  // ---- Card ------------------------------------------------------------
  function card(o) {
    return `<section class="pm-dx-card${o.cls ? " " + o.cls : ""}"${o.id ? ` id="${esc(o.id)}"` : ""}>`
      + `<header class="pm-dx-card-head"><h3>${esc(o.title)}${o.scope ? ` <span class="pm-dx-scope">${esc(o.scope)}</span>` : ""}</h3>`
      + (o.meta ? `<span class="pm-dx-meta">${esc(o.meta)}</span>` : "")
      + (o.aside || "") + `</header>`
      + `<div class="pm-dx-card-body">${o.body || ""}</div></section>`;
  }

  // ---- Module snapshot (Home) ---------------------------------------------
  // o = { title, href (module dashboard), scope?, stats: [{ label, value,
  //       qualifier?, meter?, meterTone? }], note? }
  // A compact card of a module's most material figures; the whole card
  // links to the module dashboard, where every figure drills further.
  function snapshot(o) {
    const stats = (o.stats || []).map(s => {
      const meter = s.meter === null || s.meter === undefined ? "" :
        `<span class="pm-dx-meter"><span style="width:${Math.max(0, Math.min(100, s.meter))}%;background:${tone(s.meterTone)}"></span></span>`;
      return `<div class="pm-dx-snap-stat"><span class="v">${esc(fmt(s.value))}</span>`
        + `<span class="k">${esc(s.label)}</span>${meter}`
        + (s.qualifier ? `<span class="q">${s.qualifier}</span>` : "") + `</div>`;
    }).join("");
    const body = (stats ? `<div class="pm-dx-snap-stats">${stats}</div>` : "")
      + (o.note ? `<p class="pm-dx-note">${esc(o.note)}</p>` : "");
    const head = `<span class="pm-dx-snap-title">${esc(o.title)}${o.scope ? ` <span class="pm-dx-scope">${esc(o.scope)}</span>` : ""}</span>`
      + `<span class="pm-dx-snap-go">Open dashboard <i class="fa-solid fa-arrow-right" aria-hidden="true"></i></span>`;
    return `<a class="pm-dx-card pm-dx-snap is-link" href="${esc(o.href)}">`
      + `<span class="pm-dx-card-head">${head}</span><span class="pm-dx-card-body">${body}</span></a>`;
  }

  // ---- Two-column row balance ---------------------------------------------
  // A .pm-dx-row-2 holds two .pm-dx-col columns (Needs attention | the
  // module's lead visuals). Their heights depend on the data -- a short
  // attention list beside tall heatmaps left a blank block (2026-11-02).
  // After render, move the LAST card of the taller column to the end of
  // the shorter one while that narrows the gap. A column's first card
  // (attention, coverage, heatmaps) never moves. No-op when the row is
  // stacked (one grid column, narrow screens).
  function balance(row) {
    if (!row) return;
    const cols = [...row.children].filter(c => c.classList.contains("pm-dx-col"));
    if (cols.length !== 2) return;
    if (getComputedStyle(row).gridTemplateColumns.trim().split(/\s+/).length < 2) return;
    const gap = parseFloat(getComputedStyle(cols[0]).rowGap) || 16;
    // Measure natural heights: the row stretches its columns (CSS), which
    // would make them read as equal.
    row.style.alignItems = "start";
    for (let i = 0; i < 6; i++) {
      const [a, b] = cols;
      const ha = a.offsetHeight, hb = b.offsetHeight;
      const tall = ha >= hb ? a : b, short = tall === a ? b : a;
      if (tall.children.length < 2) break;
      const last = tall.lastElementChild;
      const h = last.offsetHeight + gap;
      if (Math.abs((tall.offsetHeight - h) - (short.offsetHeight + h)) >= Math.abs(ha - hb)) break;
      short.appendChild(last);
    }
    row.style.alignItems = "";
  }

  // ---- Loading / error ---------------------------------------------------
  function skeleton() {
    const blk = cls => `<div class="pm-dx-skel ${cls}"></div>`;
    return `<div class="pm-dx" aria-busy="true" aria-label="Loading dashboard">`
      + `<div class="pm-dx-kpis">${Array.from({ length: 6 }, () => blk("kpi")).join("")}</div>`
      + `<div class="pm-dx-row-2">${blk("panel")}${blk("panel")}</div>`
      + `<div class="pm-dx-grid">${blk("chart")}${blk("chart")}${blk("chart")}</div></div>`;
  }

  // o = { title, message, retryId }
  function errorCard(o) {
    return `<div class="pm-dx-error" role="alert"><i class="fa-solid fa-triangle-exclamation" aria-hidden="true"></i>`
      + `<div><strong>${esc(o.title || "Could not load this section")}</strong><span>${esc(o.message || "")}</span></div>`
      + (o.retryId ? `<button type="button" class="pm-button" id="${esc(o.retryId)}">Retry</button>` : "")
      + `</div>`;
  }

  // 2026-11-10: a coloured key square for a KPI qualifier (same
  // .pm-dx-dot the legends use), so a split meter can name its colours.
  const dot = t => `<span class="pm-dx-dot" style="background:${tone(t)}"></span>`;

  window.gracDash = { esc, fmt, pct, dot, kpiCard, attention, distCard, ageing, table, card, snapshot, balance, skeleton, errorCard };
})();
