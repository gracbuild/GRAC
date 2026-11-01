# Responsive dashboard grids (2026-10-08)

## Problem
On a laptop with Windows display scaling (e.g. 1602 px at 125% = ~1282 CSS px,
minus the sidebar) the Home "Overview" was forced to 3 card columns inside a
~550 px column, and each card's mini metrics were forced to 2 columns, so labels
ran into each other ("Applicable0 Not Updated").

## Change (CSS only - `wwwroot/css/practice-management.css`)
No markup, JS, API or DB change. Breakpoints, spacing and card design unchanged.

| Rule | Before | After |
|---|---|---|
| `.pm-home-work:not(.org-collapsed) .pm-home-org .pm-dashboard-kpi-grid` (>=1181px) | `repeat(3, minmax(0,1fr))` | `repeat(auto-fit, minmax(max(210px, calc((100% - 28px) / 3)), 1fr))` - max 3, drops to 2/1 by the column's own width |
| `.pm-mini-metrics` | `repeat(2, minmax(0,1fr))` | `repeat(auto-fit, minmax(max(110px, calc((100% - 12px) / 2)), 1fr))` - max 2, 1 when the card is narrow |
| `.pm-mini-metrics span` | `inline-flex`, gap 6px | adds `flex-wrap: wrap`, `min-width: 0`, `overflow-wrap: anywhere` so a long label wraps under its number instead of overlapping |
| `.pm-dash-split .pm-dash-tiles` (module dashboards, >1400px) | `repeat(6, minmax(0,1fr))` | `repeat(auto-fit, minmax(max(120px, calc((100% - 50px) / 6)), 1fr))` - max 6, fewer when the half is narrow |

On wide screens the result is identical to before (3 / 2 / 6 columns).

## Verified widths (test render)
- 1600 CSS px: overview 3 columns, metrics 2 columns (as before).
- 1282 CSS px + sidebar: overview 2 columns, metrics 2 columns, no overlap.
- <=1180 px: existing stacked layout (unchanged).

After deploying: Ctrl+F5 (static CSS cached).
