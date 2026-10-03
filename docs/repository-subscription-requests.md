# Repository Subscription Requests

**Screens:**
- Practice Management: *Governance → Standards & Frameworks* (`organization-controls`) → **Add Release**
- Control Management: *Repository Management → Subscription Requests* (`subscription-requests`)

**Migrations:**
- PracticeManagement `406_repository_subscription_requests.sql` (+ rollback)
- ControlManagement `068_subscription_requests.sql` (+ rollback)

**Run order:** PM 406 first, then CM 068. Roll back in the reverse order.

---

## Business flow

```
Organization → Add Release → Subscribe from Repository → Request
   → Pending → Control Management (Subscription Requests) → Approve / Reject

Approve → organization subscription created / re-activated → "Subscribed"
Reject  → request Rejected (reason kept) → no subscription
```

## 1. Add Release (Practice Management)

The Add Release dialog now has two tabs. **Edit Release** is unchanged and has no tabs.

| Tab | What it does |
| --- | --- |
| **Custom Release** | The existing custom release form, unchanged: same fields, same `custom-release` save, same Save button. |
| **Subscribe from Repository** | Lists the Repository releases with the selected organization's state for each. The Save button is hidden on this tab; a release that is not subscribed shows its own **Request** button. |

Columns: Release / Framework, Release Code, Version, Source / Publisher, Release Status, Subscription. There is no separate Action column: the Subscription cell shows either the state or the **Request** button.

While it shows these tabs, the dialog is wider and taller (`dialog.pm-dialog-add-release`: `min(1280px, 96vw)` wide, up to `94vh` tall) so the list fits without scrolling. The class is removed on close, so every other form keeps the default size. Inside it, long framework and publisher names wrap in their cells, so the table never scrolls sideways; the Release Status and Subscription cells stay on one line.

| Subscription cell | Meaning |
| --- | --- |
| **Subscribed** badge | An active `repository_subscription` exists |
| **Request Pending** badge | An open request exists |
| **Rejected** badge + **Request** button | The latest request was rejected (the badge tooltip shows the reason); the organization can ask again |
| **Request** button | Not subscribed and no open request |

**Organization context.** The organization is the one selected in the toolbar filter when the dialog opens (the same value Add Release already used). The list is re-read every time the tab is opened, so a different organization always shows its own states.

**Eligible releases.** The same rule Organization Setup's subscription tree uses (`pm_get_practice_repository` `'repository-subscription-tree'`):
- authority `Active`
- artifact `Active`
- release `Draft` or `Active`

`Retired` releases and inactive authorities or artifacts are never listed. Each release appears once (keyed by `release_id`).

## 2. Subscription Requests (Control Management)

The grid follows the generic Repository grid, with the Status filter set to Pending / Approved / Rejected. Pending requests sort first.

Columns: Organization, Release / Framework, Release Code / Version, Requested By, Request Date, Status, Approved / Rejected By, Decision Date.

**3-dots menu:**

| Request status | Actions |
| --- | --- |
| Pending | View Subscription Request, **Approve** (comments optional), **Reject** (reason mandatory) |
| Approved / Rejected | View Subscription Request only |

There is no Add, Edit or Inactive. Requests are raised only by organizations and are never deleted.

## 3. Data model — `grac_practice.repository_subscription_request`

| Column | Notes |
| --- | --- |
| `request_id` | PK |
| `organization_id` | FK `organization` |
| `authority_id`, `artifact_id`, `release_id` | Repository release (from `grac_new`) |
| `request_status` | `Pending` / `Approved` / `Rejected` (CHECK). The same vocabulary as `organization_repository_change` (395). |
| `requested_by` | Login (session subject) |
| `requested_by_employee_id` | Set only when the login is an employee of that organization |
| `requested_dt` | UTC |
| `decided_by`, `decided_dt`, `decision_remark` | Control Management login, time and remark or reason |
| `subscription_id` | The subscription the approval created, re-activated or found |
| `entered_*`, `updated_*` | Audit columns |

**Indexes:**
- `ux_pm_repo_sub_request_pending`: unique on `(organization_id, release_id) WHERE request_status = 'Pending'`. This blocks duplicate pending requests at the database level, including two clicks at the same moment.
- `ix_pm_repo_sub_request_status` on `(request_status, requested_dt)`.

**Why a separate table.** `repository_subscription` is the subscription itself: one row per organization and release, re-activated in place by Organization Setup and read by every governance screen. It has no requester, decision or reason, and it cannot hold history. A rejected request can be asked again, and the history must remain. `subscription_status_master` (Active / Disabled / Superseded / Pending Review) describes a subscription, not a request, so it is not reused.

Every submit, approve and reject writes a `practice_audit_trace` row (entity type `repository-subscription-requests`).

## 4. Procedures

| Procedure | Caller | Purpose |
| --- | --- | --- |
| `grac_practice.sp_repository_subscription_request_get` | PM gateway shim (query) | Eligible releases plus the organization's state, `CanRequest` and the latest request |
| `grac_practice.sp_repository_subscription_request_manage` | PM gateway shim (SAVE) | Submit a Pending request |
| `grac_practice.sp_repository_subscription_request_list` | CM `cm_get_subscription_request` | All requests (`@request_id`, `@status`, `@search`) |
| `grac_practice.sp_repository_subscription_request_decide` | CM `cm_manage_subscription_request` | Approve or Reject one request |
| `dbo.cm_get_subscription_request` | CM API | Thin dispatcher. Adds the decider's `cm_user.user_name`. |
| `dbo.cm_manage_subscription_request` | CM API | Thin dispatcher: APPROVE / REJECT only |

**Approve reuses the existing subscribe path.** It does not reimplement it. `sp_repository_subscription_request_decide`:
1. Locks the request (`UPDLOCK, HOLDLOCK`) and refuses it unless it is Pending (51414).
2. Re-checks that the organization is active (51415) and the release is still eligible (51416).
3. If an active subscription already exists, it links that subscription. No duplicate is created.
4. Otherwise it calls `dbo.pm_manage_practice_repository 'repository-subscriptions' SAVE`, the existing single-subscription path. That path:
   - re-activates the organization's latest row for the release (`@p_id` = that row) or inserts a new one (`@p_id = 0`, type `Repository`);
   - copies the release (`sp_repository_subscription_copy`);
   - creates the organization controls.
5. Marks the request Approved with the `subscription_id`, then writes the audit row. All of this runs in one transaction.

`_security.isSystemAdmin` is set on that inner call by the procedure itself, server-side. Control Management is not an organization user, and its right to approve was already checked by the CM API (`subscription-requests:APPROVE`). The inner call returns its own one-row result before the procedure's final row.

**Reject:**
- Requires a reason (51412; the CM validator also requires `comments`).
- Sets the request to Rejected and creates nothing.

### Error codes

| Code | Message |
| --- | --- |
| 51401 | Please select an organization first. |
| 51402 / 51403 | Only a new request can be submitted / a submitted request cannot be changed |
| 51404 | Organization not active |
| 51405 | Release required |
| 51406 | Release not available for subscription |
| 51407 | Already subscribed |
| 51408 | A request is already pending |
| 51410 | CM: only Approve / Reject |
| 51411 | Decision must be Approve or Reject |
| 51412 | Reject reason required |
| 51413 | Request not found |
| 51414 | Already decided |
| 51415 | Organization no longer active |
| 51416 | Release no longer available |
| 51417 | Subscription could not be activated |

The PM API shows the 51xxx messages as they are (application validation block). The CM API maps 51410–51417 in `RegulatoryRepositoryService`.

## 5. API

### Practice Management (secure gateway; entity `repository-subscription-requests`)

| Method | Web route | Body | Permission |
| --- | --- | --- | --- |
| POST | `/practice-management-gateway/repository-subscription-requests/query` | `{ data: { organizationId } }` | `organization-controls:VIEW` |
| POST | `/practice-management-gateway/repository-subscription-requests` | `{ id: 0, data: { organizationId, releaseId } }` | `organization-controls:ADD` (the Add Release permission) |

**Wiring:**
- `PermissionAreaMap` maps the entity to `organization-controls`.
- It is in the Web tier's organization-scoped list, so the requested organization must be one of the caller's.
- The API checks organization access (`HasOrganizationAccessAsync`) and refuses employee (non-admin) scope, exactly as for `custom-release`.
- `ResolveProcedureAsync` routes query to `sp_repository_subscription_request_get` and manage to `sp_repository_subscription_request_manage`.

**Query response row:**
- `AuthorityCode`, `AuthorityName`, `ArtifactCode`, `ArtifactName`
- `ReleaseId`, `ReleaseVersion`, `ReleaseStatus`, `EffectiveDate`, `EndDate`
- `SubscriptionId`, `SubscriptionState`, `CanRequest`
- `RequestId`, `RequestStatus`, `RequestedBy`, `RequestedDate`, `DecisionDate`, `DecisionRemark`

### Control Management (entity `subscription-requests`)

| Method | Web route | Body | Permission |
| --- | --- | --- | --- |
| GET | `/control-management-gateway/subscription-requests?status=&search=` | — | `subscription-requests:VIEW` |
| GET | `/control-management-gateway/subscription-requests?id={id}` | — | `subscription-requests:VIEW` |
| POST | `/control-management-gateway/subscription-requests/{id}/approve` | `{ comments }` (optional) | `subscription-requests:APPROVE` |
| POST | `/control-management-gateway/subscription-requests/{id}/reject` | `{ comments }` (mandatory) | `subscription-requests:REJECT` |

**List row:**
- `Id`, `OrganizationId`, `Organization`, `OrganizationCode`
- `Release`, `ReleaseCode`, `ArtifactCode`, `ArtifactName`, `ReleaseId`, `ReleaseVersion`, `ReleaseStatus`, `Publisher`
- `RequestedBy`, `RequestedByLogin`, `RequestDate`
- `Status`, `DecidedBy`, `DecisionDate`, `DecisionRemark`, `SubscriptionId`

## 6. Menu and permissions (CM 068)

The `cm_menu` row `subscription-requests` sits under Repository Management, display order 305. The parent is taken from the Releases menu's own parent, not a fixed code: 005 seeds it as `control-management`, but a database with re-organised menus can carry another code (for example `repository-management`). It uses the 043 / 059 pattern.

| Role | View | Approve / Reject |
| --- | --- | --- |
| CM_ADMIN | ✔ | ✔ |
| CM_APPROVER | ✔ | ✔ |
| CM_REVIEWER | ✔ | — |
| CM_USER | ✔ | — |

`can_add`, `can_edit` and `can_inactive` are 0. `can_approve` grants both APPROVE and REJECT (`AuthService.LoadPermissionsAsync`). The legacy `security_permission` rows are seeded the same way. The `reference_option` group `status-subscription-request` feeds the Status filter.

## 7. Files changed

**Practice Management**
- `database/406_repository_subscription_requests.sql` (+ rollback)
- `src/PracticeManagement.Api/Controllers/PracticeRepositoryController.cs`: entity in `Supported`
- `src/PracticeManagement.Api/Services/PracticeRepositoryService.cs`: shim routing; employee-scope write guard
- `src/PracticeManagement.Web/Security/PermissionAreaMap.cs`: governed by `organization-controls`
- `src/PracticeManagement.Web/Controllers/PracticeManagementGatewayController.cs`: organization-scoped entity
- `src/PracticeManagement.Web/wwwroot/js/practice.js`:
  - `openCustomReleaseForm` (Add gets tabs; Edit is unchanged)
  - `addReleaseTabsMarkup`, `wireAddReleaseTabs`
  - `loadAddReleaseRepository`, `renderAddReleaseRepository`, `requestRepositorySubscription`

**Control Management**
- `database/068_subscription_requests.sql` (+ rollback)
- `src/ControlManagement.Api/Controllers/RepositoryController.cs`: entity in `Supported`
- `src/ControlManagement.Api/Services/RegulatoryRepositoryService.cs`: dispatcher routing; 51410–51417 messages
- `src/ControlManagement.Web/Models/RepositoryScreen.cs`: screen
- `src/ControlManagement.Web/Views/Repository/Manage.cshtml`: column headers; no Add button
- `src/ControlManagement.Web/wwwroot/js/repository.js`:
  - schema, labels, read-only
  - Status filter group
  - 3-dots menu (Approve / Reject only while Pending)
  - approve dialog title
  - `Pending` badge tone

## 8. Deployment notes

- The PM API caches whether a shim procedure exists (`ShimAvailability`). Restart the PM API after running 406, or the first probe made before the migration keeps answering "not there".
- Restart the CM API and Web after 068 (new screen and entity), and sign out and back in to Control Management so the new menu permission is loaded into the session.

## 9. Test checklist

1. **Add Release shows two tabs.** Custom Release saves exactly as before. Edit Release has no tabs.
2. **The Subscribe tab lists Repository releases.** A release that Organization Setup subscribed shows **Subscribed** with no button.
3. **Request.** The row turns to **Request Pending**. Requesting again, or from a second browser, is refused with "already pending".
4. **Switch organization and reopen.** Organization B shows its own state for the same release.
5. **Control Management → Subscription Requests** lists the request as Pending. Approve and Reject appear only on Pending rows and only for CM_ADMIN / CM_APPROVER.
6. **Approve.** In PM, the release now shows **Subscribed** and appears in Standards & Frameworks with its statements and controls. Nothing is duplicated in `repository_subscription`.
7. **Reject (with a reason).** PM shows **Rejected**, with the reason on hover, and **Request** is offered again. No subscription is created. The rejected row stays in the CM list.
8. **Employee-scope user** (non-admin role): Add Release is hidden, and a direct POST is refused.
