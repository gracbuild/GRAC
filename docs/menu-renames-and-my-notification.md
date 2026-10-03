# Sidebar renames, My Notification parent, Policies & Documents root (migration 384)

Requested by sir, 2026-09-26.

## What changed in the sidebar

| menu_key | Before | After |
|---|---|---|
| `dashboard` | Dashboard | **Home** |
| `nav-oversight` | Oversight | **Issues & Actions** |
| `gaps` | Gap Center | **Gap Register** |
| `tasks` | Task Center | **Task Board** |
| `exception-centre` | Exception Centre | **Exceptions & Waivers** |
| `nav-assurance` | Audit Management | **Audit Assurance** |
| `nav-documents` | Document Management (under Governance) | **Policies & Documents** (root, order 400) |
| `my-notifications` | My Notifications (under Oversight) | **My Notification** (root parent, order 50) |

Resulting root order: Home (0), My Notification (50), Governance (100),
Issues & Actions (200), Risk Management (280), Audit Assurance (300),
Policies & Documents (400), Organization (500), Audit Traceability (900).

### My Notification

```
My Notification            -> still opens the existing notifications inbox (page + parent, as 276)
  My Practices             -> '#'  placeholder, link to be supplied
  My Approvals             -> '#'  placeholder, link to be supplied
  My Acknowledgements      -> Practice/Index/my-acknowledgements (moved from Document Management, same link)
```

The unread-notification badge in `_Layout.cshtml` keys on
`data-menu-key="my-notifications"`, which is unchanged, so it now sits on
the parent item.

**When the My Practices / My Approvals links are known**, update
`menu_url` on the live rows **and** on the two tuples in
`274_menu_master_seed.sql` Section 1 — 274 re-asserts `menu_url`, so a
link set only in the database is reset to `#` on its next run.

## Why nothing breaks

- No `menu_key` or `menu_id` changed. Permission grants
  (`organization_role_menu_permission`), routes, active-menu highlighting
  and screen mapping all key on those.
- `module_type` was moved in step (`Oversight` -> `Issues & Actions`,
  `Audit Management` -> `Audit Assurance`, document rows ->
  `Policies & Documents`, notification rows -> `My Notification`) because
  the Role Permission matrix groups by it and the Web overlays it onto the
  page eyebrow.
- The two new rows get full rights for every active role in every active
  organisation (383's grant pattern).

## Files

| File | Change |
|---|---|
| `database/384_menu_renames_my_notification_and_policies_root.sql` (+ rollback) | the menu change |
| `database/274_menu_master_seed.sql` | snapshot carries 384; also now carries 363 (Control Statements) and 364 (Standards & Frameworks), which it had silently been reverting |
| `Models/PracticeScreen.cs` | page Titles (Home, Task Board, Gap Register, Exceptions & Waivers); `OversightGroup` = "Issues & Actions", `AuditManagementGroup` = "Audit Assurance"; new `PoliciesDocumentsGroup`, `MyNotificationGroup` used by the document and notification screens |
| `Controllers/PracticeController.cs` | the two new groups added to the `practice-management/{key}` allowed-group list |
| Partials / JS (19 files) | user-visible references to the old screen names ("Back to Gap Centre", "from Task Center", "... is not yet enabled", etc.) |

Not changed: code comments, the `_probe*.js` debug copies, and stored
remark text such as `'Closed from Gap Center 3-dot menu.'` (historical data).
No API, stored procedure or business data changed, so no API documentation
update was needed.

## Home route fix and "My work" on the Home page (migration 390, 2026-09-27)

### Home URL: /Practice/Index was 404

- **Cause.** The Home menu row had `menu_url = 'Practice/Index'`, which
  the menu tree emits literally. `Program.cs` registers
  `practice-management-home` (`Practice/{areaKey?}`) before the default
  route, so `/Practice/Index` bound `areaKey = "Index"`. `ShowArea("Index")`
  then found no screen and returned 404. Every other menu URL has three
  segments and reaches the default route, which is why only Home broke.
- **Data fix.** The Home row's `menu_url` becomes `dashboard` (in 390 and
  in 274). `_PracticeMenuTree.NormalizeMenuUrl` already maps that token to
  `Url.Action("Index","Practice")`, which is `/Practice`, the same URL
  sign-in lands on.
- **Routing fix.** `practice-management-home` now uses
  `Practice/{areaKey:regex(^(?!index$).+$)?}`. A typed or bookmarked
  `/Practice/Index` falls through to the default route and opens Home.
  `/Practice/<area>` and `/Practice/Index/<area>` behave as before.
- The Home item is now highlighted on the Home page. `_Layout` passes
  `CurrentArea = "dashboard"` there.

### "My" group becomes the Home page's My work

The Home page (`Views/Practice/Dashboard.cshtml`) opens with a personal
area above the unchanged organization overview. It has two parts:

- **Needs your attention.** One list, ordered danger > warning > info and
  then by due date. It is capped at 8 rows, with a footnote when there are
  more. A record reachable two ways (for example a task that is assigned
  to you and also has an unread alert) appears once. Every row has an
  Open link to the existing page for that record: task view, the
  Operationalize workspace, the approval queue, or My Acknowledgements.
- **My work summary.** One line per area, showing a count, a one-line
  status and a link to the existing detailed page.

| Area | Existing endpoint (unchanged) | "View all" goes to |
|---|---|---|
| Notifications | `task-notifications/me`, `/me/counts` (session recipient) | My Notifications |
| Tasks | `tasks?assignedToEmployeeId=<session>&statusCode=OpenSet` (+ `overdueOnly`) | Task Board |
| Practice instances | `workflow/resolve/instances?ownerEmployeeId=<session>` | Operationalize, pre-filtered with `?ownerEmployeeId=` (new, optional) |
| Approvals | `risk-centre/approval-queue` | Risk Management > Dashboard (approval queue) |
| Acknowledgements | `document-acknowledgements/my/batches` | My Acknowledgements |

- **Authorization.** `PracticeController.Dashboard` sets
  `ViewBag.HomeAccess` using the same
  `permissionPolicy.IsAllowed(..., ScreenPermissionArea(key), "VIEW")`
  check that guards each detailed page. Approvals needs `APPROVE` on
  Risk Centre. A section the caller cannot open is not rendered. The
  employee id always comes from the session, and server-side ownership
  and organization checks still apply.
- **Organization.** Notifications are personal. The other areas follow the
  Home page's existing Organization picker: `practice-dashboard.js`
  publishes it as the `pm:home-organization` event and
  `wwwroot/js/home-my-work.js` listens for it.
- **No new API or business logic.** Nothing was added beyond the optional
  Operationalize URL parameter.

### Sidebar: the My group is hidden, not deactivated

`menu_master.status` is both the sidebar filter and the permission filter:
`PracticeAuthenticationService` loads grants with `m.status = 'Active'`.
Setting the My rows `Inactive` would therefore have taken My Notifications
and My Acknowledgements away from every database user.

390 adds `menu_master.show_in_sidebar` (BIT, default 1) and sets it to 0
for `my-notifications` and its whole subtree, found recursively, so a
database-only child such as a My Tasks row is included. The effects are:

- The menu-master query returns `ShowInSidebar`. It is read through
  `sp_executesql`, so an API deployed before 390 still works.
- `PracticeMenuService.SidebarRows` drops hidden rows and everything below
  them, only when the sidebar tree is built.
- Status, grants, the Role Menu Permission matrix and every route are
  unchanged.
- The unread-notification badge moves to the Home item.

**Rollback.** Run `390_..._rollback.sql` and revert 390's edits in 274.

### Home layout revised (2026-09-28)

- **Row 1.** Organization overview cards on the left, with the My work
  summary beside them on the right.
- **Row 2.** "Needs your attention", full width.
- **Removed.** The organization-wide "Attention Required" list (the second
  result set of `dashboard-summary`) is no longer rendered on Home. It
  looked like a second, competing attention list. No SQL or API changed.
  `practice-dashboard.js` still null-guards that list, and a load failure
  is now reported on the overview cards.
- **No My work access.** A user with none of the My work areas sees the
  overview cards full width, and `home-my-work.js` stays idle.

### Home layout revised again (2026-09-28) - My work first, Overview scoped

This supersedes the row anatomy described just above.

- **My work is primary.** Row 1 is a two-column grid whose left
  ("primary") column stacks the My work summary above "Needs your
  attention"; the right column is the Overview. The organization-wide
  attention list stays removed. When the caller has no My work access the
  section is a plain wrapper and the Overview fills the width.
- **Overview panel (renamed).** The "Organization overview" heading is now
  just **Overview**. A collapse/expand control (the horizontal
  double-chevron `fa-angles-left` / `fa-angles-right`, styled like the
  mapping-tree toggles) sits to the left of the heading. It is **collapsed
  by default** on first load (`.pm-home-work.org-collapsed`,
  `aria-expanded="false"`).
- **Collapse changes width only.** The cards are never hidden, so the
  panel keeps its height; the toggle only switches the grid column widths.
  Expanded and collapsed are mirror states that share one strip width
  (`260-320px`): expanded gives the Overview the wide column (two-column
  cards) and shrinks My work to the strip; collapsed makes the Overview
  the strip and returns the full width to My work. Below `1180px` the row
  stacks to one full-width column as before. Toggle handled inline in
  `Dashboard.cshtml`; widths in `.pm-home-work` /
  `.pm-home-work.org-collapsed`.
- **Overview counts are scoped to the signed-in user (398).** The
  `dashboard-summary` counts report only data the caller owns, not the
  whole organization. Migration `398_overview_counts_user_scoped.sql`
  re-issues `dbo.pm_get_practice_repository` (live body from 393) and, in
  the `dashboard-summary` branch only, resolves `@p_usr_id` to an employee
  in the selected organization and scopes every count: organization
  controls by primary/secondary/backup owner name; practices by
  `practice_owner_id` / `practice_owner`; practice instances by
  `primary_owner_id` / primary / secondary owner; dependencies, evidence,
  the "instances without ..." counts and resolve items through the
  caller's own instances (`@MyInstance`), with resolve also counting items
  whose `resolution_owner_id` is the caller. An unmatched caller owns
  nothing, so all counts are 0. The org-wide attention result set below
  the counts is unchanged. No schema change; rollback re-issues the 393
  body. `practice-dashboard.js` is unchanged - it still POSTs
  `dashboard-summary` with `{ organizationId }` and binds `[data-summary]`.
- **Dependencies card.** The "Single Point" mini-metric was removed from
  the card in `Dashboard.cshtml`. The proc still returns
  `SinglePointDependencies` (now also user-scoped); it is simply not
  displayed.

### Home layout revised (2026-09-29) - two-column row, attention full width

Supersedes the row anatomy above.

- **Row 1** is a two-column grid: **My work** on the left, the **Overview**
  on the right. The Overview is **expanded by default** and lays its cards
  out **three across** so the panel stays short.
- **Row 2** is **Needs your attention**, full width, on its own below the
  grid (no longer stacked inside the left column).
- **Collapse** is unchanged in spirit: it narrows the Overview column
  (width only, cards stay visible and reflow to a single column) via
  `.pm-home-work.org-collapsed`; expanded and collapsed remain mirror
  states sharing one strip width (`260-320px`). My work is always the left
  column, the Overview always the right.
- Below `1180px` the row stacks to a single full-width column; with no My
  work access the Overview fills the width. No API/permission/calculation
  change - layout only.

- **Fixed equal height (2026-09-29).** On the desktop two-column row My work
  and the Overview share one fixed height (`430px`); each panel's body (the
  My work list, the Overview cards) scrolls internally rather than growing
  the row. This keeps the two cards the same height whatever data each
  holds, holds "Needs your attention" in place, and gives the Overview an
  internal scrollbar when collapsed to a single tall card column instead of
  stretching the page. Below `1180px` (stacked) the panels return to natural
  height.
