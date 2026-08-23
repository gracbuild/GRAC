# Task Centre v2 — developer notes

**Source requirement:** *GRAC – Task Centre, Incremental Enhancement BRD, v1.1 Final, 16 August 2026*
**Phases delivered:** 1 (governance foundation) and 2 (candidate stage + sources + upstream sync).
Still outstanding: [Deferred to Phase 3](#deferred-to-phase-3).

**Migrations:**

| Phase | Files |
|---|---|
| 1 | `192_task_centre_v2_schema.sql`, `193_task_centre_v2_procs.sql`, `194_task_centre_v2_parent_child.sql`, `195_task_centre_v2_read.sql`, `196_task_centre_v2_open.sql` |
| 2 | `197_task_candidate_schema.sql`, `198_task_candidate_procs.sql`, `199_task_candidate_sources.sql`, `200_task_upstream_sync.sql` |
| 3 | `201_task_notification_outbox_schema.sql`, `202_task_notification_procs.sql` |
| 4 | `203_task_notification_menu_seed.sql` |

(each with a matching `*_rollback.sql`)

**Backend:**
`Api/Models/TaskModels.cs`, `Api/Services/TaskService.cs`, `Api/Controllers/TaskController.cs`,
`Api/Models/TaskCandidateModels.cs`, `Api/Services/TaskCandidateService.cs`, `Api/Controllers/TaskCandidateController.cs`,
`Api/Infrastructure/TaskCandidateServiceRegistration.cs`

**Web:**
`Web/Controllers/TaskController.cs`, `Web/Controllers/TaskCandidateController.cs`,
`Web/Views/Practice/Partials/tasks.cshtml`

**Related:** [task-engine.md](task-engine.md) (the v1 engine this builds on), [org-sla-config.md](org-sla-config.md) (the SLA policy this now consumes)

---

## What v2 is

The v1 task engine (037/048) stored a single `sla_due_at` and a free-text
`priority`. It could record work; it could not *govern* it. The BRD asks
Task Centre to become "the common execution layer" — the place where
identified actions acquire an owner, a priority, a time expectation, a
controlled exception path and a completion record.

Phase 1 delivers the governance spine. Everything is **additive**: no
column dropped, no status removed, no existing caller changed.

---

## Migration order

**Run `database/_diag_task_centre_v2_prereqs.sql` first.** It reports
which upstream scripts are missing and which of 192–196 have already
landed, and prints the exact order to run.

Apply forward in numeric order:

```
192 → 193 → 194 → 195 → 196 → 197 → 198 → 199 → 200 → 201 → 202 → 203
```

Roll back in **reverse**, with a few ordering rules that matter:

```
203 → 202 → 201 → 200 → 199 → 198 → 197 → 195 → 196 → 194 → 193 → 192
```

* **202/201 are independent** of the rest — nothing else in Task Centre
  reads the outbox, so Phase 3 can be removed on its own. Disable the
  worker (`TaskNotification:Enabled = false`) before dropping the procs,
  or it will keep calling a missing one every interval.

* **200 first.** Its rollback restores `sp_task_complete` to a body that
  references neither `task_source_action_state` nor `task_candidate`, so
  the later drops cannot fail on a dependency.
* **199 before 198.** Restoring the Gap / Risk / Assurance procs removes
  the last callers of `sp_task_candidate_create` before it is dropped.
* **195 before 192** (as in Phase 1) — its rollback restores the pre-192
  view and list proc, which is what lets 192's column drops succeed.

Each script is idempotent and guarded; re-running a completed one is a
no-op.

### Why running them out of order produces a wall of errors

Each script opens with a prerequisite guard that PRINTs, `RAISERROR`s and
sets `NOEXEC ON`. That correctly prevents anything being created — but it
**cannot silence the errors that follow**.

`SET NOEXEC ON` stops *execution*, not *compilation*. SQL Server defers
name resolution for a missing **table**, which is why the guard pattern
works cleanly in 037/048. It does **not** defer resolution for a missing
**column on a table that already exists**. So running 195 before 192
makes the parser bind every `CREATE OR ALTER PROCEDURE` against the
un-migrated `practice_task` and emit:

```
Msg 207 ... Invalid column name 'parent_task_id'.
Msg 207 ... Invalid column name 'sla_status_code'.
```

Those are noise, not damage — `NOEXEC` means nothing was created and
nothing was altered. The first three lines of output are the real
message:

```
ABORT (195): run 192_task_centre_v2_schema.sql first.
```

The preflight script exists so you never have to read past that.

> **Design note.** The only way to suppress the noise entirely is to wrap
> all 21 procedures in `EXEC sp_executesql N'...'`, which is what 037 and
> 048 do for `CREATE VIEW` (a view has no deferred name resolution at
> all). That was judged not worth the cost here: it would make every
> procedure body an escaped string literal, hurting readability and
> making every future edit error-prone, to defend against a mistake the
> preflight script already catches. Revisit if these ever ship through an
> automated runner that treats any error output as a failure.

---

## The five governance rules, and where each one lives

| BRD rule | Enforced by | Notes |
|---|---|---|
| §6 Owner resolved from existing ownership data | `sp_task_owner_resolve` (193), called from `sp_task_open` (196) | 7 rungs, never invents an owner |
| §7 Priority increase free, reduction approved | `sp_task_priority_change` (193) | two completely different code paths |
| §8 Standard SLA derived from priority, never edited | `sp_task_apply_sla` (193) | the only writer of `standard_*` |
| §8 Extension is a controlled exception, not an override | `sp_task_sla_extension_request_create` / `_approve` (194) | reuses Exception Centre |
| §11/§12 Parent owns the commitment | `sp_task_child_create`, `sp_task_complete` (194) | children cannot weaken the parent |

Every rule sits in the **database**, not the API. The Gap Centre, the
overdue sweep and Exception Centre all touch tasks without going through
`TaskService`, so a rule implemented in C# would be a rule that only
applies when someone happens to use the web UI.

---

## Data model

### `practice_task` — new columns (192)

| Group | Columns |
|---|---|
| Parent / child (§11) | `parent_task_id`, `is_mandatory_child`, `child_target_date` |
| SLA split (§8) | `standard_sla_days`, `standard_due_at`, `approved_extended_due_at`, `sla_source_code`, `sla_master_id`, `sla_master_name` |
| Extension state (§8) | `extension_status_code`, `requested_due_at`, `extension_reason` |
| Priority state (§7) | `requested_priority`, `priority_change_status_code` |
| Source (§15) | `source_type_code`, `source_record_id`, `source_reference` |
| Owner provenance (§6) | `owner_source_code` |
| Completion (§10) | `completed_by_employee_id`, `completed_dt` |

**The invariant that matters:**

```
sla_due_at  =  COALESCE(approved_extended_due_at, standard_due_at)
```

`sla_due_at` stays the **effective** monitoring date, so
`sp_task_overdue_sweep` (037) and the view's `is_overdue` keep working
with no change. `standard_due_at` is the immutable original commitment —
an approved extension adds a date, it never overwrites one. That
separation is the whole point of BRD §8 and §13.

### New tables (192)

| Table | Purpose |
|---|---|
| `task_activity` | The user-facing update/comment/governance feed (§16). `practice_audit_trace` remains the immutable compliance log — this is its human-readable companion. |
| `task_attachment` | Evidence. Same shape as `exception_request_attachment`: fat `VARBINARY(MAX)` in its own table so list queries stay narrow. |
| `org_task_default_owner` | Rung 6 of the owner ladder. The **only** new ownership master data — rungs 1–5 all read tables that already exist, as BRD §6 requires. |

### `exception_request` — widened (192)

BRD §19: *"do not create a parallel exception mechanism."* So instead of a
task-side approval table, the existing one carries task requests:

- `custom_gap_id` becomes **nullable** (every pre-192 row keeps its value)
- `task_id` added, plus `due_at_original` / `due_at_requested` / `priority_original` / `priority_requested`
- `request_type_code` widened to `GAP_CANDIDATE | SLA_CANDIDATE | TASK_SLA_EXTENSION | TASK_PRIORITY_REDUCTION`
- `CHECK (custom_gap_id IS NOT NULL OR task_id IS NOT NULL)`
- filtered unique indexes: at most one Pending request of each task type, per task

---

## The owner ladder (§6)

`sp_task_owner_resolve` returns the first rung that yields an **active
employee of the requesting organisation**:

| # | `owner_source_code` | Read from |
|---|---|---|
| 1 | `EXPLICIT_SOURCE` | caller-supplied owner, or `custom_gap.owner_employee_id` |
| 2 | `PRACTICE_OWNER` | `practice.practice_owner_id` / `practice_owner` |
| 3 | `CONTROL_OWNER` | `organization_control.primary_owner` |
| 4 | `PROCESS_OWNER` | `practice_instance.primary_owner_id` / `primary_owner` |
| 5 | `FUNCTION_OWNER` | `organization_business_function.owner_name` |
| 6 | `ORG_DEFAULT` | `org_task_default_owner` |
| 7 | `MANUAL` | nothing resolved — the UI must ask a human |

Most GRAC ownership predates `organization_employee` and is stored as a
display **name**. `fn_task_employee_by_name` bridges that, and it is a
sound bridge because `009_practice_employee_master.sql` seeded the
employee master *from those very names*.

**Cross-tenant safety net.** The legacy `*_owner_id` columns are plain
`BIGINT`s with no organisation guard, so a stale value could point at
another tenant's employee. Anything that does not resolve to an active
employee of *this* organisation is discarded and the ladder falls to
`MANUAL` — leaking an assignment across a tenant boundary is far worse
than an unassigned task.

A manual reassignment stamps `REASSIGNED`: a human decision supersedes
whatever the ladder proposed.

---

## Priority governance (§7)

```
Low → Medium → High → Critical      applied immediately, SLA recalculated
Critical → High → Medium → Low      Exception Centre approval required
```

An increase updates `priority`, calls `sp_task_apply_sla` (which
re-derives the standard SLA and cascades to children), writes a
`PriorityChange` activity and a `PRIORITY_INCREASE` audit trace row.

A reduction changes **nothing** on the task. It creates a Pending
`TASK_PRIORITY_REDUCTION` exception request and parks the ask in
`requested_priority` / `priority_change_status_code` so the grid can show
a badge. `sp_task_priority_reduction_approve` applies it;
`sp_exception_request_reject` releases it.

Reason and requester are **mandatory** for a reduction and refused for
neither on an increase — asymmetric on purpose.

Children throw (`55619`): they inherit the parent's priority.

---

## SLA derivation and extension (§8, §13)

### Derivation

`sp_task_apply_sla` resolves the organisation's SLA policy for the task's
priority and writes `standard_sla_days` + `standard_due_at`.

Lookup reuses the pattern the gap flow settled on in 184 —
`sla_master.classification` matched against the priority, then the org's
tuned `org_sla_config`. `sp_org_sla_match_for_priority` is the named seam
for that.

> **Implementation note.** `sp_task_apply_sla` calls
> `sp_org_sla_match_for_severity` *directly* rather than through
> `sp_org_sla_match_for_priority`, because T-SQL forbids nesting
> `INSERT ... EXEC` (error 8164) and the priority seam is itself
> implemented that way. The seam stays for callers that are not already
> inside an `INSERT ... EXEC`.

No matching Active config → fall back to
`task_type_master.default_sla_hours` (the pre-192 behaviour) and stamp
`sla_source_code = 'TYPE_DEFAULT'`. The task detail view surfaces that as
a prompt to configure an SLA for the classification, rather than failing.

### Extension

| Step | Effect on the task |
|---|---|
| Request raised | `extension_status_code = 'Pending'`, `requested_due_at`, `extension_reason`. **`sla_due_at` unchanged** — BRD §20. |
| Approved | `approved_extended_due_at` set, `sla_due_at` moves to it, `sla_source_code = 'EXTENDED'`. `standard_sla_days` / `standard_due_at` **untouched**. |
| Rejected | `extension_status_code = 'Rejected'`. Original due date stands. |

A requested date that is not *later* than the current due date is refused
(`55658`) — early completion never needs approval.

Approval clears `escalated_at` when the new date is in the future, so
`sp_task_overdue_sweep` can escalate again if the *new* commitment is
missed. The original breach is not erased: the transition log,
`task_activity` and `practice_audit_trace` all retain it.

Children throw (`55656`): the extension is raised against the parent.

---

## Parent / child (§11, §12)

**One level only.** A child cannot have children (`55674`). The BRD's
model has exactly one accountable parent per work package.

Two implementation choices worth knowing:

1. **Children use `subject_entity_type = 'TaskChild'`,
   `subject_entity_id = <parent id>`.** They must not reuse the parent's
   subject pair, because 037's filtered unique index
   `ux_pm_practice_task_impl_dedup` allows only one open Implementation
   task per subject — `sp_task_open` would return the *parent's* id
   instead of creating a child. Source navigation is unaffected:
   `source_type_code` / `source_record_id` are inherited from the parent.

2. **Children are created as `task_type_code = 'Custom'.**` A child is a
   distributed activity, not a second instance of the parent's governed
   type; this also keeps children clear of the Implementation two-gate
   closure rule, which applies to the accountable parent. `sp_task_list`
   and `sp_task_center_counts` exclude children so the Custom tab still
   means "custom top-level tasks".

Inheritance is total — priority, standard SLA, approved extension and
effective due date all come from the parent and are read-only on the
child. Only owner, title, description and an optional
`child_target_date` (clamped to the parent's due date) belong to the
child.

Completion: `sp_task_completion_eligibility` reports the gate;
`sp_task_complete` enforces it (`55693`). Completing the last mandatory
child writes a `ParentEligibleForCompletion` note on the parent — the
parent owner still confirms.

---

## Read layer (195)

`vw_pm_practice_task` keeps every 048 column and adds the v2 set plus two
derived SLA columns:

- **`sla_timing_code`** — the temporal fact: `OnTrack | DueSoon | DueToday | Breached | Completed | NotSet`
- **`sla_status_code`** — what BRD §17's "SLA Status" field shows: the same, except an approved extension surfaces as `Extended` while inside the new window. **A breach is never masked by an extension.**

The warning threshold is *configurable*, per BRD §13: it reads
`org_sla_config.warning_pct` (tuned in the Org SLA Configuration screen),
falling back to 75%.

`sp_task_list` gains `@parent_task_id`, `@include_children`,
`@sla_status_code`, `@source_type_code`, `@source_record_id`,
`@priority`. **Children are excluded by default** — see [Behaviour
changes](#behaviour-changes).

`sp_task_get` returns five result sets in one round trip: header,
activity, evidence metadata, children, governance requests.

`sp_task_source_tasks` powers the "Related Tasks" panel on Gap /
Exception / Risk / Assurance screens (§15).

---

## API

Base route `/api/practice/tasks` (Api tier), proxied at
`/practice/api/tasks` (Web tier).

| Verb | Path | Purpose |
|---|---|---|
| GET | `/` | List (paged). New filters: `parentTaskId`, `includeChildren`, `slaStatusCode`, `sourceTypeCode`, `sourceRecordId`, `priority` |
| GET | `/counts` | Tab badges. Now also `breachedCount`, `pendingApprovalCount` |
| GET | `/{id}` | Operational detail (§16) |
| GET | `/{id}/eligibility` | Completion gate (§12) |
| GET | `/by-source` | Source → tasks (§15) |
| GET | `/owner-resolve` | Owner ladder preview (§6) |
| GET | `/attachments/{id}` | Download evidence |
| POST | `/` | Open |
| POST | `/{id}/assign` | Reassign (no approval — §6) |
| POST | `/{id}/transition` | State change |
| POST | `/{id}/close` | Close (two-gate guarded) |
| POST | `/{id}/priority` | Governed priority change (§7) |
| POST | `/{id}/sla-extension` | Raise extension request (§8) |
| POST | `/{id}/children` | Decompose (§11) |
| POST | `/{id}/complete` | Governed completion (§10, §12) |
| POST | `/{id}/activity` | Comment / update (§16) |
| POST | `/{id}/attachments` | Upload evidence (multipart) |
| POST | `/requests/{rid}/approve-sla-extension` | Approve (§8) |
| POST | `/requests/{rid}/approve-priority-reduction` | Approve (§7) |

**Rejection is deliberately absent** — it stays on Exception Centre's own
endpoint (`sp_exception_request_reject`, made task-aware in 193).
Splitting reject across two controllers would create exactly the parallel
approval mechanism BRD §19 forbids.

### Status codes

`POST /{id}/priority` returns **200** with `statusCode: "Applied"` for an
increase, and **202 Accepted** with `statusCode: "PendingApproval"` for a
reduction — 202 says precisely what happened: the ask was accepted,
nothing has changed yet. `POST /{id}/sla-extension` is always 202 for the
same reason.

### Error mapping

| SQL error | Reason code | HTTP |
|---|---|---|
| 53520 | `ILLEGAL_TRANSITION` | 409 |
| 53521 | `REASON_REQUIRED` | 400 |
| 53752 | `TWO_GATE_NOT_PASSED` | 409 |
| 55619 | `CHILD_PRIORITY_LOCKED` | 409 |
| 55620 | `REASON_REQUIRED` | 400 |
| 55621 | `ACTOR_REQUIRED` | 400 |
| 55622 | `PRIORITY_REQUEST_PENDING` | 409 |
| 55656 | `CHILD_SLA_LOCKED` | 409 |
| 55657 | `EXTENSION_PENDING` | 409 |
| 55658 | `EXTENSION_NOT_LATER` | 400 |
| 55673 | `PARENT_COMPLETED` | 409 |
| 55674 | `CHILD_NESTING_NOT_ALLOWED` | 409 |
| 55692 | `ALREADY_COMPLETED` | 409 |
| 55693 | `COMPLETION_BLOCKED` | 409 |
| 55600–55799 (other) | `VALIDATION_ERROR` | 400 |
| anything else | `SQL_ERROR` | 500 |

### Forward/backward compatibility

`TaskService` binds v2 parameters only when
`sys.parameters` says the proc declares them, and `MapRow` reads a v2
column only when the result set carries it. So the Api tier is
deployable **before or after** the migrations — neither order breaks.

---

## UI

`Views/Practice/Partials/tasks.cshtml`:

- The dead `Workflow` / `Current Stage` columns (always rendered empty)
  are replaced by **SLA Status** and **Children**.
- Owner shows the resolved **name**, with the ladder rung beneath it
  ("from Practice owner").
- Due date shows the effective date, with `std <date>` beneath when an
  approved extension is in force — the original commitment stays visible.
- In-flight requests surface as row badges ("Extension pending",
  "Priority Medium pending").
- Row menu gains **Add Update / Comment**, **Change Priority**, **Request
  SLA Extension**, **Add Child Task**, **Complete Task**. Disabled items
  state the *BRD rule* that refused them, not just "not allowed" — when
  the system says no, the operator should learn why.
- **View** now opens a real detail drawer (one `GET /{id}`) instead of the
  previous `alert()` stub: identity, origin, SLA block, description,
  children, Exception Centre requests, evidence (with upload) and the
  activity feed.

The new row actions use `prompt()`/`confirm()` to match the existing
actions in that file. Converting the whole screen to modal dialogs is a
separate UI pass — mixing the two styles would be worse than either.

---

## Behaviour changes

Three, all deliberate:

1. **`sp_task_list` excludes children by default.** Before 192 no task had
   a parent, so every existing caller sees the same rows. Now that
   decomposition exists, listing children as peers of their parents would
   misrepresent the work. Pass `includeChildren=true` or `parentTaskId`.

2. **`sp_task_center_counts` counts top-level tasks only**, and adds
   `BreachedCount` / `PendingApprovalCount`. Without the parent filter the
   Custom badge would inflate every time somebody split a task.

3. **`TaskOpenRequest` now carries `StartDate` / `TargetDate`.** The
   "+ New Task" form has always posted them; the record had no such
   members, so they were silently dropped. They now bind — which is what
   the form obviously intended.

---

## Conflict register (BRD §19)

> *"Where an existing behaviour conflicts with this BRD, preserve data
> integrity and explicitly document the conflict for review rather than
> silently removing existing functionality."*

### 1. Lifecycle vocabulary — **mapped, not replaced**

The BRD's lean lifecycle is `APPROVED → IN PROGRESS → COMPLETED`. GRAC
runs a data-driven state machine (035) with
`Open/Assigned/InProgress/PendingReview/Closed` plus the Implementation
two-gate closure (§12.2.3). We map:

| BRD | GRAC |
|---|---|
| Approved | `Assigned` (owner + priority + SLA settled) |
| In Progress | `InProgress` |
| Completed | `Closed` + `completed_by_employee_id` / `completed_dt` |

No `entity_status_master` rows added or removed, so transition rules,
two-gate closure and the 053 sample data all keep working.

**Consequence for review:** `sp_task_complete` delegates to
`sp_task_close`, so an *illegal* transition still throws 53520 → HTTP
409. A task sitting in `Assigned` cannot jump straight to Completed; it
must be started first. That matches the BRD's own three-state flow, but
it is stricter than "complete whenever you like".

### 2. Caller-supplied Target Date — **honoured**

BRD §8 says users must not edit the standard SLA. The Add Implementation
Task modal (043) and the New Task dialog both offer a Target Date field,
and removing them would delete working functionality.

Resolution: when `@target_date` is supplied, it is treated as the
standard commitment (`standard_due_at = @target_date`, `sla_source_code =
'TYPE_DEFAULT'`) so the `sla_due_at = COALESCE(extended, standard)`
invariant still holds, and the org SLA policy is simply not consulted for
that task. When it is omitted — every system-generated path — the policy
drives the date exactly as the BRD specifies.

**For review:** if the intent is that *no* human may ever set a due date,
those two form fields should be removed and this branch deleted.

### 3. Gap → Task bypassed the candidate stage — **resolved in Phase 2**

Phase 1 left `sp_custom_gap_analysis_save` (174) creating an Approved
Task directly. Migration 199 rerouted it at the `sp_custom_gap_task_create`
seam, so gap analysis now raises a Task Candidate with **no change to
174 itself**. Closed.

### 4. Event Assurance is not a candidate source — **open, needs a decision**

BRD §3 says Event Assurance creates Task Candidates. Migration 135
deliberately did the opposite: the Event Driven tab *"reads the event
engine directly rather than mirroring `event_instance` rows into
`practice_task`"*.

Wiring events in would give the same work **two execution surfaces** —
the event checklist and a task — and completing one would not complete
the other.

Per §19 the existing design stands and the deviation is logged here. To
change it, the Event Driven tab must first be reworked to read tasks
rather than the checklist. That is a product/UI decision, not a data one.
A middle option exists and was considered: raise a candidate only when an
obligation is **missed or failed**, i.e. when it genuinely becomes
remediation work, leaving normal execution on the checklist.

### 5. Exception is not a candidate source — **open, low priority**

BRD §3 lists Exception as a source. But an exception in GRAC is a formal,
time-boxed decision *not* to remediate inside the window (161's own
definition) — there is no remediation action to execute, so there is
nothing for Task Centre to own.

The one case that does generate work is an approved exception that
**expires** and needs re-assessment, and no expiry sweep exists yet.
Raising a candidate at approval time would create a task for work nobody
has agreed to do. Left unwired until the expiry sweep exists.

---

## Phase 2 — the candidate stage (197–200)

### What a Task Candidate is

BRD §2: *"an identified action awaiting execution validation"*. It is not
a lightweight task. It is the record of work an upstream centre has
already analysed, sitting in the one gate Task Centre owns: **who owns
this, and how urgent is it?** The SLA follows from urgency.

BRD §5 is emphatic that this stage *"must not duplicate analysis, risk
assessment, gap assessment or exception decision-making already performed
in upstream centres"* — which is why `task_candidate` carries no
severity, no impact and no root cause. Those live in the source and stay
there.

Custom tasks skip the stage entirely (BRD §4B): *"the creator is
explicitly creating the work."*

### Lifecycle

```
New ──validate──▶ Validated ──approve──▶ Approved ──▶ practice_task
 │                    │
 └────── discard ─────┴──▶ Discarded
```

Deliberately **not** a state-machine entity. Adding it to
`entity_status_master` would imply a richness the BRD explicitly does not
want — this is a gate, not a workflow.

### One source, many tasks — and still idempotent

BRD §15 requires one source item to be able to raise many tasks
(`GAP-101 → update policy, configure system, conduct awareness`). That
rules out a unique index on `(source_type_code, source_record_id)`. But
automatic generators must not spawn a duplicate every time a gap analysis
is re-saved.

`source_dedupe_key` reconciles the two:

* automatic triggers pass a stable key (`GAP_REMEDIATION`,
  `RISK_TREATMENT`, `OBSERVATION_REMEDIATION`) and a filtered unique
  index permits **one open candidate per (source, key)**;
* a human adding a second, different action passes **NULL**, and NULLs
  are excluded from the index.

The API's create endpoint deliberately does **not** expose the key, so a
manual add can never collide with a generator's.

### Sources wired

| Source | Seam | Dedupe key |
|---|---|---|
| Gap | `sp_custom_gap_task_create` (rewritten) | `GAP_REMEDIATION` |
| Risk | `sp_risk_candidate_accept` (superset) | `RISK_TREATMENT` |
| Continuous Assurance | `sp_org_assurance_observation_accept` (superset) | `OBSERVATION_REMEDIATION` |
| Event Assurance | **not wired** — conflict 4 | — |
| Exception | **not wired** — conflict 5 | — |

Every rewrite is a strict superset: same name, same parameters, same
result-set columns plus additions. **No caller changed anywhere** — in
particular `sp_custom_gap_analysis_save` (174) is untouched, because the
reroute happens at the seam it already calls.

Gaps that already had an open task before Phase 2 keep it: the rewritten
`sp_custom_gap_task_create` returns the existing task and raises no
candidate.

### Approval

The gate is a **confirmed owner** (`55824` otherwise). Priority always has
a value and the SLA is derived, so the owner is the only thing a human
must settle — exactly BRD §2's *"a confirmed owner, priority and SLA"*.

The task is opened through `sp_task_open`, so the state machine, audit
trail, source stamping and SLA derivation behave identically to any other
task. **The SLA is derived again at approval**, not copied from the
proposal: the org policy may have changed since the candidate was raised,
and the commitment must reflect policy at the moment it is made.

### Upstream synchronisation (§14)

> *"the originating source record must be updated to show that its
> associated task/action has been completed ... Task completion must NOT
> automatically close the upstream record."*

That second sentence is the whole design constraint. Task Centre may
report; it may not decide.

`task_source_action_state` is keyed `(source_type_code,
source_record_id)` and maintained by `sp_task_source_sync`, called from
`sp_task_complete`. **No source table's status column is touched
anywhere.**

Why one table instead of columns on each source: the alternative means
four schema changes across four modules Task Centre does not own, four
places to keep in step, and a fifth for every new source. One table gives
every source the same answer, costs no `ALTER`s outside this feature, and
cannot be mistaken for the source's own lifecycle status.

Counts cover **top-level tasks only** — a parent owns the commitment
(BRD §11), so a work package with five children is one action to the
source, not six.

`sp_task_source_action_state_get` derives the §18 wording rather than
storing it, so rephrasing never needs a data migration. Note every
`Completed` message ends by handing the decision back to the source
module — §14 expressed as UI copy.

### API — candidates

Base route `/api/practice/task-candidates`, proxied at
`/practice/api/task-candidates`.

| Verb | Path | Purpose |
|---|---|---|
| GET | `/` | List. `statusCode=OpenSet` = New + Validated |
| GET | `/counts` | Tab badge, incl. `unownedCount` |
| GET | `/{id}` | Detail + history |
| GET | `/source-items` | BRD §15 panel — candidates **and** tasks in one list |
| GET | `/source-state` | BRD §14 marker for a source screen |
| POST | `/` | Raise manually (no dedupe key) |
| POST | `/{id}/validate` | Confirm owner + priority |
| POST | `/{id}/approve` | Convert to an Approved Task (201) |
| POST | `/{id}/discard` | Will not be executed |

There is no update or delete. A candidate is validated, approved or
discarded — letting callers rewrite its origin or title would let Task
Centre quietly redefine work the source identified.

### UI

A **Task Candidates** tab leads the Task Centre, because that is the
order work actually flows in. Row actions: View, Validate, Approve,
Discard. Approve is disabled with the reason *"A confirmed owner is
required before a candidate can become an accountable task"* until the
owner is settled, and an unresolved owner renders as **Needs an owner**
rather than an empty cell.

`+ New Task` is hidden on that tab: it creates a Custom task, which by
§4B skips the candidate stage.

---

## Phase 3 — SLA notification (201–202)

Phase 1 delivered SLA *monitoring* (`sla_status_code` derived from the
organisation's own `warning_pct`). Phase 3 delivers the other half of
BRD §13: telling somebody.

### Outbox, not a sender — and why

There is **no notification delivery infrastructure in this codebase**.
`org_sla_config_notify_role` (178/182) stores which roles to notify and
`sp_org_role_holders_list` (117) resolves who holds them, but nothing
queues or sends. `PracticeEmailService` exists only in the **Web** tier
and is registered in `Web/Program.cs`, so an Api-side sweeper cannot
reach it without moving a working component.

So Phase 3 records the **obligation**: one `task_notification_outbox` row
per (task, threshold, recipient), with a status lifecycle
(`Pending → Sent | Failed | Suppressed`) ready for whatever dispatcher is
chosen later.

That is also the honest compliance answer. *"GRAC determined that these
five people should have been told, at this time, for this reason"* is the
evidentiary claim an audit cares about; an SMTP transcript is not.

### Thresholds

Elapsed percentage of the SLA window, measured against the **effective**
due date so an approved extension moves the whole scale with it (§8):

```
elapsed_pct = (now − baseline) / (due − baseline) × 100
```

| Event | Fires when | Source of the number |
|---|---|---|
| `WARNING` | `elapsed_pct >= warning_pct` | `org_sla_config.warning_pct`, else 75 |
| `BREACH` | `now > due` | implicit 100% |
| `ESCALATION` | `elapsed_pct >= escalation_pct` | `org_sla_config.escalation_pct`, else 100 |

BRD §13 asks for *"configurable notification thresholds rather than
hard-coded timings"* — hence reading the organisation's own tuned config
(183) rather than constants. A task whose SLA master never matched still
gets WARNING and BREACH on the defaults: silence is the worst possible
failure mode for an SLA monitor.

A freshly-swept task can legitimately owe all three events at once (one
created already overdue, or a week without a sweep). Recording all three
is correct — each is a distinct governance fact.

### Recipients

Two independent sources, unioned:

* **the task owner, always, for every event** — `recipient_reason_code = 'OWNER'`;
* **every active holder of every configured notify role** — `'ROLE'`.

BRD §13 says *"Owner reminders **and** configured management
escalation"*, so the owner is notified whether or not any role is
configured. A holder who is also the owner is skipped — two identical
messages for one event is noise.

A configured role with **no active holder** still produces one row with a
NULL recipient. That is deliberate: *"we were supposed to escalate to the
Compliance Manager and nobody holds that role"* is exactly the finding an
audit needs, and dropping it silently would hide a governance gap behind
a technical one. It surfaces as `unroutableCount`.

### Idempotency — and why the key carries the due date

The sweeper runs on a timer, so a Breached task must not generate a row
every 60 seconds. The dedupe index is
`(task_id, notify_event_code, due_at_key, recipient_employee_id)`.

`due_at_key` is the effective due date at the moment the row was raised.
Without it, a task warned about in January could never be warned about
again after an extension pushed it to June — the one case where a
reminder matters most. A new commitment is a new key, which re-arms the
whole sequence exactly once.

### Relationship to `sp_task_overdue_sweep`

**037 is untouched.** It transitions a breached task to `Escalated`; the
new sweeper decides who should be *told*. Two jobs, one concern each.
They can run on different schedules and neither knows about the other:
the transition is guarded by `escalated_at IS NULL`, the notification by
the outbox dedupe index.

### The worker

`TaskNotificationWorker` is a `BackgroundService` mirroring
`EventAutoRaiseWorker` deliberately — same options shape, same failure
posture, same reasoning about Hangfire (Q002 approved it, but on
condition the package arrives in a dedicated `.csproj`-only PR, so this
adds no dependency).

```jsonc
"TaskNotification": {
  "Enabled": true,
  "IntervalSeconds": 300,     // SLA thresholds move in hours; 30s would add load, not speed
  "BatchSize": 200,
  "StartupDelaySeconds": 45,
  "OrganizationId": null      // null = every organisation
}
```

Service and worker register **separately**, so an environment that would
rather drive the sweep from SQL Agent registers only the service:

```csharp
builder.Services.AddPracticeTaskNotificationService();
builder.Services.AddPracticeTaskNotificationWorker();   // optional
```

Per-task failures are parked in `practice_audit_trace` as
`NOTIFY_SWEEP_ERROR` — the same channel 037 uses for `SWEEP_ERROR` — so
one malformed task cannot stall the batch.

### API — notifications

| Verb | Path | Purpose |
|---|---|---|
| GET | `/api/practice/task-notifications` | Outbox, or one person's inbox via `recipientEmployeeId` |
| GET | `/api/practice/task-notifications/counts` | Badges, incl. `unroutableCount` |
| POST | `/api/practice/task-notifications/sweep` | Run one pass now (idempotent) |
| POST | `/api/practice/task-notifications/{id}/mark` | Dispatcher feedback |

There is no `send` endpoint, by design.

---

## Phase 4 — delivery and the source panels (203)

### My Notifications — the in-app dispatcher

Phase 3 recorded the obligation; Phase 4 delivers it, in-app. No SMTP,
no moving `PracticeEmailService`, no new dependency.

**Read = Sent.** For an in-app channel, the recipient opening and
acknowledging the message *is* the delivery, so a read maps to
`status_code = 'Sent'` rather than inventing a fifth lifecycle state.

**Nothing is marked automatically.** Auto-marking on render would record
"delivered" for rows the user scrolled past — and these rows are the
evidence that somebody was told about an SLA breach. Marking is explicit:
per row, or an intentional *Mark all read*. The unread badge then means
what it says.

**Everything is session-scoped.** The `/practice/api/task-notifications/me*`
routes take the recipient from `PracticeSessionIdentity.EmployeeIdKey`,
never from the querystring. These messages name overdue work and the
people accountable for it, so one signed-in user must not be able to read
another's — the same pattern `DocumentAcknowledgementController` uses for
its `/my-*` routes.

`sp_task_notification_mark_all` deliberately has **no** all-recipients
variant. Clearing somebody else's unread state would destroy the only
evidence they had not seen it.

| Verb | Path | Purpose |
|---|---|---|
| GET | `/practice/api/task-notifications/me` | My notifications |
| GET | `/practice/api/task-notifications/me/counts` | Unread badge |
| POST | `/practice/api/task-notifications/me/mark-all` | Mark mine read |
| POST | `/api/practice/task-notifications/mark-all` | Api-side; `recipientEmployeeId` required so there is no "mark everyone's" path |

Menu row `my-notifications` sits under `nav-oversight` at display order
270, immediately after My Acknowledgements — both are personal inboxes.
Granted to **every active role** for the same reason 154 does it:
restricting the screen to Admin would hide from people the very thing
addressed to them. `can_delete = 0` — a recipient must not be able to
erase evidence that they were told.

### Source-side Related Tasks panel (§15 / §14)

One shared partial, `_related-tasks-panel.cshtml`, mounted by every screen
that owns a task source. Duplicating it per screen would mean three
places to fix when §14's wording changes.

```js
window.__gracRelatedTasks.mount(containerEl, {
    sourceTypeCode: 'Gap',        // Gap | Risk | ContinuousAssurance | ...
    sourceRecordId: 101,
    organizationId: orgId         // optional
});
```

It shows **candidates and tasks together**. Once the candidate stage
exists, a source can have work that is identified but not yet
accountable, and hiding it would tell a gap owner *"nothing is
happening"* when something is waiting on validation. Children are
indented rather than hidden — the parent owns the commitment (§11), but
the source owner still wants to see how the work was distributed.

Above the table sits the §14 task-action status line, rendered verbatim
from the API so the phrasing that hands the closure decision back to the
source module cannot drift.

Wired into:

| Screen | Mount point |
|---|---|
| `gap-detail.cshtml` | `#gapRelatedTasks`, from `renderMetadata()` in `GapLifecycle/gap-detail.js` |
| `org-assurance-observations.cshtml` | `#oaObRelatedTasks`, from `renderRelatedTasks()` in the detail tab |
| `risk-centre.cshtml` | `#riskRelatedTasks`, from `openDetailModal()` — added in Phase 5 |

---

## Phase 5 — Risk detail view and the sidebar badge

### Risk candidate detail modal

Phase 4 could not mount the shared panel on Risk Centre because the
screen had no per-record view at all. Phase 5 adds one — as a **modal,
not a page**, reusing the screen's existing idiom (Accept and Reject are
already modals) and its existing `GET /{id}` read and `metaOf()`
renderer. The only genuinely new surface is presentation; nothing about
how a risk candidate is fetched or displayed was duplicated.

Closing goes through `closeDetailModal()` rather than the generic
`hide()`, so the panel is cleared and cannot flash the previous
candidate's tasks when the modal is reopened.

### Sidebar unread badge

Attaches to the `data-menu-key` hook `_PracticeMenuTree.cshtml` already
emits, from `_Layout.cshtml`. It is deliberately **not** in the menu
partial: that component renders from `menu_master` and knows nothing
about any one feature's counts, and teaching it about notifications would
couple generic navigation to a single module.

Entirely best-effort — a badge must never break navigation. Endpoint
missing (Phase 3 not deployed), account not mapped to an employee,
network down: every path leaves the sidebar exactly as it was. Polls
every 5 minutes, matching the sweeper's default interval, plus on tab
focus so marking things read updates without waiting out the interval.

---

## Deferred to Phase 6

| BRD | Item |
|---|---|
| §13 | **Email delivery**, if wanted alongside the in-app centre. The outbox and `mark` seam are ready; the open question is where `PracticeEmailService` should live so the Api can reach it — moving it to a shared location is clean, duplicating it into the Api is not. |
| §3 | **Event Assurance** and **Exception** as candidate sources — conflicts 4 and 5. Both are product decisions, not engineering. |
| — | **Automated tests.** Still no `Api.Tests` project, so the acceptance list below is manual. This is now the largest outstanding risk across all five phases. |

---

## Test scenarios

Not yet automated (no `Api.Tests` project — same gap noted in
[task-engine.md](task-engine.md)). Written as the acceptance list for
Phase 1, tracking BRD §20:

**Owner (§6)**
1. Task opened with no assignee against an instance whose `primary_owner` matches an employee → owner set, `owner_source_code = 'PROCESS_OWNER'`.
2. Same, but the owner name matches an employee in a *different* organisation → owner NULL, `MANUAL`.
3. Manual reassign → `owner_source_code = 'REASSIGNED'`, `Reassign` activity row, no exception request.

**Priority (§7)**
4. `Medium → High` → applied, `standard_due_at` recomputed, no exception request.
5. `High → Medium` without a reason → 400 `REASON_REQUIRED`.
6. `High → Medium` with a reason → 202, task priority unchanged, one Pending `TASK_PRIORITY_REDUCTION`.
7. Second reduction while one is Pending → 409 `PRIORITY_REQUEST_PENDING`.
8. Approve it → priority applied, SLA recomputed, children cascaded.
9. Reject it instead → priority unchanged, `priority_change_status_code = 'Rejected'`, retry allowed.
10. Priority change on a child → 409 `CHILD_PRIORITY_LOCKED`.

**SLA (§8, §13)**
11. Open a task whose priority matches an Active org SLA config → `sla_source_code = 'AUTO'`, `standard_due_at = entered + policy days`.
12. No matching config → `TYPE_DEFAULT`, date from `task_type_master`.
13. Extension requested → `sla_due_at` **unchanged**, status Pending.
14. Requested date earlier than the current due date → 400 `EXTENSION_NOT_LATER`.
15. Extension approved → `approved_extended_due_at` set, `sla_due_at` moves, `standard_sla_days` and `standard_due_at` **identical to before**.
16. Extension approved on a previously breached task → `escalated_at` cleared, breach still present in `task_activity`.
17. Extension on a child → 409 `CHILD_SLA_LOCKED`.

**Parent / child (§11, §12)**
18. Two children with different owners → both created, both inherit parent priority and due date.
19. Child target date beyond the parent's due date → clamped, not rejected.
20. Child of a child → 409 `CHILD_NESTING_NOT_ALLOWED`.
21. Complete a mandatory child → parent still open, `ChildCompleted` on the parent.
22. Complete the parent with a mandatory child open → 409 `COMPLETION_BLOCKED`.
23. Complete the last mandatory child → `ParentEligibleForCompletion` on the parent; parent completes on confirmation.
24. Parent priority increase → children's priority and dates cascade.

**Compatibility**
25. `sp_task_list` with no new parameters returns the same rows as before 192.
26. Gap SLA override (184) still works end to end; `sp_exception_request_list` still returns gap rows *and* now returns task rows.
27. Implementation task in `InProgress` → `sp_task_complete` still throws 53752.
28. Api tier deployed **before** 192–196 → list, counts and open all still work.
