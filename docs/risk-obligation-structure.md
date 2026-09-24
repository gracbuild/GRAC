# Risk pages: Impact Details and per-practice dependencies

**Status: settled.** This document replaces an earlier design for
obligation-grouped dependencies and narrative impact records. That design
was built and then withdrawn; what shipped is smaller and uses tables
that already existed. The withdrawn parts are listed at the end so a
reader who finds their leftovers knows why they are there.

---

## What the pages show now

Every risk page mounts the same component — `riskMapping` in
`wwwroot/js/RiskCentre/risk-centre.js` — over
`GET /register/{id}/mapping`, which returns
`{ practices, categories, dependencies }`.

It renders two sections into **two hosts**, and **Impact Details sits
above Existing Controls** on every page.

| Page | Impact Details host | Practices host | Impact Details | Practices |
| --- | --- | --- | --- | --- |
| Risk Analysis | `raImpactScope` | `raMapping` | editable | editable |
| Residual Analysis | `rrImpactScope` | `rrMapping` | **read-only** | editable |
| Review | `rvImpactScope` | `rvMapping` | editable | editable |
| View Risk | `rdImpactScope` | `rdMapping` | read-only | read-only |
| Accept | `acImpactScope` | `acMapping` | read-only | read-only, inside the collapsed `#acScope`, both mounted on first expand |

On **View Risk** and **Residual Analysis** the panel sits higher still —
above *Treatment details* / step 2 *Risk treatment*, not merely above
*Existing controls* — so the page states the risk in the order it was
assessed: context, inherent level, what it impacts, then what was done
about it.

**`opts.impactReadOnly` is separate from `opts.readOnly`, and defaults to
it.** Residual Analysis is the one page that needs the two halves in
different modes: the scope panel stays editable, because a residual
assessment may legitimately find the risk now reaches different
practices, but Impact Details does not — it was established at Analysis
and is revised at Review, and editing it mid-residual would change the
thing being measured while measuring it. Everything the impact table
owns keys on `impactReadOnly`: the chips-vs-picker branch in
`categoryRow`, the save bar, the asset cascade filters, the per-category
object fetches and the asset taxonomy. Only `Map a practice` and the
per-card unmap key on `readOnly`.

Two things fell out of that pass:

- The per-category object lists and the asset taxonomy are now skipped
  whenever the impact table is read-only — five fetches plus the taxonomy,
  on Residual as well as View Risk and Accept.
- `GET /mapping/options` was fetched on every editable mount and its
  result **never read**. It fed the flat practice `<select>` that
  migration 282 replaced with the cascading Practice Picker. Dropped.

**Why two hosts and not a reorder.** Existing Controls is a `pm-panel`
with its own `<h2>`; no ordering *inside* that panel can put a section
above its heading. So Impact Details gets a panel of its own above it,
and `mount()` takes `opts.impactHostId` to say where that half goes.
It is still **one component, one `/mapping` call, one `refresh()`, one
save path** — a second component would have meant fetching the same rows
twice and two places for the same save to go wrong.

Consequences worth knowing:

- `clear(hostId)` empties the twin from the stored state, so the six
  `riskMapping.clear(...)` call sites — `backFromFullPage()` clears four
  — did not have to learn each host's partner.
- `msg()` uses `querySelectorAll`: a message line is rendered in **each**
  host, because the save button is in the impact panel and the Map/unmap
  buttons are in the practices panel, and a result shown in the other
  panel is a result nobody sees.
- The `<h4>` inside the impact section is emitted **only** when both
  sections share one host (the `impactHostId`-less fallback). In its own
  panel the `<h2>` is the heading.
- `.risk-scope-deps`' top divider is now `.risk-scope-block + .risk-scope-deps`
  — a top border on the first thing in a panel is a stray rule under the
  heading, not a divider between two subjects.

### 1. Impact Details

The by-Operationalize-category table: **what this risk impacts** — which
assets, vendors, people, teams and committees. One row per category, a
`pm-checkcombo` per row, one **Save impact details** button.

This is the section that used to be labelled *Dependencies*, and it used
to sit below the practices. Nothing about it changed except the label,
the hint and the position: same categories, same pickers, same
`risk_dependency_map` store (265), same
`POST/DELETE /register/{id}/dependencies` save path, same asset cascade
filters, same locked-when-inherited rows. The label was the thing that
was wrong — it read as a duplicate of what the practice cards carry.

`Save impact details` stays disabled until it has something to save, and
rows a mapped practice brought in are locked with an `is-locked` option
class and an "inherited via …" title.

**A read-only mount renders chips, not a disabled picker.** It used to
render the same `pm-checkcombo` an editable mount does: no save button,
so nothing persisted — but the trigger opened, the boxes ticked, and the
reader was invited to make a change that the next render silently threw
away. `disabled` on every box would have fixed the writing and kept the
lie that this is a control. So `categoryRow` returns early for
`st.readOnly` with the mapped names as `.rmp-dep-chip`s — the same chip
the practice cards use — carrying the *Inherited via …* / *Mapped
directly* tooltip. No trigger, no menu, no checkbox, no asset cascade,
and the asset-taxonomy fetch is skipped on those two surfaces because
nothing reads it.

### 2. Mapped practices

One card per practice, each carrying:

- name and `Primary` / `Additional` badge
- provenance facts from `/practice-context` (284): framework, source
  root, statement, practice ref
- **Dependencies — read-only.** What that practice's obligations already
  declared on the Operationalize page and brought with them when the
  practice was mapped to this risk. Grouped by Operationalize category,
  rendered as chips. No checkbox, no save, no remove: the practice owns
  them, and the way to take them off this risk is to unmap the practice.
- its linked tasks, in an inset mini table

The list is **derived, with no extra call**: `sp_risk_mapping_get` (267)
already returns `SourcePractices` for each inherited dependency as
`STRING_AGG(practice_name, ', ')`, and `refresh()` matches those names
against the practices on the page. `p.dependencyCount` from SQL is the
authoritative count; the card states any shortfall rather than hiding it,
because a practice name containing a comma can defeat the name match.

A dependency with no `SourcePractices` is a **direct** one — added on
this risk rather than inherited — and belongs to no card. It appears in
Impact Details only.

---

## The data model, unchanged

| Table | Grain | Migration |
| --- | --- | --- |
| `risk_practice_map` | one row per practice, `map_source_code` `Primary` \| `Additional`, name/code frozen at map time | 261 |
| `risk_dependency_map` | `(risk_register_id, dependency_type_id, dependency_object_id)` — **UNIQUE** | 265 |
| `risk_dependency_map_source` | provenance: `source_kind_code` `PracticeDependency` \| `Direct`, plus `practice_id`, `practice_instance_id`, `resolution_id` | 265 |

The UNIQUE constraint is deliberate — 265's header calls it *"duplicate
dependencies are prevented when the same dependency comes through
multiple Practices"* — which is why the withdrawn design used a join
table rather than adding a column to it.

Facts worth keeping from the original inspection, because they still
shape what is possible here:

- **A risk has no obligation collection.** `risk_register.linked_obligation_id`
  (216) is a single nullable id, projected as `LinkedObligationId` and
  rendered nowhere. There is no "Obligation 1 / Obligation 2" list on any
  risk page to hang anything under.
- **Nothing associates a dependency with an obligation**, here or
  upstream: Operationalize resolves dependencies **per practice instance
  per category** (`practice_dependency_resolution`), never per
  obligation. The per-practice list above is the closest true statement
  the data supports.
- **"Impact" as a score is separate and untouched.** `risk_impact_master`
  (204) holds the 1–10 levels; `risk_register.impact_code/_name/_value`
  and `residual_impact_*` (258) hold the chosen level; `#raConsequence`
  ("Impact Analysis") is one free-text box on Risk Analysis. The
  Impact Details **section** and the impact **score** are different
  things with similar names, and both stay.

---

## What was withdrawn

An earlier revision added narrative impact records — impact area,
description, severity, affected party, estimate, horizon — attributable
to an obligation, plus a dependency-to-obligation attribution table. It
was built through five phases and then withdrawn: the thing that needed
capturing was impacted assets, vendors and people, which
`risk_dependency_map` already held.

Removed from the live path:

| Piece | State |
| --- | --- |
| `riskImpacts` component in `risk-centre.js` | deleted |
| `raImpacts` / `rrImpacts` / `rvImpacts` / `rdImpacts` panels, `acImpacts` div, `.risk-impact-*` CSS | deleted from `risk-centre.cshtml` |
| Web proxy routes `impact-areas`, `impact-details`, `dependency-obligations`, `obligations` | deleted from `Web/Controllers/RiskCentreController.cs` |
| The same routes and the `IRiskImpactDetailService` injection | deleted from `Api/Controllers/RiskCentreController.cs` |
| `IRiskImpactDetailService` registration | deleted from `RiskCentreServiceRegistration.cs` |

Left on disk, unreferenced, each with a **DEAD CODE / NOT WIRED UP**
banner at the top — delete these four together whenever convenient:

- `Api/Models/RiskImpactDetailModels.cs`
- `Api/Services/RiskImpactDetailService.cs`
- `Web/Views/Practice/Partials/_impact-detail-dialog.cshtml`
- `Web/wwwroot/js/Shared/impact-detail-form.js`

### Migration 309 is withdrawn, not reusable

`309_risk_impact_detail_and_dependency_obligation.sql` **now aborts on
purpose**: a banner, four `PRINT`s and `SET NOEXEC ON` at the top of the
file, with the script's own defensive `SET NOEXEC OFF` commented out
because it would have cancelled the abort. The body is untouched below
it, so un-withdrawing means deleting the abort block and un-commenting
that one line.

- **If 309 was never applied** — the expected case — nothing to do.
- **If it was applied**, run
  `309_risk_impact_detail_and_dependency_obligation_rollback.sql` with
  the default `@KeepData = 0`. Every DROP in it is guarded, so on a
  database where 309 never ran it is a no-op that says so.

309 stays **claimed**: the number is burnt, not recycled. 308 is still
reserved for the two obligation-guard procedure re-issues that 307
deferred (see `practice-level-obligations.md`), so the next new migration
is **310**.

---

## Migrations still owed on this database

In order: `254` → `306` → `307`. Then rebuild and restart the Web tier.
Do **not** run 309.
