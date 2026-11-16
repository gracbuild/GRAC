> **WITHDRAWN (2026-11-05, migration 520).** The Question Repository and its
> Category / Subcategory were removed; questions belong to their Question Set
> again, entered in the set page's grid. See
> [audit-question-sets.md](audit-question-sets.md). The 517 note at the end
> (Response Type list) still applies. Kept for history.

# Audit → Question Repository (migration 516, 2026-11-05)

## What it is

The **Question Repository** is an organization's library of audit questions. It sits in the menu at **Audit Assurance → Question Repository**, right after Audit Definition.

**Question Sets no longer have questions typed into them.** A set's **Add from Repository** button picks Active questions from the Repository. A question's content belongs to the Repository. Inside a set you can change only its **Order**, or **Remove from Set**.

## Question fields

| Field | Required | Notes |
|---|---|---|
| Question Code | Mandatory | Unique per organization among questions that have not been removed. It cannot be changed after the question is created. |
| Question | Mandatory | |
| Category | Mandatory | One of the organization's own categories. |
| Subcategory | Optional | Must belong to the chosen category. |
| Description / Guidance | Optional | Guidance for the auditor. Copied to the set item's help text. |
| Response Type | Mandatory | The Admin-published question types (`admin-question-types`, Control Management `GRAC_New.assurance_question_type`): Yes / No, Multiple Choice, Text, Numeric, Date, Rating, Observation Only, Evidence Upload, Checklist Item -- in the Admin's display order. Needs migration 517 (see below). |
| Mandatory | Mandatory | Yes / No. |
| Evidence Required | Mandatory | Yes / No. |
| Expected Evidence | Optional | |
| Weight | Optional | |
| Status | Mandatory | Active or Inactive. An Inactive question cannot be added to a set. Sets that already hold it keep it. |
| Version | System managed | Starts at 1. It goes up by 1 each time the content changes. A change to Status alone does not raise it. |
| Created By / Date, Modified By / Date | System | |

**Remove** is a soft delete. It is refused while an active Question Set holds the question; set the question to Inactive instead.

**Editing a question also updates its copy in every set that holds it:** text, guidance, response type, mandatory and weight.

## Categories and subcategories

Each organization has its own categories and subcategories. No organization sees another's.

Every organization starts once with the default set below, held in the global table `org_assurance_question_category_default`. Each organization can then add, rename and remove entries in **Categories** on the Repository screen.

| Category | Subcategories |
|---|---|
| IT Infrastructure | Network, Servers, Endpoints, Backup & DR |
| IT Applications | Access Control, Change Management, Application Security |
| Information Security | Policy, Incident Management, Vulnerability Management |
| HR | Onboarding, Offboarding, Training & Awareness |
| Treasury | Payments, Cash Management, Reconciliation |
| Finance & Accounts | General Ledger, Payables, Receivables |
| Operations | Process Controls, Vendor Management |
| Compliance | Regulatory Reporting, Policies & Procedures |
| General | (none). This is where existing set questions landed, and it can be renamed or removed once it is unused. |

Rules for changing categories:
- The defaults are given **once** per organization, recorded in `org_assurance_question_category_seed`. Removing every category does not bring the defaults back.
- Category and subcategory names are unique per organization and per category respectively.
- A category or subcategory that a question uses cannot be removed. Move those questions to another category first.
- A subcategory that is in use cannot be moved to another category.

## Existing set questions

Migration 516 turned every active question in an active set into a Repository question:
- It created one Repository question per organization, code and text, in category **General**.
- Where the same code was used for different texts, the later texts got the code `<code>-S<set id>`.
- Every set row is linked to its Repository question through `org_assurance_question.repository_question_id`.
- Each set row's previous code is saved in `migration_516_question_backup`.

## API

All routes sit under `/practice/api/org-assurance` (Web proxy) and `/api/practice/org-assurance` (API tier). Every call carries `organizationId`, and the Web proxy refuses an organization the caller cannot access.

| Method | Route | Purpose |
|---|---|---|
| GET | `question-categories?organizationId=` | `{ categories:[{categoryId, categoryName, displayOrder, questionCount}], subcategories:[{subcategoryId, categoryId, subcategoryName, displayOrder, questionCount}] }`. Gives the organization its defaults on first call. |
| POST | `question-categories` | `{organizationId, categoryId?, categoryName, displayOrder?}` adds a category, or renames it when `categoryId` is given. Returns `{categoryId}`. |
| DELETE | `question-categories/{id}?organizationId=` | Removes a category together with its subcategories. |
| POST | `question-subcategories` | `{organizationId, categoryId, subcategoryId?, subcategoryName, displayOrder?}` adds, renames or moves a subcategory. Returns `{subcategoryId}`. |
| DELETE | `question-subcategories/{id}?organizationId=` | Removes a subcategory. |
| GET | `question-repository?organizationId=&search=&categoryId=&subcategoryId=&status=&excludeSetId=&page=&pageSize=` | `{totalCount, page, pageSize, rows:[…]}`. `excludeSetId` leaves out questions already in that set (used by the set picker). |
| GET | `question-repository/{id}?organizationId=` | `{data:{…}}`. |
| POST | `question-repository` | `{organizationId, repositoryQuestionId?, questionCode, questionText, categoryId, subcategoryId?, guidance?, questionTypeId, questionTypeCode?, questionTypeName?, isMandatory, evidenceRequired, expectedEvidence?, weight?, status}` creates or updates a question. Returns `{repositoryQuestionId}`. |
| DELETE | `question-repository/{id}?organizationId=` | Removes a question. |
| POST | `question-sets/{id}/questions/from-repository` | `{organizationId, repositoryQuestionIds:[…]}` adds Active questions after the set's last question and skips any the set already holds. Returns `{questionSetId, addedCount}`. |

Each repository row carries: `repositoryQuestionId, organizationId, questionCode, questionText, categoryId, categoryName, subcategoryId, subcategoryName, guidance, questionTypeId, questionTypeCode, questionTypeName, isMandatory, evidenceRequired, expectedEvidence, weight, status, versionNumber, usedInSets, enteredBy, enteredDt, updatedBy, updatedDt`.

The existing endpoints changed as follows:
- `GET question-sets/{id}/questions` and `GET questions/{id}` now also return `repositoryQuestionId, categoryName, subcategoryName`.
- `POST questions` no longer creates a question. It returns `53320 ADD_FROM_REPOSITORY`. For a Repository-linked set item it changes only `displayOrder`.

### Error reasons (`reasonCode`)

| Number | Reason code |
|---|---|
| 53301 | ORGANIZATION_ID_REQUIRED |
| 53302 | CATEGORY_NAME_REQUIRED |
| 53303 | DUPLICATE_CATEGORY |
| 53304 | CATEGORY_NOT_FOUND |
| 53305 | WRONG_ORGANIZATION |
| 53306 | CATEGORY_IN_USE |
| 53307 | DUPLICATE_SUBCATEGORY |
| 53308 | SUBCATEGORY_NOT_FOUND |
| 53309 | SUBCATEGORY_IN_USE |
| 53310 | SUBCATEGORY_NAME_REQUIRED |
| 53311 | REPOSITORY_QUESTION_NOT_FOUND |
| 53312 | QUESTION_IN_USE |
| 53313 | QUESTION_CODE_REQUIRED |
| 53314 | QUESTION_TEXT_REQUIRED |
| 53315 | CATEGORY_REQUIRED |
| 53316 | RESPONSE_TYPE_REQUIRED |
| 53317 | DUPLICATE_QUESTION_CODE |
| 53318 | SUBCATEGORY_MISMATCH |
| 53319 | INVALID_STATUS |
| 53320 | ADD_FROM_REPOSITORY |
| 53322 | NO_QUESTIONS_SELECTED |
| 53323 | QUESTION_INACTIVE |

## Database (516)

**Tables:**
- `org_assurance_question_category`
- `org_assurance_question_subcategory`
- `org_assurance_question_category_default`
- `org_assurance_question_category_seed`
- `org_assurance_question_repository`
- `migration_516_question_backup`

**New column:** `org_assurance_question.repository_question_id`.

**New procedures:**
- `sp_org_assurance_question_category_ensure_defaults`
- `sp_org_assurance_question_category_list`
- `sp_org_assurance_question_category_save`
- `sp_org_assurance_question_category_delete`
- `sp_org_assurance_question_subcategory_save`
- `sp_org_assurance_question_subcategory_delete`
- `sp_org_assurance_question_repository_list`
- `sp_org_assurance_question_repository_get`
- `sp_org_assurance_question_repository_save`
- `sp_org_assurance_question_repository_delete`
- `sp_org_assurance_question_set_add_from_repository`

**Procedures re-issued from 077:**
- `sp_org_assurance_question_list`
- `sp_org_assurance_question_get`
- `sp_org_assurance_question_save`

**Menu:** a new `org-assurance-question-repository` row (also added to 274). Every active role is given full rights to it. The screen reuses the Question Sets feature flag, `screen.org-assurance-question-sets`.

**Rollback:** `516_audit_question_repository_rollback.sql` puts back the 077 bodies and the set questions' codes, then drops everything 516 added. Repository questions and categories are deleted.

## UI

- `Views/Practice/Partials/org-assurance-question-repository.cshtml` is the new screen. It is registered in `PracticeScreen.cs` and `Manage.cshtml`.
  - It has a list with filters for organization, search, category, subcategory and status.
  - Clicking a row opens the question's View.
  - Each row's 3-dot menu offers View, Edit and Remove.
  - An Add / Edit dialog holds the fields above.
  - A **Categories** dialog adds, renames and removes categories and subcategories.
- `org-assurance-question-sets.cshtml`:
  - **Add from Repository** opens a picker with search, a category filter, checkboxes and paging.
  - Editing a question in a set locks its content and leaves Order editable.
  - **Remove from Set** replaces Delete.

## 517 -- Response Type list was empty

The list read "(no response types published by Admin)" although Control
Management 024 publishes nine types. `GRAC_New.assurance_question_type` names
its columns `question_code` / `question_name`, which the 077 lookup
`sp_org_assurance_admin_question_type_list` did not recognise, so it returned
nothing. 517 re-issues it (077 body) with those two column names added and
ordered by the Admin `display_order`. Question Sets' Question Type list had the
same problem and is fixed by the same change. Response types are maintained in
Control Management, screen "Question Types" (`assurance-question-types`); renaming "Text" to
"Descriptive", for example, is done there.

