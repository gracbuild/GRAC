# User credentials — developer notes

How a user account gets its first password, and how the system stops that
password being used indefinitely.

**Migrations:** `208_default_password_provisioning.sql` / `208_..._rollback.sql`,
on top of `032_ownership_role_model.sql` (the `force_password_change` column)
and `133_org_party_and_team_type.sql` (`sp_org_user_save` / `sp_org_user_list`).
**Backend:** `Web/Controllers/PracticeManagementGatewayController.cs`,
`Web/Controllers/LoginController.cs`, `Web/Services/PracticeLoginService.cs`
(API client), `Web/Security/PasswordHasher.cs` (linked into the API),
`Api/Controllers/PracticeRepositoryController.cs` (secure/authenticate,
secure/set-password), `Api/Services/PracticeAuthenticationService.cs`,
`Api/Services/PracticeRepositoryService.cs`
**UI:** `Web/wwwroot/js/practice.js` (Users form + grid),
`Web/Views/Login/ChangePassword.cshtml`

---

## Sign-in goes through the API

The database is reached **only** through the API. Sign-in is no part of an
exception to that: the Web tier holds no connection string and opens no SQL
connection. `PracticeLoginService` is an API client.

```
Browser → LoginController → PracticeLoginService → SecurePracticeClient
        → API secure/authenticate → PracticeAuthenticationService → SQL Server
```

The verification SQL (the sign-in SELECT, permission/allowed-org/data-scope
loads, `PasswordHasher.Verify`, and the set-password call) lives in
`Api/Services/PracticeAuthenticationService.cs`. `PasswordHasher` is authored
once in `Web/Security/PasswordHasher.cs` and **linked** into the API project
(`<Compile Include=... Link=...>`), so one source file compiles into both
assemblies — no duplicate security code.

### The bootstrap problem

The API's secure endpoints require a validly-signed token, but sign-in happens
*before* a user session (and its token) exists. So the Web tier mints a
short-lived token carrying a single role, **PM_LOGIN**, purely to authenticate
the transport and key the request envelope. PM_LOGIN is deliberately absent
from `Security:RolePermissions`, so `PermissionPolicy.IsAllowed` returns false
for every area — the bootstrap token is inert on `secure/manage` and
`secure/query` and can do nothing but authenticate. `secure/authenticate` and
`secure/set-password` require only a valid token, not a permission, because
authenticating is the step before permissions apply.

This requires `Security:TokenSigningKey` to match between the Web and API
tiers — which it already must, since every data call depends on the same
shared key. The failure-reason logging (no row / no hash / password mismatch,
with the creation stamp) now happens in `PracticeAuthenticationService` on the
API side.

---

## The defect this replaced

Adding a user failed with:

```
The practice database operation failed. SQL error 51152. Reference: <guid>
```

51152 is `sp_org_user_save`'s own `THROW` — *"Password is required when
creating a User / Employee."* The Users form declared Password as optional
(`password("password","Password")` — the helper defaults `required = false`),
and the gateway only produced a `passwordHash` when a non-blank password was
present. An empty box therefore produced a payload with no hash, and the
create hit the `THROW`. Edits were unaffected: the rule is guarded by
`@p_id = 0`.

Two things were wrong, and both are fixed:

1. The form and the procedure disagreed about whether a password was required.
2. The message explaining exactly what to fix was thrown away by the API
   before it reached the user (see [Error surfacing](#error-surfacing)).

## The model

Nobody types another person's password into a form. The Password field is
gone from the Users screen entirely.

| Step | Where | What happens |
| --- | --- | --- |
| 1. Create user | `PracticeManagementGatewayController.HashSensitivePayloadFields` | No password in the payload and `action == "ADD"` → hash `UserProvisioning:DefaultPassword`, set `forcePasswordChange = 1` |
| 2. Store | `sp_org_user_save` | Writes `password_hash` and `force_password_change` |
| 3. First sign-in | `LoginController.Index` | Credentials verified, then `RequiresPasswordChange` → **no session**, render `ChangePassword` |
| 4. Change | `LoginController.ChangePassword` | Re-verifies the current password, calls `sp_org_user_set_password`, then signs in |
| 5. Later sign-ins | `LoginController.Index` | `force_password_change` is 0 → normal session |

The plaintext default never leaves the Web tier. `PasswordHasher` (PBKDF2-SHA256,
210k iterations, `iterations.salt.hash`) runs there, and only the hash reaches
the API and the database — the same arrangement migration 034 already used for
the auto-provisioned organisation admin OTP.

### Why the hash is not generated in SQL

T-SQL cannot produce a value `PasswordHasher.Verify` will accept. Defaulting
the password inside `sp_org_user_save` would mean reimplementing PBKDF2 in the
database and keeping the two in step forever. `THROW 51152` is therefore
**kept** as a backstop for callers that reach the procedure directly.

> **Deploy order:** ship `PracticeManagement.Web` together with migration 208.
> The migration alone does not fix the defect — the gateway change is what
> stops the payload arriving without a hash.

### Why two signals decide a forced change

`RequiresPasswordChange` fires on either:

* `force_password_change = 1` — set by provisioning (208, and 034 for org admins); or
* the supplied password equalling `UserProvisioning:DefaultPassword`.

The flag alone would miss accounts created before 208 existed. The comparison
alone would miss an admin-initiated reset that deliberately sets the flag
without using the default string. Neither is redundant.

## Configuration

```jsonc
"UserProvisioning": {
  "DefaultPassword": "Grac@123",
  "MinimumPasswordLength": 8
}
```

`DefaultPassword` is required — user creation throws
`InvalidOperationException` if it is blank, rather than provisioning an
account with an empty password. Override it per deployment.

**Symptom when it is missing on a deployed tier:** `POST
practice-management-gateway/users` answers **HTTP 500** and the Users form
reports "The practice service returned an invalid response". The 500 comes
from the Web tier, not the API or the database — every API- and SP-side
failure on this route surfaces as 502 with a JSON message, because
`SecurePracticeClient` wraps them in `PracticeApiException`. A 500 here
therefore always means an unhandled Web-tier exception before the API call.
`Save` now catches this one and returns
`{ success: false, message: "UserProvisioning:DefaultPassword is not
configured. …" }`, so the screen names the missing setting instead of
showing a blank failure. Fix is a config edit plus an app-pool recycle —
no migration, no schema change.

The change-password screen rejects a new password that is shorter than
`MinimumPasswordLength`, identical to the current one, or equal to the
configured default.

## API contract

### `POST secure/manage`, `entityType: "users"`

| Key | Direction | Notes |
| --- | --- | --- |
| `password` | in | **No longer sent by the browser.** Still honoured if a non-browser caller supplies it — the gateway hashes it and drops the plaintext key |
| `passwordHash` | in | Produced by the gateway. Required on create (`THROW 51152` otherwise); on edit an absent hash leaves the stored one alone |
| `forcePasswordChange` | in | `1` on gateway-provisioned creates. Absent means "no opinion": create defaults to 1, edit leaves the existing flag untouched |
| `ForcePasswordChange` | out | `sp_org_user_list`, bit |
| `CredentialStatus` | out | `sp_org_user_list`, `Default password` / `Password set`. Rendered as a Users grid column |

An ordinary edit — changing a role, a location, a reporting officer — must
not clear a pending forced change, which is why an absent
`forcePasswordChange` is `COALESCE`d to the existing value rather than to 0.

### `grac_practice.sp_org_user_set_password`

```
@employee_id   BIGINT
@password_hash NVARCHAR(500)
@entered_by    NVARCHAR(100) = N'system'
```

Sets `password_hash`, clears `force_password_change`, returns
`Success, EmployeeId`. Throws 52320 (no user), 52321 (no hash), 52322
(inactive account).

It exists instead of routing the change through the users entity save because
the caller holds **no session** — `LoginController` blocks the session until
the change completes. The entity save would have handed a pre-session caller
the organisation, role and personnel-type rewriting that comes with it. This
procedure can only touch two columns of one row.

It does not verify the old password; `LoginController` has already done so via
`PracticeLoginService.AuthenticateAsync`. It does refuse to act on an inactive
employee, so a disabled account cannot be revived through the change-password
screen.

## Error surfacing

`PracticeRepositoryService` passed application `THROW`s through to the user
only for codes **51010–51099**. Every role, menu-permission and user code
(51100–51152) and everything migrations 133 and 208 added (52300–52322) fell
past it into the generic handler, which replaced a written explanation with
`"SQL error 51152. Reference: <guid>"`.

The window is now **51000–52999** — the application block. 53xxx stays
outside it deliberately: those messages are internal invariants
(`"pm_create_organization_admin: ..."`) not written for an end user.

`PracticeRepositoryResult` gained an optional `Field`, populated from
`ValidationFieldFor(entityType, sqlErrorNumber)`. The map is keyed on entity
type as well as code because the monolith reuses numbers — 51140/51141/51142
mean Organization / Role Name / duplicate Role Name for **roles**, and
Organization / Process Name / Process Owner for **processes**. `fetchJson`
attaches it to the thrown error and `showFormError` marks that input.

An unmapped code returns `null` and the message shows at form level, exactly
as before — a missing mapping degrades presentation, never correctness. 51152
is deliberately unmapped: the Users form has no password input to mark, and
reaching it now means the gateway was bypassed or is out of date.

## Operations

Accounts still holding the default are listed by migration 208 on deploy, and
visible in the Users grid under **Credential Status**:

```sql
SELECT organization_id, employee_code, employee_name, email, status
  FROM grac_practice.organization_employee
 WHERE ISNULL(force_password_change, 0) = 1
 ORDER BY organization_id, employee_name;
```

The existing **Resend credentials** row action is unchanged — it re-runs the
org-admin OTP provisioning in `PracticeManagementGatewayController`, which
sets `force_password_change = 1` and therefore lands the recipient on the
same change-password screen.

## Rollback

`208_default_password_provisioning_rollback.sql` restores `sp_org_user_save`
and `sp_org_user_list` to their 133 definitions and drops
`sp_org_user_set_password`. **Revert the Web tier first** — after the rollback
the create path requires `$.passwordHash` again, so a build that no longer
collects a password fails every user create with SQL error 51152.

`force_password_change` values are left alone: the column belongs to 032 and
034 writes it independently, so clearing it here would also drop pending
changes for org admins. Users created under 208 keep the flag set but nothing
reads it once the Web tier is reverted — the rollback script reports them so
their passwords can be reset by hand.
