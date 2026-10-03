# Design tokens — the standard

**Applies to every stylesheet in PracticeManagement.Web.** A rule does not
type a colour, radius, shadow or font. It reads a token from
`wwwroot/css/grac-tokens.css`.

**File:** `Web/wwwroot/css/grac-tokens.css`, linked first in
`Views/Shared/_Layout.cshtml`, `Views/Login/Index.cshtml` and
`Views/Login/ChangePassword.cshtml`
**Source:** GRAC Design System (grac-design-guide)
**Introduced:** Design-alignment Phase 1 (token file) and Phase 2 (shared
stylesheets tokenised), 2026-09-25

---

## The rule

```css
/* no */
.pm-thing { color: #2465ca; border: 1px solid #e2e7f0; border-radius: 7px; }

/* yes */
.pm-thing { color: var(--primary-600); border: 1px solid var(--border); border-radius: var(--radius-md); }
```

Do not re-declare a token in another file. Every stylesheet loads after
`grac-tokens.css`, so a second `:root { --primary-500: … }` silently wins.

## Which token

| Need | Token |
|---|---|
| Primary button / selected fill / focus border | `--primary-500` (#467CEB) |
| Button hover | `--primary-600` |
| Button press (`:active`) | `--primary-700` |
| Link, icon or text in blue | `--primary-600` — #467CEB on white is below 4.5:1 for small text |
| Selected-row / info tint | `--primary-50`, `--primary-100` |
| Body text | `--fg-default` |
| Headings that need more weight | `--fg-strong` |
| Secondary text | `--fg-secondary` |
| Labels, help, meta | `--fg-muted` |
| Placeholder, disabled | `--fg-subtle` |
| Text on navy / blue | `--fg-on-dark`, `-muted`, `-subtle`, `-faint` |
| Card, table, divider line | `--border` |
| Heavier line (inputs, tree lines) | `--border-strong` |
| Page background | `--bg-page` |
| Card / panel / input fill | `--bg-surface` |
| Table header, muted fill | `--bg-subtle` |
| Sidebar | `--grac-navy-deep`; item hover `--nav-hover`, open `--nav-active` |
| Status pill | `--success-50` + `--success-700`, `--danger-50` + `--danger-700`, `--warning-50` + `--warning-700`, `--primary-50` + `--primary-700` |
| Focus | `box-shadow: 0 0 0 3px var(--focus-ring)` (`--focus-ring-danger` on an invalid field) |
| Modal scrim | `--overlay` |
| Shadow | `--shadow-card` (cards), `--shadow-menu` (dropdowns, row menus), `--shadow-modal` (dialogs, drawers) |
| Radius | `--radius-md` 8px (default), `--radius-sm` 4px (chips, checks), `--radius-lg` 12px (large tiles), `--radius-pill` |
| Font | `--font-ui` (Lato), `--font-num` (Inter, numerics) |

`--grac-gold` is brand-only. It never colours a button, link, border or
state.

## Legacy names still work

`--grac-ink`, `--grac-muted`, `--grac-line`, `--grac-blue`, `--grac-soft`,
`--grac-hover`, `--grac-danger`, `--grac-row-hover-*`, `--ml-*`,
`--brand-*`, `--text-muted`, `--border-color` and `--pm-*` are aliases in
`grac-tokens.css` section 9. The shared stylesheets no longer use them;
inline styles in views and JS still may. New code uses the token names.

## Deliberately NOT tokenised

These colours encode data. Each value is a category, not a state, so they
stay as they are:

- `.pm-obligation-type-*` and `.pm-typed-src` — the seven obligation types
- `.cal-event.status-*`, `.cal-event.criticality-*`, `.cal-status-dot.*`,
  and `--cal-src-*` — calendar legend
- `.risk-level-*` in `site.css` — risk heat colours

Also left alone: vendor CSS (`sweet-alert.css`, AdminLTE, Phosphor, Font
Awesome), the default `_Layout.cshtml.css` scoped file, the login logo
shimmer, and the tree-connector gradient in `.pm-tree-branch` (a line
drawing, not a decorative fill — its colour is tokenised).

## What Phase 2 changed visibly

- Primary blue #2465CA → #467CEB (buttons, selected tabs, focus borders).
  Blue text and links → #3568D4.
- Slate text/lines (#172033, #758095, #E2E7F0, …) → the neutral ramp.
- ~300 distinct colours across the shared CSS → the token set.
- Radii 3/5/6/7/9/10/11/12/13/14/16 px → 4 or 8 px. Pills unchanged.
- Gradients removed from the progress bar and the (already overridden)
  sidebar; glow shadows on primary buttons removed.
- Focus rings unified to 3 px `--focus-ring`.
- Login: Lato instead of Inter (Inter was never loaded), 20 px panel
  radius, no lift-on-hover on Sign In.

Not changed (awaiting approval): 13 px base text size, blue row-hover tint.

## Phase 3 — views and scripts (2026-09-25)

Inline styles in the 70 changed views/scripts now use tokens, and the
repeated form and dialog patterns use shared classes instead of inline
styles. **Structural patterns → classes** (matched exactly, so each swap is
the same element with the same content):

| Was (inline) | Now |
|---|---|
| `<label style="display:flex; flex-direction:column; font-size:12px; color:#475569">` | `class="pm-field"` (layout extras such as `margin-top`/`flex`/`min-width` stay inline) |
| `<input/select/textarea style="padding:6px 8px; border:1px solid #cbd5e1; border-radius:4px; margin-top:2px">` | `class="pm-input"` — new; shares the `.pm-form-grid` input box |
| `<span style="color:#b91c1c">*</span>` | `class="required"` |
| dialog header row + `<h2 style="font-size:18px">` + `&times;` button | `.pm-dialog-heading` + `.pm-icon-button` |
| dialog footer `display:flex; justify-content:flex-end; gap:8px` | `.pm-dialog-actions` |
| dialog message box (`display:none; padding:8px 12px; …`) | `.pm-message` (`display:none` stays inline; the scripts still toggle it) |
| `<dialog style="border:none; border-radius:8px; padding:0; box-shadow:…">` | the global `dialog` rule; only `max-width`/`width` stay inline |
| `<form method="dialog" style="margin:0; padding:20px 24px">` | the global `dialog form` rule |

**`.pm-badge`** now has one global rule (neutral pill, 11 px / 600). The
identical local copies in practice-view, resolve and resolve-workspace
were removed. Modifier classes (`.t-status`, `.gap-state-chip`,
`.risk-tab-badge`) and inline SLA colours still override it.

**Scripts:** colours set from JS (`el.style.x = …`, `style="…"` in
template strings, the `{ bg, fg }` SLA/status maps) use `var(--token)`.
A CSS variable works anywhere a colour goes in a style — but **never** in
`<input type="color">` values, stored `colorHex` data, or canvas
`fillStyle`. Those stay hex.

Numbers: literal hex in views 1,598 → 27, in JS 221 → 6, inline
`style=""` attributes 1,414 → ~900 (the rest are layout: widths, gaps,
margins, `display:none` toggles).

**Still literal, on purpose:** purple "verification/duplicate/additional"
states (a category colour with no status meaning), teal `.risk-analysed`,
the scoring-band `colorHex` defaults, `_Layout.cshtml`'s SVG stroke,
`_Layout.cshtml.css` (has uncommitted edits of its own).

**Carry forward:** layout-only inline styles (grids, widths) remain; they
can move to classes screen by screen when a screen is next touched.
