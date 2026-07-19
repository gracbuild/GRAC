# Origin-aware permission guards — developer notes

**Charter reference:** §12.1.6 (work item), §14 (RBAC matrix), §10 (roles)
**Migrations:** `040_origin_aware_permissions.sql`, `040_origin_aware_permissions_rollback.sql`
**Smoke test:** `database/deployment/07_UAT_Diagnostics_WorkflowLayer.sql`
**Backend:** `Api/Services/PermissionService.cs`, `Api/Controllers/PermissionsController.cs`, `Api/Infrastructure/PermissionServiceRegistration.cs`

---

## Model

Permission = **Role × Scope × Origin × Action → Verdict**.

- **Role** — from `organization_role.role_name` (Admin, ReleaseOwner, ControlOwner, PracticeOwner, InstanceOwner, GRAC_SYSTEM, …). Special value `ANY` matches every role in fallback rules.
- **Scope** — from `organization_role.data_scope` (GLOBAL, ORGANIZATION, RELEASE, STATEMENT, PRACTICE, INSTANCE). Special value `ANY`.
- **Origin** — from `origin_type_master.origin_code` (GRAC, Custom). Special value `ANY`.
- **Action** — string code (e.g. `RETIRE_CONTROL`, `MARK_NA`, `EDIT_TEMPLATE_SOP`, `HARD_DELETE`).
- **Verdict** — one of `Allowed`, `Denied`, `RequiresApproval`.

## Precedence

`fn_pm_can_mutate` picks the winning rule with the following ordering:

1. **Most-specific match** — fewer `ANY` wildcards wins.
2. **Priority** — lower `priority` number wins.
3. **Safety tiebreaker** — `Denied` beats `RequiresApproval` beats `Allowed` when specificity + priority tie.

Fallback deny rules (`ANY / ANY / ANY / {action} → Denied`) exist so an unknown action fails closed.

## Seeded matrix (charter §14)

| Role | Scope | Origin | Action | Verdict |
|---|---|---|---|---|
| Admin | GLOBAL | ANY | ANY | Allowed |
| ReleaseOwner | RELEASE | GRAC | RETIRE_CONTROL | Denied |
| ReleaseOwner | RELEASE | Custom | RETIRE_CONTROL | RequiresApproval |
| ControlOwner | STATEMENT | GRAC | MARK_NA | RequiresApproval |
| ControlOwner | STATEMENT | ANY | ASSIGN_PRACTICE_OWNER | Allowed |
| PracticeOwner | PRACTICE | GRAC | EDIT_TEMPLATE_SOP | Denied |
| PracticeOwner | PRACTICE | GRAC | EDIT_ADOPTION_SOP | Allowed |
| PracticeOwner | PRACTICE | Custom | RETIRE_PRACTICE | RequiresApproval |
| InstanceOwner | INSTANCE | ANY | UPLOAD_EVIDENCE | Allowed |
| ANY | ANY | GRAC | HARD_DELETE | Denied |
| GRAC_SYSTEM | ANY | ANY | CLOSE_AUTOMATIC_TICKET | Allowed |
| GRAC_SYSTEM | ANY | ANY | ASSIGN_TO_HUMAN | Denied |

## API

**POST `/api/practice/permissions/probe`**

```json
{
  "entityType": "Practice",
  "entityId": 34,
  "actorEmployeeId": 812,
  "originCode": "GRAC",
  "actionCode": "EDIT_TEMPLATE_SOP",
  "organizationId": 4
}
```

**Response**
```json
{
  "verdict": "Denied",
  "resolvedRole": "PracticeOwner",
  "resolvedScope": "PRACTICE",
  "origin": "GRAC",
  "action": "EDIT_TEMPLATE_SOP",
  "reason": "Denied by RBAC policy"
}
```

**Fail-closed** — network / DB / configuration errors always resolve to `Denied` at the controller and log at ERROR level.

## Program.cs wire-up (pending explicit approval)

Charter §5 lists Program.cs on the "never modify without an explicit request" list. This PR intentionally does not touch Program.cs. To activate the service, add one line under the other `AddScoped` calls:

```csharp
using PracticeManagement.Api.Infrastructure;
...
builder.Services.AddPracticePermissionService();
```

The extension method lives at `Api/Infrastructure/PermissionServiceRegistration.cs`.

## Gateway proxy (Wave 1 follow-up)

The Web-side gateway (`PracticeManagementGatewayController`) needs a proxy route for `permissions/probe`. That is intentionally out of scope for this PR to keep the diff small — it will land as a small companion PR once the DI wire-up is approved.

## Coexistence with existing owner columns

`repository_subscription.owner_id` and `custom_release_statement.owner_id` remain as denormalised caches per §12.1.4 coexistence rule. The RBAC rules above evaluate against `organization_role.data_scope` (which drives Scope) — no change to existing owner-column behaviour.

## Unit tests (deferred pending Api.Tests project)

Scenarios to codify when the Api.Tests project is introduced during §12.1.3:

1. Admin/GLOBAL/ANY/ANY → Allowed for arbitrary action.
2. PracticeOwner/PRACTICE/GRAC/EDIT_TEMPLATE_SOP → Denied.
3. PracticeOwner/PRACTICE/GRAC/EDIT_ADOPTION_SOP → Allowed.
4. GRAC_SYSTEM/ANY/ANY/ASSIGN_TO_HUMAN → Denied.
5. Unknown role + fallback deny → Denied.
6. Fail-closed on DB error → controller returns Denied.
