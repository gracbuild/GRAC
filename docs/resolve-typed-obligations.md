# Typed obligation detail on Operationalize — developer notes

The obligation card on the Resolve / Operationalize workspace now shows
the fields the admin module actually captured for that obligation's
type, instead of the same four for every one of them.

**Migrations:** `224_resolve_obligation_typed_detail.sql` /
`224_..._rollback.sql`, then `225_obligation_typed_detail_full_row.sql` /
`225_..._rollback.sql` (which is the one that makes it schema-driven —
see [Why the field list is not written down](#why-the-field-list-is-not-written-down-anywhere))
**API:** `Api/Models/ResolveWorkspaceModels.cs` (`ResolveObligationRow`),
`Api/Services/ResolveWorkspaceService.cs` (`ListObligationsAsync`, `OptionalJson`)
**UI:** `Web/Views/Practice/Partials/resolve-workspace.cshtml`
**Depends on:** Control Management `026` / `027` (the taxonomy tables in
`GRAC_New`), `122` (the projection this extracts), `140` / `141`

---

## What was wrong

Every obligation card showed the same strip:

```
Published frequency | Responsibility | Approval | Retention
```

Those are the columns the **pre-taxonomy flat model** had. Control
Management has since moved to the seven-type obligation taxonomy, where
each type carries its own fields:

| Type | What the admin module captures |
| --- | --- |
| State | attribute, operator, value, unit, tolerance |
| Execution | action, frequency, trigger condition, responsible party, due within |
| Assurance | verification method, scope, frequency, assurance party |
| Event Response | trigger event, response action, SLA, escalation path |
| Constraint | prohibited condition, scope, exception policy |
| Retention | retained object, min/max retention, disposal policy |
| Evidence | cross-cutting — a type of its own *and* attachable to the six above |

A State obligation rendered as "frequency / responsibility / approval /
retention" is four dashes, while the rule it actually carries —
`password length >= 12` — appeared nowhere on the screen.

## One projection, two consumers

Migration **122** had already written this projection once, for the View
Obligations screen: six `FOR JSON PATH` sub-queries plus the combined
evidence array. Pasting it into `sp_resolve_obligation_list` would have
made two places that must both learn about an eighth obligation type,
and the second one to be forgotten is the bug.

The sub-queries are keyed purely on `obligation_id` — no context, no
parameters — so 224 lifts them unchanged into

```
grac_practice.vw_pm_obligation_typed_detail
    ObligationId
    StateRulesJson  ExecutionSpecsJson  AssuranceSpecsJson
    EventResponsesJson  ConstraintRulesJson  RetentionSpecsJson
    EvidenceJson
```

and both procedures select from it:

* `sp_resolve_obligation_list` — re-issued from the 141 body with the
  view joined and the seven columns added.
* `dbo.sp_pm_view_obligations_typed` — re-issued from the 122 body with
  its inline sub-queries replaced by the join. **Same result set, same
  column names, same order** — only where those seven values come from
  has moved.

The view is deliberately **not** `SCHEMABINDING`: it reads `GRAC_New`,
which Control Management owns and reshapes on its own schedule, and
binding it would make a CM migration fail against a PM object.

No status filter on the view's base row either — consumers apply their
own. The *detail* rows are filtered to Active, because a retired state
rule is not part of the obligation any more.

## Why the field list is not written down anywhere

**Migration 225.** The first cut of this (224) listed the columns of each
detail table by name, because migration 122 listed them by name. That
list was right when 122 was written.

It was wrong by the time anyone looked at an Assurance obligation: the
card showed **Scope** and **Remarks** and nothing else, while the admin
module was capturing verification method, assurance party, **trigger
mode**, and then either event details (trigger mode = event driven) or an
assurance frequency (scheduled). `GRAC_New.obligation_assurance_spec` had
gained columns, and a projection that names columns cannot show one it
does not name.

Practice Management does not own those tables — Control Management does,
and extends them on its own schedule. Every extension needed a PM
migration to become visible, and until someone wrote it the screen showed
a subset while looking complete. That is worse than showing nothing.

So there are now **no field lists on either side**:

* The view selects the **whole detail row** per type (`SELECT s.*`), plus
  the label columns its foreign keys resolve to — a frequency id is not a
  frequency name, and only the join knows the difference.
* `publishedBlock(o)` renders **every key it receives**, hiding the empty
  ones, with `hiddenDetailKeys` for row plumbing (`status`,
  `entered_by`, `record_status_id`, surrogate keys …) and `idHasLabel`
  for a raw foreign key that has its resolved label beside it.
* `humanise()` turns any unknown key into a label — `trigger_mode`
  becomes *Trigger mode*. `detailLabels` is presentation polish for a few
  keys (`slavalue` → *SLA*), never a gate on what is shown.

`typedArrays` maps `TypeCode` → which array and what to call the badge.
That is the only per-type knowledge left, and adding an eighth type is
one entry plus one column on the view.

### The conditional shapes render themselves

`FOR JSON PATH` omits null-valued keys, and the renderer drops empty
ones. So an assurance spec with trigger mode **Scheduled** has null event
columns and simply does not show them; an **event driven** one shows the
event fields and no frequency. Neither tier encodes that rule.

### The one special case

**State** — `attribute operator value unit` is rendered as one monospace
line, because splitting `password length >= 12` across four columns hides
the thing being said. Those four keys are then marked consumed so the
generic pass does not repeat them.

**Evidence** is the seventh entry in `typedArrays` and maps to
`publishedEvidenceJson`. Without it a standalone Evidence obligation
would fall through to the flat block and show nothing of what it asks
for. Its array stays an explicit column list in the view — it is not one
table's rows but a UNION of the legacy 1:M evidence and the six per-type
link tables, so the columns have to be stated to line the halves up.

### SELECT * is right here, and not in general

`SELECT *` is normally a liability: the shape of a result set changes
under callers who did not ask for it. Here the caller is a JSON
serialiser feeding a renderer written to be shape-agnostic, and the table
belongs to another module. The alternative — a name list PM keeps in step
with CM by hand — is exactly what produced the defect.

The risk that remains is a **column collision**: if Control Management
adds a column literally called `AssuranceFrequency` to the assurance
spec, `FOR JSON` emits it twice and the browser keeps the last. Rename
the alias in the view if that ever happens.

### Finding out what the columns actually are

Migration 225's verification section dumps `sys.columns` for all six
detail tables, and a sample of the JSON the view now emits. That is the
answer to "what does the admin module capture for this type" without
needing the Control Management repository to hand.

### The fallback is not an error state

An obligation with no typed detail shows the four published fields and
says why:

> No state rule detail has been recorded for this obligation in the admin
> module.

That is the honest reading for every row Control Management `027`
back-filled as `Execution` with no detail rows — classifying them is an
SME task, not a migration. Without the sentence, four dashes look like a
rendering fault.

### Description

`ObligationDescription` is a second alias for `obligation_text`, so the
card can show it under a **Description** heading without a caller having
to know the title falls back to the same column. `description(o)`
suppresses it when the title *is* the text — `ObligationName` is
`COALESCE(NULLIF(obligation_name,''), LEFT(obligation_text, 300))`, and
repeating it verbatim underneath is noise.

## Layout: stacked, not side by side

Obligations and Dependencies were a two-column grid
(`grid-template-columns: repeat(auto-fit, minmax(430px, 1fr))`). They are
now stacked — obligations above, dependencies below.

An open obligation card can run to a dozen labelled fields, and half a
screen is not enough width for it: the columns turned every open card
into a narrow ribbon of wrapped text. Reading order is also the working
order — adopt the obligations, then resolve what they depend on.

## Degrading when 224 is not applied

`ResolveWorkspaceService` reads the seven columns through `OptionalJson`,
which checks `HasColumn` first and returns `"[]"` otherwise, and sets
`TypedDetailAvailable` from the same check. A database without 224 loads
the workspace unchanged and every card takes the flat fallback.

The reverse is also safe — a rolled-back API against a 224 database
simply ignores columns it does not read. There is no deployment ordering
constraint between the tiers, only the one inside the rollback script
(restore both procedures before dropping the view).

---

# The adoption parameters (migration 226)

Showing the published detail properly made the editable row underneath
look wrong: it was still the pre-taxonomy parameter set, asking again for
things the block above now answers.

| Field | Before | Now |
| --- | --- | --- |
| Execution frequency | select | **kept** — see below |
| Assurance frequency | select | **removed** |
| Responsibility | free text | **role**, from Role Master |
| Approval authority | free text | **role**, from Role Master |
| Assurance type | — | **new** — Manual / Automated |
| Retention | text | **removed** |
| Remarks | textarea | ~~unchanged~~ — **removed in 254**, see below |

On the evidence rows, **Collection frequency** and **Retention** are
removed for the same reason — the published evidence spec carries both.

## Remarks removed from the card (254)

Both of them, on sir's instruction:

- the **published** Remarks in the *As published* block — every typed
  array carries a `remarks` column (224 projects `roe.remarks` and the
  per-type equivalents), so it rendered on every card as free text the
  authority wrote for itself, not something the organisation acts on.
  Removed by adding `remarks` to `hiddenDetailKeys`, the same mechanism
  that already retired `scope`, `trigger_condition` and
  `exception_policy`.
- the **editable** Remarks textarea beside Implementation status.

Unlike the 226 removals above, `buildObligationPayloadRow` still sends
`remarks`. It has to: `sp_resolve_obligation_adopt` assigns
`remarks = src.Remarks` **directly, with no COALESCE**, so an omitted key
would blank the column on every save. With no input on screen, `val()`
falls through to the stored value and the save round-trips it unchanged.

The Remarks textarea in the *Add obligation* modal (`rwLocalRemarks`) is
untouched — it is a different form, and only the card was in scope.

## Why execution frequency stayed

It was not named for removal, and unlike the others it is **read back**:
migration 145 derives the instance cadence from
`practice_instance_obligation.execution_frequency_id` through
`vw_pm_practice_default_frequency`. Dropping the input would leave that
column NULL on every future adoption and quietly change what Configure
defaults an instance to. Removing it is a one-line change plus moving
that derivation to the published value — say so and it goes.

## Removed fields are omitted, not nulled

The form stops sending `assuranceFrequencyId`, `retentionPeriod`,
`collectionFrequencyId`. It does **not** send them as null.

`sp_resolve_obligation_adopt` and `sp_resolve_evidence_save` read an
absent key as "no opinion" and leave the stored value alone. A value an
organisation recorded before 226 therefore survives, instead of being
blanked by a form that no longer asks for it. Nothing was dropped from
the schema either — only from the screen.

## Card layout: published beside answers

The card body stacked *As published*, then the editable fields, then
evidence — down the left of a full-width card, with the right-hand half
empty.

The cause was `auto-fit`, on both grids:

```css
grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
```

`auto-fit` **collapses** the tracks nothing landed in and stretches the
survivors to `1fr`. `genericFields` drops every empty value, so a typed
item rendering three short values got three ~350px columns each holding
"Monthly" or "Yes" pinned to its left edge. That was the normal case, not
the edge case — the conditional shape of the typed detail means most
items render only a few of their columns.

Removing both Remarks (above) made it plain: they were the only
`.rw-span` / `.full` elements in the block, and without them nothing
anchored the width.

Now:

| | Change |
| --- | --- |
| `.rw-split` | two equal columns, `minmax(0, 1fr)` each — **not** bare `1fr`, or one long locator would push its column past half and shove the other off. Stacks under 1000px |
| `.rw-answers` | new right-hand box, same chrome and heading style as `.rw-typed`, so the pair reads as two of a kind |
| `.rw-typed dl` | `auto-fill` with a `minmax(170px, 220px)` cap — empty tracks kept, no value sprawls |
| `.rw-answers .rw-fields` | two columns over 1000px. Scoped to this column: the profile box and the dialog use the same class and are not in a split |
| `.rw-evidence .rw-fields` | `auto-fill`, `minmax(220px, 360px)` — short inputs capped, `.full` still spans every track so Evidence name and Description keep their width |

Evidence stays full width beneath both columns. Squeezing a name, a
location and a locator into half a card is exactly what the single-column
decision documented above `.rw-columns` was avoiding.

`.rw-span` still works under `auto-fill`: `grid-column: 1 / -1` spans the
tracks auto-fill created, so a State rule keeps its one wide line.

## Evidence Name (migration 254)

Sir asked for an Evidence Name on the resolve evidence rows. There was
nothing to surface: `practice_instance_evidence` (001) carries
`evidence_type_id` and free text, and `GRAC_New.requirement_obligation_evidence`
carries `evidence_type_id`, `frequency_id`, `retention_requirement` and
`remarks`. **Neither has a name column.** The only name in the system is
`evidence_type_master.evidence_type_name` — the *type*, one label shared
by every row of that type on every instance, already printed as the row
heading.

So 254 adds a real per-row name the organisation owns:
`practice_instance_evidence.evidence_name NVARCHAR(300) NULL` — "Q3
firewall ruleset export", as against the catalogue's "Configuration
Export". Nullable; an unnamed row still reads by its type, and the type
now shows as a badge beside the name when both are present.

| Layer | Change |
| --- | --- |
| DB | column; `sp_resolve_evidence_list` projects `EvidenceName`; `sp_resolve_evidence_save` takes `@evidence_name` |
| API | `ResolveEvidenceRow.EvidenceName` (read via `OptionalString`), `ResolveEvidenceSaveRequest.EvidenceName` |
| UI | first field on each evidence row; `saveEvidence` sends `evidenceName` |

Two deliberate non-changes:

- **`IsResolved` is untouched.** Resolved still means location AND
  locator, because that is the test assurance applies, and a workspace
  that called a row ready on the strength of a name would be claiming
  something assurance would then refuse.
- **The name joins the re-inherit emptiness test** in
  `sp_resolve_evidence_save`, for the same reason `evidence_description`
  is already in it: a row whose only edit was a name that has since been
  cleared goes back to *Inherited* rather than being pinned at
  *Organization Defined* forever.

The name follows the same "absent means unchanged" contract as
[Removed fields are omitted, not nulled](#removed-fields-are-omitted-not-nulled)
— `COALESCE(@evidence_name, e.evidence_name)`, so clearing the box does
not blank a stored name. The evidence list in the *Add obligation* modal
does not offer a name yet; its rows are created by type.

## Evidence remark under the name (migration 306)

The published remark on a piece of evidence was visible in exactly the
wrong half of the panel:

| Obligation state | Evidence panel shows | Remark |
| --- | --- | --- |
| not adopted | what the authority publishes, by type | **yes** — `publishedEvidenceOf` → `p.remark` |
| adopted, rows created | the real `practice_instance_evidence` rows | **no** — `sp_resolve_evidence_list` never projected it |

So the instruction disappeared at the moment the operator started filling
the evidence in. 306 brings it onto the adopted row, under the name.

**This is not the Remarks that 254 removed.** Those were two
*obligation*-level things — the `remarks` textarea on the card and the
published obligation remarks in the *As published* block (retired via
`hiddenDetailKeys`). This is `roe.remarks` on the **evidence** row, the
authority's instruction for what that piece of evidence has to show —
the same value the Practice View card already prints under each evidence
badge, and the same one this panel already prints before adoption.

| Layer | Change |
| --- | --- |
| DB | `sp_resolve_evidence_list` projects `EvidenceRemarks`. **No schema change** |
| API | `ResolveEvidenceRow.EvidenceRemarks` (read via `OptionalString`) |
| UI | `<p class="rw-note rw-evidence-remark">` between the evidence head and the input grid |

**254 is a hard prerequisite**, because 306 re-issues 254's procedure
body. On a database that never ran 254 the `evidence_name` column does
not exist and every statement touching it fails with
`Msg 207 Invalid column name 'evidence_name'` — while the `PRINT`s after
it still run, so the script *looks* half-applied. It is not:
`CREATE OR ALTER` aborts on Msg 207 and the previously deployed body
stays. 306 therefore guards on the **column**, not just on the procedure
existing, and tells you to run 254.

It sends you to 254 rather than adding the column itself on purpose: 254
also re-issues `sp_resolve_evidence_save` with `@evidence_name`, so
adding only the column would leave the Evidence name box on screen unable
to save what was typed into it. Check with:

```sql
SELECT COL_LENGTH('grac_practice.practice_instance_evidence','evidence_name') AS NameCol,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_save','P'))
                 LIKE '%@evidence_name%' THEN 'yes' ELSE 'no' END AS SaveTakesName,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_list','P'))
                 LIKE '%AS EvidenceRemarks%' THEN 'yes' ELSE 'no' END AS ListHasRemarks;
```

`NameCol` NULL means run 254; `ListHasRemarks` = no after that means
re-run 306.

How the published row is matched, in order:

1. `practice_instance_evidence.source_obligation_evidence_id` (added by
   140, written by every adopt path since 141) — the exact published row.
2. Fallback on **obligation + evidence type** through
   `vw_pm_obligation_evidence` and the `evidence_type_name` bridge between
   the two catalogues, for a row where that id is NULL: added by hand on
   the Practice Instance form, or claimed by the 231/304 "attach an
   unattached row of the right type" UPDATE, which sets
   `source_obligation_id` but not the evidence id. This is the *same*
   join 304's reconcile uses — not a new matching rule.

Both are correlated scalar subqueries, not joins. One published evidence
row can be reached through several link tables (see 302), and a join
would print the evidence row twice.

Three deliberate non-changes:

- **Read-only.** The remark is published data, so
  `sp_resolve_evidence_save` neither accepts nor stores it. **Description**
  on the same row stays the box for the organisation's own words.
- **Read live, never copied.** A value snapshotted at adoption would go
  stale the moment Control Management edits it, and the operator would be
  following an instruction the authority had already changed.
- **`IsResolved` untouched**, for the reason 254 gives above: a published
  instruction is not an organisation answer, so it cannot move a row
  towards resolved.

Blank remarks resolve to NULL (`NULLIF` on the trimmed value), so an
evidence row with nothing published renders exactly as it did before —
no empty line — and the fallback skips a blank published row in favour of
one that actually says something.

## The obligation form is a shared component

**Files:** `Views/Practice/Partials/_obligation-form-dialog.cshtml`,
`wwwroot/js/Shared/obligation-form.js` (`window.gracObligationForm`)

The add/edit form for an organisation-defined obligation used to live
inline in `resolve-workspace.cshtml`: ~110 lines of `<dialog>` and ~600
of JS — the type dropdown, the typed rule panel mirrored from Control
Management, the Assurance → Automated → Connection cascade, the evidence
list, the validation and the save.

Practice View authors the same kind of obligation at practice level
([practice-level-obligations.md](practice-level-obligations.md)), so the
form moved out rather than being copied. Two copies would have meant two
validations, two field lists and two places to change every time Control
Management adds a field — the same drift the shared task form
(`_task-form-dialog.cshtml` + `Shared/task-form.js`) was created to end.
This is that pattern applied a second time.

```js
window.gracObligationForm.open({
  scope: "instance" | "practice",
  practiceInstanceId,                  // scope "instance"
  organizationId, practiceId,          // scope "practice"
  row, recordId, detailJson, evidence,
  lookups: { frequencies, roles, assuranceTypes,
             implementationStatuses, evidenceTypes, connectionTypes },
  ensureConnectionTypes, showImplementationStatus, onSaved
});
```

Also on the module: `retire()`, `loadTypes()`, `prime()`, `vocabulary()`,
`TYPE_SCHEMA`, `retiredTypes`.

**Behaviour on Operationalize is unchanged.** Scope `instance` posts the
same payload to the same endpoint, with the same field set, the same
validation and the same "remember the id even on a failed save" retry
rule. What is left in `resolve-workspace.cshtml` is an adapter —
`openLocalForm` / `removeLocalObligation` / `primeObligationForm` — that
hands over the row, its evidence, the lookups and `loadObligations` as
the reload.

### What the module owns, and what it deliberately does not

| Thing | Lives in | Why |
| --- | --- | --- |
| `TYPE_SCHEMA`, the typed panel, the cascade, the evidence editor, validation, both save endpoints | the module | one form, one set of rules |
| The Assurance vocabulary (migration 230) | the module, exposed as `vocabulary()` | the obligation **card** needs it too, to name a published event. One fetch, one home |
| The obligation type list | the module, exposed as `loadTypes()` | the host needs the same list to decide whether its Add button can appear at all |
| `typedArrays` — which JSON array carries which type's detail | **the host** | the read side must render the two types CM retired (`Evidence`, `Retention`); the form never offers them. A copy in the module would be a smaller version of the same map. The host passes what it found as `detailJson` |
| `esc` / `F` / `options` / `normKey` | both, separately | three-line generic helpers, the way every screen partial in this codebase already carries its own |

### Two things to know when testing it

- **Styles are self-contained and `gof-` prefixed.** The inline modal
  borrowed half its rules from `#rwRoot`-scoped selectors, so on any other
  page that half would have rendered unstyled.
- **The dialog now sits outside `#rwRoot`,** so `mode=view`'s
  `.rw-view-only` CSS no longer reaches inside it. That is harmless
  because view mode hides Add, Edit and Remove — the dialog cannot be
  opened from a read-only workspace at all — but it is a real difference
  if a future action ever opens it from there.

## An id with no name beside it now resolves to the name

The card's *As published* block read

```
ASSURANCE FREQUENCY ID
4
```

on an organisation-defined obligation. "4" tells the reader nothing.

**Why only that half showed it.** The generic renderer already had
`idHasLabel`: a raw foreign key is noise when its resolved label sits in
the same object, so `assurance_frequency_id` is hidden whenever
`AssuranceFrequency` is present. Migration 224's view projects both for a
published obligation, so the id was never seen there. A **local**
obligation's `typed_detail_json` is written by the add form, which stores
**column names only** — there is no sibling name to find, and the number
was, literally, the only thing there was.

So `resolvedId(key, value)` resolves the id against the same master list
the form chose it from, and prints the name with the trailing *Id*
dropped from the label:

| key | resolved against |
| --- | --- |
| `assurance_frequency_id`, `execution_frequency_id`, `frequency_id` | `frequencies` (frequency_master) |
| `event_type_id` | the Assurance vocabulary's `eventTypes` (migration 230) |
| `connection_type_id` | `connectionTypes` (244) |
| `implementation_status_id` | `implementationStatuses` (242 / 248) |
| `evidence_type_id` | `evidenceTypes` |

**An id that does not resolve is still printed as a number.** That means
the lookup has not loaded yet, or the row points at something retired —
and inventing a name for it would be worse than admitting the number. An
id this table does not know is left exactly as it was.

`evidenceTypes`, `obligationForm` and `vocabulary` moved up to sit with
the other lookups at the top of the script. Arrow bodies made the old
placement safe, but it read as a forward reference from the renderer.

### Practice View has the same fix, in its own shape

`practice-view.cshtml` names its keys rather than iterating them, so it
never printed an id — it printed *nothing*, which left a practice-level
Assurance spec looking as though it had no cadence. `frequencyName(row,
nameKeys, idKeys)` reads the name first and falls back to resolving the
id, on both the Execution and Assurance spec lines.

## The Dependencies table: Category first, and Select as the default

Three changes to the table (migration 238's panel):

1. **Column order is Category → Applicability → Objects.** The question is
   "does this instance depend on Asset?", so the subject comes before the
   answer. Applicability used to lead, which read as a column of Yes/No
   with the thing being answered about off to its right.
2. **Applicability is Select / Yes / No, starting at Select** — an
   *unanswered* row. Anything other than Yes still leaves the row's
   editors disabled and clears its picker, so the store contract is
   unchanged: Yes applies the objects, anything else saves an empty
   resolution set.
3. **Save dependencies is disabled until every answerable row says Yes or
   No.** One button saves all five categories, so a partly answered table
   would post "no dependencies of this kind" for rows nobody had looked at
   — an answer the operator never gave. `#rwDepSaveHint` names what is
   still outstanding: *"Answer Vendor, Person to save."*

`syncDepSaveState()` owns the button's enabled state and is the only thing
that enables it — called at the end of `renderDependencyTable`, on every
Applicability change, and after a save. The button is `disabled` in the
markup too, so a load that fails leaves it off rather than offering to
save a table that is not on screen.

**A disabled Applicability row is excluded from the requirement.** Its
category is missing from this database's catalogue, or the organisation
has no records of that kind yet (Committee, in a fresh tenant). Requiring
an answer that no control can give would leave Save dead forever. Those
rows still save exactly as before — an empty resolution set.

### The one consequence worth knowing

**There is no third state in the store.** A category saved as *No* and one
never answered both hold zero rows in
`practice_dependency_resolution`, and nothing distinguishes them coming
back. So after saving a row as No and reloading, it shows **Select**
again, and Save waits for that row to be answered a second time.

Recording the answer itself needs somewhere to put it — a column on the
resolution table, or a resolution row carrying no object. That is a schema
change and was deliberately not made here. If the re-answering becomes
annoying in use, that is the fix, and it is a migration rather than a
screen change.

## Roles are stored by name, not by id

The picker offers `grac_practice.organization_role` (organisation-scoped,
de-duplicated by name) and the option **value is the role name**. No new
foreign key.

That is deliberate. `practice_instance_obligation` is an adoption
*snapshot* — it already copies `obligation_name` and
`obligation_type_code` out of `GRAC_New` for exactly this reason.
Renaming a role later should not silently rewrite what an organisation
recorded as its answer at adoption time, which is what a foreign key
would do.

## Assurance type

One genuinely new fact, so it gets a column:
`practice_instance_obligation.assurance_type NVARCHAR(40) NULL`, with
`ck_pm_pio_assurance_type` allowing `NULL`, `Manual`, `Automated`. NULL
is allowed so obligations adopted before 226 stay valid and read as "not
set".

`NVARCHAR` rather than a foreign key because it mirrors
`practice_instance.assurance_mode` — same two values, same shape, same
screen vocabulary ("Practice type" there, "Assurance type" here).
`grac_practice.assurance_type_master` exists but holds a different
vocabulary (the assurance activity catalogue); pointing this at it would
conflate two unrelated lists.

`AssuranceTypeAvailable` on the row reports whether the result set had
the column, and the control hides unless it is true — a database without
226 does not get a choice whose save would be silently dropped.

## How 226 was written

`sp_resolve_obligation_adopt` is ~280 lines and had to change in eight
places. Rather than transcribe it, the migration was generated from
`141_resolve_workspace_procs.sql` by asserting each of the eight anchors
matched exactly once and inserting around it — so the body is the 141
body plus the eight additions, with nothing lost in copying. The rollback
was generated the same way from the untouched 141 and 224 sources.

---

# Organisation-defined obligations (migration 227)

An organisation can add an obligation of its own alongside the published
ones, and the rule fields it is asked for follow the type it picks —
the same way Control Management's own obligation form works.

## Scope: one instance

A locally added obligation belongs to the practice **instance** it was
added on. `practice_instance_obligation` is keyed that way, and a
practice usually has several instances (Configure creates one per team),
so "add once, appears everywhere" would need a practice-level table plus
a fan-out rule for instances created afterwards. That is a separate
piece of work.

## `obligation_id IS NULL` is what says "local"

That column is a soft reference into `GRAC_New.requirement_obligation`,
and a locally added obligation has no row there — so NULL is the truthful
value, not a flag bolted on beside it. `inherited_from_repository` goes
to 0 to match.

Two schema consequences:

* `obligation_id` becomes **NULLable**.
* `UNIQUE(practice_instance_id, obligation_id)` is replaced by a
  **filtered** unique index `WHERE obligation_id IS NOT NULL`. SQL Server
  treats NULLs as *equal* in a UNIQUE constraint, so leaving it would
  have allowed exactly **one** locally added obligation per instance —
  a rule nobody asked for, surfacing as a baffling error on the second
  one. The filtered index keeps the rule where it means something: the
  same published obligation cannot be adopted twice.

## Rule detail is JSON, not six more tables

The published side keeps its typed detail in six tables in `GRAC_New`,
owned by Control Management. Mirroring those six in `grac_practice` would
copy a schema this module does not own and cannot see change — the
coupling that made migration 225 necessary in the first place.

Instead the local detail is one `NVARCHAR(MAX)` column,
`typed_detail_json`, holding the same array shape
`vw_pm_obligation_typed_detail` emits. Nothing queries that detail
relationally today: the card renders it, and the renderer has been
shape-agnostic since 225. So both halves leave
`sp_resolve_obligation_list` in the same shape and the screen cannot tell
them apart — which is the point.

## Where the form's fields come from

`sp_resolve_obligation_type_fields` reads `sys.columns` of the Control
Management table for the chosen type and returns it — name, data type,
length, nullability, and whether the column looks like a reference.
The add form builds its inputs from that.

So it offers exactly the fields CM's own form offers, and a column CM
adds appears here with no Practice Management change. It is the
**write-side counterpart** of the shape-agnostic renderer 225 put on the
read side.

Type codes are matched with punctuation and case stripped
(`EventResponse`, `EVENT_RESPONSE`, `Event Response` all resolve),
because `obligation_type_master.type_code` is CM's vocabulary and this
module should not depend on its exact spelling.

`sp_resolve_obligation_type_list` supplies the type dropdown. It is its
own procedure rather than a key on the shared lookups feed: that feed is
a UNION inside `dbo.pm_get_practice_repository`, a 1580-line dispatcher,
and one more branch means re-issuing the whole thing — the same blast
radius migration 122 declined for the same reason.

Only `*_frequency_id` gets a real picker; every other `*_id` renders as a
number. Guessing which catalogue an unknown foreign key points at would
be exactly the coupling this design avoids.

## The card keys on RowKey now

A local row has no `ObligationId`, so the procedure supplies **RowKey** —
`p{obligationId}` or `l{adoptionId}` — and everything that keyed on the
obligation id keys on that instead: the dirty bag, the expanded set, the
adopt checkbox, the field labels. `keyOf(o)` falls back to the published
form, so a pre-227 database is unaffected.

A local card shows a building icon instead of an adopt checkbox — it was
not adopted from anywhere, and offering to un-adopt it would be the wrong
verb — plus **Edit** and **Remove**, which post to
`/resolve/local-obligation`. It is excluded from the bulk
*Save obligations* payload: `sp_resolve_obligation_adopt` derives
`organization_modified` by comparing against what was published, and a
local row has no published side to compare with.

`sp_resolve_local_obligation_save` only ever touches rows with
`obligation_id IS NULL`, so an adopted published obligation cannot be
edited or deleted through that door.

## Rolling back is guarded

`obligation_id` can only return to `NOT NULL`, and the unfiltered UNIQUE
constraint can only return, if no local obligations exist. The rollback
checks first, and if any are found it stops, reports the count, and
leaves the column NULLable — rather than deleting an organisation's own
compliance obligations to satisfy a constraint. With the procedures gone
those rows are simply invisible; re-running 227 brings them back.

---

# Following Control Management's taxonomy (migration 228)

Two changes, both about not holding an opinion on a schema this module
does not own.

## Evidence and Retention are gone from the taxonomy

Control Management removed both types. Practice Management stops
offering them, and — more importantly — stops falling over when their
tables are not there.

* `sp_resolve_obligation_type_fields` no longer maps them, so the add
  form cannot offer a field list for a type that no longer exists.
* The type dropdown is filtered by what CM still publishes, with
  `retiredObligationTypes` as belt and braces.
* They stay **mapped for display**. Obligations adopted before the
  removal still carry those codes, and their detail must keep rendering
  — which is why the view still emits both columns rather than dropping
  them.

## The view is now assembled, not written

`vw_pm_obligation_typed_detail` named six `GRAC_New` tables. A view whose
base table has been dropped does **not** fail at deploy time — it fails
the next time somebody opens Operationalize, with *Invalid object name*.
That is the worst possible moment.

Migration 225 stopped naming **columns**. 228 stops naming **tables**:
the view is built with dynamic SQL from whichever detail tables exist,
and a missing one contributes the literal `'[]'`.

The seven output columns are **always** emitted, present tables or not.
`sp_resolve_obligation_list` selects them by name, and a view that
changed shape underneath it would trade one runtime failure for another.

Re-run 228 after any Control Management schema change.

## The Assurance trigger rule is learned, not declared

An Assurance obligation has a trigger type, and which other fields apply
depends on it — event driven wants the event details, scheduled wants a
frequency. The card already handled this (a NULL column is not
rendered); the **add form** showed every field flat.

The rule is not written down here, because this module cannot see
Control Management's form and would be guessing at both the column and
the mapping. It is read out of CM's own rows into
`grac_practice.obligation_type_field_rule`:

* A **driver** column is one whose name mentions `trigger` or `mode`,
  holds a short string, and has between 2 and 10 distinct non-null
  values. Anything else is not a selection.
* For each driver value, a column is **visible** when at least one row
  with that value has it populated.

The form then renders the driver as a select over the values CM actually
uses, and hides the fields that value does not govern. Hiding a field
also clears it, so a value cannot ride into the saved JSON under a
trigger that has no such field.

### What the first run found, and what it exposed (migration 229)

228 learned exactly one rule:

```
Assurance | trigger_mode | EventDriven | 6 fields | 3 rows seen
```

Correct — the heuristic found `trigger_mode`, and all three existing
assurance obligations are event driven. The mistake was on the other
side of the wire: the form built its trigger dropdown from the values
that **had rules**, so it offered `EventDriven` and nothing else. Nobody
could create a scheduled one.

The inference told the truth — *this is what the data shows*. The form
read it as the whole truth — *this is what exists*. Those are different
claims and only the first was ever justified.

**Migration 229** separates them:

* A marker row per distinct driver value (`visible_column = ''`), so a
  value with nothing learned about it is still a value the form offers.
* Values parsed out of the column's **CHECK constraint** when it has one.
  A constraint says what is *allowed*, which is exactly the question the
  data cannot answer — it only shows what has been *used*.
* `sp_resolve_obligation_type_field_rules` returns the value list as a
  second result set, so the form stops deriving it from rules.
* The inference moves into `sp_pm_infer_obligation_field_rules` so it can
  be re-run on its own — after CM adds a scheduled obligation, say —
  without re-running a migration.

Below two values the control stays a **text box**. A one-item dropdown is
a trap: it looks like the complete list and there is no way past it.
Letting somebody type `Scheduled` is the lesser evil, and the moment one
such obligation exists in CM the inference picks it up.

### What the inference cannot do

It is only as good as the data:

* a trigger value nobody has used yet produces **no rule**;
* a column blank in every existing row of a value looks irrelevant to it.

So a missing rule means **show everything**, never hide everything. An
over-full form is a nuisance; a form missing the field you need is a
dead end. The migration is idempotent and rebuilds the table each run —
re-run it once CM has obligations exercising the new value, and the rule
catches up.

Section 5 of the migration prints exactly what was learned, and the type
list CM still publishes. An empty rule table is not a failure.

---

# Reading Control Management instead of guessing at it (migration 230)

Everything above — the schema-driven view, the inferred trigger rule, the
CHECK-constraint parsing — was working around not being able to see
Control Management's code. Once its repository was on hand, most of it
became unnecessary.

## What the inference got right, and what it could never get

CM's `obligation-master-form.js` holds the Assurance panel:

```
Verification Method
Trigger Mode  ->  Scheduled   : Assurance Frequency
                  EventDriven : Event Domain -> Event, Due Within (days)
```

and CM 033's constraint enforces it at the database:

```sql
ck_cm_assurance_spec_trigger CHECK (
       (trigger_mode IS NULL         AND event_type_id IS NULL)
    OR (trigger_mode = 'Scheduled'   AND event_type_id IS NULL)
    OR (trigger_mode = 'EventDriven' AND event_type_id IS NOT NULL))
```

| | Inference saw | Actually |
| --- | --- | --- |
| Driver column | `trigger_mode` ✓ | `trigger_mode` |
| Values | `EventDriven` only | `Scheduled`, `EventDriven` |
| EventDriven fields | 6, whichever were populated | Event **Domain → Event** cascade + Due Within (days) |
| `scope`, `assurance_party` | would have shown them | **retired** from the panel |

Field order, labels, hints, required flags, which control type, what is
retired — `sys.columns` knows none of it, and no amount of reading rows
recovers it. It is a **presentation** contract, and CM keeps it in one
file with a note telling whoever adds a field to keep it in sync.

## So the schema is mirrored, and the existence verified

`TYPE_SCHEMA` in `resolve-workspace.cshtml` is a deliberate copy of CM's.
That is the opposite of the rule migrations 225 and 228 established — but
those were about **schema**, which is readable; this is presentation,
which is not.

The safeguard is that every mirrored field is matched to a real column
through the `/fields` endpoint before it is rendered or saved
(`columnFor`, matching on the normalised name so `verificationMethod`
finds `verification_method` and `slaDays` finds `sla_days`). A field CM
drops from the table disappears from this form by itself rather than
being posted into a column that is not there. **Copied presentation,
verified existence.**

Stored keys are the real column names, so a locally added obligation and
a published one render through exactly the same path.

## What 230 adds

`sp_resolve_obligation_vocabulary` — two result sets:

* trigger modes, from `reference_option` group `assurance-trigger-modes`
* the event type tree, flat with `ParentEventTypeId`, so the form builds
  the domain → event cascade the same way CM's does

Wrapped rather than calling CM's `sp_cm_event_type_list` directly: the
Web tier reaches the database only through PM's own procedures, and the
wrapper is where the "CM 033 not applied here" guard belongs.

## Details carried across from CM's form

* **Only the live half of a cascade is saved.** Switching trigger mode
  clears what it invalidates first — a stale event surviving a switch
  back to Scheduled would trip the CHECK constraint on save.
* **`eventDomainId` is transient.** It is a UI step; the server stores
  the leaf, which knows its parent. On edit it is derived back from the
  leaf, or the cascade would open on step two with step one blank.
* **Retired fields are hidden, not dropped.** CM keeps them in the
  payload so stored values survive an edit. PM does the same, and
  `hiddenDetailKeys` now hides them on the card too — otherwise the
  display and the add form would disagree about what an obligation is.
* **Retired types are reinstated on edit.** An obligation saved as
  Retention keeps that option on the dropdown, labelled `(retired)`,
  while it is being edited. CM guards its own form the same way; without
  it, opening such a row silently blanks its type.
* Two client-side refusals mirror the constraint — an event driven
  assurance without an event, a scheduled one without a frequency — so
  the user gets a sentence rather than SQL error text.

## 228 and 229 are not removed

They still answer for any type whose panel is not mirrored, and for a CM
release that adds a driver column nobody has told this module about.
What changed is precedence: where a mirrored definition exists it wins,
because it is the actual contract rather than a reading of the data.

---

# A modal, and evidence (migrations 231 / 232)

## First, a regression this work uncovered — migration 231

Migrations 224 and 226 re-issued `sp_resolve_obligation_list` and
`sp_resolve_obligation_adopt`, rebuilt from the bodies in **141**, where
those procedures are first defined.

Those were not the current bodies. **144** had re-emitted both, and
rebuilding from 141 silently reverted everything it fixed:

| 144 fixed | The revert |
| --- | --- |
| Count evidence from `vw_pm_obligation_evidence` (direct **and** the M:M links) | Back to direct only — under-reported, and disagreed with what adoption created |
| Adopt an existing **unattached** evidence row of the right type | Back to skipping it, leaving hand-added evidence invisible in the workspace |
| Guard per **obligation** | Back to per instance — two obligations publishing the same type shared one row, so the second got nothing |
| `UnmappedEvidenceTypes` from the view | Wrong for the same reason |

**How it happened:** picking the file where a procedure is *defined*
rather than the last file that *re-emits* it.

**The check**, before re-issuing anything:

```
grep -l "CREATE OR ALTER PROCEDURE .*<name>" database/*.sql
```

and take the **highest-numbered** match. Every object migrations 220–230
re-issued was audited this way afterwards — `sp_resolve_instance_detail`
(141 current), `pm_grant_organization_default_access` (217 current),
`sp_pm_view_obligations_typed` (122 current) were all correct. Only those
two were wrong.

231 regenerates both from 144 with every later addition re-applied, and
its verification checks each of the four fixes individually. **Nothing
was lost** — rows were never created, not deleted. It also lists the
adopted obligations whose evidence is missing; re-saving them on the
workspace creates it.

## The form is a modal now

It had grown to a dozen controls plus a cascade that re-renders, and
adding an evidence grid to an inline panel would have pushed the
obligation list around while you typed. PM's other add/edit forms are
`<dialog>`s already.

Two details worth keeping:

* **No backdrop dismissal.** Half-finished work should not vanish on a
  stray click, so Cancel and the close button are the only ways out.
  `Esc` is routed through the same teardown so panel state does not
  survive into the next open.
* **A `<div>`, not `<form method="dialog">`.** That form submits on Enter
  in any text input, which closes the dialog and discards the obligation.
  Nothing here needs form semantics — every button is `type="button"` and
  the save is a fetch.
* Only the body scrolls, so the actions stay reachable however long the
  typed panel gets.

## Evidence on an organisation-defined obligation

Adopting a published obligation creates its evidence — the authority says
what proves it. A locally added obligation had no such step: it could be
created, but nothing could ever be produced to show it had been met.

**231** adds `practice_instance_evidence.source_practice_instance_obligation_id`.
`source_obligation_id` points into `GRAC_New` and is NULL for a local
obligation, so 227's "NULL means this one" could not tell two local
obligations apart — they reported each other's counts.

**232** adds `sp_resolve_local_obligation_evidence_sync`, called from both
the add and edit paths of `sp_resolve_local_obligation_save`. Its own
procedure because three inlined copies is how two of them drift, and
because it is the only piece that has to know
`practice_instance_evidence`'s NOT NULL columns.

### The list is the complete set — but the scope is narrow

Like the dependency-category picker: what arrives **is** this
obligation's evidence, and anything of its own not in the list is
retired.

That is safe here in a way it would not be for a published obligation,
because only rows carrying **this** obligation's
`source_practice_instance_obligation_id` are ever in range. Evidence
belonging to a published obligation, or added by hand on the Practice
Instance form, has a different owner and is never touched.

### A row somebody has filled in is never retired

Location, locator or owner present means work has been done against it.
Dropping the type from the list retires the empty rows and keeps those —
the same rule `sp_resolve_obligation_adopt` applies when a published
obligation is un-adopted. The modal shows them as
*already in use — cannot be removed here* with no delete control, because
a control that appears to delete something and does not is a lie.

Retiring the obligation itself follows the same rule.

### Null means "no opinion"

`@evidence_json` NULL changes nothing — an older caller, or an edit that
did not touch evidence, must not silently retire it. An explicit **empty
array** is how you say "none", and that is what the modal always sends.

## Verification

Section 4 of the migration reports, per type, how many obligations carry
each kind of detail. All zeroes is not a fault of the migration — see the
fallback note above.

On screen, open an instance from Resolve:

* An obligation whose type has detail shows an **As published** block
  headed with the type name and the type's own field labels; a State rule
  appears as one monospace line.
* An obligation with several detail rows shows them as separate items
  with a rule count in the header.
* An obligation with no detail shows the four published fields plus the
  "no detail has been recorded" sentence.
* **Description** appears above the block, and does not repeat the title.
* Obligations and Dependencies are stacked, full width.
* The View Obligations screen is unchanged — same columns, same values.

---

# A successful save that reported failure (migration 233)

## What it looked like

Save an organisation-defined obligation: `Saving...`, then an error, and
the dialog stayed open. Click Save again — same thing. Close the dialog
and there was one extra obligation for every click.

Every one of those saves had succeeded. Only the reporting was wrong.

## Cause

232 ended `sp_resolve_local_obligation_evidence_sync` with

```sql
SELECT @added AS EvidenceAdded, @removed AS EvidenceRemoved, @kept AS EvidenceKept;
```

A `SELECT` inside a called procedure is not private to it. It becomes a
result set **of the caller**, and it arrives **first** — ahead of the row
`sp_resolve_local_obligation_save` emits at the end.

So the API read that first row, asked for `[Message]`, and threw. The
`catch` turned it into HTTP 400. But the throw happened while *reading*,
after the procedure had already committed: the obligation was on disk and
the screen was told it was not.

The duplication followed from that. A failed save left the dialog open
holding `practiceInstanceObligationId = 0`, so the next Save was another
**insert**, not an update.

> **Rule:** a procedure that another procedure `EXEC`s must not `SELECT`.
> Counts and ids travel as `OUTPUT` parameters.
>
> This is the same hazard 217 was written to avoid. It got past me here
> because the `SELECT` looked like the procedure's own return value.

## The fix, in four places

**Database (233).** The sync procedure takes `@evidence_added`,
`@evidence_removed`, `@evidence_kept` as `OUTPUT` and returns no result
set. They are set to `0` before the early `RETURN`, so a `NULL`
`@evidence_json` cannot leave the caller's variables holding stale
values. `sp_resolve_local_obligation_save` keeps exactly one result set,
with the counts as extra columns — and **all three branches** (add, edit,
retire) return the same shape, so the caller never has to test which one
it got.

**API — skip to the result set that has the answer.**

```csharp
while (!HasColumn(reader, "Message") && await reader.NextResultAsync(cancellationToken))
{
}
```

A database still on 232 now degrades to "saved" rather than repeating the
fault, and a future diagnostic `SELECT` cannot cause it again. Checked
every other `reader["Message"]` in the service: only
`sp_resolve_local_obligation_save` calls another procedure, so the loop
stays where it is needed rather than being sprayed everywhere.

**API — return the id on both paths.** `ResolveCommandResult` gained an
optional `SavedId`; the controller sends it on success *and* on failure.
A caller that fails after the row is written can then retry against that
row.

**UI — two guards.** Save is disabled for the whole round trip and
re-enabled in `finally`, so a slow save cannot be clicked twice. And if
the response names a row, the form adopts that id even on failure, so a
retry updates instead of inserting.

Either guard alone would have stopped the pile of duplicates. Both are
worth having: one prevents the double click, the other prevents the
deliberate retry.

## The duplicates already created

233 does **not** delete them — it cannot tell an accidental repeat from
two obligations an organisation deliberately named alike. It lists them,
newest first, with their evidence counts. Remove the unwanted ones **from
the Operationalize screen**, which retires them properly and retires
their empty evidence with them; a `DELETE` here would skip that.

## Verification

The migration checks that the sync takes `OUTPUT` parameters, that it no
longer `SELECT`s its counts, that the save passes them back, that all
three branches carry the count columns, and — the point of the whole
exercise — that the save still emits `Success` and `Message`.

On screen: Save once, the dialog closes and the obligation appears once.
Hold Save down or double-click it, and still once.

---

# Event overrides, inline editors, one row less (migration 234)

## The parameter row was asking twice

Every card carried an **Execution frequency** dropdown regardless of type.
For a State or Constraint obligation it was meaningless. For an Execution
obligation it duplicated the value the typed panel already showed. And
for an Assurance obligation it hid the field that actually mattered
(assurance frequency, or the event and SLA).

The dropdown is gone. Editing now lives inside the typed panel, next to
the value it overrides.

## What is editable

`publishedBlock` still shows what the authority published, but three
specific fields are rendered as editable controls bound through the same
`[data-field][data-ob]` plumbing the parameter row uses:

| Type + trigger                    | Editable fields                        |
| --------------------------------- | -------------------------------------- |
| Execution                         | `executionFrequencyId`                 |
| Assurance + trigger Scheduled     | `assuranceFrequencyId`                 |
| Assurance + trigger EventDriven   | `eventTypeId`, `slaValue`, `slaUnit`   |

Blank in any editor means "as published", and the option's label carries
the published value so the choice is never blind. `sp_resolve_obligation_adopt`
already COALESCEs `NULL` onto whatever the row holds, so an untouched
field survives across saves — the "absent key = no opinion" rule
migration 226 established still applies.

An organisation-defined obligation is not adopted from anywhere, so the
editors do not appear on its card — the same fields are already edited
on the Add form.

## Migration 234 — event override storage

Only Execution frequency and Assurance frequency had per-obligation
override columns. EventDriven had nowhere to store the organisation's
event or SLA choice.

```sql
ALTER TABLE grac_practice.practice_instance_obligation
    ADD event_type_id BIGINT NULL,     -- soft ref GRAC_New.event_type_master
        sla_value     INT    NULL,
        sla_unit      NVARCHAR(20) NULL;
```

No foreign key on `event_type_id`: `event_type_master` lives in
`GRAC_New`, and SQL Server does not allow cross-database FKs. Same soft
reference migration 127 uses for `practice_instance_dependency.event_type_id`.

## Extending the two procedures without regenerating them

`sp_resolve_obligation_adopt` and `sp_resolve_obligation_list` were both
touched by 231's regression fix, and I did not want to re-emit them from
scratch — that is exactly how the 141 → 144 divergence started.

234 patches 231's bodies **mechanically**: a build script asserts one
match per anchor, and prints which anchor missed if 231 has since drifted.
Eight anchors on the adopt procedure (table variable, INSERT columns,
INSERT SELECT, OPENJSON WITH, dirty-check, MERGE UPDATE, MERGE INSERT
columns, INSERT VALUES); two on the list procedure (one per branch of
the UNION ALL). Nothing else is touched.

## The assuranceType payload gap, fixed in passing

`ResolveObligationDecision.AssuranceType` was added by 226 and the SQL
procedure has read `$.assuranceType` since 226 — but the anonymous
object the API service serialised into `@payload_json` never listed it.
The UI's choice was being dropped between the API and SQL, silently.

The same list gained `assuranceType` and the three 234 fields together.

## Verification

Migration 234 checks that each column exists, that the adopt procedure
reads `$.eventTypeId` and writes `event_type_id` through COALESCE, and
that the list procedure projects `EventTypeId` in both halves of its
UNION ALL. A final regression guard confirms `sp_resolve_obligation_adopt`
still references `vw_pm_obligation_evidence` — the 144 fix 231 restored
must not have been re-broken by this migration.

On screen: open an Execution obligation and pick a frequency; the row
becomes dirty and Save persists it. Blank the dropdown back to "As
published (…)" and the override goes to NULL; the next reload shows the
authority's value again. For Assurance, switch the authority's rule
between Scheduled and EventDriven in the admin module and reload — the
editable field changes with the trigger.

## Migration 244 — Connection type + URL for Automated assurance

An Automated assurance obligation needs to know **how** to reach the
system under test. Migration 244 adds two nullable columns to
`practice_instance_obligation` and a `connection_type_master` lookup:

```sql
CREATE TABLE grac_practice.connection_type_master (
    connection_type_id   INT IDENTITY PRIMARY KEY,
    connection_type_code NVARCHAR(40)  UNIQUE,
    connection_type_name NVARCHAR(120),
    description          NVARCHAR(400) NULL,
    display_order        INT DEFAULT 100,
    is_active            BIT DEFAULT 1,
    ...
);

ALTER TABLE grac_practice.practice_instance_obligation
    ADD connection_type_id INT NULL FK -> connection_type_master,
        connection_url     NVARCHAR(500) NULL;
```

`API` is seeded; additional connection types (SDK, JDBC, SSH, ...) are
added by inserting new rows into the master — no code change is required.
A small read shim `grac_practice.sp_get_connection_type_lookup` returns
the active rows and is routed via `entity=connection-types` through the
same `ResolveProcedureAsync` shim path as `asset-taxonomy`.

The three Resolve procedures (`sp_resolve_obligation_adopt`,
`sp_resolve_obligation_list`, `sp_resolve_local_obligation_save`) are
extended to accept `@connection_type_id` / `@connection_url` and project
`ConnectionTypeId` / `ConnectionUrl`. Same COALESCE-onto-existing rule as
242's `implementation_status_id` — an absent key keeps the stored value.

**UI change on the same page**

- `Responsibility` is renamed to `Owner`. Its `As published` placeholder
  is dropped: nothing about this is published, so offering it as a
  fallback pointed at data that does not exist.
- `Approval authority` is temporarily hidden. The store, payload and
  save-path plumbing all stay -- the control just does not render.
- `Assurance type` renders only when the obligation's `typeCode` is
  `Assurance`. `AssuranceTypeAvailable` on the API row is always true
  when the procedure projects `AdoptedAssuranceType`, which happens on
  every row, so the UI must gate on the typeCode itself.
- When `Assurance type` is `Automated`, two inputs appear inline:
  `Connection type` (dropdown from `connection-types`) and
  `Connection URL` (free text). Switching back to Manual leaves the
  stored values alone (procedure COALESCE), so a toggle does not
  destroy the previously entered URL.

The Add-obligation modal mirrors the same rules: the Assurance type row
is hidden unless Type = Assurance, and the Connection row appears only
when Assurance type = Automated.

## Migration 334 — evidence details before the obligation is adopted

Expanding an obligation on Operationalize showed its evidence as a
read-only list — the type name, a `Not started` badge and the published
remark — with no inputs on it. The inputs appeared only *after* the
obligation had been saved once. So recording "we keep this in SharePoint,
here is the link" took two saves and a page reload for what is one
decision, and nothing on the screen said why.

### Why it was read-only

`practice_instance_evidence` rows do not exist until the obligation is
adopted. Adoption is what creates them:
`sp_resolve_obligation_adopt` writes its adoption rows and then EXECs
`sp_resolve_evidence_reconcile_for_instance` (migration 304) inside the
same transaction. Before that, there is no `evidence_id` for an input to
be bound to, and `sp_resolve_evidence_save` is addressed by `evidence_id`.

So the screen had two branches — rows exist (editable) and rows do not
(preview) — and the preview simply had nothing to offer.

### What it does now

The preview branch renders the same four inputs the editable branch
renders — **Evidence name**, **Location**, **Locator**, **Description** —
and holds what is typed on the obligation row as `o._evidenceDraft`,
keyed by evidence type:

```js
o._evidenceDraft = {
    'policy document': { evidenceName: 'InfoSec policy',
                         evidenceLocation: 'SharePoint / Policies',
                         evidenceLocator:  'https://...',
                         evidenceDescription: '...' }
};
```

It is held in JS rather than read off the DOM at save time, the way the
editable branch is, because ticking the adopt box calls
`renderObligations()`, which rebuilds the card's HTML and would throw the
typed values away. `o._edit` has exactly this problem and exactly this
solution, so the draft follows it: captured on `change`, re-rendered from
the buffer, dropped when `loadObligations()` rehydrates after a save.

Typing into one of these boxes ticks **adopt** and marks the card dirty,
for the same reason editing a parameter does — and here more strongly,
because the row this text belongs to is *created by* the adopt. An
un-adopted obligation has nowhere to put it.

### One Save, obligation and evidence together

The card's existing **Save obligation** button does three things, in
order, in one click:

| Step | Call | What it achieves |
|---|---|---|
| 1 | `POST /resolve/obligations` → `sp_resolve_obligation_adopt` | Adopts the obligation. The reconcile inside it creates the evidence rows, in the same transaction, before it returns. |
| 2 | `GET  /resolve/instances/{id}/evidence` → `sp_resolve_evidence_list` | Re-reads the rows that now exist. |
| 3 | `POST /resolve/evidence` → `sp_resolve_evidence_save`, one per draft | Writes what was typed. |

Rows that *already* existed are flushed from the DOM in step 2 exactly as
they were before migration 245 introduced that flush — that path is
unchanged. Steps 2 and 3 above are the new part, and they run only when a
draft exists.

`saveEvidence` was split so this does not duplicate the POST:
`postEvidenceValues(evidenceId, values)` is the fetch, `saveEvidence`
reads a visible row's DOM and calls it. The new path passes the draft.
Neither reloads — the caller decides — which is what lets one save flush
several rows and reload once.

### Matching a draft to the row adoption just created

On the evidence **type**, not on `ObligationEvidenceId`. That is the rule
the insert itself uses:

```sql
GROUP BY r.ObligationId, pet.evidence_type_id
```

One practice row per (obligation, evidence type). Two published evidence
rows of the same type collapse into one.

So `publishedEvidenceOf()` is now keyed the same way — by type, joining
the published remarks of the rows that merge so no instruction is lost —
where it used to key on `ObligationEvidenceId`. Keyed on the published
id, the preview promised "adopting this obligation will create these to
fill in" and then created fewer; once the boxes became editable, the
operator would have typed into a box with no row waiting for it.

It also puts the preview back in step with the count beside it.
`sp_resolve_obligation_list` computes `PublishedEvidenceCount` as
`COUNT(DISTINCT roe.evidence_type_id)` (see migration 302's note), so the
header already counted each type once while the list underneath it did
not.

The two type names are identical by construction — the insert joins
`grac_practice.evidence_type_master` to `GRAC_New.evidence_type_master`
`ON evidence_type_name` — so the match is exact, not a best guess.

`sp_resolve_evidence_list` deliberately still does **not** project
`source_obligation_evidence_id`, even though the column exists and the
reconcile writes it. A second match key that can only ever agree with the
first is not worth the column, and rows created before 144/231 carry NULL
there and would need the type fallback anyway.

### When a draft has nowhere to go

An evidence type the authority publishes may have no active match in this
organisation's catalogue — the same condition the bulk save reports as
`unmappedEvidenceTypes`. No row is created, so the draft cannot be
written. It is counted and said out loud on the card's save note rather
than dropped quietly:

> Saved. 1 evidence detail could not be saved: that evidence type has no
> match here.

### Badges on the preview

The row head reports what will happen rather than only what has not:

- **Not started** — nothing typed, obligation not being adopted.
- **Created on save** — the obligation is ticked; the row will exist.
- **Ready on save** — Location *and* Locator are both filled, which is
  the same two-field test `IsResolved` is computed from.

The rule down the left of a pending row is dashed rather than solid
(`.rw-evidence-row.pending`): the fields are real and will be saved, but
nothing is stored behind them yet.

### No database change

`334_resolve_evidence_pre_adoption.sql` creates, alters and drops
nothing. It records the change and **verifies** the four facts the screen
depends on — adopt creates the rows synchronously, one row per
(obligation, type), `sp_resolve_evidence_save` takes `@evidence_name` and
is instance-scoped, and `sp_resolve_evidence_list` returns
`SourceObligationId` and `EvidenceType` — so a deployment that is behind
on scripts fails loudly there rather than quietly on the screen. Its
rollback is a no-op; reverting the change means reverting
`resolve-workspace.cshtml`.

### Verification

1. Open Operationalize on an instance with an **un-adopted** obligation
   that publishes evidence. Expand it — the evidence rows now carry
   Evidence name, Location, Locator and Description boxes.
2. Fill in Location and Locator. The adopt box ticks itself, the card
   goes dirty, and the row head reads **Ready on save**.
3. Press **Save obligation** once. The obligation is adopted, the
   evidence rows are created, and the values you typed are on them —
   the card redraws with the normal editable rows and `1 / 1 resolved`.
4. Repeat with two published evidence rows of the **same type** on one
   obligation: the preview shows one row carrying both remarks, matching
   the `0 / 1 resolved` badge and the one row adoption creates.
5. Confirm the old path is unchanged: on an already-adopted obligation,
   edit an evidence row and press Save obligation — it saves as before.
