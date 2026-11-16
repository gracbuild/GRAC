# Audit flow redesign -- architecture (2026-11-14)

Agreed with sir on 2026-11-14. This is the target design and the order it is built in.
Each phase is a migration (or a few) with Api, Web and docs.

## Target flow

```
Question Set (master, versioned, approved) --+
                                             +--> Audit Definition (master, versioned, approved)
                                             |        scope, question sets, workflow, scoring
Audit Plan (Draft -> Submitted -> Active)    |
   +-- Engagement (was "Item")  <------------+  who audits, from / to, which audit definitions
          |   "View Scope" = live preview, nothing frozen
          v   (From date reached)
       Auditor: My Audits -> Execution (one per engagement x definition)
          |   Scope (live) + Continuous Assurance view
          |   Freeze Scope  -> scope snapshot; later changes do not affect the audit
          v
       Questions: Compliant / Not compliant (+ description, owner)
          |   Not compliant -> Audit Finding (observation), automatically
```

## Decisions (sir, 2026-11-14)

| # | Decision |
|---|----------|
| 1 | A definition's new version (created because a question set changed) goes through review and approval again. The Active version keeps running until then. |
| 2 | An engagement is a parent; it holds one execution per audit definition. Auditor, dates and team are set once on the engagement. |
| 3 | Compliance is marked once per question per execution (not per scope item) in the first release. |
| 4 | Continuous Assurance covers every scope item: practice instances directly; assets, departments, locations, vendors, applications, processes, business functions through the practice instances that resolve them in Operationalize (`practice_dependency_resolution`); asset categories through their assets. |

## Phase 1 -- Question Set versioning and approval (551, built)

**Model -- one row per version.** `org_assurance_question_set` keeps one row per version;
the versions of one set share `root_question_set_id` and `set_code`, and differ by
`version_number`. Questions stay keyed on the set row, so a version owns its questions.
Definitions already link a set row (`org_assurance_definition_question_set`), so a definition
version points at an exact question set version with no schema change there.
Executions already snapshot their questions (545 materialize), so running audits are unaffected.

*Why not a separate version table:* questions, the definition link, materialize and the
question grid all key on `org_assurance_question_set_id`. Row-per-version keeps every one of
those readers correct; a version table would have meant re-keying all of them.

**Lifecycle.** `version_status`: Draft -> UnderReview (Recommend) -> Active (Approve);
Return sends UnderReview back to Draft. Approving makes the previous Active version
Superseded. Only a Draft can be changed (header and questions). "New Version" copies the
Active version (header and questions) into a Draft with the next number; one Draft or
Under Review version per set at a time. Only Active versions can be adopted by a definition.

**Impact on approve.** For every audit definition whose current version links an older version
of the set:

| Definition's current version | What happens |
|---|---|
| Draft or Under Review | the link is moved to the new set version in place |
| Approved / Active | a new Draft version of the definition is created as a full copy (scope, question sets -- with the new set version --, workflow, scoring); it needs Submit for Review and Approve again (decision 1). The Active version keeps running. |
| Retired | nothing |

The Recommend and Approve views list these definitions first (`sp_org_assurance_question_set_impact`), so the approver sees what will happen.

**Version copy engine.** `sp_org_assurance_clone_rows` copies rows of any table with column
overrides and records old -> new ids (MERGE ... OUTPUT), so child rows are re-parented.
`sp_org_assurance_definition_version_copy_config` uses it to copy a definition version's scope
(groups, conditions, values), question set links, workflow (config, stages) and scoring (config, bands).
The same copy now runs when an Active definition is edited (definition save), so a new
draft no longer starts with an empty scope and no question sets (the 2026-11-13 finding).

**Plannable audit.** An audit can be planned and executed when it has an Active version and is
not Retired -- not only when its current status is Active. Otherwise a definition being revised
(current version Draft) would drop out of planning.

## Phase 2 -- Engagements (plan items) (552, built)

- Item renamed Engagement in UI, Api docs and messages.
- New child `org_assurance_engagement_definition` (engagement = `org_assurance_plan_item`):
  the audit definitions of an engagement. The old single `org_assurance_definition_id` on the
  item is migrated into it and kept for reading.
- Engagement page: auditor, from / to, team / department, notes, definitions (multi-pick of
  plannable audits), and **View Scope** -- the union of the definitions' scopes resolved live
  (PREVIEW, not saved).

## Phase 3 -- My Audits, live scope, Freeze Scope (555, built)

Decisions (sir, 2026-11-14): executions start automatically when the auditor opens My Audits on
or after From (Start Execution stays for an early start); My Audits is a sidebar item; the auditor
may exclude items before freezing, each with a reason; frozen is final. Details:
`docs/audit-management-module.md` (555).

- "My Audits": engagements where the user is the auditor and From <= today, with status.
- Opening one creates its executions (one per definition, origin PLAN) if not yet created --
  no scheduler needed.
- Execution scope is **live** until the auditor clicks **Freeze Scope**; Freeze resolves the scope
  (EXECUTION purpose) and snapshots the entities. Reverses the 545 "resolve at creation" for plan
  executions. Answering questions starts after Freeze.
- Freeze must apply the engagement's **Branch** narrowing (554:
  `sp_org_assurance_scope_resolution_narrow_location`) -- a branch is a Location; a
  practice instance is at a branch through its LOCATION dependency in Operationalize.

## Phase 4 -- Continuous Assurance view (556, built)

Shown from My Audits (3-dot Continuous Assurance, under the row). Details:
`docs/audit-management-module.md` (556).

Read-only, per execution: each scope item -> its practice instances (direct, or through
`practice_dependency_resolution`; asset category through assets) -> their Scheduled /
Execution obligations -> obligation status and last task status. Each obligation counted once
in the summary; shown under every item it belongs to in the detail.

## Phase 5 -- Question responses and findings (558, built)

Shown from My Audits (Answer Questions / View Answers, under the row). Details:
`docs/audit-management-module.md` (558).

- `org_assurance_execution_response`: execution, question (from the execution's snapshot),
  result Compliant / Not compliant / Not applicable, description, owner, answered by / at.
- Not compliant -> an observation (Audit Finding) is created with the question as its source,
  the description and the owner; later edits keep it in step; changing back to Compliant
  withdraws it while it is still open.
