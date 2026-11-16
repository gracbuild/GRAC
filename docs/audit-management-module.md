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
├── Audit Configuration     (org-audit-configuration -- a list since 537, one menu item since 539)
│     · org-assurance-workflow-config / -scoring-config / -triggers /
│       -scope-resolution are Inactive since 539: hidden from the sidebar,
│       hosted as sections of Audit Configuration, routes alive
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

Workflow → Scoring → Trigger → Scope Resolution (Evidence was first until 536
removed it -- see the end of this file). The first three are
independent of each other — all four are keyed on
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
   would be a race. Since 2026-11-04 the event also carries `organizationId`
   (the organization the definition was saved in) next to `definitionId` and
   `isNew`.
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

### Save and Scope fixes (2026-11-04)

Reported: adding a definition showed *"A definition with this code already
exists in the organization"* although the definition was saved, and a newly
added definition did not appear on the Scope tab until the page was refreshed.

- **Uniqueness is per organization, and stays so.** The table has
  `UNIQUE(organization_id, definition_code)` (069) and the save procedure
  checks the code within the organization only (53605, 070/119). The same code
  and name can be used in any number of organizations. Names are not unique at
  all. No database change was needed.
- **Why the message appeared.** It came from a *second* create in the same
  organization: (a) Save could be clicked again while the first POST was
  still running, and (b) in the inline workspace the form stays on screen after
  a create but still looked like a new record (`oaDefEditId` empty), so the next
  Save created again. The first create had already succeeded.
- **Fix, definitions screen.** Save runs one request at a time and disables the
  Save button meanwhile. After a create the form is switched to the saved record
  the way `openDialog(id)` does it: `oaDefEditId` set, code locked, title
  *Edit Audit Definition*. Further saves update that record.
- **Fix, scope builder.** It listens for `audit-definition-saved` and reloads its
  definition picker when the saved definition is in the organization it is
  showing. The workspace's `setSelect` then finds the new option and selects
  it through the picker's normal change handler. A definition from another
  organization is handled by the workspace changing the organization picker,
  whose handler already reloads the list.
- **API.** `OrgAssuranceDefinitionService` maps SQL 2627/2601 (two creates racing
  past the 53605 check onto the unique key) to reason `DUPLICATE_CODE` with the
  same message, instead of returning the raw constraint text.

### Form card left under the audit list (2026-11-04)

Reported: after opening an audit from the list's 3-dot menu and going back,
an Add/Edit Audit Definition card stayed visible below the list.

- Cause: the definition form is a non-modal `<dialog>` opened with `show()` as
  tab 1. Going back to the list only switched the page to list mode; the dialog
  stayed `[open]`, and outside detail mode it rendered as a plain card. The
  3-dot **Edit** action had the same effect directly: it called `openDialog(id)`
  while the page stayed in list mode.
- Fix, workspace: `setMode('list')` closes `#oaDefDialog` if it is open, so every
  way back to the list (Back to audit list, boot in list mode) hides the form.
- Fix, definitions screen: when hosted in the workspace
  (`window.__oaDefInlineForm`), **Edit** opens the audit page on Definition
  Details, the same as **View**. The standalone screen keeps its modal Edit.

### Row click and the Actions button on every Audit list (2026-11-04)

UI only -- no migration, no API change. Follows the Gap / Task / Practice View
pattern: a row click is the row's own View, and the view carries an **Actions**
button (`wwwroot/js/Shared/page-actions-menu.js`, `window.gracPageActions`)
offering the rest of the row's 3-dot items. Each screen builds both menus from
ONE item function, so the two always agree (status rules included).

| Screen | Row click | Actions button (where) | Actions items |
| --- | --- | --- | --- |
| Audit Definition | opens the read-only View page (see below) | page heading, view and edit pages | Edit / View, Audit Configuration (537; was Scope, Workflow, Scoring, Triggers, Resolve Scope), Executions, History, then Submit for Review / Approve / Activate / Retire by status |
| Audit Plans | shows the plan's items (= View Items) | items panel toolbar, when a plan is selected | Edit, Submit / Approve / Activate / Close by status, Delete |
| Executions | shows the execution (= View Details) | detail panel heading | Observations, then Start / Submit / Mark Reviewed / Approve / Close / Cancel / Delete by status |
| Observations | shows the observation (= View Details) | detail panel heading | Edit, Submit for Review / Accept / Reject / Resolve / Regenerate Gap or Open Linked Gaps / Close / Delete by status |
| Question Sets | opens the set page read-only (520; was: shows the set's questions) | set page heading, view mode | Edit |

- Rows carry `.pm-row-clickable` (pointer cursor). The 3-dot trigger and any
  `a`, `button`, `input`, `label`, `select` keep their own click.
- Audit Definition: the row-menu items now carry a `key`;
  `window.__oaDefinitions.actionItems()` returns them for the record loaded in
  the form (status from `currentStatusCode`). After a lifecycle action run on the
  audit page the form reloads the record, so the menu follows the new status.
- Executions / Observations: `rowMenuItems(id, ...)` was extracted from
  `openRowMenu`; the detail panel passes the loaded detail (status, gapId).
- Plans: `buildMenu(id, kind, statusCode)` now takes the status instead of the row;
  the Actions menu reads it from the latest list load.
- Not changed (by decision): Workflow Config, Scoring Config and Triggers --
  their rows are settings inside one audit with only Edit / Remove, so no row
  click was added. Scope Builder and Scope Resolution have no
  row menu.

### Audit View page -- one read-only page (2026-11-04)

Replaces the same-day "opens read-only" step (a read-only Definition Details
tab), which was withdrawn: the view is now its own page with no tabs.

- **Modes of `/Practice/org-audit-definition`** (`data-mode` on `.oa-ws`):
  - `list` -- no `definitionId`.
  - `view` -- `?definitionId=<id>`. Row click and the row's **View** open it.
  - `detail` (edit) -- `?definitionId=<id>&mode=edit`, or any `?step=` link, or the
    row's **Edit**. The existing 3 tabs, unchanged. `?mode=new` as before.
- **View page content** (`#oaWsView`), all read-only, each from the API the edit
  tabs already call -- no API change:
  - Definition Details: code, name, category, owner (`personWithRole`),
    effective date, status, version, and Submitted / Approved / Activated /
    Retired by + date when they happened; Objective and Description when entered
    -- `GET definitions/{id}`.
  - Scope Details: each group, joined to the previous by its operator, with its
    conditions (`AND/OR`, `NOT`, dimension: values or All) -- `GET definitions/{id}/scope`.
    "No scope defined yet." when empty.
  - Question Sets: each adopted set (Optional badge when not mandatory) with its
    questions (code, text, type, mandatory) -- `GET definitions/{id}/question-sets`,
    then `GET question-sets/{id}/questions` per set. "No question sets adopted yet."
    when empty.
  - Created / Updated.
- **Actions** (page heading): on the view page **Edit** (opens the edit page),
  **Scope** (edit page on the Scope tab), Workflow, Scoring, Triggers,
  Resolve Scope, Executions, History and the lifecycle action by status. On the
  edit page **View** replaces Edit. Built from the list row's own items
  (`window.__oaDefinitions.actionItems(id, statusCode)`).
- A lifecycle action from Actions dispatches `audit-setup-changed`; the view page
  reloads on it.
- The list row's **Edit** now dispatches `audit-definition-open` with
  `mode: 'edit'`; View and row click send `mode: 'view'`.
- The definition form is closed whenever the page is not in edit mode.
- Styles: `.oa-ws-view` / `.oa-wv-*` in `practice-management.css`, same values as
  the Gap / Task View fact grids.

### Scope and Question Set open the 3-tab page (2026-11-04)

Reported: the list's 3-dot **Scope** opened the standalone Scope Builder page,
which has no Question Set tab, so its Save did not move on to Question Set the
way the 3-tab page's flow does; and the menu had no Question Set entry.

- One page for all three: the row's **Edit**, **Scope** and the new
  **Question Set** item open the audit's 3-tab edit page with that tab selected
  (`details` / `scope` / `questions`). `openEditTab(id, step)` in
  `org-assurance-definitions` dispatches `audit-definition-open`
  `{ mode: 'edit', step }`; hosted, the workspace switches in place (only the tab,
  when that audit is already open for editing, so unsaved input stays); unhosted
  it navigates to `/Practice/org-audit-definition?definitionId=&step=`.
- The standalone Scope Builder link was removed from the row menu; that page
  itself is unchanged.
- The view page's Actions offers the same items, so Edit / Scope / Question Set
  there open the edit page on that tab. The workspace no longer overrides any
  item -- every item runs the list's own action.

### Question Repository; Question Sets pick from it (migration 516, 2026-11-05)

New menu **Audit Assurance -> Question Repository** (`org-assurance-question-repository`):
the organization's library of audit questions with its own Categories /
Subcategories (default set seeded once per organization). Question Sets now
**pick** their questions from the Repository (**Add from Repository**); a set
question's content is the Repository's, the set keeps only its Order.
Existing set questions were converted into Repository questions (category
"General"). Full description, fields, API and error codes:
[audit-question-repository.md](audit-question-repository.md).

### Question Sets: details and questions on one page (migration 520, 2026-11-05)

The 516 Question Repository was withdrawn. **Audit Assurance -> Question Sets**
lists the sets; a set opens as one page -- its details, then its questions in an
editable grid ("Add Row", Guidance / Expected Evidence under each row) saved with
one Save. Same partial in the Audit Definition page's Question Set tab. Details,
API and migration: [audit-question-sets.md](audit-question-sets.md).

### Question Set tab: selection only (2026-11-05)

The Audit Definition page's Question Set tab now shows only the selection
panel (`_audit-question-set-adoption`: Available / Asked by this audit, icon-only
`>` / `<` buttons -- fa-angle-right / fa-angle-left with a title, the dual-list
pattern used elsewhere -- Up / Down, Save question sets). The Question Sets library that sat
under it is no longer hosted there (`_audit-definition-workspace.cshtml`
dropped the `org-assurance-question-sets` partial and its organization sync).

- **Add new question set** (link under the Available list) opens
  Audit > Question Sets in a new browser tab, straight on a new set
  (`?new=1`, read by `org-assurance-question-sets.cshtml`). The organization
  is the one last picked (shared organization preference), not passed in the URL.
- Back on the audit's tab, the Available list re-reads the sets on window focus
  and on **Refresh list**, keeping picks not yet saved (anything already moved
  to "Asked by this audit" stays there).
- UI only; no database or API change.

#### Selection panel layout (2026-11-05)

- "Asked by this audit" now reads **Selected for this audit**; each list label
  carries a count badge; the footer reads "n set(s) selected for this audit".
- Labels, boxes and hints are three rows of one CSS grid (`.oa-adopt-grid`,
  grid-template-areas), so both boxes start on the same line regardless of the
  hint text under each; the `>` / `<` and up / down buttons are centred beside
  the boxes. Narrow screens restack the areas into one column.
- Boxes are taller (260px), with rounded borders, roomier options, a primary
  tint on the selected option and a focus ring (design tokens only).
- Files: `_audit-question-set-adoption.cshtml`, `practice-management.css`
  (the `.oa-adopt-*` block). UI only.

- The panel heading "Question sets used by this audit" and its line "These sets are asked by the current draft version of this audit." were removed (the tab caption and list labels say it). The line under the tab now appears only when it adds something: no audit picked yet, or "Read-only: ... while the current version is Draft."

## Audit Definition form -- Description height and full-width text fields (2026-11-13)

- The Description textarea opens six lines tall (Objective stays at two). `practice-management.css`: `.oa-ws #oaDefForm #oaDefDescription { height/min-height: calc(8.4em + 18px) }` -- six lines at 13px with line-height 1.4, plus padding and border. The id selector outranks the short-viewport (max-height: 820px) rule, so it keeps six lines there. `org-assurance-definitions.cshtml`: `rows="6"` to match.
- Objective and Description now fill the form's full width: the 1100px `max-width` cap on `.oa-ws #oaDefForm > label > textarea` is now `none`, so their right edge lines up with Effective Date like every other row.
- No database or API change.

## Scope Details -- Source Statements replace Practice Instances (migration 534, 2026-11-13)

**Request (sir).** "Filter by Practice Instances" lists every practice instance and is hard to pick from. Pick source statements instead, in a Framework -> Release -> Source Structure -> Source Statement tree, as two lists (available / selected) with `>`, `>>`, `<`, `<<`.

**Decisions (asked and answered).**
- "Control" means **source statement** (Practice Management has no Control).
- At run time the audit covers the **practice instances of the practices mapped to the selected statements** (every team).
- Source Statements **replace** Practice Instances in the Scope Builder.
- Moving a framework / release / structure stores **its statements as they are today**; statements added later are not included.

### Database (534)
- Dimension `SOURCE_STATEMENT` ("Control Statements" -- renamed from "Source Statements" the same day at sir's request, so the card reads **Filter by Control Statements**; Compliance, pickable, order 2). Also in `272_master_data_seed.sql`.
- `fn_org_scope_statement(@org)`: one row per selectable statement with framework / release / structure. Covers repository statements of active subscriptions (`fn_org_framework_statement`, 392) and custom release statements (the 347 overlay). `StatementId` = `organization_framework_statements.org_statement_id` -- the value stored in `org_assurance_scope_condition_value.dimension_entity_id`.
- `fn_org_scope_statement_instance(@org)`: statement -> active practice instances, through either mapping route (`organization_requirement.org_statement_id`, or `organization_statement_practice_mapping`).
- `sp_org_assurance_scope_statement_tree(@organization_id)`: the tree rows plus `InstanceCount` per statement.
- `sp_org_assurance_scope_dimension_values` re-issued from 074 with a `SOURCE_STATEMENT` branch (flat list).
- `sp_org_assurance_scope_resolve` re-issued from 096: picked statements become `PRACTICE_INSTANCE` snapshot rows (the execution engine is unchanged), de-duplicated against instances already in the snapshot; include-all / NOT for statements read the function (no 500-row cap).
- Rollback: `534_audit_scope_source_statements_rollback.sql`.

### API
| Method | Route | Query | Answer |
|---|---|---|---|
| GET | `/api/practice/org-assurance/scope-statement-tree` (Web: `/practice/api/org-assurance/scope-statement-tree`) | `organizationId` | `{ data: [{ frameworkKey, frameworkName, releaseKey, releaseName, structureKey, structureName, statementId, statementCode, statementName, instanceCount }] }` |

`scope-dimensions` now also returns `SOURCE_STATEMENT`; `scope-dimensions/SOURCE_STATEMENT/values` returns the statements flat. Saving a scope is unchanged (`dimensionCode: "SOURCE_STATEMENT"`, `values[].entityId` = statement id).

### UI
- `wwwroot/js/Shared/statement-tree-picker.js` -- `window.gracStatementTreePicker.attach({ host, organizationId, selected, readOnly, onChange })`. Built on the Question Set adoption dual list's grid and icon-only buttons (`.oa-adopt-grid`, `.oa-adopt-actions`); trees styled by `.oa-stmt-*` in `practice-management.css`.
  - Click a framework / release / structure / statement to mark it, then `>`; `>>` adds everything shown; `<` / `<<` take back. Double-click a statement to move it. Each side has a search that also opens the matching branches.
  - A statement with no practice instance yet is shown faded, with a note under the selected list.
  - A saved statement no longer in the tree is kept under "No longer available".
- `org-assurance-scope-builder.cshtml`: shows **Filter by Control Statements** (the picker) instead of Filter by Practice Instances.
- Scopes saved earlier with Practice Instances are not converted (one team vs every team mean different things). They keep resolving as before and are shown read-only (see "One page, one Save" below).

### Not included
- The old Control model (`organization_control`) and the "Organization Defined Practices" container have no source statement, so they are not in the tree.

## Audit Definition -- one page, one Save; Scope Builder simple only (2026-11-13)

**Request (sir).** Make the 3-tab Audit Definition page one page, in sections, neatly aligned; drop the Scope Builder's Advanced option -- Simple only. Decisions: **one Save at the bottom** of the page; a scope saved with Advanced rules is **shown read-only as sentences**.

### Page
- `_audit-definition-workspace.cshtml`: the tab strip, step caption and Previous / Next are removed. The edit page shows three section cards one under the other -- **Audit Details**, **Scope**, **Question Sets** -- each with its 278 status chip in the heading, and one **Save** at the bottom.
- Save runs, in order: `window.__oaDefinitions.save()` (the definition form's own validation and save; resolves to the id or null), `window.__oaScopeBuilder.save()`, `window.__oaAdoption.save()` (each resolves true / false). Three API calls, not one transaction: if the details fail nothing else runs; if Scope or Question Sets fail, the details stay saved and that section shows its own message, and the bar says which part failed.
- A **new** audit has no id yet: Scope and Question Sets say "Save the audit details first" (`[data-new="1"]` on `.oa-ws`). The first Save creates the audit and loads both sections; the next Save writes them.
- Saving an existing audit no longer re-binds the scope and question-set sections (it would reload them and drop the picks being saved); only a new id does.
- `?step=scope` / `?step=questions` deep links and the Actions menu's Scope / Question Set items now scroll to that section.
- The hosted screens' own chrome is hidden on this page (CSS): the definition form's heading and Save / Cancel, the Scope Builder's organization / audit pickers and its Reload / Save bar, and the question-set Save. The standalone screens keep theirs.
- The view page (read-only) is unchanged; its scope sentences now come from `js/Shared/audit-scope-summary.js` (`window.gracAuditScopeSummary.html(scopeJson)`), moved out of the workspace so the Scope Builder can reuse it.

### Scope Builder
- `org-assurance-scope-builder.cshtml`: the mode toggle, the Advanced section (groups, AND / OR / NOT, "include all values", labels) and its templates and code are removed -- here and on the standalone Scope Builder page.
- A scope Simple mode cannot show (several groups, OR, NOT, include-all, a non-pickable or legacy dimension such as Practice Instances) opens **read-only** as sentences, with the note that it still applies as saved. Save leaves it untouched. On a Draft, **Replace with a simple scope** clears the builder to an empty simple scope (after a confirm); nothing is written until Save.

### Other changes
- `org-assurance-definitions.cshtml`: `saveDefinition()` now resolves to the saved id (or null); `window.__oaDefinitions.save()` added. The standalone modal behaves as before.
- `_audit-question-set-adoption.cshtml`: `save()` resolves true / false; `window.__oaAdoption.save` added.
- `practice-management.css`: section cards, `.oa-ws-section-head` / `-hint`, `.oa-ws-pending`, the save bar; the form's own card frame and padding removed inside a section (the section is the card); the tab-strip rules removed; `.oa-wv-group` styles shared with `.oa-scope-legacy`.
- No database or API change.
- **Row menu / Actions (2026-11-13):** the **Scope** and **Question Set** items were removed from the audit list's 3-dot menu and the audit page's Actions button -- Edit opens the one page with all three sections. Workflow, Scoring, Triggers, Resolve Scope, Executions and History stay (Evidence was removed later the same day, 536): they open their own screens, which are not on this page. `?step=scope|questions` links still work (they scroll to the section).
- **Save outcome as a message box (2026-11-13):** the page's Save reports in one `gracUi.alert` -- success, "Audit created ...", or an error that carries the failing section's own text (taken from that section's inline message, which is then cleared). The inline save line under the sections was removed; the Save button sits alone on the right.
- **Effective Date blank on edit (fixed 2026-11-13):** `org-assurance-definitions.cshtml` `onlyDate()` ran `gracFormatDisplayDate`, turning `2026-11-13` into `13-Nov-2026`, which `<input type="date">` rejects, so the field opened empty. It now returns the `yyyy-MM-dd` value the input needs. (This also affected the standalone Edit dialog.)

## Evidence Config removed -- evidence is set per question (536, 2026-11-13)

**Request (sir).** Question Sets already capture each question's Evidence Type and Expected Evidence, so the separate Evidence step of Audit Configuration is removed. Decisions: the extra Evidence Config fields (collection method, frequency, owner, retention, location / locator, validity, expiry warning) are **dropped**, not moved; an execution's **Questions and Evidence snapshots both come from the audit's question sets**; the Evidence Config **tables and data are kept, unused**.

### Database -- `536_audit_evidence_config_retired.sql` (+ rollback)
- `sp_org_assurance_execution_materialize` re-issued from 120. `questions_snapshot_json` (always `[]` before -- the 099 gap) is now every Active question of the question sets the version adopted (277), set order then question order: set id / code / name / order / mandatory, question id / code / text / help, response type, mandatory, weight, evidence type, expected evidence, question version. `evidence_snapshot_json` is now those questions that name an Evidence Type (set, question, evidence type, expected evidence, mandatory, order) -- it no longer reads `org_assurance_evidence_config`. Nothing else in the procedure changed. Executions created before 536 keep their snapshots.
- `sp_org_assurance_setup_status` re-issued from 278 without the `evidence` step row.
- Menu `org-assurance-evidence-config` set **Inactive** (row and permissions kept); `274` matches.
- Kept: `org_assurance_evidence_config` / `_item`, their procedures and data, and `org_assurance_observation_evidence.evidence_config_id` (nullable, never set by the UI).

### API -- removed
- `GET  /practice/api/org-assurance/definitions/{id}/evidence-config`
- `POST /practice/api/org-assurance/definitions/{id}/evidence-config`
- `GET  /practice/api/org-assurance/collection-methods`
- `GET  /practice/api/org-assurance/frequencies`
- with their service methods and models (`OrgAssuranceEvidenceConfig*`). `GET evidence-types` stays -- the question grid uses it.

### Web
- Audit Configuration: the Evidence tab is gone; the steps are Workflow, Scoring, Trigger, Scope Resolution.
- Audit list 3-dot menu / audit page Actions: **Evidence** item removed.
- `PracticeScreen.cs` / `Manage.cshtml`: the `org-assurance-evidence-config` screen is removed, so its URL no longer opens. The partial `org-assurance-evidence-config.cshtml` is unreferenced and can be deleted.
- Executions: the Materialize dialog text says what the snapshots now hold; the Evidence and Questions tabs show the new JSON as before.

## Audit Configuration as a list; review needs the configuration (537, 2026-11-13)

**Request (sir).** Audit Configuration showed two Organization pickers (the shell's context bar and each hosted screen's own). Make it a list: the audits to configure, a 3-dot menu to configure them, a row click opening a view whose Actions configure it. Workflow / Scoring / Trigger stay **Draft-only** (084 / 087 / 093), so -- sir's decision -- the list shows Draft audits set up up to their question sets, and **Submit for Review needs the configuration to be complete**.

### Flow
Audit Definition (details, scope, question sets; Draft) -> **Audit Configuration** (Workflow, Scoring, Trigger, Scope Resolution) -> Submit for Review -> Approve -> Activate.

### Database -- `537_audit_configuration_list.sql` (+ rollback)
- `fn_org_assurance_setup_steps(@organization_id, @version_id)` -- inline function, one row per step (`StepOrder, StepKey, StepName, IsConfiguration, ItemCount, Status`). The 278 / 536 step rules moved here unchanged; chips, list and gate share it.
- `sp_org_assurance_setup_status` -- 536 body; step rows now from the function (same result sets).
- `sp_org_assurance_configuration_list(@organization_id, @search, @page, @page_size)` -- **new**. Draft audits whose current version has a Scope and at least one Question Set. COUNT header, then rows: definition columns + `WorkflowStatus, ScoringStatus, TriggerStatus, ScopeResolutionStatus, ConfiguredSteps, ConfigurationSteps (4), IsConfigured`.
- `sp_org_assurance_definition_submit` -- 070 body + gate: `THROW 53612 'Complete the audit configuration before submitting it for review. Not complete: <steps>.'` when any of Scope, Question Sets, Workflow, Scoring, Trigger, Scope Resolution is not Completed. Api reason code `CONFIGURATION_INCOMPLETE`.

### API
- `GET /practice/api/org-assurance/configuration-audits?organizationId=&search=&page=&pageSize=` -> `{ totalCount, pageNumber, pageSize, rows: OrgAssuranceConfigurationListRow[] }` (`OrgAssuranceSetupController.ListConfigurationAudits`, `IOrgAssuranceSetupService.ListConfigurationAuditsAsync`).
- `POST /definitions/{id}/submit` -- now 400 `{ error, reasonCode: "CONFIGURATION_INCOMPLETE" }` until the configuration is complete.

### Web
- `org-audit-configuration.cshtml` renders `Partials/_audit-configuration-workspace` (new) with the flow shell in **hosted** mode (`AuditFlowShell.Hosted`).
  - **List**: one Organization picker + search; Code, Name, Owner, Version, Workflow / Scoring / Trigger / Scope Resolution chips, Configured (n of 4), 3-dot (View, Workflow, Scoring, Trigger, Scope Resolution). Row click = View.
  - **View**: audit facts and every step's status, read-only; Actions = the four steps; a line says what is still open.
  - **Configure** (one page, 2026-11-13 -- sir: "like Audit Definition"): Workflow, Scoring, Trigger and Scope Resolution as **section cards one under the other**, each with its status chip and caption; the page scrolls to the step picked. **One Save** at the bottom runs the Workflow save then the Scoring save (`window.__oaWorkflowConfig.save()` / `window.__oaScoringConfig.save()`, each resolving true / false) and reports in one `gracUi.alert`. Triggers (add / edit dialog per trigger) and Scope Resolution ("Preview Resolve Now") act at once, as before. The sections' audit banners and own Save buttons are hidden; Reload, Add Trigger and Preview Resolve Now stay. Back returns to the view.
- `_audit-flow-shell.cshtml` hosted mode: no page heading, no context bar, no tab strip / caption / Previous-Next (sections instead), no URL writes; `window.__oaFlowShell.setContext / show (scrolls) / chipHtml`.
- The four step screens: `saveWorkflow` / `saveScoring` now resolve true / false and are exposed as above; all four skip writing `?definitionId=` to the address bar when `window.__oaHostNoUrl` is set (the Audit Configuration page sets it). Opened on their own routes they behave as before.
- **Menus (2026-11-13, sir):** in the Audit Definition list's 3-dot menu and the audit page's Actions, **Workflow, Scoring, Triggers and Resolve Scope are replaced by one item, Audit Configuration**. It opens this page straight on the audit's configuration; the audit and its organization travel in the encrypted navigation code (`gracSecureNav.open('org-audit-definition', 'org-audit-configuration', 'AuditDefinition', id, orgId, code)` -> `/Practice/Index/org-audit-configuration?code=`), allowed in `PracticeManagementGatewayController.IsAllowedNavigation`. On this page the row 3-dot is View + Audit Configuration, and the view's Actions is Audit Configuration.
- **Spacing (2026-11-13):** the shell's own frame and the hosted screens' panel padding are dropped with selectors that beat `.content-wrapper .pm-panel` (master-layout.css), so each section's content lines up with the page heading; the Workflow / Scoring bars (audit name, Reload, own Save) and the Trigger bar's name / Reload are hidden -- Add Trigger stays.

## Workflow template brings its stages (538, 2026-11-13)

**Request (sir).** Workflow's "Workflow Template (Admin published, optional)" only stored the template's id / code / name; no stage came with it. Picking a template must fill the stages.

**Admin tables (grac_new, read-only here; columns confirmed by sir):** `assurance_workflow_template` (workflow_template_id, template_code, template_name, description, sla_hours, escalation_rule, version_no, lifecycle_status, status) and `assurance_workflow_stage` (workflow_stage_id, workflow_template_id, stage_order, stage_name, stage_type, approval_rule, escalation_rule, sla_hours, status).

### Database -- `538_audit_workflow_template_stages.sql` (+ rollback)
`sp_org_assurance_admin_workflow_template_stage_list(@template_id)` -- new, read-only. Result 1: Id, Code, Name, Description, TotalSlaDays. Result 2: the template's **Active** stages as organization stages -- StageOrder (1..n), StageCode (`STG-01`...; the org column is NOT NULL and Admin stages have none), StageName, StageType (AUDIT/AUDITOR -> AUDITOR, REVIEW/REVIEWER -> REVIEWER, APPROVE/APPROVAL/APPROVER -> APPROVER, else CUSTOM), SlaDays (sla_hours / 24, rounded up), Instructions (the template's approval / escalation rules, and a CUSTOM stage's published type, as labelled lines), AdminStageType, SlaHours.

### API
`GET /practice/api/org-assurance/admin-workflow-templates/{templateId}` -> `{ data: { id, code, name, description, totalSlaDays, stages: [...] } }`, 404 when the template does not exist.

### Web -- `org-assurance-workflow-config.cshtml`
Picking a template loads it and fills the Stages grid -- **only the stages** (sir, 2026-11-13: Workflow Name / Total SLA / Description are not taken from the template); if stages already exist it asks first ("Replace the n stage(s)...?" -- No puts the previous template back). Roles, employees and escalation role stay empty -- the organization assigns them. Nothing is written until Save (the existing 084 save).

## Audit Configuration -- one menu item (539, 2026-11-13)

**Request (sir).** Remove the sub-menus under Audit Configuration (Workflow Config, Scoring Config, Triggers, Scope Resolution); Audit Configuration alone is enough.

`539_audit_configuration_single_menu.sql` (+ rollback) sets those four `menu_master` rows to **Inactive** -- the 279 pattern: rows, ids, parent links and permission grants kept; routes alive (screens resolve from `PracticeScreen.All`, and Audit Configuration hosts all four). Audit Configuration is now a leaf. `274` edited to match. No API or UI code change. Users sign out and in to see the menu change.

## Menu order -- Question Sets last (540, 2026-11-13)

**Request (sir).** Question Sets after Audit Definition, Audit Configuration, Plans, Executions and Observations. `540_audit_question_sets_menu_last.sql` (+ rollback) sets `org-assurance-question-sets.display_order` 445 -> **475** (Observations is 470). Order under Audit Management: Dashboard, Audit Definition, Audit Configuration, Audit Plans, Executions, Observations, Question Sets. `274` edited to match.
- **Fix (2026-11-13):** the stage grid's 3-dot menu stopped opening after a stage was edited. `wireRowMenu()` runs on every render and used `addEventListener`, so handlers stacked: with two, the first opened the menu and the second (same trigger) closed it. It now sets `body.onclick` (one handler), as Scoring and Triggers already do.

## Trigger save -- HTTP 400 (fix, 2026-11-13)

Saving a trigger answered a bare "HTTP 400". The Api binds `ScheduleTime` as `TimeSpan?` (OrgAssuranceTriggerSaveRequest), which System.Text.Json reads as `hh:mm:ss`; `<input type="time">` sends `HH:mm`, so model binding rejected the body and the screen showed only the status (ProblemDetails has no `error` field). `org-assurance-triggers.cshtml`:
- `timeOrNull()` sends the time as `HH:mm:ss`.
- `apiError()` shows the Api's `error`, or the ProblemDetails field errors, instead of "HTTP 400".
- `isoDate()` fills the Schedule From / To date inputs with `yyyy-MM-dd` when editing (they used the display formatter, which `<input type="date">` rejects -- the same bug as the audit Effective Date).
No Api or database change.

### Trigger schedule fields (2026-11-13)
In the Add / Edit Trigger dialog the schedule's second row is one aligned row (labels on one line, inputs level), and each field shows only for the frequency that uses it: **Weekly** -> Day of Week; **Monthly** -> Day of Month; **Quarterly / Annual** -> Day of Month and Month (092: `month_of_year` is the ANNUAL / QUARTERLY month); Daily -> time only. **Month** is a January-December list (still stored 1-12). Fields a frequency does not use are not sent, so a value left from another frequency is not saved. `org-assurance-triggers.cshtml` only.

## Scoring status follows the model type (541, 2026-11-13)

**Issue (sir).** A saved Weighted scoring (thresholds 80 / 60 / 59) still showed **In progress**. `fn_org_assurance_setup_steps` (537, rule from 278) counted Scoring as Completed only with bands, but Pass / Fail and Weighted are threshold-only (087: SupportsBands = 0) and save no bands -- so they could never complete, and the 537 review gate stayed shut.

`541_audit_scoring_status_by_model.sql` (+ rollback) re-issues the function with one change: Scoring is **Completed** when the config has what its model type uses -- a Pass Threshold for PASS_FAIL / WEIGHTED / PERCENTAGE / CUSTOM, or an active band for RISK_BASED / MATURITY_BASED / PERCENTAGE / CUSTOM; **In progress** when a config exists without that. Chips, the Audit Configuration list and the review gate all follow. No Api / Web change.


## Audit Configuration owns Scope and Question Sets; a popup per step; review there (543, includes 542 -- 2026-11-13)

**Request (sir).** Scope Builder and Question Sets showed on the Audit Configuration step list but were edited on Audit Definition. Move them to Audit Configuration and leave only the audit details on Audit Definition. Clicking a step should open that step alone in a popup, saved there, after which it shows Completed. Submit for Review (and Approve) belong on Audit Configuration, enabled once every step is complete (542, whose files never reached the repo, is folded in here).

### Flow
Audit Definition (**details only**) -> **Audit Configuration** (Scope Builder, Question Sets, Workflow, Scoring, Trigger, Scope Resolution; a popup each) -> **Submit for Review** (Audit Configuration) -> **Approve** (Audit Configuration) -> Activate / Retire (Audit Definition).

### Database -- `543_audit_configuration_steps.sql` (+ rollback)
- `fn_org_assurance_setup_steps` -- 541 body with two changes:
  - Scope Builder and Question Sets are configuration steps (`IsConfiguration = 1`), so "configured" counts **6**.
  - **Scope Resolution** is Completed only when the latest resolution (`org_assurance_scope_resolution.resolved_at`) is not older than the latest scope save (`org_assurance_scope_group.entered_dt` -- 074 deletes and re-inserts the groups on every save) and a scope exists. A scope saved after the last resolve makes it **In progress** -- resolve again. The chips, the list and the 537 review gate follow, so such an audit cannot be submitted until it is resolved again.
- `sp_org_assurance_configuration_list` -- 537 body: lists **every Draft and every Under Review** audit (Under Review first), no longer only Drafts with a scope and question sets (a new audit must reach the page to get them); adds `ScopeStatus`, `QuestionsStatus`; `ConfigurationSteps` = 6.
- Not changed: `sp_org_assurance_setup_status` (reads the function), `sp_org_assurance_definition_submit` (537 gate already names Scope and Question Sets), approve / transition, tables, the Draft-only rule of every save.
- Rollback restores the 541 function and the 537 list.

### API
- `GET /practice/api/org-assurance/configuration-audits?organizationId=&search=&page=&pageSize=` -> `{ totalCount, pageNumber, pageSize, rows }`; each row (`OrgAssuranceConfigurationListRow`) now also has `scopeStatus` and `questionsStatus` (Completed / InProgress / NotConfigured), `configurationSteps` is 6, and the rows are the organization's Draft and Under Review audits.
- Used from the page, unchanged: `GET definitions/{id}`, `GET definitions/{id}/setup-status`, `GET|POST definitions/{id}/scope`, `GET|POST definitions/{id}/question-sets`, the workflow / scoring / trigger / scope-resolution endpoints, `POST definitions/{id}/submit` (400 `CONFIGURATION_INCOMPLETE` until every step is Completed) and `POST definitions/{id}/approve`.

### Web
- `org-audit-configuration.cshtml`: two steps added in front -- `scope` (Scope Builder, `org-assurance-scope-builder`) and `questions` (Question Sets, `_audit-question-set-adoption`); keys and titles match `fn_org_assurance_setup_steps`.
- `_audit-configuration-workspace.cshtml`:
  - **List**: Code, Name, Owner, Version, Status, the six step chips, Configured (n of 6), 3-dot = View + **Submit for Review** (Draft) / **Approve** (Under Review). Row click = View.
  - **View**: the audit's facts and its six steps. **A step row opens that step's popup.** Scope Resolution does not open until the scope is saved (its row says "Needs the scope first."); when the scope changed after the last resolve its row says so. Under the steps: **Submit for Review** (Draft; disabled with the open steps as tooltip until all six are Completed) and **Approve** (Under Review); the same two are on Actions. Submit / Approve ask for an optional reason (Cancel stops).
  - **Step popup** (`#oaCfgStepDialog`): the hosted flow shell inside one `<dialog>`, one panel shown at a time. Heading = step name, caption, status chip, close. **Save** for Scope Builder / Question Sets / Workflow / Scoring runs that screen's own save (`window.__oaScopeBuilder / __oaAdoption / __oaWorkflowConfig / __oaScoringConfig .save()`); on success the popup closes, the step list reloads (the chip turns Completed) and a message box confirms; on failure the popup stays open with the screen's own message. Trigger and Scope Resolution save as they go, so their popup has Close only. Every open re-reads the step (`.reload()`), so edits thrown away by closing unsaved do not come back; closing (X, Close, Escape) after a change asks first. A non-Draft audit opens read-only (the screens' own read-only line, no Save).
  - The single-page "configure" mode with its one Save is gone.
- Reload hooks (the screens' own Reload code, run quietly): `org-assurance-workflow-config` `reloadWorkflow`, `org-assurance-scoring-config` `reloadScoring`, `org-assurance-scope-builder` `reloadScope`, exported as `.reload()`; `_audit-question-set-adoption` exports its `reload`. The Reload buttons behave as before. The Scope Builder no longer writes `?definitionId=` to the address bar when hosted (`window.__oaHostNoUrl`).
- `_audit-definition-workspace.cshtml`: the Scope and Question Sets sections, the "save the audit details first" placeholders and their Save steps are removed; Save writes the audit details. Creating an audit asks **"Configure now?"**, which opens Audit Configuration on it (the definitions screen's Audit Configuration item, encrypted navigation code). The read-only view page still shows the scope and question sets (Approved / Active audits are not on the configuration list). `?step=scope|questions` links open the edit page at the top.
- `org-assurance-definitions.cshtml`: **Submit for Review and Approve removed** from the 3-dot menu / Actions (542). Activate and Retire stay.
- `practice-management.css`: popup rules (`.oa-cfg-dialog`), the Scope Builder banner and the Question Sets Save hidden on `.oa-cfg`, the step-row note; the configure-mode rules and the Audit Definition scope / question-set rules removed.

### Scope Builder as a full page (2026-11-13, sir) -- superseded below
The Scope Builder is too big for a popup, so its step opens as a **full page** inside Audit Configuration (mode `scope`, `#oaCfgPage`, a section card with Cancel / Save at the bottom; the heading's Back reads "Back to audit"). The step's panel is moved out of the popup into that page once at load (listeners kept). **Save** writes the scope and returns to the audit's view (its step list, chip updated) with a message box; **Cancel** / **Back** return too, asking first when something was changed. The other steps stay popups. `_audit-configuration-workspace.cshtml` and `practice-management.css` (`.oa-cfg-page`) only.

### Step popups -- inset and close button (2026-11-13, sir) -- superseded below
The step popup had no inset (the house dialogs get their 20px from `dialog form` in control-management.css; this popup has no form of its own -- the step screens keep theirs inside their own dialogs), so the heading, content and buttons touched its edge, and the close X opened with a focus ring because `showModal()` focuses the first button. `dialog.oa-cfg-dialog` now has the same 20px padding, and the popup focuses itself on open (`tabindex="-1"`, no outline), so the X shows as the plain house icon button. Heading / body / Close-Save spacing follows `.pm-dialog-heading` (14px) and `.pm-dialog-actions` (18px). Applies to every step popup (Question Sets, Workflow, Scoring, Trigger, Scope Resolution).

### Step rows expand -- replaces the popups and the Scope full page (2026-11-13, sir)
**Request (sir).** Instead of a row click, a Configure column with a button per step; the button opens the step's screen in a row right under it, like the expand button of the Question Sets grid.
- The step list (view mode) has a fourth column, **Configure**: a `.pm-button icon` (sliders) per step, "View" on a non-Draft audit. A row click does nothing now. Scope Resolution's button is disabled until the scope is saved (tooltip says why).
- The button opens the step under its row (an expand row, `tr.oa-cfg-expand`, one cell across the table) inside a frame: the step's caption, its screen, and Cancel / Save (Close only for Trigger and Scope Resolution, which save as they go, and on a read-only audit). The button turns into a chevron; pressing it again closes the step. **One step open at a time**: opening another, Cancel, the button again or Back to audit list asks first when the open step has unsaved changes.
- **Save** runs the step screen's own save, closes the step, re-reads the list (the chip turns Completed) and confirms in a message box. A failed save keeps the step open with the screen's own message.
- How: the hosted flow shell and the frame wait in a hidden holder (`#oaCfgHolder`); opening moves the step's panel into the frame and the frame into the expand row, closing moves both back (panel to its place in the shell). The step list re-renders on refresh; an open step is put back under its row. Every open re-reads the step (`.reload()`), as before.
- The step popup (`#oaCfgStepDialog`) and the Scope Builder page (`#oaCfgPage`, mode `scope`) are removed, with their CSS.
- CSS: the step list's wrap is not height-capped; the expand cell has no hover / stripe / centred 58px last-cell styling and wraps text; the step screens' own tables inside keep their stripes and hover (`is-selected` on the expand row keeps the shared hover rule off it).
- Files: `_audit-configuration-workspace.cshtml`, `practice-management.css`.
- **List follow-up (sir):** the list no longer shows a column per step. Columns: Code, Name, Owner, Version, **Status** (Draft / Under Review), **Configured** (`n/6`), Actions. The step statuses are on the audit's view; the API row still carries them (the 3-dot Submit for Review uses them to name what is not complete).
- **Follow-up (sir):** the Configure button is the **pen** icon (`fa-pen`, the house edit icon) in both states; the open step's row **stays highlighted** (`tr.oa-cfg-step-open`: `--primary-100`, one step darker than the row-hover tint, with the hover accent down the left edge of the row and its expand row); opening a step **does not scroll** the page -- it opens downward from the row where it was clicked.

### One audit view, with the configuration -- Audit Definition and Audit Configuration (2026-11-13, sir)
**Request (sir).** The Audit Definition view page showed only details, scope and question sets: add the other configuration steps and the audit's latest status. On Audit Configuration, the 3-dot View should show that same page, while a row click keeps the step list.
- **New `wwwroot/js/Shared/audit-view.js`** (`window.gracAuditView.render(host, { orgId, definitionId, chipHtml, onSteps })` -> the definition; `versionLabel(def)`). The Audit Definition view rendering moved here (no copy left behind) and was extended. Sections, each with its step's status chip: **Definition Details** (facts, lifecycle stamps, objective / description), **Configuration Status** (every step's latest status and items, "Configured n/6"), **Scope Details** (`gracAuditScopeSummary`), **Question Sets** (with their questions), **Workflow** (template, name, total SLA, description; stages: order, stage, type, assigned to, SLA, escalation), **Scoring** (model, type, max score, thresholds, description; bands), **Trigger** (code, name, type, enabled, details, next run), **Scope Resolution** (last resolved, by, purpose, entities, number of resolutions; a note when the scope changed after it), **Created / Updated**. Reads only the existing GET endpoints (definition, setup-status, scope, question-sets + questions, workflow-config, scoring-config, triggers, scope-resolutions page 1); a failed read empties only its own section.
- **Audit Definition** (`_audit-definition-workspace.cshtml`): the view page's sections are one host (`#oaWvBody`) drawn by `audit-view.js`; the page keeps its badges, Refresh and Actions. Its own facts / scope / question-set renderers were removed.
- **Audit Configuration** (`_audit-configuration-workspace.cshtml`): the list's 3-dot is now **View** (mode `audit`: the same page, `#oaCfgAvBody`, with its own badges and Refresh) and **Configure** (the step list), then Submit for Review / Approve. A **row click still opens the step list**. On the audit view, Actions = Configure + Submit for Review / Approve.
- CSS: `.oa-cfg-audit` shows only in mode `audit`.

### Approve makes the audit Active (544, 2026-11-13, sir)
**Request (sir).** Approving should make the audit Active at once, without a separate Activate.
- **Database -- `544_audit_approve_activates.sql` (+ rollback):** `sp_org_assurance_definition_approve` (070 body) runs both lifecycle transitions through the 070 helper, one after the other: Under Review -> **Approved** (APPROVE, approved by / date), then Approved -> **Active** (ACTIVATE, activated by / date, `active_version_id` = this version). History gets both rows with the same reason. No outer transaction (the helper manages its own); if the second step ever failed the audit stays Approved and can still be activated. Rollback restores the 070 body.
- **API:** unchanged -- `POST /practice/api/org-assurance/definitions/{id}/approve` now ends with the audit **Active**.
- **Web:** Audit Configuration's Approve asks "Approving makes the audit Active" (title "Approve and activate") and confirms "Audit approved. It is now Active." Audit Definition's **Activate** item now shows only for an audit still Approved (approved before 544). Retire is unchanged (Active audits).

### Scope resolved when an execution is created; Scope Resolution no longer a step (545, 2026-11-13, sir)
**Request (sir).** Resolving the scope during configuration is too early: planning comes after configuration and the execution after that, by when the data (assets, vendors, practice instances) has changed. Resolve it when the execution is created.

**Before 545:** creating an execution (Executions -> Materialize) did not resolve anything -- the user picked one of the snapshots made earlier ("Preview Resolve Now", purpose PREVIEW), however old.

- **Database -- `545_scope_resolved_at_execution.sql` (+ rollback):**
  - `sp_org_assurance_execution_materialize` (536 body): `@scope_resolution_id` is optional (default NULL). Without it the procedure resolves the version's scope inside its own transaction (`sp_org_assurance_scope_resolve`, purpose **EXECUTION**; the resolver nests and never rolls back on its own, so a failure undoes both), links the snapshot to the new execution (`org_assurance_scope_resolution.execution_id`) and copies its entities onto the execution. A snapshot passed in is still checked and used (54019-54021). THROW 54012 (snapshot required) is gone.
  - `fn_org_assurance_setup_steps` (543 body): the **Scope Resolution step is removed** -- five steps (Scope Builder, Question Sets, Workflow, Scoring, Trigger). Chips, the list and the 537 review gate follow: Submit for Review no longer needs a resolution, and the 543 "scope changed after the last resolve" rule goes with the step.
  - `sp_org_assurance_configuration_list` (543 body): no `ScopeResolutionStatus`; `ConfigurationSteps` = 5.
  - Rollback restores the 536 materialize and the 543 function and list.
- **API:**
  - `POST /practice/api/org-assurance/executions/materialize`: `scopeResolutionId` is **optional** (`OrgAssuranceExecutionMaterializeRequest.ScopeResolutionId` is `long?`); omitted / null = resolve now. A value given must be positive.
  - `GET /configuration-audits`: rows no longer carry `scopeResolutionStatus`; `configurationSteps` = 5.
- **Web:**
  - Executions -> Materialize: the "Scope Resolution Snapshot" field is removed; the dialog says the scope is resolved now; the request sends `scopeResolutionId: null`.
  - Audit Configuration: five steps. The Scope Builder step (`Partials/_audit-scope-step.cshtml`, new) shows the Scope Builder with a **Preview** under it -- the existing Scope Resolution screen ("Preview Resolve Now", its snapshots and entities), hosted unchanged, a check of what the saved scope matches today. The flow shell binds both screens for that step (`SCOPED['scope'] = ['oaScope', 'oaRs']`). The Scope Resolution row, its blocked / stale notes and its list column are gone.
  - `audit-view.js`: the Scope Resolution section is removed (Configuration Status shows the five steps).
  - CSS: `.oa-scope-preview` (divided sub-section, the hosted panel's frame dropped).

### Audit Plan -- basic flow (546, 2026-11-14, sir)
**Agreed steps (sir).** 1. Make a plan (Annual / Quarterly / Monthly / One-Time, period). 2. Add audits to it as slots -- an audit may have many -- from the plan (Add Item) or from the audit's own menu (**Add to Plan**). 3. Submit and approve the plan. 4. Start each slot as an execution (**Start Execution**). 5. Track each slot's status. 6. Close the plan. Decisions: audits are added from both places; executions come from plan slots only for now (scheduled triggers stay configuration and do not run on their own -- nothing ran them before either); a retired audit's unexecuted slots stay, marked **Not executed**, and cannot be started.

- **Database -- `546_audit_plan_basic_flow.sql` (+ rollback):**
  - `sp_org_assurance_plan_item_save` (121 body): slots change only while the plan is **Draft or Submitted** (53909, the header's own rule); the audit must be **Active** (53933); Scheduled To >= From and both **inside the plan period** (53934); code / name are taken from the audit.
  - `sp_org_assurance_plan_item_delete` (090 body): Draft / Submitted only (53909); never a slot with an execution (53936).
  - `sp_org_assurance_plan_item_list` (121 body): + `DefinitionStatusCode/Name`, the slot's latest execution (`ExecutionId`, `ExecutionCode`, `ExecutionStatusCode/Name`; a Cancelled one only when there is no other) and `SlotStatus`: **Planned** (none yet), **InProgress** (a live execution), **Completed** (execution Approved / Closed), **NotExecuted** (none, and the audit is Retired or the plan Closed).
  - **New `sp_org_assurance_plan_item_start_execution`**: checks the slot, the plan (**Approved or Active**, 53935), the audit (**Active**, 53933 -- so a retired audit's slot cannot start) and that the slot has no live execution (53936); then runs `sp_org_assurance_execution_materialize` with origin **PLAN**, the plan / slot ids, the slot's dates as planned dates, its auditor as owner and its team, and no snapshot -- the scope is resolved now (545). Returns the new execution's row.
  - New reason codes: 53933 `AUDIT_NOT_ACTIVE`, 53934 `SLOT_OUTSIDE_PERIOD`, 53935 `PLAN_NOT_EXECUTABLE`, 53936 `SLOT_ALREADY_EXECUTED` (`OrgAssurancePlanService.MapReason`).
- **API:**
  - `GET /practice/api/org-assurance/plans/{id}/items` -- each row (`OrgAssurancePlanItemRow`) also has `definitionStatusCode`, `definitionStatusName`, `executionId`, `executionCode`, `executionStatusCode`, `executionStatusName`, `slotStatus`.
  - `POST /plan-items`, `DELETE /plans/{planId}/items/{itemId}` -- the 546 rules above (400 with the reason code).
  - **New** `POST /practice/api/org-assurance/plans/{planId}/items/{itemId}/start-execution`, body `{ organizationId, planId, actor }` -> `{ executionId, executionCode, executionName, totalEntityCount }` (`OrgAssurancePlanController.StartItemExecution`, `IOrgAssurancePlanService.StartItemExecutionAsync`, result `OrgAssurancePlanItemExecutionResult`).
- **Web:**
  - **Audit Definition** (`org-assurance-definitions.cshtml`): an **Active** audit's 3-dot / Actions has **Add to Plan**. It opens Audit Plans with the audit in the encrypted navigation code (`gracSecureNav.open('org-audit-definition', 'org-assurance-plans', 'AuditDefinition', id, orgId, code)`); the gateway allows `AuditDefinition -> org-assurance-plans` (`PracticeManagementGatewayController.IsAllowedNavigation`).
  - **Audit Plans** (`org-assurance-plans.cshtml`): opened that way, an **Add to Plan** dialog asks which Draft / Submitted plan to use, or **New Plan** (after saving it the page continues with the new plan); Add Item then opens with the audit chosen, and stays so for further slots until the page is left. The audit picker offers **Active audits only** (an existing slot's own audit is kept, marked with its status). **Add Item** is enabled only while the plan is Draft or Submitted. The items grid has a **Status** column (slot status, the execution's code, "audit retired"). A slot's 3-dot: **Edit / Remove** (plan Draft / Submitted, slot Planned), **Start Execution** (plan Approved / Active, slot Planned, audit Active -- confirms, then reports the execution code and the entity count); otherwise "No actions available". Plan transitions refresh Add Item and the slot menus.

### Approving a plan makes it Active (547, 2026-11-14, sir)
As for audits (544). **`547_audit_plan_approve_activates.sql` (+ rollback):** `sp_org_assurance_plan_approve` (090 body) runs Submitted -> **Approved** and then Approved -> **Active** through the 090 helper, inside one transaction (the helper opens none and only throws, so nesting is safe). API unchanged: `POST /practice/api/org-assurance/plans/{id}/approve` now ends **Active**. Web (`org-assurance-plans.cshtml`): Approve asks "Approving makes it Active" (title "Approve and activate"); **Activate** shows only for a plan still Approved (approved before 547).

### Audit Plans -- one plan list, slots as child rows (2026-11-14, sir)
The Audit Plans page no longer shows a plans panel beside an items panel. It
is one full-width list of plans (Code, Name, Type, Period, Owner, Slots,
Status, 3-dot). A plan's chevron -- or a click anywhere on its row -- opens
its slots in a child row right under it (Order, Audit, Scheduled, Auditor,
Team / Department, Status with the execution code, 3-dot); several plans can
be open at once and the open plan's row stays highlighted. The slots are read
when the plan opens and again after any change; more than 20 show the first
20 with "Show all n slots". "+ Add Item" sits under the slots while the plan
is Draft or Submitted, and Add Item is also on the plan's 3-dot (which no
longer has View Items). The selected-plan header, its Actions button and the
separate Add Item button are gone; the slot 3-dot (Edit / Remove / Start
Execution) and every rule behind it are unchanged. Add to Plan from Audit
Definition opens the chosen plan and its Add Item. No database or Api change.
Files: Views/Practice/Partials/org-assurance-plans.cshtml,
wwwroot/css/practice-management.css (.oa-pl-*).

### Trigger removed from Audit Configuration (548, 2026-11-14, sir)
"Remove the trigger option from configuration." Nothing ran an audit from a
trigger -- no scheduler or event listener reads `org_assurance_trigger_config`
-- and executions start from plan slots (546), yet the Trigger step blocked
Submit for Review.
- **DB `548_audit_trigger_step_removed.sql` (+ rollback):**
  `fn_org_assurance_setup_steps` (545 body) has no Trigger row -- four
  configuration steps: Scope Builder, Question Sets, Workflow, Scoring. The
  review gate in `sp_org_assurance_definition_submit` reads this function, so
  Submit for Review no longer needs a trigger. `sp_org_assurance_configuration_list`
  (545 body): no `TriggerStatus`, `ConfigurationSteps` = 4.
- **Api:** `OrgAssuranceConfigurationListRow` loses `TriggerStatus` (the service
  no longer reads it; default steps 4).
- **Web:** `org-audit-configuration.cshtml` -- the Trigger step is gone;
  `_audit-configuration-workspace.cshtml` -- list subtitle, Configured n/4, the
  Submit for Review step names and the step frame's trigger note;
  `js/Shared/audit-view.js` -- the Trigger section and its read (and the
  date-time helper only it used) removed from the one audit view.
- **Not changed:** the trigger table and its rows, the trigger procedures and
  endpoints, the standalone Triggers screen (its menu has been inactive since
  539), execution origin TRIGGER. Auto-run from triggers can come back with the
  risk-based planning phase.

### Audit Configuration leaves the sidebar (549, 2026-11-14, sir)
Audit Configuration is opened from Audit Definition -- the list's 3-dot and the
view page's Actions ("Audit Configuration", via `gracSecureNav`) -- so its own
sidebar item goes.
- **DB `549_audit_configuration_menu_hidden.sql` (+ rollback):** `menu_master`
  row `org-audit-configuration` set **Inactive** (the 279 / 539 pattern: row,
  parent link and grants kept). `274_menu_master_seed.sql` updated to match.
- **Web:** only Active menu rows pass the permission filter, so the screen now
  follows Audit Definition's grants -- `PracticeController.ScreenPermissionArea`
  and `Security/PermissionAreaMap` map `org-audit-configuration` ->
  `org-audit-definition` (page load and the navigation-code VIEW check).
  `PracticeScreen` description updated. The page, its list mode and its route
  are unchanged; Under Review audits are approved by opening Audit
  Configuration from the audit's row in Audit Definition.

### Audit plan with id 0 (550, 2026-11-14)
**Symptom:** on Audit Plans, opening a plan's slots answered "HTTP 404" and the
plan's 3-dot Add Item said "Pick a plan first." The plan list returned
`planId: 0` -- the plan was stored with `org_assurance_plan_id = 0`. The page
treats 0 as no id (`row.planId || row.PlanId`), so it called
`/plans/undefined/items` (404 from the `{id:long}` route); the Api also rejects
plan id 0.
**Cause:** `192_practice_data_reset.sql` reseeds emptied tables with
`DBCC CHECKIDENT (..., RESEED, 0)`. On a table that never had a row since it
was created, SQL Server gives the first insert the reseed value itself -- 0.
**Fix -- `550_audit_plan_zero_id_repair.sql`:** reports every table with an
id-0 row; renumbers the id-0 plan to the next free id (copy with
IDENTITY_INSERT, repoint every foreign key that references it, delete the old
row, reseed) in one transaction; reseeds every empty table left at 0 to 1.
`192_practice_data_reset.sql` now reseeds a never-used table to 1 (0
otherwise). No Api or Web change.

### Question Set versioning and approval (551, 2026-11-14, sir)
First phase of the audit flow redesign -- see `docs/audit-flow-redesign.md` for
the whole design. Question Sets and Audit Definitions are masters: approved, and
changed only by a new version.

**Model.** One `org_assurance_question_set` row per version; a set's versions
share `root_question_set_id` and `set_code` (unique key now
`(organization_id, set_code, version_number)`). Questions stay on their version's
row; a definition version links an exact set version; executions snapshot
their questions -- none of those readers changed. `version_status`:
Draft -> UnderReview (Recommend) -> Active (Approve); Return -> Draft; approving
makes the previous Active version Superseded. Only a Draft is changed (53840).
New Version copies the Active version into a Draft (one open version per set,
53841). Existing sets became v1 Active (v1 Draft if their old status was Draft
and no audit used them). Only Active versions can be adopted (53714).

**On approve,** every audit whose CURRENT version uses an older version of the set:
Draft / Under Review -> the link moves in place (history `QSET_UPDATE`);
Approved / Active -> a new Draft version, a full copy with the new set version
(history `CREATE`), which needs Submit for Review and Approve again -- the Active
version keeps running; Retired -> nothing. The set page lists these audits for a
Draft / Under Review version, and Recommend / Approve show them before confirming.

**Copy engine.** `sp_org_assurance_clone_rows` (generic MERGE ... OUTPUT copy
with overrides and an old -> new id map) and
`sp_org_assurance_definition_version_copy_config` (scope groups / conditions /
values, question set links, workflow config / stages, scoring config / bands).
Editing an Active audit (definition save) now uses it too -- its new Draft version
keeps the scope, question sets, workflow and scoring (it started empty before).

**Plannable audit** = has an Active version and is not Retired, so an audit being
revised stays in planning: plan item save, the slot list's new
`DefinitionIsPlannable`, Start Execution (which now runs the ACTIVE version --
it ran the current version, which can be a Draft), the plan's audit picker and
Audit Definition's Add to Plan.

**API** (`/api/practice/org-assurance`, Web proxy `/practice/api/org-assurance`):

| Method | Route | Body / query | Returns |
|---|---|---|---|
| GET | `question-sets?organizationId=&search=&page=&pageSize=` | | one row per set (its latest version) + `RootQuestionSetId, VersionNumber, VersionStatus, ActiveVersionNumber` |
| GET | `question-sets/{id}?organizationId=` | | the version + `VersionNumber, VersionStatus, ChangeNote, Submitted*, Approved*, ActiveQuestionSetId / ActiveVersionNumber, OpenQuestionSetId / OpenVersionNumber / OpenVersionStatus` |
| GET | `question-sets/{id}/versions?organizationId=` | | every version, newest first |
| GET | `question-sets/{id}/impact?organizationId=` | | audits affected by approving this version: `DefinitionId, DefinitionCode, DefinitionName, CurrentVersionNumber, CurrentStatusCode / Name, LinkedSetVersion, ActionCode (UPDATE_IN_PLACE / NEW_VERSION), ActionText` |
| POST | `question-sets/{id}/new-version` | `{ organizationId, actor }` | `{ questionSetId }` of the new Draft |
| POST | `question-sets/{id}/submit` | `{ organizationId, note, actor }` (note = change note) | Recommend |
| POST | `question-sets/{id}/return` | `{ organizationId, note, actor }` (note = reason) | back to Draft |
| POST | `question-sets/{id}/approve` | `{ organizationId, actor }` | `{ questionSetId, definitions: [{ definitionId, definitionCode, definitionName, actionCode, newVersionNumber }] }` |
| DELETE | `question-sets/{id}?organizationId=` | | a Draft v2+ is discarded; a whole set only when no audit uses it (53846) |

Definition question sets (`GET definitions/{id}/question-sets`): adopted rows add
`SetVersionNumber, SetVersionStatus`; available rows are Active versions only and
add `SetVersionNumber`. Plan items add `DefinitionIsPlannable`. Reason codes:
53840 VERSION_NOT_DRAFT, 53841 VERSION_IN_PROGRESS, 53842 NO_ACTIVE_VERSION,
53843 NO_QUESTIONS, 53844 NOT_UNDER_REVIEW, 53846 SET_IN_USE, 53849 CLONE_FAILED,
53714 (definition question set save) only Active versions.

**UI.** Question Sets list: Version (with "(vN Active)" while a newer version is
open) and the version Status; 3-dot by status -- Edit / Recommend / Discard Draft,
Approve / Return to Draft, New Version. Set page: Version facts (version, status,
recommended, approved, change note), "Audits using this question set" (warning
note + table) for a Draft / Under Review version, and Versions (row opens that
version). Edit only for a Draft. Audit Configuration's question set picker and the
audit view show the set version (e.g. `QS-01 v2`).

**Note.** `tool_import_audit_question_sets.sql` saves through
`sp_org_assurance_question_set_save`, so an imported set is a Draft v1 to be
approved; importing into a set that is no longer Draft fails (53840) -- use New Version.

### Engagements (552, 2026-11-14, sir)
Phase 2 of `docs/audit-flow-redesign.md`. A plan's items are **Engagements**: who
audits (auditor, team, department, branch), when (from / to) and **which audit
definitions -- one or more**. Decision (sir): an engagement is a parent holding one
execution per audit definition.

**DB `552_audit_engagements.sql` (+ rollback):**
- `org_assurance_plan_item` (the engagement) + `engagement_code` (plan code +
  `-E01`, `-E02` ...) and `engagement_name` (default: the first audit's name).
- NEW `org_assurance_engagement_definition` -- the engagement's audits, in order
  (filtered unique index on item + definition while active). Existing items got one
  row each. The item's own `org_assurance_definition_id` / code / name stay as its
  FIRST audit, so pre-552 readers keep working.
- `sp_org_assurance_plan_item_save`: `@definitions_json` (`[{"definitionId":1}, ...]`)
  or the single `@org_assurance_definition_id`; `@engagement_name`. Every audit must
  be plannable (551); one already started on the engagement may stay, but cannot be
  removed (53938 DEFINITION_STARTED); the same audit twice -> 53937.
- `sp_org_assurance_plan_item_list` + `EngagementCode, EngagementName,
  DefinitionCount, DefinitionCodes, ExecutionCount, ExecutionDoneCount, CanStart`;
  `SlotStatus` rolls up: Completed when every audit's execution is Approved / Closed,
  InProgress when any is live, NotExecuted when the plan is Closed or no audit can be
  planned, else Planned.
- NEW `sp_org_assurance_engagement_definition_list` -- per audit: plannable flag,
  Active version, latest execution.
- `sp_org_assurance_plan_item_start_execution` (rewritten): one execution per audit
  not yet started that has an Active version, all in one transaction; returns a row
  per execution (53936 when none is left).
- NEW `sp_org_assurance_engagement_scope_preview` -- **View Scope**: each audit's scope
  resolved by the existing resolver (PREVIEW, Active version) inside a transaction
  that is rolled back -- nothing saved, nothing frozen -- with the audits that bring
  each entity in.

**API:**

| Method | Route | Body / query | Returns |
|---|---|---|---|
| POST | `plan-items` | + `engagementName`, `definitionIds[]` (in order; `definitionId` alone still works) | `{ planItemId }` |
| GET | `plans/{planId}/items?organizationId=` | | + the 552 engagement columns |
| GET | `plans/{planId}/items/{itemId}/definitions?organizationId=` | | the engagement's audits |
| POST | `engagements/scope-preview` | `{ organizationId, planItemId? , definitionIds? }` | `{ dimensions: [{ dimensionCode, dimensionName, entityCount }], entities: [{ dimensionCode, dimensionName, entityId, entityCode, entityName, definitionCodes }] }` |
| POST | `plans/{planId}/items/{itemId}/start-execution` | `{ organizationId, actor }` | first execution's fields + `executions[]` (one per audit started) |

**UI (Audit Plans).** "Item" / "slot" read **Engagement**. Plan list column
Engagements; plan 3-dot Add Engagement. Engagement rows: Order, Engagement (name +
code), Audits, Scheduled, Auditor, Team / Department, Status ("n / m done" for
several audits). Engagement 3-dot: Edit / Remove (Planned, plan Draft / Submitted),
**View Scope**, Start Execution (while an audit is left to start). The engagement
dialog: Name, Order, the audits in a dual list (Available / In this engagement,
> < and up / down -- the `.oa-adopt-grid` picker), a **View Scope** link (the
selected audits, unsaved), dates, auditor, team, department, branch, notes. View
Scope dialog: per-type counts and the entity list with the audits that bring each in.

### Role Responsibilities; the engagement's Assigned Auditor lists auditors only (553, 2026-11-14, sir)
The engagement dialog asked for a Role and then a person; the role is always the
auditor's. Nothing said which roles are auditor roles. A first cut (an "Auditor
Role" tick on Role Master) was replaced the same day, at sir's request, by a
general mechanism: **Role Responsibilities** -- what a role *does* (Auditor, Audit
Reviewer, Audit Approver ...), distinct from menu permissions (which *screens* it
may use). The next such need is a master row, not a new column.
- **DB `553_role_responsibilities.sql` (+ rollback):**
  - `role_responsibility_master` (global: code, name, description, order, active).
    Seeded `AUDITOR` / Auditor, `AUDIT_REVIEWER` / Audit Reviewer,
    `AUDIT_APPROVER` / Audit Approver. Screens use the **code**.
  - `organization_role_responsibility` (role -> responsibilities, many; soft
    deactivation; one active row per role + responsibility).
  - If the first cut ran: roles ticked `is_auditor_role` get `AUDITOR`;
    `sp_org_auditor_list` is dropped; the column is left unread.
  - `sp_org_role_save` / `sp_org_role_list` (465 bodies, the Role Master gateway
    shims' inner procedures): save `$.responsibilityIds` (array; absent = unchanged,
    empty = clear); list returns `ResponsibilityIds` (comma list) and
    `Responsibilities` (names).
  - NEW `sp_get_role_responsibility_lookup` ("role-responsibilities" lookup, the
    time-zones shim shape) and `sp_org_responsibility_holder_list(@organization_id,
    @responsibility_code)`: active people whose role (`organization_employee.role_id`,
    the `sp_org_role_holders_list` rule) is active and carries the responsibility.
  - Rollback restores the 465 bodies and drops the new procedures; tables kept.
- **API:**
  - `GET /api/practice/org-roles/responsibility-holders?organizationId=&code=`
    (Web proxy `/practice/api/org-roles/responsibility-holders`) ->
    `[{ employeeId, employeeCode, employeeName, designation, roleId, roleName }]`.
    Replaces the first cut's `org-roles/auditors`.
  - `POST /api/practice/role-responsibilities/query` (lookup; whitelisted in
    `PracticeRepositoryController`, shim mapped in `ResolveProcedureAsync`;
    baseline `role-responsibilities:VIEW` in Web `LoginController`).
- **UI:**
  - Role Master: **Responsibilities** multi-select (`comboChecks`, lookup
    `role-responsibilities`, loaded by `ensureRoleResponsibilityLookup`); grid gains
    a Responsibilities column.
  - Audit Plans engagement dialog: Assigned Auditor is one select of the people
    whose role carries **Auditor** ("Name - Role"); the role is saved from the person
    picked; an engagement's auditor no longer in the list is kept as an extra option
    "(no longer an auditor)"; with nobody listed the box says to give a role the
    Auditor responsibility.
- After deploying, give the auditor roles the **Auditor** responsibility in Role
  Master. More responsibilities are added as rows in `role_responsibility_master`.

### Branch audit -- an engagement's Branch narrows its scope (554, 2026-11-14, sir)
Asked whether a branch can be audited today: no -- the engagement's Branch was free
text used by nothing, and the scope had no branch filter. Decisions (sir): **a branch
is a Location** (Location master), and **a practice instance belongs to a branch
through its LOCATION dependency resolved in Operationalize**. The audit definition's
scope stays the full set; the engagement narrows it (never widens it).
- **Narrowing rule:** practice instances kept when an active
  `practice_dependency_resolution` row of type LOCATION points at the branch (the 415
  View Data Scope rule); assets kept when `organization_dependency_asset.location_id`
  is the branch; departments, vendors and any other dimension kept as picked.
- **DB `554_engagement_branch_scope.sql` (+ rollback):**
  - NEW `sp_org_assurance_scope_resolution_narrow_location(@organization_id,
    @resolution_id, @location_id)` -- narrows a resolved snapshot, recomputes its
    totals; no transaction of its own (nests).
  - `sp_org_assurance_scope_dimension_values` (534 body) + `BRANCH` = the
    organization's active Locations. BRANCH stays non-pickable, so the Scope Builder
    does not change.
  - `sp_org_assurance_plan_item_start_execution` (552 body): with a Branch, each
    audit's scope is resolved (EXECUTION), narrowed and passed to materialize as its
    snapshot (materialize unchanged); the snapshot is linked to its execution. An
    audit with nothing at the branch stops the start (**53942**, names the audit).
    *Superseded by 555: executions start with a live scope; the narrowing is applied
    to the live scope and at Freeze Scope (an empty scope is refused there, 54035).*
  - `sp_org_assurance_engagement_scope_preview` (552 body): `@location_id`; a saved
    engagement uses its own Branch.
  - Errors: 53939 ids required, 53940 the branch is not a Location of the
    organization, 53941 snapshot not found, 53942 nothing at the branch.
- **API:**
  - `GET /api/practice/org-assurance/scope-dimensions/BRANCH/values?organizationId=`
    -> `[{ id, code, name }]` (the branch list).
  - `POST engagements/scope-preview` body gains `locationId` (unsaved pick).
  - `MapReason`: 53939-53942.
  - Plan items already carry `assignedBranchId` / `assignedBranchName`; the id is now
    a Location id.
- **UI (Audit Plans engagement dialog):** Branch is a select of Locations ("whole
  scope (no branch)" first) with a one-line hint; View Scope from the dialog uses the
  branch picked; the 3-dot View Scope shows "at <branch>". Engagements saved before
  554 show their branch text as "(text only -- does not narrow the scope)".

### My Audits -- live scope, Freeze Scope (555, 2026-11-14, sir; redesign Phase 3)
**Decisions (sir):** executions start **automatically** when the auditor opens My Audits
on or after the engagement's From date (Start Execution on the plan stays, to start early);
**My Audits** is a new sidebar item; before freezing the auditor may **exclude items, each
with a reason**; a frozen scope is **final** (to change it, cancel and start again).
- **Model:** an engagement's execution is created with a **live scope** -- no entity rows,
  `scope_frozen_at` NULL. Its live scope is the audit's scope resolved now, narrowed to the
  engagement's Branch (554). **Freeze Scope** (the execution's owner = the engagement's
  Assigned Auditor only): resolve (EXECUTION), narrow, remove and record the exclusions, copy
  the entities, Planned -> In Progress. Manual / trigger executions are frozen at creation as
  before; executions that existed before 555 are marked frozen.
- **DB `555_my_audits_freeze_scope.sql` (+ rollback):**
  - `org_assurance_execution` + `scope_frozen_at`, `scope_frozen_by` (backfilled once).
    NEW `org_assurance_execution_scope_exclusion` (item, reason, who, when).
  - Menu `org-my-audits` "My Audits" under `nav-assurance` (468), granted to every active
    role (it shows only the caller's own audits); written back into 274.
  - `sp_org_assurance_execution_materialize` (545 body) + `@live`. **Fix (found on first
    run, "Invalid object name org_assurance_workflow_config_stage"):** since 120 the
    workflow and scoring snapshots read `org_assurance_workflow_config_stage` and
    `org_assurance_scoring_config_band`, which never existed, plus columns not on those
    tables, so every materialize failed. They now read `org_assurance_workflow_stage`
    (083) and `org_assurance_scoring_band` (086) with their real columns. The snapshot
    JSON keys changed accordingly (StageType, RoleId/Name, EmployeeId/Name, SlaDays,
    escalation, Instructions; ScoringModelType, thresholds, BandMinScore / BandMaxScore,
    BandOutcomeCode, BandColorHex); the Executions page shows them as raw JSON only.
  - `sp_org_assurance_plan_item_start_execution` (554 body): creates the executions live;
    the 554 branch narrowing moves from start to the live view and Freeze;
    + `@suppress_result`.
  - `sp_org_assurance_execution_start` (099 body): refuses a live scope (54030).
  - `sp_org_assurance_execution_get` (120 body) + `ScopeFrozenAt`, `ScopeFrozenBy`,
    `ScopeExclusionCount`.
  - NEW `sp_org_assurance_my_audits_prepare(@employee_id)` -- starts the auditor's due
    engagements (From <= today, plan Approved / Active, audits not started); one failing is
    reported, the others still start.
  - NEW `sp_org_assurance_my_audit_list(@employee_id)` -- one row per audit of the
    auditor's engagements; `AuditState` Upcoming / Ready / ScopeLive / InProgress / Done /
    Cancelled.
  - NEW `sp_org_assurance_execution_live_scope` (rolled-back resolve + narrow; a frozen
    execution returns its entities), `sp_org_assurance_execution_freeze_scope`,
    `sp_org_assurance_execution_scope_exclusion_list`.
  - Errors: 54030 live scope -- freeze first; 54031 already frozen; 54032 not the assigned
    auditor; 54033 not Planned; 54034 exclusion invalid / without reason; 54035 nothing left
    in scope; 54036 employee required.
- **API** (`OrgAssuranceExecutionController`; the caller is `X-PM-Caller-Employee-Id`,
  stamped by the Web tier from the session):
  - `POST /api/practice/org-assurance/my-audits/prepare` -> `{ data: [{ planItemId,
    engagementCode, started, message }] }`
  - `GET  /api/practice/org-assurance/my-audits` -> `{ data: [{ organizationId, planCode,
    engagementCode, engagementName, branchName, scheduledFrom, scheduledTo, definitionCode,
    definitionName, executionId, executionCode, executionStatusCode, scopeFrozenAt,
    totalEntityCount, auditState, ... }] }`
  - `GET  /executions/{id}/live-scope?organizationId=` -> `{ data: [{ dimensionCode,
    dimensionName, entityId, entityCode, entityName }] }`
  - `GET  /executions/{id}/scope-exclusions?organizationId=`
  - `POST /executions/{id}/freeze-scope` `{ organizationId, exclusions: [{ dimensionCode,
    entityId, reason }], actor }` -> `{ executionId, executionCode, totalEntityCount,
    excludedCount }`
  - `GET /executions/{id}` adds `scopeFrozenAt` (null = live), `scopeFrozenBy`,
    `scopeExclusionCount`. Reason codes 54030-54036 mapped.
- **UI:**
  - NEW `Partials/org-my-audits.cshtml` (screen `org-my-audits`): opening it (and Refresh)
    starts the due engagements, then lists the caller's audits -- Engagement (plan),
    Audit, Branch, Scheduled, Status, Scope -- with a State filter (select) and search.
    Row menu: **Review & Freeze Scope** (live), **View Scope** (frozen; exclusions shown
    with their reasons), **Start now** (not started).
  - **No popup** (sir, the 543 rule): Review & Freeze Scope, View Scope, Continuous
    Assurance and Answer Questions open in a **child row under the audit's row -- the Audit
    Plans child row** (sir, 2026-11-14: "like the child row, like the other forms"): list wrap
    `.oa-pl-wrap`, `tr.oa-pl-items-row > td > .oa-pl-items` (44px indent, the accent down the
    left edge shared with the open row `.oa-pl-open`, inner grids not height-capped). Inside it
    the frame keeps the caption and the save bar (`.oa-cfg-frame`, `.oa-cfg-savebar`; the
    section carries `.oa-cfg` for those). The scope frame: caption, the live scope with a Keep
    tick per item (unticking shows the reason box), "n of m kept" on the save bar, Close /
    Freeze Scope. Freeze asks one gracUi confirm (final, starts the audit). One open at a time;
    it stays open when the list re-renders.
  - Executions details: a **Scope** tile (Live / Frozen date, n excluded).
  - Audit Plans: Start Execution wording -- the scope stays live until the auditor freezes it.

### Continuous Assurance view (556, 2026-11-14, sir; redesign Phase 4)
Decision 4: Continuous Assurance covers every scope item -- practice instances directly;
assets, departments, branches (Locations), vendors, applications and processes through the
practice instances they are resolved against in Operationalize; asset categories through their
assets.
- **What the auditor sees** (My Audits -> 3-dot **Continuous Assurance**, in the row under the
  audit -- the same frame as Freeze Scope, no popup): over the execution's scope (frozen, or the
  live scope now), each scope item -> its practice instances (with how: Direct, or the
  dependency type) -> their active **Execution / Assurance** obligations (the scheduled ones,
  338 / 449) -> the obligation's **implementation status** and its **last task** (number,
  status, due date; `schedule_occurrence_task` -> `practice_task`). An item no instance covers,
  and an instance with no scheduled obligation, say so. Summary badges: totals (scope items,
  practice instances, obligations, items with no instance), obligations by status, by last
  task status -- each obligation counted **once**; in the detail it is shown under every item
  that brings it in. Read-only.
- **DB `556_continuous_assurance_view.sql` (+ rollback):** no schema change.
  `sp_org_assurance_execution_live_scope` (555) re-issued with `@mode`: `SCOPE` (default,
  unchanged) / `ASSURANCE` (result 1 summary `SummaryKind` Totals / ObligationStatus /
  LastTaskStatus, `Label`, `ItemCount`; result 2 detail). One procedure resolves the items, so
  Freeze, View Scope and this view never disagree. Rollback: the 555 body.
- **API:** `GET /api/practice/org-assurance/executions/{id}/continuous-assurance?organizationId=`
  -> `{ summary: [{ summaryKind, label, itemCount }], detail: [{ dimensionCode, dimensionName,
  entityId, entityCode, entityName, practiceInstanceId, instanceCode, instanceName, via,
  obligationId, obligationName, obligationType, frequency, obligationStatusCode,
  obligationStatusName, lastTaskId, lastTaskNumber, lastTaskStatusCode, lastTaskStatusName,
  lastTaskDueDate }] }`.
- **UI:** `org-my-audits.cshtml` -- the frame holds two panes (scope / Continuous
  Assurance); the menu item shows for Scope to freeze, In progress and Done. Columns: Scope
  item, Practice instance (code, via), Obligation (type - frequency), Status, Last task.

### Engagement / execution with id 0 (557, 2026-11-14)
My Audits' 3-dot said "No actions available" for an In-progress audit: GET my-audits returned
`planItemId 0` and `executionId 0` -- the first engagement and execution of the database were
stored with id 0 (the cause in 550: a never-used table reseeded to 0 gives its first row 0).
- **DB `557_audit_zero_id_repair.sql`** (no rollback; same rows, new ids): reports every
  identity table with an id-0 row; moves the id-0 row of `org_assurance_plan_item` and of
  `org_assurance_execution` to the next free id in one transaction each -- foreign keys pointing
  at the table paused (NOCHECK), row copied out, deleted, re-inserted with the new id
  (IDENTITY_INSERT), every reference repointed (foreign key columns, plus same-named columns in
  `org_assurance_*` tables: `org_assurance_plan_item_id`, `org_assurance_execution_id`,
  `execution_id`), foreign keys back on (re-validated when they were trusted); identity reseeded;
  empty identity tables still at 0 reseeded to 1 (550 step 3 again); report after.
- **UI:** `org-my-audits.cshtml` tests the execution id against null, not for truthiness, so
  an id 0 never hides the actions.

### Question responses and findings (558, 2026-11-14, sir; redesign Phase 5)
Decision 3: compliance is marked **once per question per execution**.
- **Where:** My Audits -> 3-dot **Answer Questions** (In Progress) / **View Answers** (Done),
  in the row under the audit (same frame, no popup). The execution's questions (its snapshot),
  grouped by question set, each with an Answer select (Compliant / Not compliant / Not
  applicable). **Not compliant** opens a description and an owner (the `owners` feed, 342 --
  employees of the organization). Summary badges: Not answered / Compliant / Not compliant /
  Not applicable. One **Save Answers** writes the changed answers; the save bar counts them.
  The grid has the Question Sets grid's spreadsheet look (sir, 2026-11-14): cells carry the
  lines, inputs have no border -- the `.qs-grid` rules moved from the Question Sets page into
  `practice-management.css`, scoped `#qsSetView` / `#oaMyRoot` so neither page changes otherwise.
  Columns: Question, Answer, Description, Owner. **No Finding column** (sir: the description is
  the finding) -- the finding a Not compliant answer raised shows as "Finding <code> <status>"
  under its description.
- **Findings:** a Not compliant answer raises an **Audit Finding** (`org_assurance_observation`)
  through the existing observation save (116a): type Finding, severity Medium (changed on
  Observations), source = the question, description, owner, reported by the auditor, code
  `<execution code>-<question code>` (`-2`, `-3` ... if used before). Later edits update it while
  it is Open / In Review; past that the answer is saved and the finding left as it is. Changing
  the answer to Compliant / Not applicable **withdraws** (soft-deletes, 108) an Open or Rejected
  finding; once it is past Open the change is refused (54045).
- **Rules:** only while the execution is **In Progress** (scope frozen), only by its **assigned
  auditor**; the question must be in the execution's snapshot; an answer cannot be cleared.
- **DB `558_audit_question_responses.sql` (+ rollback; table kept):** NEW
  `org_assurance_execution_response` (unique execution + question; result, description, owner,
  current finding, who / when); NEW `sp_org_assurance_execution_response_list` (questions from
  the snapshot with answers and findings; counts per result) and
  `sp_org_assurance_execution_response_save` (one question; finding raised / edited / withdrawn
  in the same transaction). Errors 54040 not In Progress, 54041 not the assigned auditor, 54042
  question not in the execution, 54043 result invalid, 54044 description / owner missing or owner
  not of the organization, 54045 finding past Open, 54046 employee required.
- **API:** `GET /api/practice/org-assurance/executions/{id}/responses?organizationId=` ->
  `{ questions: [{ setOrder, questionSetCode, questionSetName, questionId, questionCode,
  questionText, helpText, isMandatory, displayOrder, evidenceTypeName, expectedEvidence,
  resultCode, description, ownerEmployeeId, ownerDisplayName, answeredBy, answeredDt,
  observationId, observationCode, observationStatusCode, observationStatusName }], counts:
  [{ resultCode, questionCount }] }`; `POST .../executions/{id}/responses` `{ organizationId,
  questionId, resultCode, description, ownerEmployeeId, actor }` -> `{ questionId, resultCode,
  observationId, observationCode, observationStatusCode, observationStatusName }` (caller =
  session employee). Reason codes 54040-54046 and the observation codes 54109 / 54112 / 54113.
- **Not in this phase:** submitting the execution for review when every question is answered
  (Submit / Review / Approve exist on Executions; no completeness check yet).

### Observations -- details in a child row; finding with id 0 (2026-11-14, sir)
- **Child row** (sir: "like the child row, like the other forms"): `org-assurance-observations.cshtml`
  was a list beside a details panel. Now one full-width list (`.oa-pl-wrap`); a row click (or
  View Details) opens the observation's details, evidence and history in a **child row under
  it** -- the Audit Plans child row (`tr.oa-pl-items-row > td > .oa-pl-items`, open row
  `.oa-pl-open`); a second click closes it. The panel itself (title, Actions, tiles, Details /
  Evidence / History tabs) is unchanged; it waits in a hidden holder (`#oaObHolder`) and is
  held by reference, so a list refresh re-mounts it under its row. The title cell wraps (no
  horizontal scrollbar). Ids are read with `??`, never `||` (0 is an id).
- **"Failed to load observation: HTTP 404":** the first finding raised from an answer was
  stored with `org_assurance_observation_id = 0` (the 550 cause: a table that never had a row
  gives its first row 0). The page read `row.observationId || row.ObservationId` -> undefined ->
  `/observations/NaN` -> 404. **557** now also moves an id-0 observation (references: every
  foreign key, plus `org_assurance_observation_id` columns in any table, e.g.
  `custom_gap_observation`), and step 3 reseeds to 1 every empty identity table whose identity
  is 0 **or NULL** (a never-used table reseeded to 0 can report NULL). Re-run 557.
- **My Audits:** the frame is likewise held by reference (a filter / search re-render no longer
  loses it; if its audit is filtered out it closes).

### Audit Categories replaced (559, 2026-11-15, sir)
- **List** (Audit Definitions -> Audit Category dropdown; master `grac_new.assurance_category`),
  in this order: Internal Audit, Information Systems Audit, Cybersecurity Audit, Compliance
  Audit, Operational Audit, Process Audit, Regulatory Inspection, Third-Party Audit, Self
  Assessment, Management Review, Special Investigation.
- **Rows:** matched on `category_code`. Kept (same id, renamed / reordered): INT_AUDIT,
  IS_AUDIT, PROC_AUDIT, REG_INSPECTION, SELF_ASSESS, MGMT_REVIEW. New: CYBER_AUDIT, COMP_AUDIT,
  OPS_AUDIT, THIRD_PARTY_AUDIT, SPECIAL_INVESTIGATION. Every other category is deleted, or made
  inactive (`is_active = 0`, status Inactive) when a foreign key (e.g.
  `grac_new.assurance_starter_template`) or an audit definition version uses it.
- **`sp_org_assurance_admin_category_list`** (072 body): lists a row only when active on both
  `status` and `is_active`; sorted by `display_order`, then name. API unchanged
  (`GET .../org-assurance/categories` -> `[{ id, code, name, description }]`); no UI change.
- **Saved definitions** keep the category name they were saved with. Editing one whose category
  was retired shows the dropdown empty -- pick a new category before saving.
- Rollback: `559_audit_categories_rollback.sql` (the 15 earlier categories and the 072 body).

### Audit Definition -- Assurance Approach, Audit Mandate, Applicable Frameworks (560, 2026-11-15, sir)
Audit Change spec, P0 phase A (plan: `docs/audit-change-p0-plan.md`).
- **Fields** (Audit Definition form, Audit Details):
  - **Assurance Approach** sits in the third column under Effective Date. It is how the audit is conducted, kept separate from Audit Category (what kind of audit). Values come from the master `org_assurance_approach_master`: Risk-Based, Periodic, Continuous, Event-Driven, Thematic, Ad-hoc.
  - **Audit Mandate**: why the audit is required, a **multi-select** (sir, 2026-11-15) of `org_assurance_mandate_master`, 14 values: REG Regulatory Requirement, STAT Statutory Requirement, BOARD Board-Directed, AC Audit Committee-Directed, RC Risk Committee-Directed, CHARTER Internal Audit Charter, POLICY Internal Policy / Governance Requirement, MGMT Management-Directed, CONTRACT Contractual / Agreement Requirement, FRAMEWORK Framework / Certification Requirement, INCIDENT Incident / Event-Driven Mandate, INVEST Special Investigation / Vigilance, EXTERNAL External Authority / Supervisory Direction, OTHER Other. It sits in a third row on the same 1fr / 2fr / 1fr tracks as the rows above: Mandate under Category, and Applicable Frameworks across Owner and Approach. Other Frameworks / Standards has its own full-width row under it, like Objective.
  - **Applicable Frameworks**: the organization's subscribed frameworks in a `.pm-checkcombo` (the Practice picker list, `/practice/api/practice-picker/frameworks`; "Organization Defined Practices" is left out), plus **Other Frameworks / Standards**, one per line, for organizations without subscriptions.
  - A saved framework that is no longer subscribed is shown under Other, so it is not lost.
  - The view page (`audit-view.js`) shows Approach, Frameworks and Mandate.
- **Data model:**
  - `org_assurance_definition_version` gets `assurance_approach_id` / `_code` / `_name` (FK to the master; code and name are copied at save, as for the category). New table `org_assurance_definition_mandate`: one row per version per mandate (mandate id, and code and name as saved). The free-text `audit_mandate` column of the first 560 cut is dropped while it is empty.
  - New table `org_assurance_definition_framework`: one row per version per framework, with `release_id` (null when typed) and `framework_name`.
  - All of this is versioned with the definition. `copy_config` copies the frameworks and the mandates, and the version row (approach) is copied whole, so a version made by a Question Set approval keeps them.
- **Procedures:**
  - New `sp_org_assurance_approach_list` and `sp_org_assurance_mandate_list`.
  - `sp_org_assurance_definition_save` (551 body) takes `@assurance_approach_id`, `@audit_mandate_ids_json` (`[id, ...]`) and `@applicable_frameworks_json`. For each list, null leaves it unchanged and `[]` clears it.
  - `sp_org_assurance_definition_get` (119 body) returns the approach, a **second result set** with the frameworks and a **third** with the mandates.
  - `copy_config` (551 body) also copies the frameworks.
  - Errors: 53613 (approach missing or inactive), 53614 (framework list is not valid JSON), 53615 (a mandate missing or inactive, or the mandate list not valid JSON).
- **API:**
  - New `GET /api/practice/org-assurance/approaches` and `GET .../mandates` return `[{ id, code, name, description }]`.
  - `GET .../definitions/{id}` adds `assuranceApproachId`, `assuranceApproachCode`, `assuranceApproachName`, `auditMandates: [{ definitionMandateId, auditMandateId, mandateCode, mandateName, displayOrder }]` and `applicableFrameworks: [{ definitionFrameworkId, releaseId, frameworkName, displayOrder }]`.
  - `POST .../definitions` adds `assuranceApproachId`, `auditMandateIds: [id, ...]` and `applicableFrameworks: [{ releaseId | null, name }]` (null leaves the list unchanged).
  - Reason codes `APPROACH_NOT_FOUND`, `FRAMEWORKS_INVALID` and `MANDATE_INVALID`.
  - The Api reads the new columns tolerantly, so it also runs before 560 is applied.
- **Style fix (same day):** the form's own `.oa-ws #oaDefForm input` rule (full width, 36 px, border) and its bold label rule also hit the multi-select's checkboxes, search box and option labels, which stretched each checkbox across the row. Both rules now skip them with `:not([type="checkbox"]):not([data-checkcombo-search])` / `:not([data-checkcombo-option])`, so the multi-select keeps the shared `.pm-checkcombo` look. Its trigger gets the form's top gap and control height (`practice-management.css`).
- **Shared:** new `js/Shared/checkcombo.js` (`window.gracCheckCombo.html / wire / values`). It holds the `.pm-checkcombo` markup and behaviour that practice.js, tprm-common.js and event-profiles.js each emit themselves.
- Rollback: `560_audit_definition_fields_rollback.sql` puts the procedures back to 551 / 119 and drops the approach and mandate lists. Tables and columns are kept.

### Question Sets -- Testing Guidance and question Status (561, 2026-11-15, sir)
Audit Change spec 4.2.3, P0 phase B (`docs/audit-change-p0-plan.md`).
- **Testing Guidance:** the row's "Description / Guidance" is renamed **Testing Guidance**. It is the field for test procedures, from a short instruction to detailed step-by-step steps; there is no separate Test Procedure master.
  - The box is larger: 4 rows and up to 20,000 characters. The column `help_text` is NVARCHAR(MAX).
  - The read-only view shows it as "Testing guidance:".
  - The Api field is still `helpText`.
- **Status:** the edit grid has a **Status** column again (Active / Inactive) after Weight.
  - A new row starts Active and can be set either way.
  - The read-only questions table shows Status too.
  - An Inactive question stays in the set but is not taken into an execution. That was already the case: the 555 snapshot reads only `status = 'Active'`.
- **Question set list:** Questions, Mandatory and Total Weight now count **Active questions only**. `sp_org_assurance_question_set_list` is re-issued from the 551 body; before, it also counted Inactive questions.
- **Unchanged:** the Api, the tables and `sp_org_assurance_question_set_questions_save` already handle `status` and long `helpText`.
- Rollback: `561_question_set_testing_guidance_rollback.sql` (551 list body).

### Scope Builder -- Step 1 Audit Subjects, Step 2 Discover (562, 2026-11-15, sir)
Audit Change spec 4.2.1, P0 phase C1 (`docs/audit-change-p0-plan.md`).
- **Decisions:**
  - The audit subjects are the **Operationalize dependency categories** -- Asset, Vendor, Department / Person, Team, Committee, Location, Business Function -- and nothing else; Control Statements is not a subject (sir, same day).
  - Step 1 looks and works like Operationalize -> Dependencies, with the same logic (sir, same day). Inactive or other dependency types (Tool, Application, Process, ...) are not shown.
  - Step 1 and Step 2 are done in Audit Configuration.
  - Step 3 (review, untick records, manual items, approve the snapshot) happens on the engagement's live scope in My Audits. That is phase C2, which also brings manual subjects.
- **Step 1 -- Select Audit Subjects** (the Scope Builder screen, same look):
  - One **Category | Objects** table, as in Operationalize (no Applicability column: an audit picks subjects). Drawn by the new shared `js/Shared/dependency-picker.js` (`window.gracDependencyPicker`):
    - Asset: the Category -> Sub Category -> Type filters, then the asset picker (shows the picked assets until a filter is picked).
    - Department / Person: the departments narrow the persons. With no person ticked the departments are saved (`DEP_DEPARTMENT`), otherwise the persons (`DEP_PERSON`).
    - Vendor, Team, Committee, Location, Business Function: one multi-select each.
    - Objects come from the same gateway dependency-options query Operationalize uses (active objects of the organization). A category with none shows "No active ... records for this organization yet."
  - Each of those categories, when its dependency type is active and has an allowed source table, is a scope dimension `DEP_<CODE>`, named after the type, category `Subject`. Any other `DEP_` dimension is set inactive. Re-run 562 after activating a type.
  - `sp_org_assurance_scope_dimension_list` (074 body) is re-issued to return `dependency_type_id`; the Api's `OrgAssuranceScopeDimensionRow` carries `DependencyTypeId`.
  - resolve-workspace and the Risk Centre still keep their own inline copies of this table's logic; they can move onto the shared module.
  - Values are that type's objects from the table named in `dependency_type_source_config` (the same allow-list as 497 and the Api's dependency-options query).
  - At execution, a subject resolves to the **active practice instances that depend on it** (`practice_dependency_resolution`), stored as PRACTICE_INSTANCE rows, as 534 does for control statements. Branch narrowing (554), Freeze Scope (555) and Continuous Assurance (556) therefore work unchanged.
  - Subjects add up: the audit covers the instances of every subject picked.
  - A scope saved on Control Statements, or on the older Departments / Vendors / Assets filters, opens read-only and applies as saved. **Replace with a simple scope** switches it to subjects.
- **Step 2 -- Discover Related GRAC Intelligence** (replaces the 545 Preview under the Scope Builder; the Scope Resolution screen keeps its own route):
  - It lists what the saved subjects lead to today: Practice Instances, Practices, Control Statements, Risks, Gaps, Exceptions, Assets and Vendors.
  - Each record shows **why** it is related:
    - "Depends on Location "Kochi"", "Under control statement ...", "Practice of instance(s) ...".
    - "Impacts ..." (Risk Impact Details), or "Linked to practice ..." (treatment mapping, or the risk's own practice).
    - "Raised against practice ..." (Gap Center gaps, exceptions).
    - "Instance X depends on it" (assets, vendors).
  - Category list in the Audit Plans child-row pattern: tick **Include** per category (Draft only, saved at once), and click a category to open its records under it.
  - Discovery is optional and needs only Operationalize data.
- **Data:**
  - New `fn_org_assurance_dep_type(@dimension_code)`: the dependency type behind a `DEP_` code, or behind an older ASSET / DEPARTMENT / VENDOR / APPLICATION / PROCESS / BRANCH dimension.
  - New `org_assurance_scope_category` (per definition version, default all included), copied with the version by `copy_config` (560 body).
  - Re-issued: `sp_org_assurance_scope_dimension_list` (074 body), `sp_org_assurance_scope_dimension_values` (554 body) and `sp_org_assurance_scope_resolve` (534 body).
  - New: `sp_org_assurance_scope_discover` (two result sets) and `sp_org_assurance_scope_category_save`.
  - Errors 53705 / 53706.
- **API:**
  - `GET .../definitions/{id}/scope-discovery?organizationId=&versionId=` returns `{ categories: [{ categoryCode, categoryName, displayOrder, itemCount, isIncluded }], rows: [{ categoryCode, recordId, recordCode, recordName, status, reason }] }`.
  - `POST .../definitions/{id}/scope-categories` takes `{ organizationId, categories: [{ code, isIncluded }] }`.
  - Reason codes `INVALID_CATEGORIES` and `UNKNOWN_CATEGORY`.
- **Web:**
  - `org-assurance-scope-builder.cshtml`: Step 1 is the dependency table (the old per-dimension cards, their template and the statement tree picker include are removed), Step 1 text, and the `audit-scope-loaded` event.
  - New `wwwroot/js/Shared/dependency-picker.js`.
  - `_audit-scope-step.cshtml`: the Step 2 panel.
  - The flow shell no longer binds the Scope Resolution screen to this step.
  - The step's line in Audit Configuration is updated.
- Rollback: `562_scope_subjects_discovery_rollback.sql`.

### Scope Builder -- Step 3 Review and Confirm (563, 2026-11-15, sir)
Audit Change spec 4.2.1, P0 phase C2. Step 3 happens on the engagement's live scope in **My Audits -> Review & Freeze Scope** (decided with C1).
- **What the auditor sees** (same child-row frame, under the scope list):
  - The scope list gains a **Why in scope** column (the subject link that brings each practice instance in).
  - **Related GRAC Intelligence**: Step 2's category list (Practices, Control Statements, Risks, Gaps, Exceptions, Assets, Vendors, Manual Items), discovered over **this engagement's** practice instances, i.e. the scope narrowed to its Branch. Practice Instances are the scope list itself and are not repeated.
  - **Include** tick per category; it starts from the definition's Step 2 ticks.
  - Click a category to open its records in a child row: untick a record (it needs a reason), or add a **manual item** (name and note). Manual items can be added to any category, or to Manual Items.
  - **Search** filters the records; a category shows "m of n".
  - Freeze sends the review with the scope exclusions. The result is kept as the **approved scope snapshot, version 1**, never changed afterwards (spec 6; a change will be a new version, phase F).
  - **View Scope** shows the snapshot read-only: version, approver and date, categories, kept and excluded records with reasons, and manual items. A scope frozen before 563 says no review was recorded.
  - If the review cannot be loaded, the scope list still freezes as before.
- **Data:**
  - New `org_assurance_execution_scope_review` (execution, definition version, version_no, status Approved, approver, date), `..._review_category` (code, name, order, count, included) and `..._review_item` (record, why related, kept / excluded with reason, manual item and note).
  - `sp_org_assurance_execution_live_scope` (556 body): a caller that created `#scope_review_pi` gets the scope items there, so the review reads exactly the items Freeze takes.
  - `sp_org_assurance_scope_discover` (562 body) + `@execution_id`: the engagement's version and its scope's instances (an instance without a subject link reads "In the engagement scope"). A caller that created `#scope_review_cat` / `#scope_review_out` gets the results there. Step 2 is unchanged.
  - `sp_org_assurance_execution_freeze_scope` (555 body) + `@review_json` `{ categories: [{ code, isIncluded }], excluded: [{ categoryCode, recordId, reason }], manual: [{ categoryCode, name, note }] }`: after the entities are copied, discovers over the frozen scope, validates the review, writes the snapshot, and also returns `ReviewId` / `ReviewVersionNo`.
  - New `sp_org_assurance_execution_scope_review_get`: header, categories, items -- the snapshot when there is one, otherwise (live) the discovery to review.
  - Errors 54037 (review not valid, record no longer related, reason missing, practice instance unticked here), 54038 (manual item without a name), 54039 (unknown category).
- **API** (`OrgAssuranceExecutionController`):
  - `GET executions/{id}/scope-review?organizationId=` -> `{ header: { reviewId, versionNo, reviewStatus, approvedBy, approvedDt, isFrozen }, categories: [{ categoryCode, categoryName, displayOrder, itemCount, isIncluded }], items: [{ categoryCode, recordId, recordCode, recordName, status, reason, isKept, exclusionReason, isManual, manualNote }] }`.
  - `POST executions/{id}/freeze-scope` body gains `review` (optional; sent as `@review_json` only when present); the response gains `reviewId`, `reviewVersionNo`.
  - Reason codes `REVIEW_INVALID`, `REVIEW_MANUAL_NAME_REQUIRED`, `REVIEW_UNKNOWN_CATEGORY`.
- **Web:** `org-my-audits.cshtml` (Why in scope column, Related GRAC Intelligence section, review sent on Freeze, snapshot on View Scope); `_audit-scope-step.cshtml` header comment.
- Generated by `Claude outputs/s563/gen563.py` (+ `web563.py`). Rollback: `563_scope_review_confirm_rollback.sql` (procedures back to 556 / 562 / 555; the snapshot tables are kept).

### Audit Configuration -- Control and Practice Mapping (564, 2026-11-15, sir)
Audit Change spec 4.2.2, P0 phase D.
- **What it is:** a step of Audit Configuration between Scope Builder and Question Sets (the spec's order) that associates the audit (its current version) with the GRAC records it is about. It is contextual intelligence only: nothing is written to a practice or statement, and ownership does not move.
  - **Controls** are source statements (there is no Control record in Practice Management). They are picked in the Scope Builder's two-list statement tree (`js/Shared/statement-tree-picker.js`, which gains an optional `selectedInfo` line).
  - **Practices** and **Practice Instances**: the organization's active ones, in multi-select combos (`js/Shared/checkcombo.js`). Picking practices narrows the instance list to theirs, which is how individual instances are included selectively; with none picked every instance is listed.
  - **Manual mappings** where the record is not in GRAC: Type (Control / Practice / Practice Instance / Other), Reference, Name (required), Note, in the Question Sets grid's look (`.qs-grid`).
  - Many-to-many: an audit maps many records, and a record can be mapped by many audits.
  - A mapped record that is no longer active stays mapped, is listed as such, and can be removed.
- **Optional:** the step shows **Optional** until something is mapped, then Completed. It never blocks Submit for Review and is not counted in the list's configured steps. Draft only, like every step; a new version copies it.
- **Data:**
  - New `org_assurance_definition_mapping` (per definition version: mapping_type, record id / code / name as mapped, manual_kind, manual_reference, note, display_order).
  - `fn_org_assurance_setup_steps` (548 body) gains the `mapping` step (StepOrder 3, IsConfiguration 0, Completed / Optional); Question Sets, Workflow and Scoring move to 4, 5 and 6.
  - `sp_org_assurance_definition_submit` (537 body): the review gate reads `IsConfiguration = 1` (it read "every step but details"), so the optional step never blocks. The required steps are unchanged.
  - `sp_org_assurance_definition_version_copy_config` (562 body) copies the mapping.
  - New `sp_org_assurance_mapping_options` (active practices with instance counts; active instances with their practice), `sp_org_assurance_definition_mapping_get` (header + rows with IsAvailable), `sp_org_assurance_definition_mapping_save` (replaces the Draft version's mapping; names are read from GRAC; a record already mapped and no longer active may stay).
  - Errors 53707 (list not valid / unknown type or kind), 53708 (record not found in this organization), 53709 (manual mapping without a name).
- **API** (`OrgAssuranceDefinitionController`):
  - `GET mapping-options?organizationId=` -> `{ practices: [{ id, code, name, instanceCount }], instances: [{ id, code, name, practiceId, practiceCode }] }`.
  - `GET definitions/{id}/mapping?organizationId=&versionId=` -> `{ header: { definitionId, versionId, statusCode, isEditable }, items: [{ mappingId, mappingType, recordId, recordCode, recordName, manualKind, manualReference, note, displayOrder, practiceId, isAvailable }] }`.
  - `POST definitions/{id}/mapping` `{ organizationId, items: [{ mappingType, recordId, manualKind, reference, name, note }], actor }` -> `{ definitionId, mappingCount }`.
  - Reason codes `INVALID_MAPPING`, `MAPPED_RECORD_NOT_FOUND`, `MANUAL_MAPPING_NAME_REQUIRED`.
- **Web:**
  - New `Partials/_audit-mapping-step.cshtml` (`window.__oaMapping` save / reload).
  - `org-audit-configuration.cshtml`: the step.
  - `_audit-configuration-workspace.cshtml`: the step's Save, and Optional is not "not complete".
  - `_audit-flow-shell.cshtml`: the Optional chip.
  - `audit-view.js`: a "Control and Practice Mapping" section on the audit view, and "Configured n/m" leaves out an Optional step.
  - `practice-management.css`: the frame's panel rule and the `.qs-grid` selectors include the mapping step.
- Generated by `Claude outputs/s564/gen564.py`. Rollback: `564_audit_control_practice_mapping_rollback.sql` (setup steps 548, submit 537, copy_config 562; the mapping table is kept).

### Annual Audit Plan, Audit Programmes, Planning Methodology (565, 2026-11-16, sir)
Audit Change spec 4.3, P0 phase E. Hierarchy: **Annual Audit Plan -> Audit Programmes -> Audit Engagements**.
- **Decisions (sir, 2026-11-16):**
  - The programme layer is **mandatory**: every engagement belongs to a programme of its plan. Existing engagements moved into a "General Programme" per plan.
  - **Planning Methodology per programme** (a configurable master: Risk-Based, Regulatory / Mandatory, Periodic, Event-Driven, Thematic, Management-Directed, Ad-hoc). The plan shows every methodology its programmes use, so one plan can mix them.
  - **Plan revision:** an Approved / Active plan is revised with a reason. Its version goes up by one, the old values are kept in the revision history, and the plan goes back to Draft to be re-submitted and re-approved. Running audits continue; new starts wait for the re-approval.
  - Programmes are added and edited **inline** in the plan's child row (no popups).
- **What the user sees (Audit Plans):**
  - The plan dialog gains Financial Year, Planned Budget + Currency, Planned Effort (days), Objectives, Planned Coverage and Resources.
  - The plan list gains Programmes, and Engagements shows planned vs actual ("5 planned, 1 in progress, 2 completed").
  - A plan's child row shows a facts line (version, financial year, methodologies, planned vs actual) and its programmes (code, programme, planning methodology, owner, planned vs actual, 3-dot Edit / Add Engagement / Remove). A programme row opens its engagements under it (the 552 engagement grid, unchanged).
  - "+ Add Programme" (and the plan's 3-dot) opens the inline form: name, methodology (required), order, owner (role + holder), objective.
  - The engagement dialog gains **Programme** (required; preselected from the programme it is added from, or the plan's only one).
  - Plan 3-dot **Revise** (Approved / Active) asks for the reason. "Show revision history" in the child row lists the revisions (version, was, reason, by, on).
- **Data:**
  - Plan columns `financial_year`, `objectives`, `planned_coverage`, `planned_budget`, `budget_currency`, `planned_effort_days`, `resources_note`.
  - New `org_assurance_planning_methodology_master` (seeded once per code; administrators may change it), `org_assurance_plan_programme` (code PLAN-P01..., name, objective, methodology, owner, order, is_default), `org_assurance_plan_revision` (from / to version, previous status, reason, the plan and its programmes as JSON, who, when).
  - `org_assurance_plan_item.org_assurance_programme_id`, backfilled.
  - New `fn_org_assurance_engagement_progress(@plan_id)`: per engagement, its audits, started and done, Planned / InProgress / Completed (the item list's slot rule).
  - New procedures `sp_org_assurance_planning_methodology_list`, `sp_org_assurance_plan_programme_list / _save / _delete`, `sp_org_assurance_plan_revise`, `sp_org_assurance_plan_revision_list`.
  - Re-issued `sp_org_assurance_plan_save / _get / _list` (121 bodies) and `sp_org_assurance_plan_item_save / _list` (552 bodies). If no programme is given, `item_save` uses the engagement's own, or the plan's only programme.
  - Errors 53943 (engagement without a programme), 53944 (programme not of this plan), 53945 (negative budget / effort), 53946 (programme still has engagements), 53947 (programme name), 53948 (methodology), 53949 (revision reason / plan not Approved or Active).
- **API** (`OrgAssurancePlanController`):
  - `GET planning-methodologies`.
  - `GET plans/{id}/programmes`, `POST plan-programmes`, `DELETE plans/{planId}/programmes/{programmeId}`.
  - `POST plans/{id}/revise { organizationId, reason }`, `GET plans/{id}/revisions`.
  - `POST plans` gains the annual fields.
  - `GET plans` / `plans/{id}` gain the programme count, methodologies and planned vs actual; the detail also has the annual fields.
  - `POST plan-items` gains `programmeId`; item rows gain `programmeId / Code / Name`.
  - Reason codes PROGRAMME_REQUIRED, PROGRAMME_NOT_IN_PLAN, NEGATIVE_BUDGET, PROGRAMME_HAS_ENGAGEMENTS, PROGRAMME_NAME_REQUIRED, METHODOLOGY_REQUIRED, REVISION_NOT_ALLOWED.
- **Web:** `org-assurance-plans.cshtml` (generated edit `Claude outputs/s565/web565.py`); `practice-management.css` (`.oa-pl-plan-facts`, the programme child rows).
- **Plan form full view (2026-11-16, sir):** the Add / Edit Plan form uses the shared `pm-dialog-fullpage`. It fills the content area beside the sidebar and below the topbar, and the master page stays usable (`show()`, not `showModal()`; Escape closes it). The fields scroll inside `.oa-pl-plan-fields`, as Organization Requirements and Role Master do.
  - Layout (same day, sir: "align it so the scrollbar goes"): one 4-column grid (`.oa-pl-plan-grid`): Code, Type, Period From, Period To; Name (two columns), Owner Role, Owner; Financial Year, Planned Budget, Currency, Planned Effort; then Objectives, Planned Coverage, Resources and Description, each on its own full-width row (3 lines; sir, same day). Below 992px it drops to two columns. The fields scroll only when the window is too short.
- **Not in this phase:** an administration screen for the methodology master (it is a seeded table today); budget actuals (planned vs actual covers engagements); approval workflow beyond the plan's existing Submit / Approve.
- Generated by `Claude outputs/s565/gen565.py`. Rollback: `565_audit_plan_programmes_rollback.sql` (procedures back to 121 / 552; the new tables and columns are kept).

### Audit Engagements as a record -- planned and independent, with the audit team (566, 2026-11-16, sir)
Audit Change spec 4.5, P0 phase F. An engagement is now a record of its own, with its own menu (**Audit Engagements**, under Audit Assurance after Audit Plans).
- **Decisions (sir, 2026-11-16):**
  - **Two kinds, one lifecycle.** PLANNED: in a programme of an approved plan (plan and programme mandatory; approved with the plan). INDEPENDENT: outside the annual plan; plan and programme optional (a reference only), approved by its authority. Both run the same execution lifecycle.
  - Mandatory for both: Audit Definition(s), Audit Subject, Scope, Audit Team (the lead).
  - An independent engagement needs its **Initiation Source** (Board / Audit Committee, Regulator / RBI, Chief Audit Executive, Management Request, Fraud / Vigilance, Incident / Event, Follow-up Audit, Other), the **reason for initiation** and, to be approved, an **approval reference**.
  - **Audit Team:** Lead Auditor (mandatory, one), Team Members (several), Subject Matter Experts (optional), Engagement Reviewer (optional, one), External Auditors (optional), Team Remarks. Eligible auditors are the people whose role carries the Auditor responsibility (553); no separate auditor master. The same person may be on several engagements. Engagement responsibility is not the person's designation.
  - The team is stored against the engagement. Changes are trailed: a removed member stays as a row with who removed them and when; each row keeps the name, designation and role as they were when added.
- **Assumed (not answered; to confirm):**
  - Status is derived: **Draft** (independent, not approved) / **Planned** / **In Progress** / **Completed** (from its executions), plus **Cancelled** with a reason (only while no execution is live).
  - The engagement form is a full view like the plan form.
  - Subject matter experts may be any active employee (not only auditors).
  - An independent engagement's executions are created with origin MANUAL and no plan (planned ones stay PLAN).
- **What the user sees:**
  - **Audit Engagements** list: organization / status / type / plan filters (selects), search, Code, Engagement, Type (with the initiation source), Plan / Programme, Audit Subject, Lead Auditor, Planned, Audits (done / total), Status. The chevron or a row click opens the details in a child row: the record, its audits and its team with the trail.
  - 3-dot: View, Edit (independent Draft; planned while the plan is Draft / Submitted and nothing started), Audit Team (until completed), Approve (independent Draft; asks for the approval reference), Start Execution, View Scope, Cancel Engagement (reason; nothing started), Delete (independent Draft).
  - "+ Add Independent Engagement".
  - The engagement form (Audit Plans and Audit Engagements, the same form) opens in full view: type, plan, programme, order; name, audit subject; for an independent one initiation source, approval reference and reason; the audits (dual list) and View Scope; planned start / end, branch; auditee (role -> person) and department; lead auditor, team members, reviewer, subject matter experts, external auditors (one per line, "Name - Organisation"), team remarks; objective, scope, instructions, notes. "Audit Team" opens the same form with only the team editable.
  - Audit Plans keeps its flow; its engagement dialog is now this shared form (the old "Assigned Team" text box is replaced by the team; existing text is kept on the record).
- **Data:**
  - `org_assurance_plan_item.org_assurance_plan_id` becomes NULLable (its index rebuilt). New columns: `engagement_origin` (PLANNED default), `audit_subject`, `engagement_objective`, `scope_summary`, `auditee_role_id / _role_name / _employee_id / _name`, `engagement_instructions`, `team_remarks`, `initiation_source_code`, `initiation_reason`, `approval_status`, `approval_reference`, `approved_by / _dt`, `cancelled_dt / _by`, `cancel_reason`.
  - New `org_assurance_engagement_initiation_master` (the eight sources) and `org_assurance_engagement_team` (LEAD / MEMBER / SME / REVIEWER / EXTERNAL, snapshots, removed_by / removed_dt). Existing engagements get a LEAD row from their assigned auditor.
  - New `fn_org_responsibility_holder` (553's rule in one place; `sp_org_responsibility_holder_list` re-issued over it), `fn_org_assurance_engagement_status` (progress and actual dates), `fn_org_assurance_engagement_rows` (the list and detail row); `fn_org_assurance_engagement_progress` re-issued over the status function (+ Cancelled).
  - New procedures `sp_org_assurance_engagement_initiation_list`, `_list`, `_get`, `_team_list`, `_team_apply` (internal), `_team_save`, `_approve`, `_cancel`, `_delete`.
  - Re-issued `sp_org_assurance_plan_item_save / _list` (565 bodies: independent engagements, the record fields, the team, code ENG-yyyy-nnnn when there is no plan), `sp_org_assurance_plan_item_start_execution`, `sp_org_assurance_my_audits_prepare`, `sp_org_assurance_my_audit_list` (555 bodies: an approved independent engagement starts and shows in My Audits).
  - Errors 53950 (subject), 53951 (scope), 53952 (lead), 53953 (initiation source / reason), 53954 (not an auditor), 53955 (lead changed after start), 53956 (approval state), 53957 (cancelled / completed), 53958 (cancel reason / live executions), 53959 (team list).
  - Menu `org-audit-engagements` (467, briefcase) under nav-assurance, given to every role that has Audit Plans with the same rights; written back into 274.
- **API** (`OrgAssurancePlanController`):
  - `GET engagement-initiation-sources`.
  - `GET engagements?organizationId=&status=&origin=&planId=&search=&page=&pageSize=`, `GET engagements/{id}` (`{ engagement, audits, team }`), `GET engagements/{id}/team?includeHistory=`.
  - `POST engagements/{id}/team { organizationId, team: [{ teamRole, employeeId?, name?, organisation? }], teamRemarks }`, `POST engagements/{id}/approve { approvalReference }`, `POST engagements/{id}/cancel { reason }`, `DELETE engagements/{id}`, `POST engagements/{id}/start-execution { organizationId, planId? }`.
  - `POST plan-items`: `planId` optional for `engagementOrigin: INDEPENDENT`; gains `auditSubject`, `engagementObjective`, `scopeSummary`, `auditee...`, `engagementInstructions`, `teamRemarks`, `team[]`, `initiationSourceCode`, `initiationReason`, `approvalReference`. Item rows gain `engagementOrigin`, `auditSubject`, `approvalStatus`, `cancelledDt`.
  - My Audits rows: `planId` may be null.
  - Reason codes AUDIT_SUBJECT_REQUIRED, SCOPE_REQUIRED, LEAD_AUDITOR_REQUIRED, INITIATION_REQUIRED, NOT_AN_AUDITOR, LEAD_LOCKED, APPROVAL_STATE, ENGAGEMENT_CLOSED, CANCEL_NOT_ALLOWED, TEAM_INVALID.
- **Web:**
  - New shared form `Partials/_audit-engagement-form.cshtml` + `js/Shared/audit-engagement-form.js` (`window.gracEngagementForm`: `open`, `openScope`, `startExecution`). The 552-565 engagement dialog code (dual list, programme, auditor and branch lists, View Scope, Start Execution) moved here from `org-assurance-plans.cshtml` (generated edit `Claude outputs/s566/web566.py`).
  - New `Partials/org-audit-engagements.cshtml`; `PracticeScreen.cs` and `Manage.cshtml` register it. Reuses the Audit Plans list / child-row styles, `pm-view-field`, `gracCheckCombo`, `gracPageActions` and `__roleHolderPicker`; no new CSS.
  - Gated by the Audit Plans feature (`screen.org-assurance-plans`).
- **Scope approval** (the spec's "versioned, immutable snapshot that replaces the freeze") was built in 563 and is unchanged.
- **Not in this phase:** an approval workflow for independent engagements beyond one Approve with a reference; changing the lead after an execution started (53955); team-based visibility in My Audits (it still lists the lead's audits).
- Generated by `Claude outputs/s566/gen566.py`. Rollback: `566_audit_engagements_record_rollback.sql` (procedures back to 553 / 555 / 565; the new procedures and functions dropped; the menu set Inactive; tables and columns kept, and the plan column stays NULLable).

### Test Working Papers, question conclusions, execution score, findings with the spec 4.7 fields (567, 2026-11-16, sir)
Audit Change spec 4.6 / 4.7, P0 phase G. Working papers replace the 558 answer grid; a question's conclusion comes from its working papers; the auditor raises findings from a working paper, and nothing raises one automatically (gaps and exceptions in scope never become findings on their own).
- **Decisions (sir, 2026-11-16):**
  - A **Workpapers** page (menu): pick an execution, its questions, each question's working papers in a child row with an inline form. My Audits' "Answer Questions" / "View Answers" became **Working Papers**, which opens this page on the execution.
  - **Test result:** Satisfactory / Partially Satisfactory / Unsatisfactory / Not Applicable. The question's conclusion defaults to the worst **approved** paper; the auditor may conclude otherwise with a reason.
  - **Review:** the engagement's Reviewer (566), or the Lead Auditor when there is none. Nobody reviews their own paper. The lead or the reviewer reopens an approved paper, with a reason.
  - **Score:** question weight x conclusion (Satisfactory 100, Partial 50, Unsatisfactory 0; Not Applicable left out), mapped to the audit version's scoring bands. The lead writes the overall audit conclusion.
- **Working paper lifecycle:** Draft (being prepared) -> Pending (submitted; needs the procedure performed, the result and the conclusion) -> Reviewed (optional) -> Approved, or Returned (reason) back to the preparer. Reopen: Approved -> Returned (reason), which clears the question's conclusion and re-scores. Draft papers can be deleted. "Draft" is the preparing state before the spec's Pending.
- **Who does what:** the team is the engagement's lead, members and subject matter experts (566). The lead assigns questions. A question is prepared by its auditor, or by anyone on the team when unassigned (the lead always). A paper is edited / submitted / deleted by its preparer or the lead. The lead or the question's auditor concludes it, once every paper is approved. Everything happens while the execution is In Progress.
- **What the user sees (Workpapers):**
  - List: organization / "My engagements | All executions" / status filters, search. Execution, Audit, Engagement, Status, Lead / Reviewer, My Role, Concluded (n / total), Awaiting Review, Score. 3-dot: Working Papers, Activity.
  - The execution's child row: a facts line (score and band, lead, reviewer, your role), the Audit Conclusion (the lead edits it), and the questions (code, question, assigned to, papers by state, conclusion from the papers, conclusion). 3-dot: Working Papers, Add Working Paper, Assign, Conclude, Activity.
  - A question's child row: the testing guidance, expected evidence and weight; its working papers (paper, method, result, review status, prepared by, reviewed / approved, finding; 3-dot View, Edit, Submit for Review, Mark Reviewed, Approve, Return, Reopen, Raise Finding, Delete); the inline form (working paper, assign, conclude or raise finding); the activity.
  - Working paper form: testing method (Inspection, Inquiry, Observation, Reperformance, Reconciliation, Analytical Review, Configuration Testing, System Testing, Sampling and Transaction Testing), sampling method, sample size, test result, testing guidance (prefilled from the question; editing it here never changes the question set), procedure performed, population, sample details, evidence references, deviations, auditor comments, conclusion; reviewer comments are read-only and kept with who / when.
  - Raise Finding (from a Partially Satisfactory / Unsatisfactory paper): title, severity, target closure date, responsible owner, description, audit criteria, condition, root cause, risk and impact, recommendation, supporting evidence. Code `<paper code>-F` (-F2 ...).
- **Observations:** a **Finding** tab (with Details / Evidence / History): origin (failed or partially satisfactory testing, control deficiency, practice deficiency, existing gap, exception, risk-related concern, manual), the working paper, criteria, condition, root cause, risk and impact, recommendation, management response, corrective action, supporting evidence. Saved on their own; read-only once Closed.
- **Executions:** Submit needs every question concluded, every paper approved and the audit conclusion written (54064).
- **Data:**
  - New `org_assurance_testing_method_master` (9), `org_assurance_observation_origin_master` (7), `org_assurance_execution_question` (an execution's questions from its frozen snapshot: testing guidance = the question's help_text, weight; assignee; conclusion, reason, who / when), `org_assurance_working_paper`, `org_assurance_execution_activity` (the history).
  - `org_assurance_execution`: score_pct, score_band_code / _name, score_refreshed_dt, audit_conclusion, conclusion_by / _dt. `org_assurance_observation`: observation_origin_code, org_assurance_working_paper_id, audit_criteria, condition_text, root_cause, risk_impact, recommendation, management_response, corrective_action, supporting_evidence.
  - Functions `fn_org_assurance_wp_roles` (lead / team / reviewer of an execution for a person), `fn_org_assurance_wp_question_state` (papers by state, the suggested conclusion).
  - Procedures `sp_org_assurance_testing_method_list`, `_observation_origin_list`, `_wp_log` (internal), `_wp_question_sync` (internal), `_execution_score_refresh` (internal), `_wp_execution_list`, `_wp_overview`, `_wp_activity_list`, `_wp_question_assign`, `_working_paper_save`, `_working_paper_action`, `_wp_question_conclude`, `_execution_conclusion_save`, `_wp_raise_finding` (through `sp_org_assurance_observation_save`, 116a), `_observation_finding_get / _save`.
  - Re-issued `sp_org_assurance_execution_transition` (099 body) with the Submit gate.
  - The 558 answers became working papers: one Approved paper per answered question (Compliant -> Satisfactory, Not compliant -> Unsatisfactory, Not applicable -> Not Applicable; the description as conclusion / deviations), the question concluded the same, the finding the answer raised linked to the paper (origin Testing); scores worked out. The 558 table and procedures are kept (old data readable); the page no longer calls them.
  - Errors 54051 (not on the team), 54052 (not In Progress), 54053 (not found), 54054 (not editable in its state), 54055 (submit incomplete), 54056 (reviewer only / own paper), 54057 (reason needed), 54058 (lead only), 54059 (assignee not on the team), 54060 (papers not all approved), 54061 (conclusion reason), 54062 (invalid value), 54063 (finding from a satisfactory paper), 54064 (execution submit incomplete), 54065 (observation closed).
  - Menu `org-workpapers` (470, file-pen) under nav-assurance, every active role (as My Audits); Observations moved to 471. Both written back into 274.
- **API** (new `OrgAssuranceWorkpaperController` + `OrgAssuranceWorkpaperService`, registered in Program.cs): `GET testing-methods`, `GET observation-origins`, `GET workpapers/executions`, `GET executions/{id}/workpapers`, `GET executions/{id}/workpaper-activity`, `POST execution-questions/{id}/assign | conclude | working-papers`, `POST working-papers/{id}/action | finding`, `POST executions/{id}/audit-conclusion`, `GET / POST observations/{id}/finding`. Reads return the procedures' rows (EvidenceCenterService's pattern). The caller is the session employee (X-PM-Caller-Employee-Id). Execution reason code WORKPAPERS_INCOMPLETE (54064).
- **Web:** new `Partials/org-workpapers.cshtml` (registered in PracticeScreen.cs and Manage.cshtml; gated by the Audit Plans feature); `org-my-audits.cshtml` (the answer pane, its Save and its code removed; Working Papers via `gracSecureNav`, filter `AssuranceExecution`, allowed in `PracticeManagementGatewayController`); `org-assurance-observations.cshtml` (Finding tab); `practice-management.css` (the `#oaMyRoot .qs-grid` rules removed with the grid). Generated edits: `Claude outputs/s567/web567.py`, `web567b.py`.
- **Not in this phase:** evidence files attached to a working paper (evidence references are text; evidence stays per question, 536); the Executions page showing the score (it is on Workpapers); configurable severities / observation workflows beyond the existing ones.
- Generated by `Claude outputs/s567/gen567.py`. Rollback: `567_audit_working_papers_rollback.sql` (the transition back to 099; the new procedures and functions dropped; the menu Inactive and Observations back to 470; tables and columns kept).

### Audit Reports (568, 2026-11-16, sir; P1 phase H)
Audit Change spec 4.9 (reports). One report per engagement, built in the app from the audit data.
- **Decisions (sir, 2026-11-16):** one report per **engagement** (all its executions); in-app with editable narrative sections, printed / saved as PDF from the browser; a **template** = which sections, their order, headings and standard text.
- **Assumed (to confirm):** Draft -> In Review (the lead submits; Executive Summary and Overall Conclusion written) -> Approved (the engagement Reviewer, else the lead; every execution Approved or Closed) or Returned (reason) -> Issued (the lead; data and sections frozen as that version). Revise: Issued -> Draft as version + 1 (reason); every issued version stays readable.
- **Sections (spec 4.9):** Audit Objective and Mandate (objective, subject, auditee, type, audits with their mandates); Scope and Methodology (scope, branch, department, audits with approach and items in scope, testing methods used, the team); Audit Period (planned, actual, plan, financial year, programme); Executive Summary (counts + the lead's text); Audit Coverage (per audit: questions concluded, partial, unsatisfactory, papers, score and band); Key Findings (risk rating = severity, condition, root cause, status); Management Responses (response, corrective action, owner, target date); Recommendations; Overall Audit Conclusion (each audit's conclusion + the lead's text); Approval and Issue History.
- **What the user sees (Audit Reports, menu after Observations):**
  - View **Reports**: the engagements with an execution -- Engagement, Name, Plan, Lead / Reviewer, Executions Approved, Findings, Report, Status, Issued; filters organization / view / report status, search. A row opens the report as a document in its child row; the lead edits each section's narrative and inclusion (Save Report) while Draft / Returned. 3-dot: Create Report (a template is picked, the default chosen), Open, Submit for Review, Approve, Return, Issue, Revise, Print / Save as PDF. An issued report shows its frozen data; a "Version shown" select reads earlier issued versions.
  - View **Report Templates**: Code, Template, Default, Sections, Reports, Active; a row opens the editor (name, default, active, description; per section order, heading, include, standard text). "+ Add Template". The organization's "Standard Audit Report" template (every section) is made the first time templates are read. Reports already made keep their own sections.
  - Print: the browser's print dialog with only the report (the Risk Centre's window.print() way; @media print rules on the page).
- **Data:** `org_assurance_report_section_master` (10), `org_assurance_report_template` / `_template_section`, `org_assurance_report` (one active per engagement), `_report_section`, `_report_issue` (data JSON + sections JSON per issued version), `_report_history`. `fn_org_assurance_engagement_roles` (lead / reviewer of an engagement). Procedures `sp_org_assurance_report_section_master_list`, `_report_template_list / _get / _save`, `_report_list`, `_report_create`, `_report_data_json` (the report data as one JSON document -- live, and frozen at issue), `_report_get`, `_report_section_save`, `_report_action`. Errors 54070-54079. Menu `org-audit-reports` (472, file-lines), the Audit Plans permissions copied; written back into 274.
- **API** (new `OrgAssuranceReportController` + `OrgAssuranceReportService`, registered in Program.cs): `GET report-sections`, `GET report-templates`, `GET report-templates/{id}`, `POST report-templates`, `GET reports`, `POST reports`, `GET reports/{id}?versionNo=`, `POST reports/{id}/sections`, `POST reports/{id}/action` (SUBMIT / RETURN / APPROVE / ISSUE / REVISE). Reason codes REPORT_*.
- **Web:** new `Partials/org-audit-reports.cshtml` (registered in PracticeScreen.cs and Manage.cshtml; gated by the Audit Plans feature). No shared CSS change (page-scoped report and print styles).
- **Not in this phase:** a Word / PDF file generated on the server (the browser's Save as PDF); distribution (email) of an issued report.
- Rollback: `568_audit_reports_rollback.sql` (procedures and the function dropped; menu Inactive; tables kept).

### Deploy
Run **543** (after 537 and 541), **544**, **545**, **546**, **547**, **548**, **549**, **550**, **551**, **552**, **553**, **554**, **555**, **556**, **557**, **558**, **559**, **560**, **561**, **562**, **563**, **564**, **565**, **566**, **567** and **568** -> restart the Api -> publish Web. Users sign out and back in to see the sidebar changes (549, 555 My Audits, 566 Audit Engagements, 567 Workpapers, 568 Audit Reports).

### Owner labels (2026-11-15)
Audit Definition's Owner pair now has a label on each select: **Owner Role** (the role) and **Responsible Owner** (the person holding it), instead of one "Owner" label over both. `org-assurance-definitions.cshtml` markup only -- ids, order, picker behaviour and the workspace layout rules unchanged.

