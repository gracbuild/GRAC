# Single sign-on -- Microsoft Entra ID and Google (2026-10-12)

The login page offers **Sign in with Microsoft** and **Sign in with Google**
beside the existing User ID / password form. Decisions (2026-10-12):

| Question | Decision |
| --- | --- |
| Providers | Microsoft Entra ID + Google, OpenID Connect |
| Tenant | ~~One tenant in appsettings~~ -> **organization-wise** (2026-10-13, migration 466): one multi-tenant app registration per provider in appsettings; each organization's tenant / domains / login mode in the database |
| Unknown person | Blocked. Only an active GRAC employee whose **email** matches can sign in; no account is created |

Password sign-in, ReviewLogin and the forced password change are unchanged,
except that an organization set to **SSO Only** cannot use the password form.

## Organization-wise policy (migration 466, 2026-10-13)

App credentials (ClientId / ClientSecret) stay in configuration -- secrets
never go in the database. Which people may sign in how is per organization,
in `grac_practice.organization_sso_setting` (no row = SSO off), edited at
**Organization Administration -> Organization tab -> Single Sign-On** and saved
by the card's own **Save** (shown with the screen's ADD or EDIT grant; without
it the fields are read-only). Moved there from Organization Setup on
2026-10-13 so each organization's admin manages its own sign-in policy:

(The card is hidden only for a caller without `organization-administration:VIEW`; any
other load failure -- 466 not run, API not redeployed -- is shown inside the
card.)

| Field | Column | Rule |
| --- | --- | --- |
| Enable Single Sign-On | `sso_enabled` | off = no SSO sign-in for this organization's employees |
| Login Mode | `login_mode` | `SSO_AND_PASSWORD` (default) or `SSO_ONLY` (password form refused; needs SSO enabled) |
| Allowed Sign-in Providers | `allow_microsoft`, `allow_google` | at least one when enabled |
| Microsoft Tenant ID(s) | `microsoft_tenant_ids` | required for Microsoft; GUIDs, comma separated |
| Allowed Email Domains | `allowed_email_domains` | required for Google (Google has no tenant); optional extra check for Microsoft |

Lists are stored trimmed, lower-case, de-duplicated. Every save is audited in
`practice_audit_trace` (`entity_type = 'organization-sso-setting'`,
`CREATE`/`UPDATE`, before/after JSON).

**Enforced at sign-in by the API** (`PracticeAuthenticationService`), against
the organization of the employee the email matched:

* SSO: SSO enabled, provider allowed, Microsoft token `tid` in the tenant
  list, email domain in the domain list (when set). Otherwise
  `/Login?sso=notallowed` -- "Single sign-on with this account is not enabled
  for your organization."
* Password: when the organization is SSO enabled + `SSO_ONLY`, a **correct**
  password is refused with "Your organization signs in with single sign-on"
  (the wrong-password message is unchanged, so this reveals nothing to someone
  without the password). The API returns `Field = "sso-required"`.
* The configured ReviewLogin admin is not an employee sign-in and is never
  held to an organization's policy, so a mis-configured organization can
  always be corrected.
* 466 not applied / no row: every SSO sign-in is refused, password sign-in as
  before.

**Deploy:** run `database/466_organization_sso_settings.sql`, deploy API +
Web, then enable SSO per organization in Organization Administration. SSO users of the
earlier single-tenant setup cannot sign in by SSO until their organization's
policy is saved (with that tenant id).

**Card only when SSO is configured (2026-11-15).** The Single Sign-On card is
rendered only when this deployment has at least one provider configured --
`Sso:Microsoft` or `Sso:Google` with both `ClientId` and `ClientSecret` set
(`SsoProviders.Enabled`, the same test the login page and `Program.cs` use).
With no `Sso` section (single sign-on is on hold) the card does not appear;
`Manage.cshtml` decides it at render time and `practice.js` already skips the
card when it is absent. An organization's saved policy is kept either way.

## Auto-create users on first SSO sign-in (migration 467, 2026-10-13)

Three more settings on the same Single Sign-On card:

| Field | Column | Rule |
| --- | --- | --- |
| Auto-create Users on First SSO Sign-in | `auto_create_users` | needs SSO enabled |
| Default Role for New Users | `default_role_id` | required when auto-create is on; an active role of the organization |
| Admin Approval Before Activation | `require_admin_approval` | default **on**; on = created as *Pending Approval*, off = created Active and signed straight in |

With auto-create on, a tenant id / email domain may not also be used by
another auto-create organization (save error 57472), so a new person always
matches exactly one organization.

**Flow** (`PracticeAuthenticationService.AuthenticateExternalAsync`): the IdP
vouched for the person, the policy checks pass, but no **active** employee has
the email -> `sp_org_sso_provision_user`:

* an employee with that email exists but is not active -> stays blocked
  (`?sso=notfound`); one still *Pending Approval* -> `?sso=pending`;
* the one organization whose policy accepts provider + tenant (Microsoft) +
  domain (always for Google, when set for Microsoft) gets a new employee:
  name = token `name` (else given + family name, else the email's local
  part), email, employee code = the email's local part (`-2`, `-3`... when
  taken), the default role, `party_type` Employee, **no password**
  (`password_hash` NULL, so password sign-in is impossible),
  `force_password_change` 0, plus the `user_organization_map` row
  `sp_org_user_save` also writes; audit `practice_audit_trace`
  `entity_type = 'sso-provision'`, `CREATE`;
* approval required -> status `Pending Approval` (record status Inactive, so
  every Active-only lookup, owner picker and sign-in ignores the user) and the
  login page says "Your GRAC account has been created and is waiting for
  administrator approval" (`Field = sso-pending`);
* auto approve -> status Active and the person is signed in at once.

Department, location, designation are not in the token; the admin fills
them through the Users form (Department is required there, as for every
user).

**Approve / reject:** Organization Administration -> Users tab. A *Pending
Approval* row (Status column; Credential Status shows *Single sign-on*) gets
an **Approve** row action (organization-administration ADD/EDIT) ->
`sp_org_sso_user_approve` -> Active, audited `sso-provision` / `APPROVE`.
Reject = the existing **Inactive** action; an inactive user is never created
again by SSO.

API: `POST /practice/api/org-sso/approve-user { organizationId, employeeId }`
(Web proxy, same guard as save) -> `POST /api/practice/org-sso/approve-user`.
The save body / GET response also carry `autoCreateUsers`, `defaultRoleId`,
(`defaultRoleName` on GET) and `requireAdminApproval`.
`secure/authenticate-external` Data also carries `displayName`.

Migration: `database/467_sso_user_auto_provisioning.sql` (+ rollback). It also
re-issues `sp_org_user_list` (341 body) so Status shows *Pending Approval* and
Credential Status *Single sign-on*.

### Settings API

| Tier | Route | Guard |
| --- | --- | --- |
| Web | `GET /practice/api/org-sso?organizationId=` | session, organization allowed, `organization-administration:VIEW` |
| Web | `POST /practice/api/org-sso` | session, organization allowed, `organization-administration:ADD` or `EDIT` |
| API | `GET /api/practice/org-sso?organizationId=` -> `sp_org_sso_setting_get` | |
| API | `POST /api/practice/org-sso` -> `sp_org_sso_setting_save` | errors 57466-57469 returned as `{ error }` (400) |

POST body / GET response:

```json
{ "organizationId": 10, "ssoEnabled": true, "allowMicrosoft": true, "allowGoogle": false,
  "microsoftTenantIds": "00000000-0000-0000-0000-000000000000",
  "allowedEmailDomains": "client.com", "loginMode": "SSO_AND_PASSWORD" }
```
(GET also returns `updatedBy`, `updatedDt`; POST returns `{ success, error, saved }`.)

`secure/authenticate-external` Data now also carries `tenantId` (the token's
`tid`); a policy refusal returns `Success = false, Field = "sso-not-allowed"`.

## Flow

1. `GET /Login/External?provider=Microsoft|Google[&returnUrl=]` (button on the
   login page) -> OpenID Connect challenge to the provider.
2. Provider -> `GET /signin-oidc-microsoft` or `/signin-oidc-google`
   (authorization code + PKCE, `response_mode=query`). The handler stores the
   provider's answer in a short-lived cookie `.PracticeManagement.External`
   (scheme `PracticeManagement.External`, SameSite=Lax, 5 min) and redirects to
3. `GET /Login/ExternalCallback` (`LoginController`):
   * reads and deletes the external cookie;
   * email = Google: `email` only when `email_verified` is true;
     Microsoft: `email`, else `preferred_username`, else `upn`;
   * API `secure/authenticate-external` { email, provider, subject, tenantId } ->
     `PracticeAuthenticationService.AuthenticateExternalAsync`: the same
     sign-in body as a password sign-in (roles, permissions, allowed
     organizations, data scope), matched on **email only**, no password,
     `MustChangePassword` always false; success is written to
     `practice_audit_trace` (`entity_type = 'sso-login'`, `action_type =
     'LOGIN'`, `after_json = {provider, subject, tenantId}`); the
     organization's SSO policy is checked first (above);
   * match -> `SignIn()` (the same session a password sign-in creates) ->
     a one-line page that navigates on to the app (`SameSiteHop`): the
     session cookie is SameSite=Strict and the navigation started at the
     provider, so a plain 302 would arrive without it;
   * no match / policy refusal / no email / provider error ->
     `/Login?sso=notfound|notallowed|noemail|failed`
     with a message on the login page.

Logout clears the GRAC session only (no single logout at the provider).

## Configuration (`PracticeManagement.Web/appsettings.json`)

```json
"Sso": {
  "Microsoft": { "TenantId": "", "ClientId": "", "ClientSecret": "" },
  "Google":    { "ClientId": "", "ClientSecret": "" }
}
```

A provider is enabled only when all its values are set; with none set the
login page and pipeline are exactly as before. Keep secrets out of the file in
production (environment variables `Sso__Microsoft__ClientSecret`, etc., or a
key vault).

### Microsoft Entra ID (Azure portal -> App registrations -> New) -- GRAC's own registration, once
* Supported account types: **Accounts in any organizational directory (multitenant)**.
* Redirect URI (Web): `https://<grac-host><PathBase>/signin-oidc-microsoft`
* Certificates & secrets -> new client secret -> `ClientSecret`.
* Overview -> Application (client) ID -> `ClientId`.
* `TenantId`: leave **blank** (authority `organizations`). A value restricts
  sign-in to that one tenant (the old single-tenant behaviour).
* Token configuration -> add optional claim `email` (ID token) -- recommended.
* Issuer: `/organizations` publishes a templated issuer, so `Program.cs`
  accepts a token only when its issuer is
  `https://login.microsoftonline.com/{tid}/v2.0` for the token's own `tid`
  (`SsoProviders.IsValidMicrosoftIssuer`).

### Each client organization (once)
* Their Entra admin signs in once and grants **admin consent** for the GRAC app
  (or opens `https://login.microsoftonline.com/<their-tenant-id>/adminconsent?client_id=<ClientId>`).
* Their Directory (tenant) ID goes into Organization Administration -> Single Sign-On.
* Google Workspace clients: their email domain goes into Allowed Email Domains.

### Google (Google Cloud console -> APIs & Services -> Credentials)
* OAuth consent screen configured; OAuth client ID, type Web application.
* Authorized redirect URI: `https://<grac-host><PathBase>/signin-oidc-google`
* Client ID -> `ClientId`, Client secret -> `ClientSecret`.

HTTPS is required outside Development (cookies are Secure there).

## Files

| Tier | File | Change |
| --- | --- | --- |
| Web | `PracticeManagement.Web.csproj` | `Microsoft.AspNetCore.Authentication.OpenIdConnect` 8.0.11 |
| Web | `Program.cs` | external cookie + one OpenIdConnect scheme per configured provider; `UseAuthentication()` when any is configured |
| Web | `Services/SsoProviders.cs` | new -- which providers are configured, scheme names, callback paths |
| Web | `Controllers/LoginController.cs` | `External`, `ExternalCallback`, `?sso=` messages, `DefaultUrl` / `LoginUrl` helpers |
| Web | `Services/PracticeLoginService.cs`, `Services/SecurePracticeClient.cs` | `AuthenticateExternalAsync` -> `secure/authenticate-external` |
| Web | `Views/Login/Index.cshtml`, `wwwroot/css/login.css` | "or" divider + one button per provider |
| Web | `appsettings.json` | empty `Sso` section |
| API | `Controllers/PracticeRepositoryController.cs` | `POST secure/authenticate-external` (+ `Supported`) |
| API | `Services/PracticeAuthenticationService.cs` | `AuthenticateExternalAsync`; password and SSO share `AuthenticateCoreAsync` |

Organization-wise (466):

| Tier | File | Change |
| --- | --- | --- |
| DB | `database/466_organization_sso_settings.sql` (+ rollback) | `organization_sso_setting`, `sp_org_sso_setting_get` / `_save` |
| API | `Models/OrganizationSsoSettingModels.cs` | new -- setting / save contracts, `SsoLoginModes`, `SignInFailures`, `AuthenticationOutcome` |
| API | `Services/OrganizationSsoSettingService.cs`, `Infrastructure/OrganizationSsoSettingServiceRegistration.cs`, `Controllers/OrganizationSsoSettingController.cs`, `Program.cs` | new `/api/practice/org-sso` |
| API | `Services/PracticeAuthenticationService.cs` | returns `AuthenticationOutcome`; `LoadSsoPolicyAsync` / `CheckSsoPolicy`; SSO Only check; `tenantId` in the audit row |
| API | `Controllers/PracticeRepositoryController.cs` | `tenantId` in; `Field = sso-required / sso-not-allowed` out |
| Web | `Controllers/OrganizationSsoSettingController.cs` | new proxy `/practice/api/org-sso` |
| Web | `Services/SsoProviders.cs`, `Program.cs` | TenantId optional (`organizations`), multi-tenant issuer check |
| Web | `Services/PracticeLoginService.cs` | `SignInAsync` / `AuthenticateExternalAsync` return `PracticeSignInOutcome`; `tenantId` sent |
| Web | `Controllers/LoginController.cs` | `tid` passed; `?sso=notallowed`; SSO Only message on the password form |
| Web | `Views/Practice/Manage.cshtml`, `wwwroot/js/practice.js` | Single Sign-On card on Organization Administration's Organization tab with its own Save (existing setup card / heading-with-button / form-field components) |

Matching uses `organization_employee.email`; audit rows use the existing
`practice_audit_trace`.

## Not included (possible next steps)
* Linking the provider's subject id to the employee (survives an email change).
* Per-organization app registration (own ClientId / secret) -- only if a client requires it.
* Single logout at the provider.
* GRAC MFA for password users (SSO users get the provider's MFA).
