# Dependency pickers empty for organization users (2026-10-08)

**Symptom:** on Operationalize, the Team dependency (and the other dependency categories) offered no options for an
organization admin, while admin@grac.local could pick them.

**Cause:** every dependency picker loads its objects from `dependency-options/query`. The gateway requires
`dependency-options:VIEW` for it (`PermissionAreaMap` has no mapping for it), but `dependency-options` has no
`menu_master` row, so no database role could be granted it. Only `PM_ADMIN` (`*:*`) passed. The 403 is swallowed by
`loadDependencyObjectsFor` (`catch → []`), so the picker simply showed nothing. Risk → Impact Details uses the same
call and had the same problem.

**Fix (Web only, no database change):**
- `LoginController.SupportingReads` adds `dependency-options:VIEW`, the auxiliary-lookup pattern already used for
  `owners`, `time-zones` and `team-members`.
- `PracticeManagementGatewayController.OrganizationScopedEntityTypes` adds `dependency-options`, so a caller can only
  read registers of their own allowed organizations. This is what makes granting it to every signed-in user safe.

Permissions are read at sign-in: users must sign out and in again.
