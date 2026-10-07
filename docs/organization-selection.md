# Organization dropdown: order and remembered choice (2026-10-06)

**Request:** an admin who can see several organizations landed on a
different organization on every page. Organizations must be listed in
organization-id order, the default must be the same everywhere, and an
organization picked on one page must stay selected on every page until
another is picked.

## Behaviour

- Every Organization dropdown lists organizations by `organization_id`.
- Default = the organization the user last **picked** on any page
  (browser `localStorage`, key `grac.practice.selectedOrganizationId`,
  the key the generic screens in `practice.js` already used); with nothing
  remembered, or when it is not in the user's list, the lowest id.
- Only the user's own change is remembered. A page that sets the
  organization itself -- `?organizationId=` / `?orgId=`, a dashboard
  drill-down, a record's own organization (`definitionId`), a navigation
  code -- still wins on that page and does not replace the remembered one.
- "All organizations" (filters on generic screens and the Assurance
  Calendar) is not an organization: those filters still open on "All", and
  choosing "All" does not clear the remembered organization.

## Implementation

| Piece | Change |
|---|---|
| `wwwroot/js/Shared/org-preference.js` (new) | `window.gracOrgPref`: `apply(select)` (sort by id, pick preferred, remember later user changes), `preferred(values, select)`, `sort(list)`, `watch(select)`, `get/save`. A capture-phase `change` listener saves trusted changes on watched selects. |
| `Views/Shared/_Layout.cshtml` | loads it in `<head>` (before partial inline scripts) |
| `_workflow-common.cshtml` | `loadOrgs()` sorted by id; `populateOrgSelect()` uses `apply` -- covers workflow, event, resolve, event-profile, asset-category-assurance, definitions, plans, question-set pages |
| `gaps.cshtml`, `tasks.cshtml` | `apply` instead of first org |
| 8 org-assurance pages (evidence, executions, observations, scope builder / resolution, scoring, triggers, workflow config) | `preferred(...)` instead of `orgs[0]` |
| Asset & Contract pages (14 `AssetConfig/*.js`), document acknowledgements (2), document uploads, Exception Centre, management dashboards, org SLA config, risk acceptance authority, Risk Centre | `apply` instead of `selectedIndex = 1`; Risk Centre watches all six `.risk-org-filter` selects |
| `practice.js` | lookups organizations sorted by id; the remembered org now applies on Standards & Frameworks / Control Applicability / Control Statements too; "All" no longer clears it; the "switch to another organization when the grid is empty" fallback is removed (it overrode the user's choice) |
| `practice-dashboard.js` (Home) | sorted, remembered default |
| `practice-calendar.js` | sorted; a pick is remembered; still opens on "All" |
| API `OrganizationAccessService.ListAllowedAsync` | `ORDER BY organization_id` (was name) -- `GET /practice/api/organizations/allowed` |

Not changed: the Audit flow shell (`_audit-flow-shell.cshtml`) keeps its
"Select an organization..." prompt by design (one org is preselected only
when the user has exactly one). No database change: the lookups procedure
is unchanged and the client sorts its organizations.
