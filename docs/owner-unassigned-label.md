# Empty Owner reads "Unassigned" (2026-10-08)

An empty owner is a missing person, not a status, so it does not use "Not Updated" (that word is reserved for the
Applicability / Implementation status vocabulary, styled as a status badge and offered in the Status filters). It was
shown as "Not set", "no owner" or "Unassigned" depending on the screen. It is now **"Unassigned"** everywhere
("Unassigned" was already used on Standards & Frameworks and in practice.js).

| Where | Was |
| --- | --- |
| Operationalize grid, Owner column (`resolve.cshtml`) | no owner |
| Operationalize workspace, Instance Owner and Obligation Owner pickers (`resolve-workspace.cshtml`) | Not set |
| Shared obligation form, Owner picker (`Shared/obligation-form.js`) | Not set |
| Asset form-template history line (`AssetConfig/asset-form-templates.js`) | not set |
| Business Services note (`AssetConfig/business-services.js`) | no owner |
| Instance-profile save message (`ResolveWorkspaceService.cs`) | owner not set |

Display text only. The empty option still posts `""` / `0`, so saves and filters are unchanged.
Deliberately not changed: Practice type, Criticality, Assurance type and Connection type pickers (still "Not set");
the generic empty-field placeholder in view forms; finding / metric names "No owner" (Business Services issue type,
Risk dashboard drill-down).
