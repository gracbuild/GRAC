# Organization Registry (migrations 569-575)

Organization Management -> **Organization Registry**: the organization master
data of the workbook *GRAC_Organization_Registry_Muthoot_Lakeshore_Pilot_Populated.xlsx*
(sheets 01-13, controlled values in sheet 15), implemented in the existing
Organization module.

## Hierarchy

```
Organization            (sheet 01)  grac_practice.registry_organization     NEW
  -> Legal Entity       (sheet 02)  grac_practice.organization              EXISTING row, extended
       -> parent / subsidiary Legal Entity (organization.parent_organization_id)
       -> Organization Units, Locations, Departments, Business Functions, Teams,
          People, Committees, Committee Members, Business Processes,
          Products & Services, Delivery Channels   (sheets 03-13)
```

* **The existing Organization record is the Legal Entity.** Nothing moved:
  every `organization_id` in GRAC keeps its meaning and data. The row gains the
  sheet-02 columns, `registry_organization_id` (up to its Organization) and
  `parent_organization_id` (holding / subsidiary structure).
* **Organization** (sheet 01, the GRAC tenant / group profile) is the new
  level above it. Sheet 02 has no Organization Code column, so the link is a
  GRAC field ("Organization") on the Legal Entity; the import links each
  sample Legal Entity to the Organization whose *Registered Name* equals its
  *Legal Name*.
* **Existing data.** Migration 569 left the existing organizations without
  an Organization; **574** gives each one an Organization of its own (see
  *574* below), so none is left unassigned. `in_scope_for_grac` is back-filled
  `Yes` (they are GRAC tenants); every other sheet-02 column stays empty.
  Legal Entity Code = `organization_code`, Legal Name = `organization_name`,
  Entity Type = `entity_type`, Registered Office Address = `address_line1`,
  City / State / Country = `city` / `state_province` / `country`,
  Record Status = `status` -- the values already there are kept.
* Interpretation of the request's "two levels above the current Organization
  level": the hierarchy is **Organization -> Legal Entity**, with the existing
  organization *as* the Legal Entity, plus Legal-Entity-to-Legal-Entity
  parenting for group structure. No third, separate level was added.

## Registry areas reuse the existing tables

START HERE says the registry must not create duplicate master records, and
GRAC already had a master for most areas, so each sheet extends the table GRAC
already uses (Organization Administration and Dependencies keep working on the
same rows):

| Sheet | Table |
|---|---|
| 03 Organization Units | `organization_division` |
| 04 Locations | `organization_location` |
| 05 Departments | `organization_department` |
| 06 Business Functions | `organization_business_function` |
| 07 Teams | `organization_team` |
| 08 People | `organization_employee` |
| 09 Committees | `organization_committee` |
| 10 Committee Members | `organization_committee_member` |
| 11 Business Processes | `organization_dependency_process` |
| 12 Products & Services | `organization_product_service` (new) |
| 13 Delivery Channels | `organization_delivery_channel` (new) |
| semicolon lists | `organization_channel_product`, `organization_channel_process`, `organization_process_risk_category` (new) |
| 15 Masters & Codes | `org_registry_master_value` (new); LocationType -> `location_type_master`, CommitteeMemberDesignation -> `committee_designation_master` (existing FKs) |

All added columns are NULLable: the monolith (`pm_manage_practice_repository`)
that the existing screens save through knows none of them, and its UPDATEs
leave them as they are.

**Assets and Third-Party Management are not part of this** (START HERE scope);
they remain their own modules.

## Rules (sp_orgreg_<area>_save, migration 571)

Applied in this order, identically for all thirteen areas (one generated
specification):

1. Mandatory fields -- the workbook's `*` columns, plus the GRAC links GRAC
   needs (every child record belongs to one Legal Entity: `organization_id`
   is NOT NULL on all those tables, so "Legal Entity Code", optional in the
   workbook, is required in GRAC; Teams and People carry a GRAC "Legal Entity"
   field because their sheets have no Legal Entity column).
2. Types and formats: dates (`yyyy-mm-dd`, shown with the app's date format,
   never as Excel serials), whole numbers, latitude / longitude ranges,
   DD-MM for the financial year, e-mail and URL shape, lengths.
3. Date order: Effective To / Closure / Exit / Member Until / Withdrawal not
   before their start.
4. Controlled values: must be on the sheet-15 list. A value off the list is
   accepted only if the record already holds it (so an older record can be
   saved unchanged). Business Function status is Active / Inactive only (the
   CHECK constraint of migration 365).
5. References must exist; `le` fields must point into the same Legal Entity,
   `org` fields (people) into the same Organization. Parents cannot be the
   record itself or create a loop. A child record cannot be moved to another
   Legal Entity (other records refer to it there).
6. Unique codes: Organization and Legal Entity codes are unique across GRAC;
   every other code is unique within its Legal Entity (the existing GRAC
   rule for division / department / function / employee codes, extended to
   the new code columns as filtered unique indexes). Location, team,
   committee and process names keep their existing per-Legal-Entity
   uniqueness; Official Email stays unique across GRAC; one membership per
   person per committee (existing constraint).
7. Each save writes a `practice_audit_trace` row (`entity_type`
   `org-registry/<area>`, before and after images of the registry columns).

**No delete.** Inactive / closed / expired records stay for traceability; a
record is retired through its status (Record Status, Operational Status,
Product Status, Channel Status). `record_status_id` follows it (Active ->
Active, Draft / Pending Approval -> Draft, everything else -> Inactive), so
the other GRAC screens that list only active records stop offering it.
Business Functions are the exception: `organization_business_function` has
no `record_status_id` on every database (008 adds it only where the table
already existed), so their status column alone carries it -- Active /
Inactive, per the CHECK of migration 365. 571 aborts up front if any other
`record_status_id` it writes is missing (2026-11-16 fix after Msg 207 on
`sp_orgreg_functions_save`).

Errors are `THROW 52700-52706` with the message prefixed `[fieldKey]`; the
Api returns `{ error, field }` and the screen marks the field.

## Screen

`org-registry`, first menu of Organization Management and the module's landing
page (`PracticeController.OrganizationManagementAreas / MenuAreas`, route
`/org-registry`). Partial `Views/Practice/Partials/org-registry.cshtml`,
behaviour `wwwroot/js/Organization/org-registry.js`, field definitions
`wwwroot/js/Organization/org-registry-fields.js` (generated).

* **Tabs**: one per area of the menu. Toolbar: Organization, Legal Entity,
  Status (the area's status list) and Search filters (selects, per the
  toolbar convention), Refresh, Add. (The hierarchy panel with per-area
  counts was removed on 2026-11-16 at sir's request; the Organization /
  Legal Entity selects set the context instead. `sp_orgreg_summary` and
  `GET /summary` stay available but the screen no longer calls them.)
* **Rows** open the record in a row under them (no popups; the Audit Plans
  child-row style `.oa-pl-wrap` / `.oa-pl-items`). Every reference reads
  "code - name" and links to the record it points at. Edit turns the row into
  the form; Add opens the form in a row at the top.
* **Controls**: controlled values are selects of the sheet-15 list (values
  marked "not approved" are the sample-data additions below); references are
  searchable single-selects that list "code - name", store the record's id and
  follow the form's Legal Entity / Organization; the semicolon lists are
  multi-selects (`gracCheckCombo`); dates are date inputs; free text stays
  free text.

Access: the `org-registry` grant (VIEW / ADD / EDIT; 570 grants all three to
active GLOBAL-scope roles) **and** a GLOBAL-scope sign-in
(`Controllers/OrgRegistryController.cs`, Web tier).

The existing **Organizations** list is now **Legal Entities** (menu name,
screen title, column headings), with an *Organization* column; its view page
reads "Legal Entity" and shows the Organization and parent Legal Entity
(`sp_org_organization_list` re-issued by 570 from 518's body plus those
columns). "Add Legal Entity" still opens Organization Setup (onboarding with
administrator and subscriptions).

## 574: three menus, no unassigned Legal Entities, mandatory defaults

`database/574_org_registry_defaults_and_menus.sql` (+ rollback), 2026-11-16:

* **Three menus instead of thirteen tabs** -- one page
  (`Partials/org-registry.cshtml`), one grant (`org-registry`; the two new
  keys map to it in `PracticeController.ScreenPermissionArea`, so ticking them
  in Role Menu Permission has no effect):

  | Menu (screen key) | Tabs |
  |---|---|
  | Organization Structure (`org-registry`) | Organizations, Legal Entities, Organization Units, Locations, Departments |
  | People & Governance (`org-registry-people`) | People, Teams, Committees, Committee Members |
  | Business Operations (`org-registry-operations`) | Business Functions, Business Processes, Products & Services, Delivery Channels |

  A reference that points
  into another menu opens that menu's page on the record; the record travels
  in `sessionStorage`, never in the URL. Groups: `GROUPS` in
  `org-registry.js`.
* **Every Legal Entity has an Organization.** Each existing organization row
  without one gets an Organization built from it (`ORG-<code>`, its name,
  Organization Type from its entity type when that is an OrganizationType
  value else `Other`, its industry else `Not specified`, a
  `data_quality_note` saying so). One per Legal Entity -- grouping them is a
  business decision: re-assign on Legal Entities and set the spare
  Organization Inactive. The "not yet assigned" group and filter option are
  gone; a Legal Entity onboarded later through Organization Setup shows under
  "All Organizations" until it is given an Organization.
* **Mandatory fields defaulted on pre-registry records** (only where empty):
  Entity Type `Other`; Unit Type `Other`, Is Operational `Yes`; Location Code
  `LOC-<id>`, State `Other`, Country = the Legal Entity's if a sheet-15 value
  else `India`, Customer-facing `No`; Department Type `Other`; Function
  Category `Other` (Active / Inactive functions only -- the 365 CHECK);
  Team Code `TEAM-<id>`, Team Type `Other`; Person Category `Employee`
  (`Other` for vendor staff), Person Status `Active` / `Other`, Designation
  `Not specified`; Committee Code `COMM-<id>`, Committee Type `Other`,
  Mandate `Not recorded`; Membership Code `MEM-<id>`; Process Code
  `PROC-<id>`, Process Level `L1`, Process Nature `Core`. These are
  placeholders to be corrected record by record.
* The page's sample-data banner was removed (the caveats stay in each
  record's Remarks).
* 570's menu row now carries the 574 name and order too, so re-running 570
  does not undo it; 274 amended.

## 575: module split -- Organization Management vs Practice Management

`database/575_org_registry_module_split.sql` (+ rollback), 2026-11-16, sir:
GRAC's own module keeps only Organizations and Legal Entities; everything
else is maintained by the organization's own administrator in Practice
Management, where Organizations and Legal Entities are shown read-only.

| Module -> Menu (screen key) | Tabs | Who |
|---|---|---|
| Organization Management -> Organizations & Legal Entities (`org-registry`) | Organizations, Legal Entities | `org-registry` grant + GLOBAL-scope sign-in; every Legal Entity |
| Practice Management -> Organization -> Organization Structure (`org-registry-structure`, new) | Organizations (read-only), Legal Entities (read-only), Organization Units, Locations, Departments | its own grant; the signed-in user's organizations only |
| Practice Management -> Organization -> People & Governance (`org-registry-people`) | People, Teams, Committees, Committee Members | its own grant; own organizations |
| Practice Management -> Organization -> Business Operations (`org-registry-operations`) | Business Functions, Business Processes, Products & Services, Delivery Channels | its own grant; own organizations |

* **Menus.** The three Practice Management screens sit under the
  `organization-administration` root ("Organization"), display order
  10 / 20 / 30, shown in the sidebar. The root keeps its own url, so it is a
  page-parent: clicking it still opens Organization Administration. Each
  role gets on the three the VIEW / ADD / EDIT it has on
  `organization-administration` (missing rows only). They are separate grants
  now -- the 574 mapping of `-people` / `-operations` onto `org-registry` is
  gone from `PracticeController.ScreenPermissionArea`. 274 amended (rows,
  parents, 2d guard trimmed, new 2e shows the three). `org-registry` stays
  hidden from the Practice Management sidebar.
* **Read-only Organizations / Legal Entities** outside Organization
  Management: no Add / Edit on those tabs (`READ_ONLY` in `org-registry.js`),
  the Web proxy answers 403 to a save, and the procedures refuse it (52707)
  whenever a scope is passed.
* **Scope.** The Web proxy (`OrgRegistryController`) reads `?screen=` (sent by
  the page on every call) to pick the grant, the allowed areas
  (`ScreenAreas`, = `GROUPS` in the JS) and the scope. On the Practice
  Management screens a non-GLOBAL user is confined to
  `HttpContext.AllowedOrganizationIds()`: the proxy strips any
  `allowedLegalEntityIds` the browser sent and adds its own (query on GET,
  body on POST / PUT; an empty list is sent as `0` = none). The procedures
  (571, regenerated) take `@allowed_legal_entity_ids` (JSON array, NULL =
  every Legal Entity): lists, lookups and summary only return rows of those
  Legal Entities (and their Organizations); a save of a record -- or into a
  Legal Entity -- outside the set throws 52707.
* **Links** between records only go to screens of the same module; a
  reference into the other module reads as plain text.

## Organization Administration tabs retired (2026-11-16)

Sir: remove Practice Management -> Organization Administration's Location,
Department, Business Function, Teams, Committees and Users / Employees tabs --
they edit the same records as the registry screens. Before removing them,
everything they could do that the registry could not was moved, so nothing
is lost:

| Retired tab | What only that tab could do | Now |
|---|---|---|
| Location | Time Zone (`time_zone_id`, 360) | Organization Structure -> Locations: **Time Zone** |
| Business Function | Criticality (`criticality`, NOT NULL, default Medium) | Business Operations -> Business Functions: **Criticality** (Critical / High / Medium / Low; new records start at Medium) |
| Teams | In-house / Vendor-managed (`team_type`, 133), Vendor (`vendor_id`), Team Members (`organization_team_member`, 362) | People & Governance -> Teams: **Team Sourcing**, **Vendor**, **Team Members** |
| Users / Employees | login e-mail, role, personnel type, provider, credentials, single sign-on **Approve** (467) | User Management (screen `users`, Administration) -- it already had the login fields and Resend Credentials; **Approve** was added there |
| Department, Committees | nothing beyond the registry | -- |

* **Rules kept from the old saves.** Criticality must be one of the four
  values. A vendor-managed team needs a Vendor that is Active and belongs to
  the team's Legal Entity; an in-house team's Vendor is cleared (133's rule).
  Team Members must be people of the team's Legal Entity; the saved list
  replaces the old one. A Time Zone must be Active (a record keeps an
  inactive one it already has). `GRAC_New.time_zone_master` belongs to
  another module, so every read is behind `OBJECT_ID` (as in 361 / 381):
  without it the field is empty and a save keeps the record's time zone.
* **Generator.** New field kinds `choice` (fixed code / label list:
  Criticality, Team Sourcing) and `timezone`; `EXTERNAL` records a field may
  point at without being a tab (`vendors` -> `organization_dependency_vendor`,
  returned by `sp_orgreg_lookups` as Kind `vendors`); `multi_extra` for a
  bridge that needs more columns (team members: Legal Entity, Active status);
  `noseed` keeps the new fields out of the sample-data import -- 569, 570
  and 572 regenerate byte-identical. Only **571** changed.
* **Screen.** `Manage.cshtml` no longer renders Organization
  Administration's child tabs (`showChildTabs`); the page keeps its
  Organization tab (profile, Single Sign-On, Subscribed Releases). The
  screen description says so (`PracticeScreen.cs`). Organization Setup
  (onboarding) keeps its tabs.
* **User Management Approve.** `practice.js` offers Approve on a user whose
  Status is Pending Approval (ADD / EDIT grant), reusing `approveSsoUser`;
  `OrganizationSsoSettingController` `approve-user` now accepts ADD / EDIT on
  User Management (`users`) as well as on Organization Administration.

## API

Web proxy `practice/api/org-registry` (also under
`OrganizationManagement/practice/api/org-registry`) -> Api
`api/practice/org-registry` (`OrgRegistryController`, `OrgRegistryService`).

| Method | Path | Grant | Returns |
|---|---|---|---|
| GET | `/lookups?registryOrganizationId=&legalEntityId=` | VIEW | `{ data: { masters: [{Group, Value, IsWorkbookValue, Note, DisplayOrder, LegalEntityId}], records: [{Kind, Id, Code, Name, LegalEntityId, RegistryOrganizationId, ParentId, Status}] } }` |
| GET | `/summary?registryOrganizationId=` | VIEW | `{ data: [{LegalEntityId, LegalEntityCode, LegalEntityName, ParentLegalEntityId, RegistryOrganizationId, Status, InScopeForGrac, Units, Locations, Departments, Functions, Teams, People, Committees, CommitteeMembers, Processes, Products, Channels}] }` |
| GET | `/{area}?registryOrganizationId=&legalEntityId=&id=&status=&search=` | VIEW | `{ data: [row] }` -- `Id, Code, Name, Status, LegalEntityId/Code/Name, RegistryOrganizationId/Code/Name, UpdatedBy, UpdatedDate`, every field as its PascalCase key; a reference as `<Field>Id` plus `<Field>Code` / `<Field>Name`; a multi-select as a JSON array |
| POST | `/{area}` | ADD | create: body `{ data: { <fieldKey>: value } }` -> `{ success, message, id }` |
| PUT | `/{area}/{id}` | EDIT | update, same body |

Every call carries `screen=<screen key>` for the Web proxy (stripped
before the Api). Api only (set by the Web proxy, never the browser):
`allowedLegalEntityIds` -- comma list on GET (`0` = none), JSON array in the
POST / PUT body; absent = every Legal Entity. A save refused for scope
answers 400 with the 52707 message.

`{area}`: `organizations, legal-entities, units, locations, departments,
functions, teams, people, committees, committee-members, processes, products,
channels`. `registryOrganizationId`: `0` all, `-1` Legal Entities not yet
assigned. A refused save answers 400 `{ success: false, error, field }`.
The actor is always the session sign-in (set by the Web tier).

## Sample data (572)

`572_org_registry_sample_data.sql` loads every populated row of sheets 01-13
(2 Organizations, 2 Legal Entities, 6 units, 6 locations, 10 departments, 10
functions, 10 teams, 12 people, 6 committees, 18 memberships, 12 processes, 8
products, 8 channels, plus the channel / process links). Codes and remarks
are kept verbatim.

* **Order-independent**: pass 1 matches or inserts every record (only the
  mandatory columns), pass 2 fills every column with references resolved
  through workbook code -> GRAC id maps, so circular references (unit <-> its
  primary location, department <-> function, person <-> team) resolve.
* **Idempotent and non-destructive**: matched by code in its Legal Entity (a
  Legal Entity also by exact legal name -- an existing organization is adopted
  and keeps its own code; a location / team / committee / process also by
  name when the existing row has no code yet). Pass 2 only fills columns that
  are still empty, so a re-run changes nothing and never overwrites an edit.
* Inserted rows carry `entered_by = 'seed-572'`; the rollback deletes exactly
  those.
* **People**: loaded as `organization_employee` rows with no password and no
  role, so they cannot sign in and do not trigger the People Onboarding
  event (migration 131 only enqueues employees that have a role). A sample
  e-mail already used by someone else in GRAC is left empty (the script lists
  them).

### Workbook values that could not be loaded exactly as given

| Sheet | Record(s) | Column | Workbook value | What the import does |
|---|---|---|---|---|
| 02 Legal Entities | LE-MF-0001 | Entity Type* | Holding / Operating Company | Not in 15 Masters & Codes (LegalEntityType); added to the list flagged 'not approved' so the row loads as given. |
| 02 Legal Entities | LE-LH-0001 | Entity Type* | Operating Company | Not in 15 Masters & Codes (LegalEntityType); added to the list flagged 'not approved' so the row loads as given. |
| 03 Organization Units | UNIT-MF-HO | Business Unit Type | Corporate | Not in 15 Masters & Codes (BusinessUnitType); added to the list flagged 'not approved' so the row loads as given. |
| 03 Organization Units | UNIT-MF-OPS | Business Unit Type | Operations | Not in 15 Masters & Codes (BusinessUnitType); added to the list flagged 'not approved' so the row loads as given. |
| 03 Organization Units | UNIT-MF-CTRL | Business Unit Type | Control / Assurance | Not in 15 Masters & Codes (BusinessUnitType); added to the list flagged 'not approved' so the row loads as given. |
| 05 Departments | DEPT-MF-FIN | Department Type* | Finance | Not in 15 Masters & Codes (DepartmentType); added to the list flagged 'not approved' so the row loads as given. |
| 05 Departments | DEPT-MF-HR | Department Type* | Corporate | Not in 15 Masters & Codes (DepartmentType); added to the list flagged 'not approved' so the row loads as given. |
| 05 Departments | DEPT-MF-IA | Department Type* | Control | Not in 15 Masters & Codes (DepartmentType); added to the list flagged 'not approved' so the row loads as given. |
| 08 People | PERS-MF-CEO | Person Category* | KMP | Not in 15 Masters & Codes (PersonCategory); added to the list flagged 'not approved' so the row loads as given. |
| 11 Business Processes | PROC-MF-LENDING-L1 | Regulatory Impact | High | Not in 15 Masters & Codes (RegulatoryImpact); added to the list flagged 'not approved' so the row loads as given. |
| 12 Products & Services | PROD-MF-GOLD | Product Category* | Loan | Not in 15 Masters & Codes (ProductCategory); added to the list flagged 'not approved' so the row loads as given. |
| 12 Products & Services | PROD-MF-NCD | Product Category* | Investment | Not in 15 Masters & Codes (ProductCategory); added to the list flagged 'not approved' so the row loads as given. |
| 12 Products & Services | PROD-LH-IPD | Product Category* | Healthcare Service | Not in 15 Masters & Codes (ProductCategory); added to the list flagged 'not approved' so the row loads as given. |
| 12 Products & Services | PROD-MF-GOLD | Secured / Unsecured (if applicable) | Secured | Not in 15 Masters & Codes (SecuredUnsecured); added to the list flagged 'not approved' so the row loads as given. |
| 12 Products & Services | PROD-MF-BUS | Secured / Unsecured (if applicable) | Unsecured | Not in 15 Masters & Codes (SecuredUnsecured); added to the list flagged 'not approved' so the row loads as given. |
| 12 Products & Services | PROD-MF-NCD | Secured / Unsecured (if applicable) | Not applicable | Not in 15 Masters & Codes (SecuredUnsecured); added to the list flagged 'not approved' so the row loads as given. |
| 13 Delivery Channels | CHAN-MF-BR | Channel Type* | Physical | Not in 15 Masters & Codes (ChannelType); added to the list flagged 'not approved' so the row loads as given. |
| 13 Delivery Channels | CHAN-MF-WEB | Channel Type* | Digital | Not in 15 Masters & Codes (ChannelType); added to the list flagged 'not approved' so the row loads as given. |
| 13 Delivery Channels | CHAN-MF-CC | Channel Type* | Assisted | Not in 15 Masters & Codes (ChannelType); added to the list flagged 'not approved' so the row loads as given. |
| 13 Delivery Channels | CHAN-LH-REF | Channel Type* | Partner | Not in 15 Masters & Codes (ChannelType); added to the list flagged 'not approved' so the row loads as given. |
| 01 Organization Profile | M/s Lakeshore Hospital and Research Centre Limited | Organization Code* | ORG-MF-0001 | Duplicate code; loaded as ORG-LH-0001 (note kept on the record). |
| 13 Delivery Channels | CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF | Processes Supported (codes) | PROC-LH-BILL | No process has this code; the one code that extends it, PROC-LH-BILL-L1, was linked. |
| 13 Delivery Channels | CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF | Processes Supported (codes) | PROC-LH-CLIN | No process has this code; the one code that extends it, PROC-LH-CLIN-L1, was linked. |
| 13 Delivery Channels | CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF | Processes Supported (codes) | PROC-LH-IT | No process has this code; the one code that extends it, PROC-LH-IT-L1, was linked. |
| 13 Delivery Channels | CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF | Processes Supported (codes) | PROC-LH-LAB | No process has this code; the one code that extends it, PROC-LH-LAB-L1, was linked. |
| 13 Delivery Channels | CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF | Processes Supported (codes) | PROC-LH-PAT | No process has this code; the one code that extends it, PROC-LH-PAT-L1, was linked. |
| 13 Delivery Channels | CHAN-LH-HOSP, CHAN-LH-WEB, CHAN-LH-CALL, CHAN-LH-REF | Processes Supported (codes) | PROC-LH-PHARM | No process has this code; the one code that extends it, PROC-LH-PHARM-L1, was linked. |
| 13 Delivery Channels | CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC | Processes Supported (codes) | PROC-MF-COLL | No process has this code; the one code that extends it, PROC-MF-COLL-L1, was linked. |
| 13 Delivery Channels | CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC | Processes Supported (codes) | PROC-MF-GOLD | No process has this code; the one code that extends it, PROC-MF-GOLD-L1, was linked. |
| 13 Delivery Channels | CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC | Processes Supported (codes) | PROC-MF-IT | No process has this code; the one code that extends it, PROC-MF-IT-L1, was linked. |
| 13 Delivery Channels | CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC | Processes Supported (codes) | PROC-MF-KYC | No process has this code; the one code that extends it, PROC-MF-KYC-L1, was linked. |
| 13 Delivery Channels | CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC | Processes Supported (codes) | PROC-MF-LENDING | No process has this code; the one code that extends it, PROC-MF-LENDING-L1, was linked. |
| 13 Delivery Channels | CHAN-MF-BR, CHAN-MF-WEB, CHAN-MF-MOB, CHAN-MF-CC | Processes Supported (codes) | PROC-MF-TREAS | No process has this code; the one code that extends it, PROC-MF-TREAS-L1, was linked. |

Field Dictionary data types that contradict the column ("Date" for text
columns such as *RBI / Regulator Classification*, *Regulator*, *City / Town*,
*Committee Mandate*, *Employee / Director Reference No.*, *Customer Segment*;
"Unique code" for *PIN Code*; YesNo for *Secured / Unsecured*) were not
followed; the column's meaning and the sample values were. Each is noted in the field mapping below.

## Field mapping

Generated from the same specification as the migrations and the screen.
*(new)* = column added by 569 to an existing table.

### 01 Organization Profile -> `grac_practice.registry_organization` (new table)

| Workbook column | Column | Kind | Required | Note |
|---|---|---|---|---|
| Organization Code* | `organization_code` | code | Yes |  |
| Registered Name* | `registered_name` | text | Yes |  |
| Common / Brand Name | `brand_name` | text |  |  |
| Organization Type* | `organization_type` | master `OrganizationType` | Yes |  |
| Industry* | `industry` | text | Yes |  |
| RBI / Regulator Classification | `regulator_classification` | text |  | Field Dictionary lists Data Type 'Date'; the sample value is text, so it is stored as text. |
| Registration / CIN | `registration_cin` | text |  |  |
| LEI (if applicable) | `lei` | text |  |  |
| Date of Incorporation | `incorporation_dt` | date |  |  |
| Registered Office Address | `registered_office_address` | textarea |  |  |
| City | `city` | text |  |  |
| State | `state` | master `State` |  |  |
| Country | `country` | master `Country` |  |  |
| PIN Code | `pin_code` | text |  | Field Dictionary marks this 'Unique code'; a PIN code is shared by many records, so it is free text. |
| Corporate Website | `corporate_website` | url |  |  |
| Financial Year Start (DD-MM) | `financial_year_start` | ddmm |  |  |
| Financial Year End (DD-MM) | `financial_year_end` | ddmm |  |  |
| Primary Contact Role | `primary_contact_role` | text |  |  |
| Primary Contact Official Email | `primary_contact_email` | email |  |  |
| Data Cut-off Date | `data_cutoff_dt` | date |  |  |
| Record Status* | `record_status` | master `RecordStatus` | Yes |  |
| Remarks | `remarks` | textarea |  |  |
| (GRAC import note) (GRAC link) | `data_quality_note` | textarea |  | Not a workbook column. Written by the sample-data import when a workbook value could not be loaded as given. |

### 02 Legal Entities -> `grac_practice.organization`

| Workbook column | Column | Kind | Required | Note |
|---|---|---|---|---|
| Organization (GRAC link) | `registry_organization_id` *(new)* | ref -> organizations (any) | Yes | Not a workbook column (sheet 02 has no Organization Code). The GRAC link from a Legal Entity up to its Organization. |
| Legal Entity Code* | `organization_code` | code | Yes |  |
| Legal Name* | `organization_name` | text | Yes |  |
| Short Name | `short_name` *(new)* | text |  |  |
| Entity Type* | `entity_type` | master `LegalEntityType` | Yes |  |
| Parent Legal Entity Code | `parent_organization_id` *(new)* | ref -> legal-entities (org) |  |  |
| Registration Number | `registration_number` *(new)* | text |  |  |
| Date of Incorporation | `incorporation_dt` *(new)* | date |  |  |
| Registered Office Address | `address_line1` | textarea |  |  |
| City | `city` | text |  |  |
| State | `state_province` | master `State` |  |  |
| Country | `country` | master `Country` |  |  |
| Regulator | `regulator` *(new)* | text |  |  |
| Regulatory Classification | `regulatory_classification` *(new)* | text |  |  |
| Business Activity | `business_activity` *(new)* | text |  |  |
| In Scope for GRAC?* | `in_scope_for_grac` *(new)* | master `YesNo` | Yes |  |
| Entity Owner Person Code | `entity_owner_employee_id` *(new)* | ref -> people (org) |  |  |
| Record Status* | `status` | master `RecordStatus` | Yes |  |
| Effective From | `effective_from` *(new)* | date |  |  |
| Effective To | `effective_to` *(new)* | date |  |  |
| Remarks | `legal_entity_remarks` *(new)* | textarea |  |  |

### 03 Organization Units -> `grac_practice.organization_division`

| Workbook column | Column | Kind | Required | Note |
|---|---|---|---|---|
| Unit Code* | `division_code` | code | Yes |  |
| Unit Name* | `division_name` | text | Yes |  |
| Unit Type* | `unit_type` *(new)* | master `OrgUnitType` | Yes |  |
| Parent Unit Code | `parent_division_id` *(new)* | ref -> units (le) |  |  |
| Legal Entity Code | `organization_id` | ref -> legal-entities (any) | Yes | Optional in the workbook; required in GRAC because every unit belongs to one Legal Entity (organization_id NOT NULL). |
| Primary Location Code | `primary_location_id` *(new)* | ref -> locations (le) |  |  |
| Unit Head Person Code | `head_employee_id` | ref -> people (org) |  |  |
| Unit Head Designation | `head_designation` *(new)* | text |  |  |
| Business Unit Type | `business_unit_type` *(new)* | master `BusinessUnitType` |  |  |
| State / Region | `state_region` *(new)* | text |  |  |
| Unit Cost Centre | `cost_centre` *(new)* | text |  |  |
| Is Operational?* | `is_operational` *(new)* | master `YesNo` | Yes |  |
| Record Status* | `status` | master `RecordStatus` | Yes |  |
| Effective From | `effective_from` *(new)* | date |  |  |
| Effective To | `effective_to` *(new)* | date |  |  |
| Remarks | `remarks` *(new)* | textarea |  |  |

### 04 Locations -> `grac_practice.organization_location`

| Workbook column | Column | Kind | Required | Note |
|---|---|---|---|---|
| Location Code* | `location_code` *(new)* | code | Yes |  |
| Location Name* | `location_name` | text | Yes |  |
| Location Type* | `location_type_id` | locationtype (location_type_master) | Yes |  |
| Legal Entity Code | `organization_id` | ref -> legal-entities (any) | Yes | Optional in the workbook; required in GRAC (organization_location.organization_id NOT NULL). |
| Organization Unit Code | `division_id` *(new)* | ref -> units (le) |  |  |
| Parent Location Code | `parent_location_id` *(new)* | ref -> locations (le) |  |  |
| Address Line 1 | `address_line1` | text |  |  |
| Address Line 2 | `address_line2` | text |  |  |
| City / Town | `city` | text |  | Field Dictionary lists Data Type 'Date'; a city is text. |
| District | `district` *(new)* | text |  |  |
| State* | `state_province` | master `State` | Yes |  |
| PIN Code | `postal_code` | text |  |  |
| Country* | `country` | master `Country` | Yes |  |
| Latitude (optional) | `latitude` *(new)* | decimal |  |  |
| Longitude (optional) | `longitude` *(new)* | decimal |  |  |
| Region / Zone Label | `region` | text |  |  |
| Location Head Person Code | `location_head_id` | ref -> people (org) |  |  |
| Opening Date | `opening_dt` *(new)* | date |  |  |
| Closure Date | `closure_dt` *(new)* | date |  |  |
| Customer-facing?* | `customer_facing` *(new)* | master `YesNo` | Yes |  |
| Operational Status* | `status` | master `RecordStatus` | Yes |  |
| Remarks | `remarks` | textarea |  |  |

### 05 Departments -> `grac_practice.organization_department`

| Workbook column | Column | Kind | Required | Note |
|---|---|---|---|---|
| Department Code* | `department_code` | code | Yes |  |
| Department Name* | `department_name` | text | Yes |  |
| Short Name | `short_name` *(new)* | text |  |  |
| Department Type* | `department_type` *(new)* | master `DepartmentType` | Yes |  |
| Parent Department Code | `parent_department_id` *(new)* | ref -> departments (le) |  |  |
| Legal Entity Code | `organization_id` | ref -> legal-entities (any) | Yes | Optional in the workbook; required in GRAC (organization_department.organization_id NOT NULL). |
| Primary Organization Unit Code | `primary_division_id` *(new)* | ref -> units (le) |  |  |
| Department Head Person Code | `head_employee_id` | ref -> people (org) |  |  |
| Department Head Designation | `head_designation` *(new)* | text |  |  |
| Primary Business Function Code | `primary_business_function_id` *(new)* | ref -> functions (le) |  |  |
| Cost Centre | `cost_centre` *(new)* | text |  |  |
| Centralised / Distributed | `centralisation` *(new)* | master `Centralisation` |  |  |
| Record Status* | `status` | master `RecordStatus` | Yes |  |
| Effective From | `effective_from` *(new)* | date |  |  |
| Effective To | `effective_to` *(new)* | date |  |  |
| Remarks | `remarks` *(new)* | textarea |  |  |

### 06 Business Functions -> `grac_practice.organization_business_function`

| Workbook column | Column | Kind | Required | Note |
|---|---|---|---|---|
| Function Code* | `function_code` | code | Yes |  |
| Function Name* | `function_name` | text | Yes |  |
| Function Category* | `function_category` *(new)* | master `FunctionCategory` | Yes |  |
| Parent Function Code | `parent_function_id` *(new)* | ref -> functions (le) |  |  |
| Business Unit Type | `business_unit_type` *(new)* | master `BusinessUnitType` |  |  |
| Function Owner Person Code | `owner_employee_id` *(new)* | ref -> people (org) |  |  |
| Accountable Department Code | `accountable_department_id` *(new)* | ref -> departments (le) |  |  |
| Executive Sponsor Person Code | `executive_sponsor_employee_id` *(new)* | ref -> people (org) |  |  |
| Description / Scope | `description` *(new)* | textarea |  |  |
| Key Responsibilities | `key_responsibilities` *(new)* | textarea |  |  |
| Primary Legal Entity Code | `organization_id` | ref -> legal-entities (any) | Yes | Optional in the workbook; required in GRAC (organization_business_function.organization_id NOT NULL). |
| Record Status* | `status` | master `RecordStatus` | Yes | Migration 365 limits a business function's status to Active / Inactive (CHECK constraint); only those two are offered. |
| Effective From | `effective_from` *(new)* | date |  |  |
| Effective To | `effective_to` *(new)* | date |  |  |
| Remarks | `remarks` *(new)* | textarea |  |  |

### Fields added 2026-11-16 (not workbook columns)

| Area | Field | Column | Kind | Required |
|---|---|---|---|---|
| Locations | Time Zone | `time_zone_id` -> `GRAC_New.time_zone_master` | timezone |  |
| Business Functions | Criticality | `criticality` | choice Critical / High / Medium / Low | Yes |
| Teams | Team Sourcing | `team_type` | choice InHouse (In-house) / Vendor (Vendor-managed) | Yes |
| Teams | Vendor | `vendor_id` -> `organization_dependency_vendor` | ref (same Legal Entity) | for Vendor-managed |
| Teams | Team Members | `organization_team_member.employee_id` | multiref -> people (same Legal Entity) |  |

### 07 Teams -> `grac_practice.organization_team`

| Workbook column | Column | Kind | Required | Note |
|---|---|---|---|---|
| Team Code* | `team_code` *(new)* | code | Yes |  |
| Team Name* | `team_name` | text | Yes |  |
| Team Type* | `team_classification` *(new)* | master `TeamType` | Yes | Stored in team_classification: organization_team.team_type already means In-house / Vendor (migration 133) and is left as it is. |
| Legal Entity (GRAC link) | `organization_id` | ref -> legal-entities (any) | Yes | Not a workbook column. GRAC requires it (organization_team.organization_id NOT NULL); the import takes it from the Parent Department, else the Organization Unit. |
| Parent Department Code | `parent_department_id` | ref -> departments (le) |  |  |
| Primary Function Code | `primary_function_id` *(new)* | ref -> functions (le) |  |  |
| Organization Unit Code | `division_id` *(new)* | ref -> units (le) |  |  |
| Team Manager Person Code | `team_manager_id` | ref -> people (org) |  |  |
| Team Purpose | `team_purpose` *(new)* | textarea |  |  |
| Record Status* | `status` | master `RecordStatus` | Yes |  |
| Effective From | `effective_from` *(new)* | date |  |  |
| Effective To | `effective_to` *(new)* | date |  |  |
| Remarks | `remarks` | textarea |  |  |

### 08 People -> `grac_practice.organization_employee`

| Workbook column | Column | Kind | Required | Note |
|---|---|---|---|---|
| Person Code* | `employee_code` | code | Yes |  |
| Full Name* | `employee_name` | text | Yes |  |
| Person Category* | `person_category` *(new)* | master `PersonCategory` | Yes |  |
| Employment Type | `employment_type` *(new)* | master `EmploymentType` |  |  |
| Employee / Director Reference No. | `reference_no` *(new)* | text |  | Field Dictionary lists Data Type 'Date'; the sample values are reference numbers, so it is stored as text. |
| Official Email | `email` | email |  | organization_employee.email is unique across GRAC (ux_pm_employee_email). |
| Official Phone (optional) | `official_phone` *(new)* | text |  |  |
| Designation* | `designation` | text | Yes |  |
| Role Name / Functional Role | `functional_role` *(new)* | text |  |  |
| Legal Entity (GRAC link) | `organization_id` | ref -> legal-entities (any) | Yes | Not a workbook column. GRAC requires it (organization_employee.organization_id NOT NULL); the import takes it from the Department, else the Organization Unit. |
| Department Code | `department_id` | ref -> departments (le) |  |  |
| Primary Function Code | `business_function_id` | ref -> functions (le) |  |  |
| Team Code (primary) | `primary_team_id` *(new)* | ref -> teams (le) |  |  |
| Organization Unit Code | `division_id` | ref -> units (le) |  |  |
| Primary Location Code | `location_id` | ref -> locations (le) |  |  |
| Reports To Person Code | `reporting_officer_id` | ref -> people (org) |  |  |
| Functional Reporting To Person Code | `functional_reporting_to_id` *(new)* | ref -> people (org) |  |  |
| Joining / Appointment Date | `appointment_dt` *(new)* | date |  | Stored in appointment_dt, not onboarded_dt: onboarded_dt drives the People Onboarding event (migration 131). |
| Exit / End Date | `exit_dt` *(new)* | date |  |  |
| Person Status* | `person_status` *(new)* | master `PersonStatus` | Yes |  |
| Key Managerial Personnel? | `is_kmp` *(new)* | master `YesNo` |  |  |
| Record Status* | `status` | master `RecordStatus` | Yes | organization_employee.status is also the sign-in status: only Active people can sign in (and only with a password set). |
| Remarks | `remarks` *(new)* | textarea |  |  |

### 09 Committees -> `grac_practice.organization_committee`

| Workbook column | Column | Kind | Required | Note |
|---|---|---|---|---|
| Committee Code* | `committee_code` *(new)* | code | Yes |  |
| Committee Name* | `committee_name` | text | Yes |  |
| Committee Type* | `committee_type` *(new)* | master `CommitteeType` | Yes |  |
| Legal Entity Code | `organization_id` | ref -> legal-entities (any) | Yes | Optional in the workbook; required in GRAC (organization_committee.organization_id NOT NULL). |
| Committee Mandate* | `mandate` *(new)* | textarea | Yes | Field Dictionary lists Data Type 'Date'; a mandate is text. |
| Scope / Responsibilities | `scope_responsibilities` *(new)* | textarea |  |  |
| Chairperson Person Code | `chairperson_id` | ref -> people (org) |  |  |
| Committee Secretary Person Code | `secretary_id` | ref -> people (org) |  |  |
| Review Frequency | `review_frequency` *(new)* | master `ReviewFrequency` |  | Kept as the workbook value; review_frequency_id (frequency_master) is kept in step when a frequency of the same name exists. |
| Terms of Reference Reference | `tor_reference` *(new)* | text |  |  |
| Constituted Date | `constituted_dt` *(new)* | date |  |  |
| Last Reviewed Date | `last_reviewed_dt` *(new)* | date |  |  |
| Next Review Due Date | `next_review_due_dt` *(new)* | date |  |  |
| Record Status* | `status` | master `RecordStatus` | Yes |  |
| Effective From | `effective_from` *(new)* | date |  |  |
| Effective To | `effective_to` *(new)* | date |  |  |
| Remarks | `remarks` | textarea |  |  |

### 10 Committee Members -> `grac_practice.organization_committee_member`

| Workbook column | Column | Kind | Required | Note |
|---|---|---|---|---|
| Membership Code* | `membership_code` *(new)* | code | Yes |  |
| Committee Code* | `committee_id` | ref -> committees (any) | Yes |  |
| Person Code* | `employee_id` | ref -> people (org) | Yes |  |
| Designation in Committee* | `designation_id` | designation (committee_designation_master) | Yes |  |
| Member Since | `member_since` *(new)* | date |  |  |
| Member Until | `member_until` *(new)* | date |  |  |
| Voting Member? | `is_voting_member` *(new)* | master `YesNo` |  |  |
| Permanent Invitee? | `is_permanent_invitee` *(new)* | master `YesNo` |  |  |
| Attendance / Participation Requirement | `participation_requirement` *(new)* | text |  |  |
| Record Status* | `status` | master `RecordStatus` | Yes |  |
| Remarks | `remarks` *(new)* | textarea |  |  |

### 11 Business Processes -> `grac_practice.organization_dependency_process`

| Workbook column | Column | Kind | Required | Note |
|---|---|---|---|---|
| Process Code* | `process_code` *(new)* | code | Yes |  |
| Process Name* | `process_name` | text | Yes |  |
| Process Level* | `process_level` *(new)* | master `ProcessLevel` | Yes |  |
| Parent Process Code | `parent_process_id` *(new)* | ref -> processes (le) |  |  |
| Process Nature* | `process_nature` *(new)* | master `ProcessNature` | Yes |  |
| Business Function Code | `business_function_id` *(new)* | ref -> functions (le) |  |  |
| Owning Department Code | `owning_department_id` *(new)* | ref -> departments (le) |  |  |
| Process Owner Person Code | `process_owner_id` | ref -> people (org) |  |  |
| Accountable Executive Person Code | `accountable_executive_id` *(new)* | ref -> people (org) |  |  |
| Description / Objective | `description` *(new)* | textarea |  |  |
| Key Activities / Scope | `key_activities` *(new)* | textarea |  |  |
| Primary Product / Service Code | `primary_product_id` *(new)* | ref -> products (le) |  |  |
| Primary Channel Code | `primary_channel_id` *(new)* | ref -> channels (le) |  |  |
| Applicable Legal Entity Code | `organization_id` | ref -> legal-entities (any) | Yes | Optional in the workbook; required in GRAC (organization_dependency_process.organization_id NOT NULL). |
| Primary Organization Unit Code | `primary_division_id` *(new)* | ref -> units (le) |  |  |
| Applicable Location Scope | `location_scope` *(new)* | text |  |  |
| Process Frequency | `process_frequency` *(new)* | master `ProcessFrequency` |  |  |
| Approx. Annual Volume (optional) | `annual_volume` *(new)* | number |  |  |
| Customer Impact? | `customer_impact` *(new)* | master `YesNo` |  |  |
| Regulatory Impact | `regulatory_impact` *(new)* | master `RegulatoryImpact` |  |  |
| Key Regulatory / Policy References | `regulatory_references` *(new)* | textarea |  |  |
| Key Risk Categories | `risk_category` in `organization_process_risk_category` *(new)* | multimaster `ProcessRisk` |  | Semicolon-separated in the workbook; stored one row per category (organization_process_risk_category). |
| Record Status* | `status` | master `RecordStatus` | Yes |  |
| Effective From | `effective_dt` | date |  |  |
| Effective To | `effective_to` *(new)* | date |  |  |
| Remarks | `remarks` | textarea |  |  |

### 12 Products & Services -> `grac_practice.organization_product_service` (new table)

| Workbook column | Column | Kind | Required | Note |
|---|---|---|---|---|
| Product / Service Code* | `product_code` | code | Yes |  |
| Product / Service Name* | `product_name` | text | Yes |  |
| Product Category* | `product_category` | master `ProductCategory` | Yes |  |
| Scheme / Variant Name | `scheme_variant` | text |  |  |
| Description | `description` | textarea |  |  |
| Owning Business Function Code | `owning_function_id` | ref -> functions (le) |  |  |
| Owning Department Code | `owning_department_id` | ref -> departments (le) |  |  |
| Product Owner Person Code | `product_owner_id` | ref -> people (org) |  |  |
| Applicable Legal Entity Code | `organization_id` | ref -> legal-entities (any) | Yes | Optional in the workbook; required in GRAC (every product belongs to one Legal Entity). |
| Customer Segment | `customer_segment` | text |  |  |
| Secured / Unsecured (if applicable) | `secured_unsecured` | master `SecuredUnsecured` |  | Field Dictionary links this to YesNo, but the column asks Secured / Unsecured and the sample answers Secured / Unsecured / Not applicable; those three are kept as their own list. |
| Regulatory Classification | `regulatory_classification` | text |  |  |
| Launch Date | `launch_dt` | date |  |  |
| Withdrawal Date | `withdrawal_dt` | date |  |  |
| Product Status* | `status` | master `ProductStatus` | Yes |  |
| Remarks | `remarks` | textarea |  |  |

### 13 Delivery Channels -> `grac_practice.organization_delivery_channel` (new table)

| Workbook column | Column | Kind | Required | Note |
|---|---|---|---|---|
| Channel Code* | `channel_code` | code | Yes |  |
| Channel Name* | `channel_name` | text | Yes |  |
| Channel Type* | `channel_type` | master `ChannelType` | Yes |  |
| Description | `description` | textarea |  |  |
| Owning Business Function Code | `owning_function_id` | ref -> functions (le) |  |  |
| Channel Owner Person Code | `channel_owner_id` | ref -> people (org) |  |  |
| Applicable Legal Entity Code | `organization_id` | ref -> legal-entities (any) | Yes | Optional in the workbook; required in GRAC (every channel belongs to one Legal Entity). |
| Primary Organization Unit Code | `primary_division_id` | ref -> units (le) |  |  |
| Customer-facing?* | `customer_facing` | master `YesNo` | Yes |  |
| Operational Hours / Availability | `operational_hours` | text |  |  |
| Geographic Scope | `geographic_scope` | text |  |  |
| Products / Services Supported (codes) | `product_service_id` in `organization_channel_product` | multiref -> products (le) |  | Semicolon-separated codes in the workbook; stored one row per product (organization_channel_product), as the sheet itself recommends. |
| Processes Supported (codes) | `process_id` in `organization_channel_process` | multiref -> processes (le) |  | Semicolon-separated codes in the workbook; stored one row per process (organization_channel_process). |
| Channel Status* | `status` | master `ChannelStatus` | Yes |  |
| Remarks | `remarks` | textarea |  |  |

## Files

| Layer | File | Change |
|---|---|---|
| DB | `database/569_org_registry_schema.sql` (+ rollback) | new tables, columns, FKs, unique indexes |
| DB | `database/570_org_registry_masters_menu.sql` (+ rollback) | sheet-15 values, location types, designations, menu + grants, Legal Entities list proc |
| DB | `database/571_org_registry_procedures.sql` (+ rollback) | lookups, summary, 13 list + 13 save procedures |
| DB | `database/572_org_registry_sample_data.sql` (+ rollback) | pilot sample rows |
| DB | `database/274_menu_master_seed.sql` | amended: `org-registry` row and parent, `organizations` named Legal Entities, sidebar guard |
| Api | `Controllers/OrgRegistryController.cs`, `Services/OrgRegistryService.cs`, `Models/OrgRegistryModels.cs`, `Infrastructure/OrgRegistryServiceRegistration.cs`, `Program.cs` | new endpoints |
| Web | `Controllers/OrgRegistryController.cs` | proxy + VIEW/ADD/EDIT + GLOBAL scope |
| Web | `Views/Practice/Partials/org-registry.cshtml`, `wwwroot/js/Organization/org-registry.js`, `wwwroot/js/Organization/org-registry-fields.js` | the screen |
| Web | `Models/PracticeScreen.cs`, `Controllers/PracticeController.cs`, `Views/Practice/Manage.cshtml` | screen registration, module menu / landing / route; "Add Legal Entity" |
| Web | `wwwroot/js/practice.js`, `wwwroot/js/Organization/organization-view.js`, `Views/Practice/Partials/organization-view.cshtml` | Legal Entity labels, Organization column / facts |
| DB | `database/574_org_registry_defaults_and_menus.sql` (+ rollback) | three menus, an Organization per unassigned Legal Entity, mandatory defaults |
| DB | `database/575_org_registry_module_split.sql` (+ rollback) | module split: menu names / placement, Organization Structure menu, grants |
| DB | `database/571_org_registry_procedures.sql` | regenerated for 575: `@allowed_legal_entity_ids` on every procedure, error 52707; regenerated again 2026-11-16: Time Zone, Criticality, Team Sourcing / Vendor / Members, vendors in lookups |
| Web | `Views/Practice/Manage.cshtml`, `Models/PracticeScreen.cs` | Organization Administration child tabs retired |
| Web | `wwwroot/js/practice.js`, `Controllers/OrganizationSsoSettingController.cs` | Approve (single sign-on) on User Management |
| Tools | `tools/org-registry/` | generator for 569-572 and `org-registry-fields.js` |

## Deploy

1. Run `569`, `570`, `571`, `572` (sample data -- optional outside the
   pilot), then `574`, then `575`. Each aborts cleanly if its predecessor is
   missing. On a database that already has 571: **re-run 571** (the
   procedures gained a parameter and, on 2026-11-16, the retired tabs'
   fields), then run 575. 571 now also needs 133, 360 and 362 (it aborts
   with a message otherwise).
2. Deploy Api and Web (new controllers; no shim probe, so no restart order).
3. Sign out and in again (menu and grants are read at sign-in). Hard-refresh
   (new and changed JS).

## Not done / open

* A role that has VIEW on `organization-administration` but none of the three
  registry grants keeps the Organization root only while one child is
  visible (`PermittedMenu` drops a parent with no permitted children). 575
  copies the root's grants to the children, so this only arises if they are
  later removed in Role Master.

* 574 gives each existing Legal Entity its own Organization; Legal Entities
  of one group have to be moved under one Organization by hand.
* New organizations onboarded through Organization Setup get no Organization
  automatically (that path is the monolith); assign them on Legal Entities.
* The sample-data values flagged "not approved" need a data-owner decision:
  approve them (leave them), or change the records to a sheet-15 value and
  set the master row Inactive.
* Committee membership history: the existing unique constraint allows one
  membership per person per committee, so a re-appointment after an end date
  updates the existing membership rather than adding a second one.
* Team memberships beyond the primary team (sheet 07's note on a bridge
  table) are the Teams area's Team Members field (`organization_team_member`,
  migration 362); a person's own record keeps their primary team.
* A Legal Entity created on the registry is a GRAC organization without an
  administrator or subscriptions; set those up from Organization Setup.

## 585: "Organization" is a pure menu group (2026-11-18, sir)

- 575 kept `organization-administration`'s url, so the sidebar parent "Organization" always opened the Organization Administration page and its sub-menu (Organization Structure, People & Governance, Business Operations) could not be closed by clicking it.
- 585 sets that menu row's `menu_url` to NULL: the parent renders as `#` without `data-nav-href`, so it opens and closes like every other group. Children, order and grants are unchanged; 274 amended.
- Decision (sir): the Organization Administration page gets no other sidebar entry; its route and permissions are unchanged.
- Rollback: `585_organization_menu_group_rollback.sql` (url restored). Users sign out and back in to see the change.
