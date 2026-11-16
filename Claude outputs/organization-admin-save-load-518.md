
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
