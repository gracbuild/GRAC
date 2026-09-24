# Bulk Mark Applicability — developer notes

Tick several rows whose applicability has not been decided, mark them in one
modal, save once. Available on two screens:

| Screen | Key | Entity | Id posted |
| --- | --- | --- | --- |
| Source Statements (statement tree) | `source-statements` / `organization-controls` | `statement-applicability-bulk` | `FrameworkStatementId` |
| Organization Practices | `organization-requirements` | `requirement-applicability-bulk` | `organization_requirement_id` |

**Frontend:** `practice.js` — `bulkEnabled`, `bulkCell`, `openBulkApplicabilityForm`,
`saveBulkApplicability`
**Backend:** `PracticeRepositoryService` — `SaveStatementApplicabilityBulkAsync`,
`SaveRequirementApplicabilityBulkAsync`
**No migration.** Nothing in the database changed.

---

## There is no second copy of the rules

Both bulk methods **loop the routine the single-record save already uses**, once
per selected id:

* statements → `SaveStatementApplicabilityAsync`, the same method the
  `statement-applicability` entity calls;
* practices → `dbo.pm_manage_practice_repository`, entity
  `organization-requirements`, action `EDIT` — the same call the single-record
  form makes.

So every rule fires per record with no restating: 51044/51045/51047/51048 for
statements, 51032/51033/51034 for practices. **A rule added to the single-record
path applies to bulk the moment it is added.** The statement path's side effects
come along too — the practice import and the statement→practice mapping rows.

One shared payload carries the three applicability fields. For practices that is
enough because the procedure's `UPDATE` branch `COALESCE`s every column it does
not receive from the row it is updating, so nothing else on the record moves.

## Skip and report, per row

The semantics `sp_risk_bulk_review` established for bulk in this schema. A record
that fails a rule is recorded with its reason and the rest proceed — one bad row
must not cost the user the other forty-nine.

`PracticeRepositoryResult.Data` carries `{ Id, Outcome, Reason }` per record.
`Success` is **"at least one row changed"**, because a run where everything was
skipped is a failure the user has to see, not a green message over an unchanged
grid.

That last point has a wrinkle worth knowing: `fetchJson` throws on
`success: false` and the thrown error carries **only the message** — the report
never reaches the UI. So when nothing applied, `BulkResult` puts the distinct
reasons (up to three) *into the message*. Whole-batch failures are usually one
cause repeated, so this stays short.

### Transactions

| Path | Unit of atomicity | Why |
| --- | --- | --- |
| Statements | one explicit transaction per statement, opened by the bulk method | The single-record routine does several writes — the MERGE, the practice import, the mapping insert — and a failure between them would leave a statement Applicable with no practices imported. |
| Practices | the procedure's own `BEGIN TRAN` | `pm_manage_practice_repository` runs `SET XACT_ABORT ON; BEGIN TRAN; … COMMIT` with no `CATCH`, so it is already atomic per call. |

**No outer transaction spans the batch, deliberately.** For practices it would be
actively harmful: `XACT_ABORT` dooms an enclosing transaction on the first
failure, rolling back the records that had already succeeded — the opposite of
skip-and-report. `SaveStatementApplicabilityAsync` gained an optional
`DbTransaction` parameter for the statement path; it defaults to null, so the
single-record caller is unchanged.

## Permissions

Both entities resolve through `PermissionAreaMap` to the **same area as the
single-record save they loop** — `organization-controls` for statements,
`organization-requirements` for practices — and sit in `CanSaveEntity`'s
ADD-or-EDIT list beside `statement-applicability`. A role that cannot mark one
record cannot mark fifty.

They are dispatched **above** the monolith in `ExecuteAsync`, so they inherit
every check already performed on the request: the organization-access test and
the Rule 5 employee-scope guard. Neither is in that guard's refuse list, which is
correct — employees may mark statement applicability, and that is what this is.

## Which rows can be ticked

`isBulkEligible` — applicability is `Not Updated`, **or blank**. Blank counts
because a statement with no organization row yet has no status at all and the
grid already renders that as `Not Updated`.

`bulkEnabled` is not simply "which screen". Source Statements has two levels and
only the second lists statements:

* **Level 1** is the subscribed-release summary. Those rows carry no
  applicability, so without the guard every release would read as `Not Updated`
  and offer a checkbox that marks nothing.
* **Custom releases** render through their own flat grid with no applicability
  column and their own actions.

An ineligible row still gets an **empty** `<td class="pm-select-cell">`, not no
cell — the columns must line up whether or not a given row can be ticked.

## Selection is per load

`bulkSelection` is cleared at the top of `loadRows()`, which every refetch goes
through: page change, search, filter, organization change and Refresh. So the
user is always looking at exactly the rows they are about to change; a selection
surviving a page change would mean saving against rows no longer on screen.

`pruneBulkSelection` covers the other case — a client-side status filter can drop
an eligible row from the statement tree without a refetch, and a selection the
user can no longer see must not travel to the server.

There is **no select-all**. With paging, a select-all covering only the visible
page invites the assumption that it covered the register.

## Column-count invariant

Every colspan adds `bulkColumnCount()`. Four places must stay in step:

1. `listColumnCount()` — the loading / empty / error row.
2. `renderStatementTreeHeader` and the statement tree's empty row.
3. `renderStatementPracticeRows` header.
4. `renderRequirementControlGroups` — its header **and** the `colspan` on the
   `pm-control-group-row` band.

## The two status vocabularies stay apart

They are genuinely different and always have been:

* a **statement** is `Not Updated` / `Applicable` / `Not Applicable` / `Retired`
  — the list `openStatementApplicabilityForm` hard-codes, matching THROW 51044;
* a **practice** takes whatever `applicability_status_master` publishes, through
  the `applicability-status` lookup.

The bulk modal reuses each screen's own list rather than inventing a third. It
offers `Not Updated` on neither — marking a batch as "not updated" is not a
decision, and the rows are already there.

## Client-side validation is a convenience, not the authority

`validateBulkApplicability` mirrors the conditional rules so the user is told
before the round trip rather than getting fifty identical skips back. The server
remains authoritative — the same rules live in `SaveStatementApplicabilityAsync`
(51045/51047) and in the `organization-requirements` branch of
`pm_manage_practice_repository` (51032/51034) — so a rule missed on the client
still cannot get past it.

## What was not touched

Single-record Mark Applicability, on either screen, is unchanged: same action,
same form, same entity, same save path. `SaveStatementApplicabilityAsync` gained
only an optional parameter. Search, filters, sorting and pm-grid paging are
untouched; the bulk button lives in the toolbar and the checkbox is a leading
column.
