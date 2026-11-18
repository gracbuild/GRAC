# Organization Management lands on a list of organizations (2026-11-02)

## The ask
> organization management le first landing page organization list akanam. grid lu
> Organisation Short Name, Organisation Long Name, Start Date, End Date, Selected
> Standards and Frameworks, SPOC Name, and Organisation Status ithrem columns anu
> vendathu. pinne row click cheyyumbo ipo ulla organization nte page varanam.
> organization management lu edukumbo first tab mathram mathi. means organization
> details. bhaki location division department onnum venda.

Three things:

1. The module's landing page becomes a **list** of organizations, seven named columns.
2. **Row click** opens that organization's page (Organization Setup).
3. On the Organization Setup page, show **only the Organization tab**.

Confirmed in the same exchange: SPOC Name is the **Admin Full Name** already captured at
onboarding; frameworks show up to **three codes then "+N more"**; the list carries an
**Add Organization** button.

## What already existed
The `organizations` screen was already registered in `PracticeScreen.All`, already had a
3-dot action set (`view / edit / manage / inactive`), and `Manage.cshtml` already had
`Model.Key == "organizations"` branches suppressing Back and the generic Add. Its
`menu_master` row is **Inactive**, so it never appeared in the sidebar.

That is what makes this change small: it is a landing page and a column list, not a new
screen. **No menu migration and no permission migration were needed** — see the permission
note below.

Of the seven requested columns, five were already in the monolith's `organizations`
projection (`dbo.pm_get_practice_repository`, latest body in migration 404): Code, Name,
SubscriptionStartDate, SubscriptionEndDate, Status. Two were not.

## Migration 510 — the two missing columns

`database/510_organization_list_spoc_frameworks.sql` (+ rollback).

### SPOC Name
There is no SPOC column anywhere in `grac_practice`, and no SPOC field on any form. What
does exist is the **Admin Full Name** captured on the onboarding form:
`pm_create_organization_admin` (217) stores it as an `organization_employee` holding the
organization's Admin role. So SPOC is **derived**, not stored — no new column, no new form
field, nothing to backfill:

```sql
(SELECT TOP (1) e.employee_name
   FROM grac_practice.organization_employee e
   JOIN grac_practice.organization_role r ON r.role_id = e.role_id
  WHERE e.organization_id = o.organization_id
    AND (r.role_code = N'ORG_ADMIN' OR r.role_name = N'Admin')
  ORDER BY CASE WHEN e.status = N'Active' THEN 0 ELSE 1 END,
           CASE WHEN r.role_code = N'ORG_ADMIN' THEN 0 ELSE 1 END,
           e.employee_id) AS SpocName
```

Active preferred, then `ORG_ADMIN` over a role merely *named* Admin, then the earliest — so
a re-provisioned organization still shows one name rather than none.

### Selected Standards and Frameworks
Aggregated from `repository_subscription` joined to `grac_new.artifact`. A `CROSS APPLY`
counts `COUNT(DISTINCT a.artifact_id)`, and the cell prints up to three artifact codes then
`+N more`. `DISTINCT` on the artifact, so two releases of one framework are one entry and
count once.

"Subscribed" is `status = 'Active' AND ISNULL(subscription_status,'Active') = 'Active'` —
the way 404 reads a live subscription everywhere else. A **Disabled** subscription keeps
`status = 'Active'`, so testing only that column would have counted frameworks the
organization is no longer subscribed to.

### Why a shim and not the monolith
House gateway-shim pattern (134, 361, 419, 465). `CREATE OR ALTER` on
`dbo.pm_get_practice_repository` would replace all 2,000+ lines of it, so instead:

* `grac_practice.sp_org_organization_list` — 404's `organizations` branch **copied verbatim**
  with only the two columns added.
* `grac_practice.sp_org_organizations_repository_get` — takes the monolith's same seven
  parameters and calls the list.

Verbatim matters: the *same* branch (`WHERE @p_id = 0 OR organization_id = @p_id`) seeds the
Edit form on the organization page. Dropping a column from the list would have blanked a
field on that form. `TotalRows = COUNT(*) OVER ()` is kept for the generic pagination (300).

**Read only. There is no manage shim** — nothing about saving an organization changes, so
writes keep going to the monolith untouched.

### Column guard
The guard checks the **columns** the body reads, not just the tables —
`organization_employee.role_id/status/employee_name`, `organization_role.role_code/role_name`
(added by 027), `repository_subscription.artifact_id/subscription_status`,
`grac_new.artifact.artifact_code` — and `SET NOEXEC ON` on a miss.

This is the `reissued_proc_needs_column_guard` trap that bit 498 on production: a proc body
is column-validated at CREATE time, so one missing column fails that CREATE with Msg 207
while the script carries on and still PRINTs success.

## Api — one routing line

`PracticeManagement.Api/Services/PracticeRepositoryService.cs`, `ResolveProcedureAsync`:

```csharp
else if (!isManage && entityType.Equals("organizations", StringComparison.OrdinalIgnoreCase))
    shim = "grac_practice.sp_org_organizations_repository_get";
```

`!isManage` is the whole safety of it. `ShimExistsAsync` falls back to the monolith when the
shim is absent, so SQL and Api can be deployed in either order — but **the probe is cached
per process, so the Api must be restarted after running 510.**

## Web

### `Models/PracticeScreen.cs`
```csharp
new("organizations","Organizations","Organizations on the platform, their subscription
    window, frameworks and SPOC.","building",
    ["Code","Name","SubscriptionStartDate","SubscriptionEndDate",
     "FrameworkSummary","SpocName","Status"], OrganizationGroup),
```

### `Controllers/PracticeController.cs`
* `OrganizationManagementAreas` is now an **ordered `string[]`** with `organizations` first,
  because `VisibleMenu()` projects the sidebar straight from that sequence.
* `OrganizationManagementAreaSet` keeps the old `HashSet` with `StringComparer.OrdinalIgnoreCase`
  for the three membership tests. Array `.Contains` is case-**sensitive** and `areaKey` comes
  straight off the URL, so using the array for those would have 404'd spellings the HashSet
  accepted.
* `Index()` with no `areaKey` in this module → `ShowArea("organizations")` instead of
  `OrganizationSetupIndex()`.
* `OrganizationManagementMenuUrl("organizations")` → `""` (the module root).

**The sidebar does not change.** `VisibleMenu` looks each area up in the screens the menu
service returns, and `organizations` has no Active `menu_master` row, so it is dropped — the
sidebar still shows Organization Setup and Organization Dependencies, and the list is reached
as the module's landing page, not as a menu item.

**Permissions.** Because that menu row is Inactive, the screen would otherwise grant nobody
anything (the same case `practice-instances` is in since 288). So `ScreenPermissionArea` maps
`organizations` → `organization-setup`: whoever may open Organization Setup may see the list
of what they can open. No permission migration.

### `wwwroot/js/practice.js`

**Column headings.** `columnLabel()`'s label map is **global** and contains
`Name: "Practice Instance Name"`, so the requested headings could not be had by renaming
anything there. A per-screen override was added next to the existing `wrappedColumnsByScreen`,
consulted first:

```js
const columnLabelsByScreen = {
  "organizations": {
    Code: "Organisation Short Name", Name: "Organisation Long Name",
    SubscriptionStartDate: "Start Date", SubscriptionEndDate: "End Date",
    FrameworkSummary: "Selected Standards and Frameworks",
    SpocName: "SPOC Name", Status: "Organisation Status"
  }
};
```

**Row click.** `organizationRowAttrs()` puts the existing `.pm-row-clickable` affordance —
the same one the Gap / Task / Exception / Risk / Organization Practices grids carry — on the
generic row, gated on `VIEW` exactly as `practiceRowViewAttrs()` is, and carries the row
index the way `practiceRowViewAttrs()` does. The click branch in the `#practiceRows`
listener uses the same exclusions as the row-clicks above it (the 3-dot trigger, the
bulk-select cell, any inner control).

**The id is never in the URL.** The first attempt navigated to
`?organizationId=3`, which put a row key in the address bar — sir's instruction is that a
URL must never show it. It now travels inside the **encrypted navigation code**, the same
`NavigationContextProtector` envelope every other cross-screen drill in this app already
uses:

```js
const code = await createNavigationCode({
  sourceArea: "organizations", targetArea: "organization-setup",
  filterType: "Organization", filterId: organizationId, organizationId,
  displayCode: ..., displayName: ...
});
window.location.assign(`${buildAppUrl("organization-setup")}?code=${encodeURIComponent(code)}`);
```

The code is minted server-side by the gateway's `navigation-code` endpoint, which re-checks
`VIEW` on **both** the source and the target area, and the envelope expires after 30
minutes. Two server-side changes were needed for it:

* `PracticeManagementGatewayController.IsAllowedNavigation` — `"organization-setup"` added
  to the `FilterType: "Organization"` arm's target list, so that page is a legal
  destination for an organization context. Both areas still go through `PermissionArea`,
  so this widens nothing.
* `Security/PermissionAreaMap.cs` — `["organizations"] = "organization-setup"`. This was a
  real defect, not just plumbing for the code: `PermissionAreaMap.For("organizations")`
  returned `organizations` unchanged, and that `menu_master` row is Inactive, so
  `organizations:VIEW` is a grant **no role can hold**. The list's own `organizations/query`
  would have answered 403 for every real role while `admin` (`*:*`) saw it work — exactly
  the failure that file's own header describes. It has to match
  `PracticeController.ScreenPermissionArea`, which maps the same key: that one permissions
  the page, this one the entity read behind it.

**The path is the area key, not the attribute route.** The first attempt used
`buildAppUrl("OrganizationSetup")` on the reasoning that `[HttpGet("OrganizationSetup")]` is
absolute under the current PathBase. That is only half true, and it 404'd:

```
http://localhost:5031/OrganizationManagement/OrganizationSetup?organizationId=3
HTTP ERROR 404
```

`/OrganizationManagement` is a **PathBase** in a hosted deployment (`Hosting:PathBase` →
`app.UsePathBase`), but on a plain host it is a conventional **route** —
`OrganizationManagement/{areaKey?}` in `Program.cs` — and `ModuleRouteBase()` returns
`/OrganizationManagement` in *both* cases, from `RouteData.Values["moduleKey"]` in the
second. So the URL became a request for `areaKey = "OrganizationSetup"`, which is not in
`OrganizationManagementAreas`, and `ShowArea` answered `NotFound()`.

`organization-setup` is the one spelling correct under both: the action's *other* attribute
route under a PathBase, and the module route's `areaKey` without one. The same spelling is
used for the "Add Organization" button.

**The setup page opens on the clicked row.** `populateSetupOrganizationSelector()` used
`getSavedOrganizationId()` then the first organization. The decrypted context now wins over
both. The code is resolved by `loadSetupNavigationContext()`, a thin wrapper over the
existing `loadNavigationContext()`, inserted into the workspace bootstrap
(`loadLookups().then(loadSetupNavigationContext).then(initOrganizationSetup)`) so it runs
before the selector is built. An expired code is **not** fatal — it is logged and the page
falls back to the remembered organization, as it did before. The organization is also
written to the shared org preference, so every other org-scoped page follows.

**The bootstrap early return — the bug this first shipped with.** The page came up on
"Loading..." with:

```
Organization Setup initial load failed. TypeError: Cannot set properties of null
  (setting 'innerHTML') at populateSetupOrganizationSelector
```

`practice.js` had, near the end:

```js
if (screen.Key === "organizations" || isOrganizationWorkspace) {
  loadLookups().then(initOrganizationSetup)...
  return;
}
```

`organizations` was in that condition from when that screen key **was** the Organization
Onboarding page (its old title was literally "Organization Onboarding"). Now that
`Manage.cshtml` renders the generic grid for it, there is no `#organizationSetup` panel and
therefore no `#setupOrganization` element, so `initOrganizationSetup()` threw — and the
`return` also skipped the grid bootstrap, which is why the list never loaded.

Fixed by dropping `screen.Key === "organizations" ||`, leaving the condition as
`isOrganizationWorkspace`. The three real workspace screens are unaffected. Two comments
elsewhere in the file that quoted the old condition verbatim were corrected with it.

### `Views/Practice/Manage.cshtml`
* **Add Organization** on the list: a link to Organization Setup, not the `#addRecord`
  button, because that page's Organization selector already offers "New Organization" when
  no `?organizationId=` is supplied. Gated on the same `ADD` permission.
* `organizationSetupInModule = isOrganizationOnboarding && isOrganizationManagementModule`
  suppresses the child tab strip and the child tab panels, leaving only the Organization tab.
  (The same flag later took on the view mode and the hidden combo — see the follow-up below.)
* "Add Organization" links to `<AppBasePath>/organization-setup` as a plain `href`, not via
  `asp-action`: a tag helper here can resolve against the Practice route registered *before*
  the Organization Management one and emit `/Practice/...`, losing the module.
* The toolbar filters that cannot apply are hidden: Organization (the rows *are* the
  organizations), Owner, Criticality and Origin — none of which is a column of an
  organization. Search, Status and Entered from/to stay, because
  `sp_org_organization_list` takes `@p_search`, `@p_status`, `@date_from` and `@date_to`.
  The elements stay in the DOM rather than being removed, because `loadRows()` reads
  `.value` on each of them unconditionally.

Scoped to **that page and that module** on purpose:

| Page | Tabs |
|---|---|
| Organization Setup, in Organization Management | Organization only — **changed** |
| Organization Administration | its six, unchanged |
| Organization Dependencies | its three, unchanged (hiding those leaves the page empty) |
| the same screen under Practice Management | unchanged |

`loadSetupChildRows()` already no-ops for `"organization"` and for a missing panel, so
nothing JS-side needed changing.

## The organization page is a VIEW page (2026-11-02, follow-up)

The ask: a row click opens the organization's **view** page, not the edit page; that page
carries an **Actions** button with **Edit**; and the Organization combo box is gone from view
and edit, since the organization comes from the row that was clicked.

### First cut, and why it was replaced
The first attempt made Organization Setup *itself* render read-only and flip to editable from
an Actions menu. Sir asked for a proper separate view page instead, so that was reverted:
`setupState.readonly`, `setupIsReadonly()`, `applySetupMode()`, `enterSetupEditMode()`, the
tree's `disabled` flag and the Actions button are all gone, and `renderSetupBasic` /
`renderSetupAttributes` are back on `isOrganizationAdministration` alone. **Organization Setup
is purely the edit / onboarding page again.**

### The view page
A new workflow screen, `organization-view`, following the house pattern for a full-page
record view (`practice-view`, `gap-view`, `task-view`, `exception-view`): its own partial, its
own JS, registered in `Manage.cshtml`'s `workflowScreens` so the generic grid layout is
skipped entirely.

| File | |
|---|---|
| `Views/Practice/Partials/organization-view.cshtml` | new, 174 lines |
| `wwwroot/js/Organization/organization-view.js` | new, ~365 lines |

Layout follows `gap-view.cshtml`: section headings over `.ov-facts` definition lists on a
tinted panel, the same read-only visual language — **Organization Details** (short name, long
name, industry, entity type, SPOC, status), **Subscription** (start, end, framework count),
**Address & Locale**, **Organization Attributes**, **Standards & Frameworks**. No new design
tokens, no new component.

**Three reads (four since 2026-11-03), all of them calls that already existed.** No new endpoint, no new stored
procedure, no new column:

| Read | What it gives |
|---|---|
| `POST {gateway}/organizations/query  { id }` | the organization row — 510's `sp_org_organization_list`, the same read the landing list uses, and where `SpocName` comes from |
| `POST {gateway}/organization-setup/query` | 404's branch: table 2 = metadata definitions with this organization's values, table 3 = the authority/artifact/release tree carrying `IsSubscribed` |
| `GET {gateway}/lookups` + `POST {gateway}/time-zones/query` | labels. `time-zones` is deliberately **not** in the generic `/lookups` UNION (migration 361), so it is its own entity — exactly as `practice.js`'s `ensureTimeZoneLookup` fetches it. Both are allowed to fail: a missing label degrades one field, it does not fail the page |

**Attributes render from the API rows** (`MetadataName` + `DataType`), not from a copy of
`practice.js`'s `setupAttributeSchema` — one less place for the two to drift. The value is
picked by `DataType` the way `parseAttributeValue()` does, with a fallback across the value
columns so an unfamiliar `DataType` still shows what it holds.

**Frameworks** are grouped Authority › Artifact › release chips from the subscribed rows — a
real list, not the landing list's "+N more" summary, because there is room here.

**Release owner beside each release (2026-11-03).** Ask: *"organization nte view page lu
subscribed frameworks list cheyyumbo athinte nere aa organization le aa framework owner ne
koodi kanikkanam"*. Each release chip now reads `ISO27001 2022` **Owner: EMP01 - Name**, or
*Owner: Not assigned* when none is set.

- **The owner is the release owner** (`repository_subscription.owner_id`), the one set by
  *Update Owner* on Standards & Frameworks and used by Repository Updates. It is stored per
  subscribed release, so it is shown per release chip, not per artifact.
- **A fourth read, also existing:** `POST {gateway}/subscribed-frameworks/query
  { data: { organizationId } }`. This is the Standards & Frameworks summary
  (`PracticeRepositoryService.QuerySubscribedFrameworksAsync`) and already returns `ReleaseId`
  and `OwnerName` (`employee_code - employee_name`), so the text matches that screen.
- **No grant needed.** It is a `LoginController.SupportingReads` entity, open to every signed-in
  user, so the page needs nothing beyond what it already had.
- **Allowed to fail,** like the lookups: the owners then read *Not assigned* and the rest of the
  page is unaffected.
- **Joined in the browser by `ReleaseId`.** The 404 `organization-setup` tree carries no owner.
  Changing it would mean re-issuing the monolith branch, and Organization Setup reads the same
  branch.
- **Files:** `wwwroot/js/Organization/organization-view.js` (`load`, `renderFrameworks`, header
  comment); `Views/Practice/Partials/organization-view.cshtml` (`.ov-release-item`,
  `.ov-release-owner` CSS, comment). No SQL, no Api change.

**The Actions button** is `wwwroot/js/Shared/page-actions-menu.js`
(`window.gracPageActions.attach`), the same module Practice / Gap / Task / Exception View use.
`getItems()` runs on each open: Edit appears once an organization is loaded and only with the
screen's EDIT or ADD grant. Edit mints a **fresh navigation code** for `organization-setup`,
so the id stays out of the URL on that hop too.

### Registration
| Where | What |
|---|---|
| `PracticeScreen.cs` | `organization-view` in `OrganizationGroup` |
| `Manage.cshtml` | added to `workflowScreens` |
| `PracticeController.OrganizationManagementAreas` | added, so `ShowArea` accepts it in the module |
| `PracticeController.ScreenPermissionArea` | `organization-view` → `organization-setup` |
| `PermissionAreaMap` | `organization-view` → `organization-setup`, for the gateway's checks on the navigation code it mints and resolves |
| gateway `IsAllowedNavigation` | `organization-view` added to the `FilterType: "Organization"` targets |

It has no `menu_master` row, so `VisibleMenu` drops it and it never appears in the sidebar —
reached from the list, not the menu. No menu or permission migration.

**It needed an attribute route of its own**, unlike every other workflow screen. Those are
reached as `Practice/Index/{areaKey}`, which is four segments — more than the module's own
`OrganizationManagement/{areaKey?}` route takes. And under a hosted PathBase of
`/OrganizationManagement` the path is just `/organization-view`, which matches no conventional
route and would 404. So `PracticeController` gained `OrganizationView`, with
`[HttpGet("OrganizationView")]` and `[HttpGet("organization-view")]`, exactly as
`OrganizationSetupIndex` has.

### Two traps avoided while writing it
* **PathBase at parse time.** `_Layout` sets `window.appBasePath` *after* `@RenderBody`, so a
  `U()` call made while the partial's `<script>` is still parsing would build URLs against an
  empty base. `api` is therefore resolved inside `init()`, never at parse time.
* **`@` in a `<script>` block.** The partial's inline script mentions `@@section Scripts` in a
  comment, escaped — an unescaped `@section` there compiles as C# and fails the build.

### Scoping
The `organization-setup` read goes through the gateway's `ValidateRequestedOrganization`, so a
caller cannot read an organization outside their access even holding a valid code: that call
403s and the page shows its "not found" panel rather than any data. (The `organizations` read
filters on `id` and is not organization-validated — the same as the landing list, which has
always returned every organization — but it is not enough on its own to render the page.)

### What stayed from the earlier cut
The Organization combo is still **hidden** on Organization Setup inside this module (the
organization comes from the row, or from the view page's Edit), the page still shows only the
Organization tab, and it still has a Back button to the list. `organizationSetupInModule` is
the single condition for all three. The combo is hidden rather than removed because
`loadOrganizationSetup`, `saveOrganizationSetup` and `populateSetupOrganizationSelector` all
read `#setupOrganization` unconditionally.

`practice-management.css` keeps **one** `[hidden]` rule from that cut —
`.pm-setup-toolbar label[hidden]`, which the combo needs because `.pm-setup-toolbar label` is
`display: inline-flex` and an author `display` rule beats the browser's own `[hidden]`
default. The rest were removed with the mode they served.

### Still open, not done here
A blanket `.pm-button[hidden]` rule would fix several buttons that set `.hidden = true` today
and are **not** actually hidden by it — `#addRecord` on Role Menu Permission, User Role
Assignment and Practice Instances, and `#pvActionsBtn` in `practice-view.cshtml`. Intended
there too, but it changes other screens, so it is a separate change.

The navigation-code POST is a small per-file copy in `organization-view.js`, which is this
codebase's existing convention for a standalone page — `practice-calendar.js`'s
`navigateToPractice` says so explicitly for the same two calls. Folding `practice.js`,
`practice-calendar.js` and this one onto a shared `Shared/navigation-code.js` is a worthwhile
tidy-up and has not been done.

## One menu in the module (2026-11-02, follow-up)

> "organization setup and dependencies ee 2 menus ini organization module lu venda.
> Framework subscription request approval nte oru menu mathram mathi ee module lu."

### The split that made it possible
`PracticeController` had one array doing two jobs: `OrganizationManagementAreas` was both the
set of areas `ShowArea` accepts **and** the sequence `VisibleMenu` projects the sidebar from.
Those are different questions now, so there are two lists:

| List | Holds | Answers |
|---|---|---|
| `OrganizationManagementAreas` | `organizations`, `organization-view`, `organization-setup`, `subscription-requests` | what may OPEN in this module |
| `OrganizationManagementMenuAreas` | `subscription-requests` | what the SIDEBAR shows |

`OrganizationManagementAreaSet` is the union of the two, and remains the case-insensitive
`HashSet` every membership test uses — array `.Contains` is case-sensitive and `areaKey`
comes straight off the URL.

* **Organization Setup** stays reachable and leaves the menu. It has to stay reachable: the
  organization view page's Actions > Edit and the landing list's Add Organization button both
  go there.
* **Organization Dependencies** leaves the module entirely. With its menu gone nothing here
  linked to it, so keeping it reachable would have left a page with no way in. The screen is
  untouched and still works under Practice Management; its `OrganizationDependencies` actions
  now answer `NotFound()` inside this module, which is the intent.
* `OrganizationManagementMenuUrl` lost its `"OrganizationDependencies"` fallback. Every area
  but the two named ones is now reached by its own area key — which is both its attribute
  route under a hosted PathBase and the module route's `areaKey` without one — so the fallback
  *is* the key and a new area needs no line there.

### Then a second entry, because there was no way back
With one menu, opening the approval screen left no route back to the organization list — it
was the module root and had no menu row. So the list is a menu entry too, and the first one:

```
Organizations
Subscription Requests
```

Two things had to change for it.

**The menu row — migration 512.** `organizations`' `menu_master` row has existed since the
beginning but is **Inactive**, named "Organization Onboarding", parented to
`nav-organization`. `VisibleMenu` resolves each entry against `VisibleScreens`, which is built
from Active rows only, so the entry was dropped silently.

The first cut fixed that in code, with a fallback to the static `PracticeScreen` registry. Sir
asked the obvious question — *"menu db nnu alle? apo db change ille?"* — and was right: a menu
belongs in `menu_master`. So 512 makes the row real instead, and the code fallback is gone, so
the database is authoritative again (setting the row Inactive now hides the entry, as it
should).

| Column | Before | After |
|---|---|---|
| `status` | Inactive | **Active** |
| `menu_name` | Organization Onboarding | **Organizations** |
| `parent` | `nav-organization` | **`Organization`** (as `organization-setup`) |
| `module_type` | Organization Setup | **Organization** |
| `show_in_sidebar` | 1 | **0** |

`module_type` matters more than it looks: `_Layout`'s no-menu fallback block lists every Active
screen whose group is `Organization Setup` under Organization Setup, and the list does not
belong there. `Organization` is the value `organization-dependencies` already carries and the
group the screen declares in `PracticeScreen.All`, so the registry and the row agree.

The `Organization` parent is what keeps both rows out of **Practice Management's** sidebar:
that one is a tree built from Active rows, and a child whose parent is absent is never
reached. Organization Management does not use the tree, so it still shows them.
`show_in_sidebar = 0` is the explicit guard on top, in case that group is ever activated.

No grants are needed. `ScreenPermissionArea` maps `organizations` to `organization-setup`, as
it did while the row was Inactive, so whoever may open Organization Setup may see the list.
One consequence worth knowing: the row now appears in Role Master's matrix, and **ticking it
there has no effect** while that mapping stands. Giving the screen its own grants instead is a
separate change.

**A route of its own** — `[HttpGet("organizations")]`, the third time in this work.
`OrganizationManagementMenuUrl` returned `""` for the list, written when nothing linked to it,
and an empty `MenuUrl` makes `_PracticeMenuTree` fall through to its group-based guesses, which
point into the Practice Management module. The area key is correct under both hosting shapes
once the route exists, so the `""` special case is gone.

**Deployment**: the module's sidebar is now entirely DB-driven, so it needs **511 and 512 both
run** and a fresh sign-in. Until then it comes up short or empty — which is the failure this
change exists to fix, so check it after deploying rather than assuming.

## Two sessions built the approval screen at once

Worth recording, because it cost real work. On 2026-11-02 the same instruction reached two
Claude sessions on the same working tree. Between 18:41 and 18:46 one of them built the
approval screen as `subscription-requests` — dedicated Api and Web controllers, a service, a
partial, and `511_subscription_requests_org_management.sql`. Between 18:49 and 18:52 the other
built the same feature as `subscription-request-approvals` — gateway shims over 406's own
procedures, the generic grid, and `511_subscription_request_approvals.sql`. Two migrations
carried the number **511** and `PracticeScreen.All` carried both screens.

Sir chose to keep the first. The second was removed: its `PracticeScreen` entry, its
`practice.js` pieces (headings, `actionDefinitions`, the `approve` label and icon, the
permission-gate line, the Pending-only narrowing, the `handleAction` branch and
`decideSubscriptionRequest`), its Api `Supported` entry, its shim routing and employee-scope
guard entry, and its `274` row. Its two SQL files are in `database/_to_delete/`.

The kept implementation is the better one on the point that matters most: its Web proxy
requires a **GLOBAL data scope** to list or decide, so an organization admin cannot approve
their own organization's request. The removed one relied on the screen's APPROVE grant and the
employee-scope backstop, which is weaker.

Two things this episode is worth remembering for:

* **A grep keyed to your own name proves nothing.** Checking `274` for
  `subscription-request-approvals` matched only my own row and reported the other session's
  row as absent. The later read-modify-write then added mine beside theirs, putting two rows
  with the same `menu_key` into one `MERGE USING (VALUES ...)` — which fails at runtime with
  **Msg 8672**, "attempted to UPDATE or DELETE the same row more than once". Grep for the
  *subject*, not for your own identifier.
* **Check file mtimes before editing a shared tree**, and say so plainly when they show
  another writer.

### The 404 on the kept screen
Its grid reported `Request failed (HTTP 404)` on load. The Web proxy was registered at one
absolute route, `practice/api/subscription-requests`, while the partial correctly prefixes
`window.appBasePath` — which is `/OrganizationManagement` on a plain host, where that segment
is a conventional route rather than a PathBase. So the browser asked for
`/OrganizationManagement/practice/api/subscription-requests` and nothing matched. Fixed the
way `PracticeManagementGatewayController` already solves it, with both spellings:

```csharp
[Route("practice/api/subscription-requests")]
[Route("OrganizationManagement/practice/api/subscription-requests")]
```

That is the **third** appearance of this trap in one day — after `OrganizationSetup` and
`organization-view`. The rule: inside this module, a URL built from `AppBasePath` needs either
the module-prefixed route registered, or the area key, which is correct under both hosting
shapes.

## Still plain text elsewhere
The encrypted `?code=` is now used for this navigation, but it is **not** used everywhere in
the application. These page navigations still put readable ids in the address bar:

| File | URL |
|---|---|
| `TaskCentre/task-view.js` | `task-edit?taskId=`, `task-complete?taskId=&from=view` |
| `ExceptionCentre/exception-view.js` | `exception-analysis?exceptionId=`, `gap-view?gapId=` |
| `RiskCentre/risk-centre.js` | `gap-detail?gapId=&orgId=` |
| `EvidenceCenter/evidence-center.js` | `resolve-workspace?instanceId=&organizationId=` |
| `AssetConfig/asset-activities.js` | `task-view?taskId=` |

Converting those is a separate change and has not been made here.

## Not changed
* The monolith. The `organizations` **write** path, the Edit form and its fields.
* `menu_master` / 274, and every permission table.
* The list's row scope: the `organizations` read returns every organization, as the branch
  always did — 510 copies 404's `WHERE` clause verbatim. The screen is governed by
  `organization-setup`, a GRAC-admin screen.

## Verification
* `510` + rollback: static sweep (parens 86/86 and 4/4, `BEGIN`/`END` balanced, ASCII-only)
  and `sqlfluff parse --dialect tsql` — **0 unparsable** on both (2,961- and 331-line trees).
* `practice.js`: `node --check` clean.
* No `@` introduced inside any `<script>` block in `Manage.cshtml` (the Razor sigil trap).

## To deploy
1. Run `510_organization_list_spoc_frameworks.sql`.
2. **Restart the Api** — `ShimExistsAsync` caches its probe per process.
3. Restart / redeploy Web.
4. Hard-refresh the browser: `practice.js` changed.

## Admin Email / Admin Full Name did not save or load — 518 (2026-11-05)

> "organization management lu add new organization lu admin name and admin email
> save cheyyunnathu save akunnilla ennu thonnunnu. veendum edukumbo athu load akunnilla."

Admin Email and Admin Full Name are **not organization columns**. After the
`organization-setup` save, `saveOrganizationSetup()` calls
`POST {gateway}/organization-admin/provision-and-notify`, which creates the
organization's Admin employee through `pm_create_organization_admin` (217) and emails
the one-time credentials. Two separate defects:

### Save: provisioning never ran
`pm_manage_practice_repository` (404) ends with `SELECT ... @new_id Id`, so the save
returns the new organization's id as **`Id`**. `extractNewOrganizationId()` read only
`OrganizationId` / `NewOrganizationId`, got 0, and `setupState.organizationId` is empty
for a new organization. With an email supplied, neither branch ran, so provisioning was
skipped **with no message**. The page said "saved successfully", no admin was
created and no email went out. SPOC Name on the list stayed blank for the same reason.

Fix (`practice.js`): `extractNewOrganizationId()` also reads `Id`. A new `else` branch
reports "Admin not provisioned: the saved organization's id was not returned", so this
can never be silent again.

### Load: the form never read the admin
`renderSetupBasic()` had no `adminEmail` / `adminName` values and the
`organization-setup` read does not return them. Admin Email was also `required`, so
editing an existing organization forced the user to retype it, and the retyped value
then did nothing.

Fix:
* **SQL 518** (`518_organization_list_spoc_email.sql` + rollback) re-issues 510's
  `sp_org_organization_list` with **`SpocEmail`** beside `SpocName`. Both columns now come
  from one `OUTER APPLY` using 510's exact pick rule. The shim, the monolith and every
  table are untouched.
* **`practice.js`**: `loadSetupOrganizationAdmin()` reads `POST {gateway}/organizations/query { id }`.
  This is the call the landing list and `organization-view` already make, under the same
  `organization-setup` permission. It runs before `renderSetupBasic()`, and
  `setupAdminField()` applies the rule below:

| Organization | Admin fields |
|---|---|
| New | unchanged — Admin Email required, provisioned on Save |
| Existing, admin exists | shown, **read-only**, not required |
| Existing, admin could not be read | read-only, blank; Save provisions nothing |
| Existing, **no admin** (created while the bug above was live) | editable, optional; Save provisions one |

Changing an existing admin's email is deliberately not offered. The proc names the
employee `ORGADMIN-<organization id>`, one per organization, so a second email would
collide. That would be a separate change.

Organization Administration's read-only Organization tab now shows the admin as well,
because it renders the same values.

### To deploy
1. Run `518_organization_list_spoc_email.sql`. No Api restart is needed: the shim already
   exists, and only the procedure behind it changed.
2. Redeploy Web and hard-refresh the browser, because `practice.js` changed.
3. For organizations created before this fix: open each one, type the Admin Email and Name,
   and Save. This provisions the admin and emails the credentials.

## 2026-11-16: the list is "Legal Entities" (migration 570)

The Organization Registry (migrations 569-572, `docs/organization-registry.md`)
makes the organization row the **Legal Entity** level under a new
**Organization** level. This list is therefore renamed *Legal Entities*
(menu_master and 274, `PracticeScreen` title, column headings "Legal Entity
Code / Name / Status"), gains an *Organization* column, and the module now
lands on *Organization Registry* (first menu). `sp_org_organization_list` was
re-issued by 570 from 518's body with `RegistryOrganizationId / Code /
RegistryOrganization` and `ParentLegalEntityId / ParentLegalEntity` added;
nothing else in it changed. The view page reads "Legal Entity" and shows the
Organization and parent Legal Entity. "Add Organization" is "Add Legal Entity"
and still opens Organization Setup.
