# Practice View page — developer notes

**Page:** `Web/Views/Practice/Partials/practice-view.cshtml` (full page, not a modal)
**Reached from:** Organization Practices (`organization-requirements`) and the older `practices` grid → 3-dot menu → **View**
**API:** `GET /api/practice/workflow/practice-configure/detail`
**Backend:** `Api/Controllers/PracticeConfigureController.GetPractice`, `Api/Services/PracticeConfigureService.GetPracticeDetailAsync`
**Procedure:** `grac_practice.sp_practice_detail_get` (migration 139, amended by 218, 301, 303, 316)

---

## Two identifiers, one page

The Organization Practices grid is **one row per `organization_requirement`**. Its
`PracticeId` column comes from an `OUTER APPLY` over `grac_practice.practice`, so it is
**NULL whenever no practice row exists yet**. `practice.js` therefore navigates on
whichever id the row actually carries:

```js
const filterType = practiceId ? "Practice" : "OrganizationRequirement";
```

and the page forwards whichever it received. `sp_practice_detail_get` accepts both.

## Why a requirement can have no practice row

`grac_practice.practice` rows are materialised lazily, not at requirement creation:

| Trigger | Where |
| --- | --- |
| Saving the requirement (Mark Applicability included) | `pm_manage_practice_repository`, `organization-requirements` branch |
| Configuring an instance | same proc, `practice-instances` branch |
| Adding a practice by hand | same proc, `practices` branch |

A requirement created by the migration-010 sync from applicable controls and never
touched since has **no practice row**. Those untouched rows are exactly the ones still
sitting at applicability `Not Updated` — which is why the symptom looked like "View is
broken for practices that aren't marked Applicable".

Before migration 218 that state produced:

```
sp_practice_detail_get -> THROW 52500
  -> GetPracticeDetailAsync returns Success = false
  -> GetPractice returns NotFound()
  -> "This practice could not be loaded (HTTP 404)."
```

## The 218 fallback

When the requirement resolves to no practice, the procedure now answers from
`grac_practice.organization_requirement` instead of throwing. Field mapping:

| Response column | Practice path | Fallback path |
| --- | --- | --- |
| `PracticeId` | `p.practice_id` | **`0`** |
| `PracticeCode` / `PracticeName` | `p.practice_code` / `p.practice_name` | `q.requirement_code` / `q.requirement_name` |
| `Description` | `p.description` | `q.requirement_statement` |
| `OriginType` | `p.origin_type` | `q.origin_type` |
| `PracticeOwner` / `PracticeOwnerId` | `p.practice_owner*` | **`NULL`** (owner is a practice column) |
| `ApplicabilityStatus` | `p.applicability_status` | `COALESCE(aps.status_name, q.applicability_status)` |
| `ExclusionJustification` | `p.exclusion_justification` | `q.exclusion_justification` |
| `Status` | `p.status` | `COALESCE(rs.status_name, q.status)` |
| `RequirementCode` / `RequirementName` | joined `req.*` | `q.requirement_code` / `q.requirement_name` |
| `ActiveInstanceCount` | live count | **`0`** |

Two things to hold on to:

- **`PracticeId` is `0`, not `NULL`.** `PracticeConfigureService` reads it with
  `Convert.ToInt64`, which throws on `DBNull`. `0` is also what the page tests.
- **The two SELECTs must keep identical column names and types.** The reader binds by
  name; a column present in one branch and missing from the other is a runtime
  `IndexOutOfRangeException`, not a compile error.

The procedure does **not** materialise a practice row. It is a read path — a GET that
writes would create practice rows for Not Applicable requirements as a side effect of
somebody merely looking at one.

New error code: `52512` — requirement not found for this organization. (`52500` and
`52501` keep their existing meanings for the practice path; the 139 header reserves
52500–52512 for this file's procedures.)

## Section order

Top to bottom: **Practice Details → Practice Instances → Obligations.**

Practice Instances moved above Obligations. The page now reads *what this
practice is → where it is carried out → what it requires*, and Configure —
the action that creates the instances — is the first one you meet instead
of the last. Obligations is also by far the tallest section, so with it in
the middle the instance list sat below a screen of obligation cards.

Evidence is **not** a section of its own on this page: it renders inside
each obligation card (`renderEvidence`, a type badge with the published
remark beneath). See [Evidence: type name and remark](#evidence-type-name-and-remark-migration-302).

## Configure button

Configure lives in the **Practice Instances** panel header, not in the page
heading. It acts on that list, so it belongs beside it; in the heading it
read as an action on the practice as a whole. Only the element moved — same
`#pvConfigureBtn` id, same `openConfigure` handler, same dialog, same
`practiceId > 0` gate. `Back to Practices` stays in the heading, because
that *is* a page-level action.

`#pvRoot .pm-panel-header > .pm-button` right-aligns it (`margin-left:auto`)
and centres it against the title — the header is `align-items: baseline`,
which parked the button a few pixels low. The rule keys on the button, so
headers without one are untouched.

`practice-view.cshtml` only shows Configure when `practiceId > 0`:

```js
document.getElementById('pvConfigureBtn').hidden = !(practiceId > 0);
```

Configure creates one `practice_instance` per selected team against a practice id
(`sp_practice_instance_configure`, which throws 52505 without a valid practice). With no
practice row there is nothing to hang instances on, and configuring instances for a
requirement nobody has marked Applicable would be wrong regardless. The page still
renders the full detail panel read-only.

## Add New Obligation (migration 307)

The Obligations panel header carries **Add New Obligation**. It authors a
**practice-level** obligation — one the organization owns, against the
practice, applying to every Practice Instance of it. That is a different
thing from *Add obligation* on Operationalize, which adds one to a single
instance; both write through the same shared form
([resolve-typed-obligations.md](resolve-typed-obligations.md#the-obligation-form-is-a-shared-component)),
opened here with `scope: "practice"`.

The practice's own obligations render as the **first** group of the panel,
above the published ones, each with an *on N instances* badge and Edit /
Remove. They lead because they are the half this page can change, and
burying them under the published groups would hide what the button just
created.

Three details worth knowing:

- **The button is hidden unless `practiceId > 0` and the obligation type
  list loaded.** No types means no way to say what an obligation *is*, and
  the save procedure refuses one without a type — so it does not appear
  rather than leading somewhere that cannot succeed. A requirement with no
  practice row (see [The 218 fallback](#the-218-fallback)) has nothing to
  hang obligations on either.
- **Loading the panel reconciles it.** `loadPracticeObligations` posts to
  `/practice/api/practice-obligations/fan-out` before it reads, so an
  instance created after a definition existed picks up its copies without
  anyone pressing Save. Idempotent, and best-effort — the list is still
  correct if it fails, the instances are simply not caught up yet. Same
  argument migration 304 made for evidence.
- **The published half failing no longer blanks the panel.** The two feeds
  are independent, so a failure on the published one shows a warning line
  above the practice's own obligations instead of an empty state that
  would claim there are none.

The form is told `showImplementationStatus: false` and
`showConnection: false`: both are facts about *doing* the work, and the
work happens on an instance. The practice says what is required; the
instance answers how far and against what.

## Configure closes itself on a successful save

`saveConfigure` used to leave the dialog open on success, with the outcome
table inside it, and the Save button disabled — so the operator closed it
by hand and only then saw the new instances.

Now, on success and in this order:

1. `renderOutcome(body)` — the summary and the per-team table, still
   inside the dialog.
2. `loadTeams` → `loadPractice` → `loadInstances` →
   `loadPracticeObligations`, all **awaited**. The refresh finishes
   *before* the dialog closes, so the new instances are already listed
   behind it rather than filling in afterwards. The last one is migration
   307's fan-out: a new instance needs its copies of the practice's own
   obligations.
3. The same summary is written to `#pvInstanceMessage`, a `.pm-message` in
   the Practice Instances panel.
4. The dialog closes after **700ms** — the delay the shared task form uses
   after a save. A modal that vanishes the instant the click lands reads
   as though nothing happened.

**On failure nothing above runs.** The dialog stays open, the error goes
in `#pvConfigureMessage` as it always did, the Save button is re-enabled
and the selection is intact for a retry.

Three details that make it behave:

- **The summary is on the page, not only in the dialog.** Closing would
  otherwise take the only record of what happened with it — including the
  two things worth reading: how many teams were skipped for already having
  an instance, and how many instances were created *with no owner* (not
  assurance-eligible). `outcomeSummary(body)` builds that sentence once and
  both places use it.
- **`#pvInstanceMessage` is cleared when a save starts.** A previous
  "3 instances created" sitting behind a dialog that is about to show an
  error would read as though this attempt had worked.
- **`configureOpenSeq`** is bumped on every open and captured by the
  delayed close, so a dialog the operator closed and reopened inside those
  700ms is not shut under them.

The Save button is not re-enabled on the success path, and does not need
to be: `loadTeams` clears `selected` and re-renders, and the selection-count
sync sets `disabled = selected.size === 0`.

## Obligations panel

This panel is why the **View Obligations** entry was removed from the Organization
Practices 3-dot menu. It opened a dialog showing the same obligations the View page
renders inline, so the menu carried two routes to one thing. Removed from
`actionDefinitions`, from the per-applicability override in `allowedActions`, and from
the action dispatcher, along with its now-unreferenced label and icon entries.

`showEvidenceObligations()` itself is **not** dead — the dialog is still opened from the
Practice Instance evidence section (`#viewEvidenceObligations`) and re-entered internally
when the user switches practice inside it.

Otherwise unaffected by all of the above — `loadObligations()` already sends
`organizationRequirementId` alongside `practiceId`, and
`sp_pm_view_obligations_typed` (migration 122) accepts either. A requirement with no
practice row still shows its published obligations.

## Obligation text (migration 301)

Each obligation card prints the authored text under its name.
`sp_pm_view_obligations_typed` had the text all along but only ever borrowed it, as the
fallback when an obligation was published without a name:

```sql
COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
         LEFT(o.obligation_text, 300)) AS ObligationName
```

301 adds `o.obligation_text AS ObligationText` beside it — raw and untruncated. That
fallback is untouched, which is the catch: for a nameless obligation the *name* already
**is** the text, so printing both would repeat the same words, exactly for anything under
300 characters. `obligationText(row, name)` drops the second line whenever either string
starts with the other, so those cards render as they always did.

The API needed no change — `ReadTablesAsync` builds a dictionary per row keyed by column
name, so a new column flows through on its own. `ObligationTypedRow` in
`PracticeRepositoryModels` gained the property for documentation only; nothing
deserializes into it.

## Mapped frameworks (migration 301)

Practice Details shows a **Frameworks** row: one `pm-badge` per framework release the
practice is mapped to.

**Source:** `grac_practice.organization_statement_practice_mapping` → `GRAC_New.release`.
This is the same relationship the Source Statements grid already reads in the other
direction (its `statement_practice_counts` CTE counts practices per statement), not a
second definition of it. `release_id` on that table is nullable, so the org statement's
own release is the fallback.

A practice that arrived through a **Control** rather than a Statement has no mapping row
at all. The `UNION`'s second arm covers it from `organization_control.release_id`, held
back by a `NOT EXISTS` so it stays silent for any practice that does have statement
mappings.

The label is built with the same `COALESCE(artifact_code + ' ' + version_no, ...)`
expression `sp_pm_view_obligations_typed` uses, so a release named in the header and the
same release named on an obligation card below read identically.

**Why JSON, not `STRING_AGG`.** The page draws one badge per release. Splitting a
delimited string on `', '` breaks the first time an artifact name contains a comma, and
breaks silently — as two half-named badges. `FOR JSON PATH` is also the shape this schema
already uses for repeating detail (`StateRulesJson`, `EvidenceJson`, …), and the page
already carries the `jsonArray()` parser for it. `COALESCE(..., N'[]')` means empty is
never NULL.

**Three ways to have nothing, one outcome.** No mapping, an empty array, or a database
still on the pre-301 procedure — all produce `''` from `frameworkChips()`, which the
existing `.filter()` in `renderPractice` drops. The row is simply not drawn, the way it
already is not drawn for a practice with no owner. `GetPracticeDetailAsync` reads the
column through `HasColumn` for the same reason: the app and the database deploy
separately, and against a pre-301 database `reader["MappedFrameworksJson"]` would throw
`IndexOutOfRange`, land in the catch, and answer the page with "could not be loaded". An
unapplied migration should cost the Frameworks row, not the whole page.

Both branches of `sp_practice_detail_get` return the column — the practice branch **and**
the 218 requirement-fallback branch — because a caller reading it by name must find it
whichever branch answered.

## Mapped source statements (migration 316)

Practice Details shows a **Source Statement** row directly beneath **Frameworks**: one
`pm-badge` per Source Statement the practice is mapped to. Same rendering as Frameworks
(`sourceStatementChips()`, a near-copy of `frameworkChips()`), same `'html'` render kind,
same `pm-detail-wide` (2-column span) — which is what puts it on its own row immediately
under Frameworks rather than beside it.

**Source: the same `organization_statement_practice_mapping` rows Frameworks reads,
joined to `GRAC_New.framework_statement` instead of `GRAC_New.release`.** This is not a
second lookup of what the practice is mapped to — `MappedFrameworksJson` already
establishes `m.org_practice_id = <organization_requirement_id> AND m.status = 'Active'`
as the scope; `MappedSourceStatementsJson` uses the identical `WHERE`, and the join
target (`fs.framework_statement_id = m.framework_statement_id`) is exactly the join
`QueryReleaseStatementsAsync` (`PracticeRepositoryService`, the Source Statements grid)
already uses to read `StatementReference` / `StatementTitle` off `GRAC_New.framework_statement`.

The label (`SourceStatement`) is built as `statement_reference + ' - ' + statement_title`,
falling back to whichever half is present — the same concatenation
`QueryOrganizationRequirementFallbackAsync` already builds for `MappedControl` from the
same two columns.

**No Control-origin fallback, unlike Frameworks.** `MappedFrameworksJson`'s `UNION` second
arm supplies a release for a practice that arrived through a Control (which has no
`organization_statement_practice_mapping` row at all). A Control has no individual
statement underneath it to name, so that same practice correctly gets `'[]'` here even
though it still shows a Framework — this is the "if none available, handle gracefully"
case, not a bug: the row is simply not drawn, same as any practice with nothing mapped.

**Multiple statements.** A practice can be mapped to more than one Source Statement (the
same many-to-many `organization_statement_practice_mapping` table that lets one practice
carry several Frameworks). Every distinct one renders as its own badge, ordered by
`StatementReference`, exactly like Frameworks orders by `FrameworkRelease`.

Same defensive shape as Frameworks throughout: `COALESCE(..., N'[]')` in SQL so empty is
never `NULL`; `HasColumn(reader, "MappedSourceStatementsJson")` in
`GetPracticeDetailAsync` so a pre-316 database degrades to "row omitted" rather than
"page could not be loaded"; `jsonArray()` on the client parses defensively the same way.
Both branches of `sp_practice_detail_get` return the column, for the same reason
Frameworks does.

## Evidence: type name and remark (migration 302)

Each evidence renders as its type name badge with the remark on the line beneath.
Before this, the section printed the type name **twice** and no remark.

**The duplication was in the data, not the binding.** `EvidenceJson` in
`vw_pm_obligation_typed_detail` is a `UNION ALL` of two paths to the *same*
`requirement_obligation_evidence` row:

| Path | How it is reached |
| --- | --- |
| `Direct` | the row carries `obligation_id` — the legacy 1:M path, still populated |
| `Link` | the same row via one of the six per-type evidence link tables |

A row that is both stamped **and** linked satisfies both arms and comes back twice, with
the same `ObligationEvidenceId`. That is what read as `Evidence: Policy Policy`. Neither
row is wrong; the list was just one row per *path* instead of one per *evidence*.

302 wraps the union in `ROW_NUMBER() OVER (PARTITION BY ObligationEvidenceId ...)` and
keeps the first. The `Link` row wins the tie because it is the one carrying
`LinkTypeCode`. The projection is otherwise untouched — columns are named instead of
`SELECT *` only so the ranking column stays out of the JSON.

**`Remarks` was already there**, projected as `roe.remarks` since 224. The page simply
never rendered it, which is why the second badge looked like it was standing in for the
remark. No API change was needed for either half of this fix.

### Why 302 re-runs 228's builder

The view is **not hand-written**. Migration 228 assembles it with dynamic SQL, probing
`OBJECT_ID` for every GRAC_New detail table and each of the six link tables so a type
whose table Control Management has dropped resolves to `'[]'` rather than failing to
parse. Freezing a static view would throw that away. 302 is therefore 228's builder with
the `@evidence` fragment de-duplicated.

**Re-running 228 after a CM schema change reinstates the duplicates.** Re-run 302
afterwards, or run 228 then 302.

### Three consumers, one fix

`EvidenceJson` is shared, so all three were showing the doubled list and all three are
fixed together:

| Consumer | Where |
| --- | --- |
| Practice View obligation cards | `practice-view.cshtml`, `renderEvidence` |
| Resolve Workspace obligation detail | `resolve-workspace.cshtml`, `publishedEvidenceJson` |
| View Obligations dialog | `practice.js`, `expandTypedObligationRows` |

`sp_resolve_obligation_list.PublishedEvidenceCount` is **not** affected — it never read
this view, computing `COUNT(DISTINCT roe.evidence_type_id)` in its own `OUTER APPLY`, so
it was already counting each type once.

`renderEvidence` still de-duplicates client-side, keyed on `ObligationEvidenceId` with a
fall back to the type name. That is deliberate: the app and the database deploy
separately, and it is what keeps the page correct against a database that has not had 302
applied yet.

## Implementation Status replaces Requirement (migration 303)

Practice Details leads with the practice's implementation roll-up. **Requirement
was removed from this section** — the page already names it in the heading and
again on every obligation card, so a third copy was repetition.

`sp_practice_detail_get` now returns `PracticeImplementationStatus` using the
same rule and the same four labels as the Organization Practices list (see
`docs/organization-practices-implementation-status.md` for the rule itself).
Two choices keep the two screens agreeing:

1. **Keyed on `organization_requirement_id`, not `practice_id`.** That is the key
   the list rolls up on — its `PracticeInstanceCount` joins practice on
   `organization_requirement_id` too. Rolling up by `practice_id` here would make
   the View disagree with the row the user clicked to reach it, whenever a
   requirement has more than one practice.
2. **Applicability read from `organization_requirement`.** The practice row
   carries an `applicability_status` of its own and this deliberately ignores it:
   it can lag the requirement, and the list never reads it. The practice branch
   joins `applicability_status_master` through `req` for exactly this.

Both branches gain the column — the practice branch and the 218 requirement
fallback. The detail grid grew a third render kind for it, `'badge'`, alongside
`'html'` (Frameworks) and plain escaped text, so the status renders as the same
`pm-badge` the grids give it through `formatCell`.

## Practice Instances section

Lists every instance under the practice, in the Practice Instances screen's own
columns and order:

`Code · Name · PrimaryOwner · Department · Criticality · ImplementationStatus · Status`

**Execution Frequency, Assurance Frequency and Practice Type (`AssuranceMode`) were
removed from this grid on request** (display only — this grid's own request, not the
generic Practice Instances screen it reuses). They were the middle three entries of
`instanceColumns`; deleting the three array entries is the entire change. The API keeps
returning them — `QueryPracticeInstanceFallbackAsync` and its `@@practice_id` filter are
untouched — and `renderObligation`/`renderPracticeObligation`'s own `ExecutionFrequency`
reads (a different context, the obligation cards further down the page) are unaffected.
No colgroup or per-column width ever keyed this table by position: `.pm-table-wrap table`
is `width: 100%` with no fixed column widths, so the remaining seven columns simply
reflow to fill the row. The `:last-child` override two paragraphs down still finds the
correct column (now `Status`) because it selects by position-in-row, not by name.

**No new endpoint and no new query.** It posts to the existing
`practice-instances` entity with `practiceId` set — a filter that query already
supports (`@@practice_id` in `QueryPracticeInstanceFallbackAsync`), so this is the
Practice Instances list with one more `WHERE` clause. `PermissionAreaMap` already
maps `practice-instances` to `organization-requirements`, so the section is
governed by the screen the user is on.

`instanceColumns` is one list that drives both the header and every row, so the
two cannot drift apart. Criticality, Implementation Status and Status render as
badges, matching `formatCell` in the grids.

Three details worth knowing:

* **No practice row means no instances**, and that is the empty state, not a
  failure: Configure creates instances against a practice id, so a requirement
  that has never been marked Applicable has none by definition. `loadInstances`
  returns the empty state without calling the API.
* **The empty-state message is the Practice Instances grid's, word for word.**
* **`.pm-table-wrap` reserves its last column for Actions** — 58px and centred.
  This grid is read-only and has no Actions column, so a scoped override returns
  its last column (Status) to a normal one.

`loadInstances` is not awaited by `init()`, like `loadObligations` — the page is
usable without it. `saveConfigure` calls it after a successful save so instances
Configure just created appear without a reload.

## The Practice Instances menu entry was retired

The 3-dot menu on **Organization Practices** no longer offers *Practice
Instances*. It opened Operationalize filtered by requirement (migration 287), and
that is reachable two other ways now — this page lists the instances, and
Operationalize owns working on one.

Removed in three places, all in `practice.js`:
`actionDefinitions["organization-requirements"]`, the `applicable` branch of
`allowedActions`, and the dispatcher arm that was its only caller.

**`newInstance` stays**, and stays applicable-only. **The `practices` screen still
offers `instances`** — `openInstancesFor` and its dispatcher arm are untouched, so
nothing about Operationalize or the Practice Instance flow changed.

## Evidence no longer waits for a save (migration 304)

*Operationalize, not this page — recorded here because the evidence data is the
same and the two were diagnosed together.*

`practice_instance_evidence` rows were created in exactly one place: the evidence
block inside `sp_resolve_obligation_adopt`, which runs **only on save**. So an
obligation could be adopted and show nothing under Evidence, and the panel had to
say so:

> 1 evidence type is published, but no row exists here … press Save obligations to
> try again

On the reported instance that message was **not** a catalogue problem. Diagnosis
ruled out both candidates — no name mismatch between `GRAC_New` and
`grac_practice.evidence_type_master`, and no orphan `evidence_type_id`. All three
obligations showed `PublishedCount = 1`, `CreatableTypes = 1`, and zero rows of
any kind. The rows were simply never inserted, because the evidence was published
to the repository *after* those obligations were adopted, and nothing re-runs that
insert.

### The fix

`304_evidence_reconcile_on_load.sql`:

1. **`sp_resolve_evidence_reconcile_for_instance`** — new, carrying the
   adopt-unattached `UPDATE` and insert-missing `INSERT` **byte for byte from
   244**, with one substitution: the driving set is the adoption table rather
   than the call's payload (`FROM @req r WHERE r.IsAdopted = 1` → `FROM @adopted r`).
   Verified by diff: four changed lines, nothing else.
2. **`sp_resolve_obligation_adopt`** — re-emitted from 244 with that block removed
   and an `EXEC` in its place. One copy of the rule, not two. It keeps behaving as
   before because it writes its adoption rows *earlier* in the same procedure, so
   the reconcile sees what the payload just made true.

`ResolveWorkspaceService.ListObligationsAsync` then calls the same procedure
before listing. A read that writes, deliberately — and the pattern already in use
here: `QuerySubscribedFrameworksAsync` and `QueryReleaseStatementsAsync` both sync
before querying.

### Why it is safe on every load

* **Idempotent** — the `INSERT` keeps its original `NOT EXISTS` guard
  (instance + evidence type + source obligation, Active), so a second load writes
  nothing.
* **Adopted only** — `@adopted` reads `practice_instance_obligation` where
  `status = 'Active'`. Adopting is still the decision; an un-adopted obligation
  gets no rows.
* **Repository only** — `obligation_id > 0` excludes organisation-defined
  obligations, whose evidence travels the 231/232 link column.
* **No result set** — a plain `EXEC` returns nothing, so no `INSERT … EXEC` and
  nothing that could block a `ROLLBACK`.
* **Creates only** — never deletes or overwrites. Retiring evidence when an
  obligation is un-adopted stays in `sp_resolve_obligation_adopt`, where that
  decision is made.
* **Fails soft** — `ReconcileEvidenceForInstanceAsync` catches and logs, like
  `SyncGapForInstanceAsync`. On a database without 304 the call raises 2812 and is
  swallowed, so the workspace still lists obligations with whatever rows exist.

### Un-adopted obligations show the published list

`evidenceBlock` now renders `publishedEvidenceJson` — already on every card, and
already de-duplicated by 302 — as read-only "Not started" entries with their type
name and remark, instead of a bare count. The operator sees what adopting will
commit them to.

The "press Save to try again" sentence is gone. An **adopted** obligation now
arrives with its rows created and never reaches that branch; reaching it while
adopted means the reconcile could not run, which the text now names as a fault to
report rather than a chore to hand the operator.

`database/_diag_unmapped_evidence_types.sql` is the permanent check — section 1
needs no parameters and returns nothing once this is applied.

## Rollback note

`218_practice_detail_requirement_fallback_rollback.sql` restores the 139 procedure body.
The Web change is safe to leave in place: with the fallback gone, `PracticeId` is always
a real id, so `!(practiceId > 0)` never hides anything it did not hide before.

`301_practice_view_text_and_frameworks_rollback.sql` restores the 224 and 218 bodies.
Nothing errors afterwards: obligation cards lose the text line, Practice Details loses the
Frameworks row, and both were read defensively from the start. No Web or API rollback is
needed.

**301 re-emits both procedures whole**, because `CREATE OR ALTER` replaces a procedure
whole. The next change to either body belongs in 301, not in 224 or 218.

`304_evidence_reconcile_on_load_rollback.sql` restores 244's adopt procedure with
its evidence block inline and drops the reconcile procedure. It reinstates a known
defect: evidence is created on save only again. **Roll the API back with it, or
first** — `ListObligationsAsync` calls the dropped procedure, and although that
call fails soft (the workspace still loads), it will log a warning on every load
until the Web tier is rolled back too. Rows created while 304 was in place are
correct and are left alone; they are the rows adoption would have made anyway.

`303_practice_detail_implementation_status_rollback.sql` restores the 301 body —
`ObligationText` and `MappedFrameworksJson` intact, `PracticeImplementationStatus`
gone. The header loses that row and nothing errors: the column is read through
`HasColumn` and the renderer omits a row with no value. The Organization
Practices list is unaffected; it derives its own copy in the API and never called
this procedure. **The next change to this procedure's body belongs in 303**, not
in 301 or 218.

`302_evidence_dedupe_rollback.sql` restores 228's builder unmodified. It reinstates a
known defect — evidence listed once per path again, on all three screens above — and
nothing errors in either direction, because `renderEvidence` keys its blocks on the row's
own identity. The next change to the view's builder belongs in 302, not in 228.

`316_practice_detail_source_statements_rollback.sql` restores the 303 body —
`MappedFrameworksJson` and `PracticeImplementationStatus` intact,
`MappedSourceStatementsJson` gone. The header loses the Source Statement row and nothing
errors: the column is read through `HasColumn` and `renderPractice`'s filter already drops
a row with no value, the same path a pre-301 database takes for Frameworks. **The next
change to this procedure's body belongs in 316**, not in 303, 301 or 218.

The `instanceColumns` column removal (Execution Frequency, Assurance Frequency, Practice
Type) has no database or API component and so nothing to roll back beyond re-adding the
three array entries in `practice-view.cshtml` — see
[Practice Instances section](#practice-instances-section).
