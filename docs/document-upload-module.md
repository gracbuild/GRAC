# Document Upload & Acknowledgement Module

Ported from the legacy GRAC Plus stack (`WebApp/Controllers/DocumentUploadAndAcknowledgement.cs`, `WebAPI/DataSource/DocumentUpload.Datasource.cs`) into the Practice Management solution. This document describes the Phase 1 slice — controlled-document register, upload, and review-approve workflow. Phase 2 (acknowledgement creation, user acknowledgement, workflow view) is scoped separately.

## Migrations

| Script | Purpose |
| --- | --- |
| `146_document_upload_schema.sql` | 12 tables in `grac_practice`: `organization_department`, 5 lookup masters, `document_upload`, `document_upload_file`, 2 distribution join tables, `document_upload_history`. |
| `147_document_upload_procs.sql` | 15 stored procedures (`sp_document_type_list`, `sp_document_stage_list`, `sp_document_status_list`, `sp_document_source_type_list`, `sp_document_distribution_type_list`, `sp_organization_department_list`, `sp_organization_employee_by_department`, `sp_document_register_list`, `sp_document_details_get`, `sp_document_distribution_department_list`, `sp_document_distribution_employee_list`, `sp_document_file_get`, `sp_document_file_save`, `sp_document_upload_save`, `sp_document_upload_workflow_transition`). |
| `148_document_upload_seed.sql` | Lookup rows matching the legacy catalog: `POLICY`/`SOP` types, `Draft`/`Reviewed`/`Published` stages, `Active`/`Retired` status, `UPLOADED`/`POLICY_DRIVEN` sources, `Organization`/`Departments`/`Users` distribution types. |
| `149_document_upload_menu_seed.sql` | Adds the `document-uploads` menu row, grants the Admin role on every organisation, registers and enables the `screen.document-uploads` feature flag. |
| `219_document_file_save_output_param.sql` | Re-issues `sp_document_file_save` with `@document_file_id BIGINT OUTPUT` in place of its trailing `SELECT SCOPE_IDENTITY() AS DocumentFileId`. A result set produced inside a nested procedure reaches the client ahead of the outer procedure's own SELECT, so every save that carried a file returned the `DocumentFileId` row first and `SaveAsync` read `DocumentId` off it — surfacing as a message box containing the single word `DocumentId` with the save page left open. |

Each migration has a matching `_rollback.sql`. Roll back in order 219 → 149 → 148 → 147 → 146.

**Rule this module now enforces:** a procedure called by another procedure returns its values through `OUTPUT` parameters, never a `SELECT`. `sp_document_upload_save` must return exactly one result set — its `DocumentId` row — in all three modes.

## Domain model

`document_upload` is the register: one row per document per organisation. `document_code` is a system-generated short code (`DU-N`), unique per organisation. `company_document_code` is the caller-supplied internal reference.

The lifecycle position is stored on `current_stage_id` (`Draft` → `Reviewed` → `Published`); rejection at either transition sends the document back to `Draft`. Retiring a published document is a status change (`Active` → `Retired`), not a stage change — a policy that was published stays in the Published stage after retirement.

Distribution is driven by `distribution_type_id`:

- `Organization` — the document applies to the whole org, no join rows written.
- `Departments` — `document_upload_distribution_department` holds one row per targeted department.
- `Users` — `document_upload_distribution_employee` holds one row per targeted employee.

File binaries live in `document_upload_file`, one row per version. `is_current` marks the latest; older versions stay for audit. This split from the register keeps `SELECT * FROM document_upload` narrow.

`document_upload_history` captures every material change with a `change_reason` (`Create`, `Edit`, `StatusChange`, `Review-Approve`, `Review-Reject`, `Approve-Approve`, `Approve-Reject`). It replaces the legacy `_his` shadow tables, which duplicated every column on every change.

## API tier (`PracticeManagement.Api`)

Base route: `/api/practice/document-uploads`. All endpoints run through `DocumentUploadService`, which resolves the connection string via `SqlConnectionStringResolver` and calls the stored procedures. No SQL is written inline in the service — every write goes through `sp_document_upload_save` or `sp_document_upload_workflow_transition`.

### Lookups (JSON, `GET`)

| Route | Purpose |
| --- | --- |
| `lookups/types` | Document types (Policy, SOP, …). `?includeAll=true` prepends an "All" row for filters. |
| `lookups/stages` | Draft / Reviewed / Published. Same `?includeAll`. |
| `lookups/statuses` | Active / Retired. |
| `lookups/source-types` | Uploaded / Policy Driven (the second is Inactive by default). |
| `lookups/distribution-types` | Organization / Departments / Users. |
| `lookups/departments?organizationId={id}&includeAll=` | Departments in the organisation. |
| `lookups/employees?organizationId={id}&departmentIds=1,2,3&includeAll=` | Employees, optionally filtered by department. |

### Register (JSON, `GET`)

| Route | Purpose |
| --- | --- |
| `?organizationId={id}&typeId=&stageId=&statusId=&search=&page=&pageSize=` | Paginated list. Filters are `-1` for "any". Response includes `totalRows`. |
| `{documentId}` | Full document detail card with joined lookups and employee names. |
| `{documentId}/distribution/departments` | Departments the document is distributed to. |
| `{documentId}/distribution/employees` | Employees the document is distributed to. |
| `{documentId}/file` | Streams the current file with its stored `Content-Type` and filename. |

### Register (writes)

`POST /` and `PUT /{documentId}` are **multipart/form-data**. The form field list matches `DocumentUploadSaveForm` in `Models/DocumentUploadModels.cs`. `File` carries the binary; `DistributionIds` is a comma-separated string of department or employee ids. On `POST`, the file is required; on `PUT`, it is optional (upload one only when creating a new version).

Every write forwards `CallerEmployeeId` and `CallerDisplayName` for audit stamping. `CallerEmployeeId` should come from the session (never from the browser) — the Web tier adds it before proxying.

`POST /{documentId}/toggle-status?organizationId={id}` — flips `Active` ↔ `Retired`. JSON body carries the caller stamps.

`POST /{documentId}/workflow` — JSON body:

```
{ "transition": "Review" | "Approve",
  "decision":   "Approve" | "Reject",
  "remark":     "...",
  "callerEmployeeId":  123,
  "callerDisplayName": "Hena E K" }
```

Transitions:

| From stage | Transition | Decision | To stage |
| --- | --- | --- | --- |
| Draft    | Review  | Approve | Reviewed  |
| Draft    | Review  | Reject  | Draft (remark logged) |
| Reviewed | Approve | Approve | Published |
| Reviewed | Approve | Reject  | Draft (back to editor) |

Any other combination is rejected by `sp_document_upload_workflow_transition` with error 52744.

### Errors

Stored procedures raise structured errors in the `52700-52799` range via `THROW`. The service catches `SqlException` and returns a `DocumentSaveResult { Success = false, Error = message }` or `DocumentWorkflowResult { Success = false, Error = message }`. Controllers translate that to HTTP 400.

Anything that is *not* a `SqlException` escapes the service and is caught by the controller, which returns HTTP 400 with the raw `ex.Message`. That path is a diagnostic, not a business error — a framework message shown verbatim in the UI (the `DocumentId` box that 219 fixes) means a reader/binding bug, not a rejected save.

Every `DocumentId` read goes through `SeekResultSetAsync(reader, "DocumentId", ct)`, which advances past result sets that do not carry the column instead of assuming the first one does. It is what keeps the Api correct against a database that has not taken 219 yet, and it makes any future nested-`SELECT` regression harmless rather than user-visible. When the column is genuinely absent the save is still reported as successful — the procedure committed before it returned — and a warning is logged.

## Web tier (`PracticeManagement.Web`)

Base route: `/practice/api/document-uploads`. Thin HTTP proxy in `Controllers/DocumentUploadController.cs` that forwards every call to the Api. Session presence and organisation scope are checked before proxying — the tier NEVER opens a SQL connection.

Multipart requests are streamed straight through (`StreamContent`), so the Web tier never buffers a 50 MB file in memory. The `Program.cs`-registered `PracticeManagementApi` HttpClient is reused.

## UI

The register + upload + workflow ships as a single Razor partial:

- `Views/Practice/Partials/document-uploads.cshtml` — filter toolbar, data table, `New Document` modal (multipart form), Review/Approve modal.
- `wwwroot/js/DocumentUpload/document-uploads.js` — loads lookups, drives the list and modals, submits multipart via `fetch`.

Save failures are shown with `window.gracAlert` (`grac-dialog.js`, loaded by `_Layout`) as `type: "error"` with an explicit title, the same call shape Exception Centre and Risk Centre use. A bare `alert()` is rebound by `grac-dialog.js` to an **Information** dialog, so a terse server message reads as a stray notice rather than a failed save.

`Manage.cshtml` includes `"document-uploads"` in its `workflowScreens` set, so `/practice/manage/document-uploads` renders the partial. Menu visibility is gated by `149_document_upload_menu_seed.sql`.

## Wire-up

Program.cs has one added line (charter §5, approved):

```csharp
builder.Services.AddPracticeDocumentUploadService();
```

That is the only change to a charter-protected file. The extension is defined in `Infrastructure/DocumentUploadServiceRegistration.cs` and registers `IDocumentUploadService` → `DocumentUploadService` as scoped.

## Phase 2 (not in this migration)

- `tbl_acknowledgement_master` / `_details` / `_pending` / `_users` — mapped to `grac_practice.document_acknowledgement*` tables in a later migration.
- `CreateAcknowledgement`, `GetAcknowledgementList`, `GetAcknowledgementDocuments`, user-side acknowledgement endpoints.
- Partial + JS: `acknowledgement-list.cshtml`, `create-acknowledgement.cshtml`, `user-acknowledgement*.cshtml`.
- Ownership: the acknowledgement flow flips a document's `acknowledgement_required` flag into a per-user pending row that the user acknowledges from the User Acknowledgement screen.
