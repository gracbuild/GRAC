# Practice-level obligations

**Status: built (Phases 1–4), not yet run against a database.**

**Event-driven extension (migrations 340–344):** a practice-level
obligation created here — and an instance-only custom obligation (227) —
can now be declared event-driven (`event_type_id`) and reaches the whole
Profile/Role/Asset-Category event-driven flow (Configure Checklists, the
Checklists tab, raising) exactly like a catalog obligation. See
`docs/event-driven-profile-mapping.md`, section *"Custom obligations reach
the event-driven flow"*, for the composite-identity design and the API/UI
changes.

| Layer | Files |
| --- | --- |
| DB | `database/307_practice_level_obligations.sql` + rollback |
| API | `Models/PracticeObligationModels.cs`, `Services/PracticeObligationService.cs`, `Infrastructure/PracticeObligationServiceRegistration.cs`, `Controllers/PracticeObligationController.cs` |
| Web | `Controllers/PracticeObligationController.cs` (proxy) |
| UI | `Partials/_obligation-form-dialog.cshtml`, `wwwroot/js/Shared/obligation-form.js`, the Obligations panel in `Partials/practice-view.cshtml` |

**Still open, deliberately:** the two procedure re-issues in **308** —
see [Procedures](#procedures). Until they are applied a fanned-out copy is
visible and correct on Operationalize but is still editable through the
instance door; the UI does not offer those buttons, the database does not
yet refuse them.

There is no `sqlcmd` and no `dotnet` in the environment this was written
in, so **nothing below has been executed**. It has been reviewed
statically: `node --check` on the extracted JS, and a manual sweep of the
SQL for Msg 130 / Msg 156, `BEGIN`/`END` balance, transaction pairing and
result-set discipline.

**The ask:** an **Add New Obligation** button in the Practice View
Obligations panel that creates an organisation-owned obligation at the
**practice** level, which then applies to every Practice Instance of that
practice — existing and future — while instance-specific custom
obligations keep working exactly as they do today.

Migration 227 predicted this work and declined it on purpose:

> **SCOPE: ONE INSTANCE** — A locally added obligation belongs to the
> practice instance it was added on. […] so "add it once, it appears
> everywhere" would need a practice-level table and a fan-out rule for
> instances created afterwards. That is a separate piece of work; this is
> the smaller, honest version.

This is that separate piece of work, and the shape 227 named — a
practice-level table plus a fan-out — is the shape below.

---

## Read this first: the database is behind

`306` failed on this database because **254 was never applied**. Before
building a feature that sits on top of 227 / 231 / 232 / 233 / 242 / 244,
we need to know what is actually deployed — re-issuing a procedure from
its *latest* repository body onto a database sitting at an *older* state
is how a working screen regresses.

```sql
SELECT 'practice_instance_obligation.typed_detail_json (227)' AS Object_,
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_obligation','typed_detail_json')
                 IS NULL THEN 'MISSING' ELSE 'present' END AS State_
UNION ALL SELECT 'practice_instance_evidence.source_practice_instance_obligation_id (231)',
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_evidence','source_practice_instance_obligation_id')
                 IS NULL THEN 'MISSING' ELSE 'present' END
UNION ALL SELECT 'practice_instance_obligation.implementation_status_id (242)',
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_obligation','implementation_status_id')
                 IS NULL THEN 'MISSING' ELSE 'present' END
UNION ALL SELECT 'practice_instance_obligation.connection_type_id (244)',
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_obligation','connection_type_id')
                 IS NULL THEN 'MISSING' ELSE 'present' END
UNION ALL SELECT 'sp_resolve_local_obligation_save (227/232/233/242/244)',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_local_obligation_save','P')
                 IS NULL THEN 'MISSING' ELSE 'present' END
UNION ALL SELECT 'sp_resolve_local_obligation_evidence_sync (232/233)',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P')
                 IS NULL THEN 'MISSING' ELSE 'present' END
UNION ALL SELECT 'sp_resolve_obligation_type_fields (227)',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_obligation_type_fields','P')
                 IS NULL THEN 'MISSING' ELSE 'present' END;
```

Any `MISSING` row is a migration to apply before Phase 1 starts.

---

## Decisions taken

| Question | Decision |
| --- | --- |
| Section order on Practice View | Details → **Practice Instances** → Obligations. **Done** — see [practice-view-page.md](practice-view-page.md) |
| Configure button | in the Practice Instances panel header. **Done** |
| Evidence section | stays inside each obligation card; no standalone panel |
| Who owns a practice-level obligation after fan-out | **the practice.** Edit at practice level updates every instance; retire retires everywhere. The instance copy is read-only as an obligation — the instance still owns its own *parameters* (adopt, frequency, owner, implementation status) |
| Evidence declaration | **yes**, the 232 way: the add form carries an evidence list, and fan-out creates `practice_instance_evidence` rows per instance so they can be resolved in the workspace |

---

## Schema

### 1. `grac_practice.practice_obligation` — the definition

One row per organisation-authored obligation on a practice. Columns
mirror the local-obligation set on `practice_instance_obligation` so the
add form, the API model and the renderer are the same shape:

```
practice_obligation_id  BIGINT IDENTITY  PK
organization_id         BIGINT NOT NULL  -> organization
practice_id             BIGINT NOT NULL  -> practice
obligation_name         NVARCHAR(500) NOT NULL
obligation_description  NVARCHAR(MAX) NULL
obligation_type_code    NVARCHAR(60)  NOT NULL   -- GRAC_New.obligation_type_master
typed_detail_json       NVARCHAR(MAX) NULL       -- same JSON shape as 227
execution_frequency_id  INT NULL -> frequency_master
execution_frequency     NVARCHAR(120) NULL
responsibility          NVARCHAR(300) NULL
approval_authority      NVARCHAR(300) NULL
assurance_type          NVARCHAR(40)  NULL       -- Manual / Automated
remarks                 NVARCHAR(MAX) NULL
evidence_json           NVARCHAR(MAX) NULL       -- the declared evidence list
status                  NVARCHAR(30) NOT NULL DEFAULT 'Active'
record_status_id        INT NOT NULL
entered_by/dt, updated_by/dt
```

`evidence_json` is stored on the definition, not only replayed at save
time, because an instance created next month has to be seeded from it.

### 2. `practice_instance_obligation.source_practice_obligation_id` — the marker

```
source_practice_obligation_id BIGINT NULL -> practice_obligation
```

This one column carries the whole distinction the ask requires:

| Row | `obligation_id` | `source_practice_obligation_id` |
| --- | --- | --- |
| adopted published obligation | the GRAC_New id | NULL |
| **instance** custom obligation (227, unchanged) | NULL | NULL |
| **practice-level** copy (new) | NULL | the definition id |

Nothing about the existing two rows changes, which is what keeps
instance-specific custom obligations working exactly as they do today.

---

## Procedures

### New

| Procedure | Job |
| --- | --- |
| `sp_practice_obligation_save` | add / edit / retire one definition, then fan out. Validation copied in spirit from 227 (name required, type must exist in `obligation_type_master`, `ISJSON` on the detail, assurance type in Manual/Automated) |
| `sp_practice_obligation_fan_out` | the propagation rule. `@practice_obligation_id` NULL = every definition on the practice; `@practice_instance_id` NULL = every active instance. Idempotent |
| `sp_practice_obligation_list` | the definitions for the Practice View panel, with a per-definition instance count |

### Re-issued — **each from its latest body, named here so nobody picks the wrong file**

| Procedure | Latest body lives in | Change |
| --- | --- | --- |
| `sp_resolve_local_obligation_evidence_sync` | **233** | `+ @suppress_result BIT = 0` (the 298 pattern) so fan-out can call it per instance without spraying a result set per call at the client |
| `sp_resolve_local_obligation_save` | **244** | `AND source_practice_obligation_id IS NULL` on the edit and retire `WHERE` — a practice-owned copy cannot be edited or retired through the instance door. Enforced in the procedure, not just hidden in the UI |
| `sp_resolve_obligation_list` | **244** | project `SourcePracticeObligationId` so the workspace can badge the row and disable its Edit / Remove actions |

`sp_resolve_obligation_type_fields` and `sp_resolve_obligation_type_list`
(both 227) are **reused unchanged** — the add form asks for exactly what
Control Management asks for, on both screens.

---

## The propagation rule

`sp_practice_obligation_fan_out`, in order:

1. **Create or refresh the copy** on every active instance of the
   practice — `MERGE practice_instance_obligation` on
   `(practice_instance_id, source_practice_obligation_id)`, writing
   `obligation_id = NULL`, `inherited_from_repository = 0`,
   `organization_modified = 1`, and the definition's name, description,
   type, detail, frequency, responsibility, approval authority, assurance
   type and remarks. Instance-owned parameters are **not** overwritten.
2. **Retire copies of a retired definition** — status `Retired`, never
   deleted, the same treatment 227 gives a retired local obligation.
3. **Evidence per instance** — `EXEC sp_resolve_local_obligation_evidence_sync`
   with that copy's `practice_instance_obligation_id`, the definition's
   `evidence_json` and `@suppress_result = 1`. Reused, not reimplemented:
   it already knows the NOT NULL columns, already revives a retired row of
   the same type instead of duplicating it, and already refuses to retire
   an evidence row somebody has filled in.

### When it runs

| Trigger | Covers |
| --- | --- |
| `sp_practice_obligation_save` | every instance that exists **now** |
| API, when the resolve workspace loads its obligations | an instance created later, and any drift — beside the `sp_resolve_evidence_reconcile_for_instance` call migration 304 already makes there |
| API, when Practice View loads | the practice's own list stays honest |

`sp_practice_instance_configure` (latest body: **145**) is deliberately
**not** re-issued. It is ~400 lines and the reconcile-on-load path already
covers a new instance, which is exactly the reasoning migration 304
recorded when it stopped evidence depending on somebody pressing Save.

---

## API and UI

| Layer | Work |
| --- | --- |
| API | `PracticeObligationService` + controller: `GET /api/practice/practice-obligations?organizationId&practiceId`, `POST` save, `POST retire`. Models mirror `ResolveLocalObligation*` |
| Web | forwarding controller actions, same `ForwardGetAsync` / `ForwardPostAsync` shape as `PracticeInstanceWorkflowController` |
| Web UI | **Add New Obligation** in the Practice View Obligations panel header, opening the obligation form |

### The form is extracted, not copied

The obligation add/edit form exists today **inline** in
`resolve-workspace.cshtml`: ~120 lines of `<dialog>` markup (`#rwLocalForm`
and friends) and ~400 lines of JS — type-driven rule fields from
`sp_resolve_obligation_type_fields`, the evidence row builder, the
Automated/connection visibility rules, and the save call.

Practice View needs the same form. So it moves into a shared pair, the way
the task form already does it (`_task-form-dialog.cshtml` +
`wwwroot/js/Shared/task-form.js`):

```
Partials/_obligation-form-dialog.cshtml
wwwroot/js/Shared/obligation-form.js   ->  window.pmObligationForm.open({
                                              scope: 'instance' | 'practice',
                                              ...
                                           })
```

`resolve-workspace.cshtml` then includes the partial and calls it with
`scope: 'instance'`; Practice View calls it with `scope: 'practice'`. The
two scopes differ only in which endpoint the Save button posts to.

**This is the one part of the plan that touches a working screen.** It is
also the only way to have one form and not two — and duplicating 500 lines
of form logic is exactly the drift this codebase keeps paying for
elsewhere.

**Phase 3 is now done**, ahead of Phases 1 and 2. Doing the refactor
first was the safer order: it is behaviour-neutral, and it can be tested
on Operationalize alone — today, against the database as it stands —
instead of arriving later bundled with new tables and a new endpoint,
where a regression in the add/edit flow would be hard to attribute.

The `practice` scope is implemented in the module and is inert until
Phase 2 gives it an endpoint: nothing calls it yet, because Practice
View's **Add New Obligation** button is Phase 4.

What to test on Operationalize before Phase 1 starts: add an obligation
of each type (the State / Execution / Assurance / EventResponse /
Constraint panels), the Assurance cascade both ways
(Scheduled ↔ EventDriven), Assurance + Automated showing Connection type
and URL, declaring and removing evidence, an evidence row already filled
in refusing to be removed, editing an existing organisation-defined
obligation, removing one, and `mode=view` still hiding Add / Edit /
Remove.

---

## Phases

| Phase | Deliverable | Risk |
| --- | --- | --- |
| 0 | run the prereq check above; apply whatever is missing (254 at minimum) | **still to do** — it is a read plus known migrations |
| 1 | **DONE** `307`: the table, the marker column, three new procedures, rollback. **Additive only** — the two re-issues moved to 308 | low: it either runs or its guards refuse it by name |
| 2 | **DONE** API models, service, registration, controller; Web proxy | low, additive |
| 3 | extract the shared obligation form; point Operationalize at it | **DONE** — see [resolve-typed-obligations.md](resolve-typed-obligations.md#the-obligation-form-is-a-shared-component). Behaviour-neutral, but the regression surface is the Operationalize add/edit obligation flow, so test that before Phase 1 |
| 4 | **DONE** Add New Obligation on Practice View, with the practice's own obligations as the first group of the panel. The workspace badge + disabled Edit/Remove on a copy waits on 308's `SourcePracticeObligationId` | low |
| 5 | **DONE** docs: this file, `resolve-typed-obligations.md`, `practice-view-page.md` | none |

## What 308 still owes

Both need a procedure re-emitted from its **latest** body, and the
database has to be at that state first — which is exactly what Phase 0's
check establishes:

| Procedure | From | Change |
| --- | --- | --- |
| `sp_resolve_local_obligation_save` | **244** | `AND source_practice_obligation_id IS NULL` on the edit and retire `WHERE`, so the instance door will not open on a row the practice owns |
| `sp_resolve_obligation_list` | **244** | project `SourcePracticeObligationId`, so the workspace can badge the copy and disable its Edit / Remove |

Neither is a correctness problem for the fan-out. Both are the difference
between *the UI does not offer it* and *the database will not do it*.

## How to try it once 307 is applied

1. Open a practice with at least one Practice Instance.
2. **Add New Obligation** → pick a type, fill the rule fields, declare an
   evidence type or two, Save.
3. The card appears in the **Organization defined** group with
   *on N instances*, where N is the practice's active instance count.
4. Open one of those instances in Operationalize: the obligation is there,
   adopted, marked *Organization defined*, with its evidence rows waiting
   for a location and a locator.
5. Configure a new team into the practice, then reload Practice View: the
   count goes up without anyone pressing Save — that is the fan-out
   running on load.
6. Edit the definition (rename it): every instance's copy is renamed.
   Remove it: every copy is retired, and any evidence already filled in
   stays attached to the retired row rather than being deleted.

Phases 1 and 3 both want a database to run against. There is no `sqlcmd`
or `dotnet` in this environment, so everything shipped from here is
reviewed by static sweep only — which is what let `306` reach a database
it could not run on.
