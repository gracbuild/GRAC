# Audit Management (formerly Assurance)

**Migrations:** `276_audit_management_menu_restructure.sql`,
`276_audit_management_menu_restructure_rollback.sql`, plus the amendment in
`274_menu_master_seed.sql`.

**Web:** `Models/AuditFlow.cs`, `Views/Practice/Partials/_audit-flow-shell.cshtml`,
`Views/Practice/Partials/org-audit-definition.cshtml`,
`Views/Practice/Partials/org-audit-configuration.cshtml`.

Phase 1 turns the flat Assurance menu into a two-flow Audit Management module.
It is **navigation only**: no screen was rewritten, no API changed, and no
assurance data was touched.

---

## Menu

Phase 3 (`279`) collapsed the Audit Definition branch into a single list —
Scope Builder and Question Sets are now tabs inside the selected audit, not
menu items. See **Phase 3** below.

```text
Audit Management            (nav-assurance -- renamed, key unchanged)
├── Audit Definition        (org-audit-definition -- the ONLY audit list)
│     · org-assurance-definitions / -scope-builder / -question-sets
│       are Inactive since 279: hidden from the sidebar, routes alive
├── Audit Configuration     (org-audit-configuration -- page AND parent)
│     ├── Evidence Config         org-assurance-evidence-config
│     ├── Workflow Config         org-assurance-workflow-config
│     ├── Scoring Config          org-assurance-scoring-config
│     ├── Triggers                org-assurance-triggers
│     └── Scope Resolution        org-assurance-scope-resolution
├── Assurance Plans         org-assurance-plans
├── Executions              org-assurance-executions
└── Observations            org-assurance-observations
```

`menu_key` never changes — `nav-assurance` keeps its key because
`organization_role_menu_permission` rows point at `menu_id`, and `274` resolves
parents by key. Only the displayed name and `module_type` moved to
"Audit Management". Every child keeps its own menu row, its own route and its
own permission grants, so deep links and bookmarks keep working.

### Clickable parents

`Audit Definition` and `Audit Configuration` are the first menu rows that are
both a page and a parent. Two changes make that work:

1. `_PracticeMenuTree.MenuUrl` previously returned `#` for any row with
   children. It now honours a parent's `menu_url`. No pre-276 parent had one,
   so nothing else changes.
2. AdminLTE's treeview calls `event.preventDefault()` on **any** `.nav-link`
   whose `li` owns a `.nav-treeview` — so an `href` alone would never navigate.
   `_PracticeMenuTree` emits the target as `data-nav-href` and `_Layout` binds a
   click handler that navigates explicitly. It does not test
   `event.defaultPrevented`: both handlers are bound on `document` and their
   order depends on load order, which would make that signal unreliable.

---

## The flow shell

`_audit-flow-shell.cshtml` is the tab / stepper chrome, driven by an
`AuditFlowShell` (a screen plus an ordered `AuditFlowStep[]`). Each panel
renders the **existing** screen partial unchanged, so every screen still has
exactly one implementation. `?step=<key>` deep-links a tab. Every step stays
enabled — a completed step is never locked, and neither is one further ahead.

Co-hosting those partials is safe for four verified reasons:

- Element ids do not collide — each partial uses its own prefix (`oaDef`,
  `oaScope`, `qs`, `oaEv`, `oaWf`, `oaSc`, `oaTg`, `oaRs`). Checked across both
  flows before the shell was written.
- `_workflow-common` self-guards on `window.__wfCommon`, so rendering it once
  per hosted partial attaches it once.
- Every partial boots with the same `DOMContentLoaded` +
  `readyState !== 'loading'` pair, which fires its boot exactly once.
- The partials reference `@Model` only in their page heading, so handing them
  the container screen is harmless. Those nested headings are hidden by
  `.oa-flow-panel .pm-page-heading`, which keeps all eight files byte-identical
  whether opened standalone or hosted.

### Configuration step order

Evidence → Workflow → Scoring → Trigger → Scope Resolution. The first four are
independent of each other — all five are keyed on
`(org_assurance_definition_id, org_assurance_definition_version_id)` — so this
is the BRD reading order (Sec 5, 6, 7, 9), not a dependency chain. Scope
Resolution is last because it *resolves* the scope authored in the Definition
flow into an immutable snapshot, which makes it the natural closing step.

---

## Two model constraints that shaped this

**Question Sets is organization-scoped.** `org_assurance_question_set` has no
definition FK, and `org_assurance_question_link` links questions to
`PRACTICE / REQUIREMENT / OBLIGATION / ASSET / RISK / EVIDENCE_TYPE` — never to
a definition. No `question_set_id` reference exists outside 076/077. So step 3
of the Definition flow does **not** yet inherit the audit picked in steps 1–2.
Closing that needs a real link table; it is Phase 2 work.

**Assurance Plans spans audits.** `org_assurance_plan` is organization-scoped
and its `org_assurance_plan_item` rows each reference a definition, so one plan
covers several audits. It therefore stays a sibling of the two flows rather
than a step inside the per-audit stepper.

---

## Permissions

`276` grants `can_view` on a container to a role exactly when that role can
already view at least one of its children — a container is pure navigation, so
its visibility follows the screens it hosts. Nobody gains access to a screen
they could not already open. `can_add/edit/delete/approve` stay `0`: there is
nothing on a container page to edit.

On the Web tier the check is `PermissionPolicy.IsAllowed(roles, area, "VIEW")`
against `Security:RolePermissions` in `appsettings.json`. `PM_ADMIN` (`*:*`),
`PM_REVIEWER` and `PM_OWNER` (`*:VIEW`) cover the new areas by wildcard.
`PM_ORG_ADMIN` has an explicit list with no wildcard and already lists none of
the `org-assurance-*` areas, so its access is unchanged — the containers are
consistent with the screens they host.

---

## Phase 2

**Migrations:** `277_org_assurance_definition_question_set_schema.sql`,
`278_org_assurance_setup_procs.sql` (+ rollbacks).
**API:** `OrgAssuranceSetupController`, `OrgAssuranceSetupService`,
`OrgAssuranceSetupModels`.
**Web:** the context bar and chips in `_audit-flow-shell.cshtml`, plus
`_audit-question-set-adoption.cshtml`.

### The audit → question-set link (277)

`org_assurance_definition_question_set` is the edge that was missing: which
question sets an audit **version** asks. It is keyed on
`(definition_id, version_id)` like every other config table, so a new version
can adopt a different list without rewriting history, and it is a many-to-many
*adoption* — question sets stay reusable across audits and nothing in `076`
changed. A unique index on `(version_id, question_set_id)` keeps a hand-written
insert honest even though the save proc replaces the whole list.

`_audit-question-set-adoption.cshtml` renders above the untouched library
screen as the Question Sets step's `HeaderPartial`. It has no picker of its
own — it listens for the shell's `audit-context-change` event, which is the
whole point of the shared context. Editable only while the version is Draft,
matching every other config screen.

### Shared audit context

One Organization + Audit picker at the top of each flow drives every tab. The
six definition-scoped screens each expose a uniform `oa<Prefix>PickOrg` /
`oa<Prefix>PickDef` pair and already reload on `change`, so the context bar
drives them by setting the value and dispatching `change` — **no edits to those
six files**. Question Sets is organization-scoped and takes the org only.

Applying context retries on a short bounded interval, because the hosted
partials populate their own selects asynchronously during boot; the target
option may not exist at the moment the context changes. Context is re-applied
whenever a tab is shown, and mirrored into `?definitionId=` — the same
parameter the hosted screens already accept.

### Status chips (278)

`GET /practice/api/org-assurance/definitions/{id}/setup-status` returns one row
per step, keyed by the **same** step keys the Web tier uses, so a row maps
straight onto a tab. Vocabulary:

| Status | Meaning |
| --- | --- |
| `Completed` | the step has the rows it needs |
| `InProgress` | a header exists but its detail rows do not |
| `NotConfigured` | nothing recorded for this version |

Only Workflow (config without stages) and Scoring (config without bands) can be
half-done; every other step is a single collection and is therefore binary.
`details` is `Completed` by definition — the audit exists and has a version, or
the procedure would have thrown.

Chips render only once an audit is selected, and a failed roll-up clears them
silently: a status summary is decoration, and it must not block the flow.

### Still outstanding

- **Eager boot remains.** All hosted partials still initialise on page load.
  Deferring them means changing the `DOMContentLoaded` + `readyState` boot in
  each of the eight screens, which would undo the "those files stay untouched"
  property that makes this safe. Worth doing, but as its own change.
- **Status refresh is coarse.** The hosted screens save through their own code
  and do not announce it, so the shell refreshes chips on tab change, on window
  focus, and on the `audit-setup-changed` event the adoption panel raises. A
  save on another tab is reflected on the next tab switch, not instantly.

---

## Run order

`276` runs after `274`. On a fresh database `274` already produces the
restructured tree and `276` reports 0 changes. Rolling `276` back and re-running
`274` reinstates the restructure — revert `274`'s Audit Management lines too if
the intent is to return to "Assurance" permanently.

---

## Phase 3 — the audit is the primary entity

**Migration:** `279_audit_definition_single_list.sql` (+ rollback).
**Web:** `_audit-definition-workspace.cshtml`, a rewritten
`org-audit-definition.cshtml`, and four additive hooks in
`org-assurance-definitions.cshtml`.

Phase 1/2 showed three lists side by side. Phase 3 makes Audit Definition one
audit list, with Definition / Scope / Question Set as three sections **of a
selected audit**:

```text
Audit Definition
 └── Audit list  (the only list)
       ├── New Definition ──▶ ① Definition Details ② Scope Details ③ Question Set
       └── 3 dots → View ──▶ the same three tabs, for that audit
```

### Two modes, one page

`.oa-ws[data-mode]` switches between them; the hosted screens are unaware.

| Mode | URL | Shows |
| --- | --- | --- |
| `list` | no `definitionId`, no `mode` | the audit list only |
| `detail` | `?definitionId=<id>` or `?mode=new` | the three tabs, bound to that audit |

`?step=` deep-links a tab, so `?definitionId=42&step=scope` opens audit 42's
scope directly.

### How the same form serves list and tab

`org-assurance-definitions` owns exactly one add/edit form, inside a
`<dialog>`. Copying those fields into a second form would guarantee drift, so
the workspace sets `window.__oaDefInlineForm` and the screen calls
`dialog.show()` instead of `showModal()`; CSS then strips the dialog chrome and
lays it out inline as tab 1. **One form, one submit handler, one validation
path.**

### The four hooks added to the definitions screen

Additive only — no business logic was rewritten:

1. `window.__oaDefInlineForm` chooses `show()` over `showModal()`, and makes
   `closeDialog()` a no-op (inline, there is nothing to close back to).
2. `window.__oaDefinitions = { open, reload, orgId }` publishes the functions
   the screen already had, so the workspace drives the same entry points.
3. A successful save dispatches `audit-definition-saved` carrying the
   `definitionId` **from the POST response**. This is the only reliable way to
   learn a brand-new audit's id — re-reading the list and picking the newest row
   would be a race.
4. A `View` row action, first in the 3-dot menu. It fires a cancelable
   `audit-definition-open`; when the workspace already hosts the screen it
   cancels the event and switches tabs in place, otherwise the screen navigates
   to `/Practice/org-audit-definition?definitionId=…`.

### One audit, one id

Save on tab 1 binds the audit and advances to Scope. Tabs 2 and 3 are guarded
until that id exists — they show *"Save the definition details first"* rather
than letting someone author a scope with nothing to attach it to. Scope and
question sets always write against the same `definitionId`, so no independent
records are created just because the UI shows tabs.

### Removing the separate lists (279)

The three standalone rows are set to `Inactive`, **not deleted**. Deleting
would cascade into `organization_role_menu_permission` and throw away every
per-screen grant. Only `Active` passes the sidebar and permission filters, so
`Inactive` is exactly "not shown" while ids and grants survive. Routes are
unaffected either way — `PracticeController` resolves screens from
`PracticeScreen.All`, not from `menu_master` — so existing deep links such as
`/Practice/org-assurance-scope-builder?definitionId=123` keep working, and the
row menu still offers the per-section jumps.

### Not addressed

- **Audit Configuration is unchanged.** It still uses the generic
  `_audit-flow-shell` with its own context bar. Folding it into the same
  master-detail workspace is the obvious follow-on, but it was not asked for
  and would have doubled the blast radius of this change.
- The list's column set is whatever `org-assurance-definitions` already
  renders. The example in the request (Audit Name / Type / Status / Created)
  was not imposed on it, because changing the grid is a separate decision from
  restructuring the navigation.
