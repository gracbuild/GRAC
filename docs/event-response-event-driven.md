# Event-driven obligations are Event Response (CM 086 + PM 513)

**Date:** 2026-11-04

**Applies to:** Control Management (GRAC-ADMIN) and Practice Management.

This supersedes "event-driven Assurance" everywhere it appears in
`event-driven-profile-mapping.md`, `resolve-typed-obligations.md` and
Control Management's `docs/event-driven-assurance-design.md`.

## The request

> "Obligation type assurance akumbo ipo scheduled ano event driven ano enna oru chodyam undallo. Apo event driven anennu select cheythal sambhavikunna karyangal event response leku mattan patto? Event response lu event driven ano ennu chodikenda avasyam illa. Pakshe event ethanu people ano asset ano ennathu avide chodikanam. Assurance lu event driven ano scheduled ano ennu chodkanda. Assurance scheduled mathre undaku."

Decisions confirmed before coding:

1. Every existing event-driven Assurance obligation is converted to Event Response automatically.
2. Event Response asks **People / Asset**, then **the event** (Onboarding, Offboarding, Commissioning, Decommissioning). It does not ask for a separate free-text trigger.
3. The deadline is in **days** only.

## What the user sees

| Screen | Before | After |
| --- | --- | --- |
| Obligation Master (GRAC-ADMIN), type **Assurance** | Verification Method, **Trigger Mode** (Scheduled / Event Driven), then a Frequency or an Event Domain → Event → Due Within | Verification Method, **Assurance Frequency** (required). No trigger mode. |
| Obligation Master, type **Event Response** | Trigger Event (free text), Response Action, SLA Value + SLA Unit | **Applies To** (People / Asset) → **Event** → Response Action → **Due Within (days)** |
| Practice Management obligation form (Operationalize / Practice View custom obligations) | Same as Control Management before | Same as Control Management after |
| Operationalize, "Your answers" on an adopted Event Response | — (Event-driven Assurance had Event + SLA value + SLA unit) | **Event** + **Due within (days)** |
| Operationalize, published detail of an Event Response | Trigger event, SLA, SLA unit | **Event** (name), **Due within (days)**, Response action |
| Task Center tab | "Event Driven Assurance" | "**Event Response**" (same panel) |
| GRAC-ADMIN Raise Event preview | counted Assurance obligations | counts Event Response obligations |

## Control Management — migration 086

**Schema (`GRAC_New.obligation_event_response`)**

| Change | Detail |
| --- | --- |
| `event_type_id BIGINT NULL` | Added. FK `fk_cm_event_response_event_type` to `event_type_master`. Indexed by `ix_cm_event_response_event_type`. |
| `sla_days INT NULL` | Added. CHECK `ck_cm_event_response_sla_days`, range 0..3650. |
| `trigger_event` | Changed to nullable. It is no longer asked for. |
| `sla_value` / `sla_unit` | Retired. Values are converted to `sla_days`: Hours are rounded up to a day, Weeks ×7, Months ×30, Years ×365. Originals are kept in `migration_086_event_response_sla`. |

**Data**

Each active assurance spec with `trigger_mode = 'EventDriven'`, on an obligation typed Assurance, becomes an Event Response row:

| Event Response column | Taken from the assurance spec |
| --- | --- |
| `response_action` | `verification_method` |
| `event_type_id` | `event_type_id` |
| `sla_days` | `sla_days` |
| `remarks` | `remarks` |

For each converted obligation:

- The obligation is re-typed **EventResponse**.
- Its Assurance evidence links move to Event Response links.
- The assurance spec is set **Inactive**, not deleted, because past CM checklist items reference it.
- The conversion is logged in `migration_086_assurance_conversion`.

Two more data changes:

- Unclassified active assurance specs are stamped **Scheduled**, logged in `migration_086_assurance_mode`.
- The `EventDriven` assurance trigger-mode option is set Inactive.

**Rule**

`ck_cm_assurance_spec_scheduled_only` requires every active assurance spec to be Scheduled or unclassified. It is added WITH NOCHECK only if some spec could not be converted; report 086-b lists those.

**Procedures**

| Object | Change |
| --- | --- |
| `sp_cm_obligation_assurance_save` | Scheduled only. An event is refused with **52837**. Parameters are unchanged. |
| `sp_cm_obligation_event_response_save` | Adds `@p_event_type_id` and `@p_sla_days`. An active row needs an active leaf event under an active domain (**52845** / **52846**). Days must be 0..3650 (**52847**). The old `@p_sla_value` / `@p_sla_unit` are still accepted and converted. |
| `sp_cm_obligation_event_response_get` | Adds `EventTypeId`, `EventCode`, `EventName`, `EventDomainId`, `EventDomainCode`, `EventDomainName`, `EventSubjectEntity`, `SlaDays`. |
| `cm_manage_obligation_taxonomy` | The `obligation-event-response` branch forwards `eventTypeId` and `slaDays`. |
| `fn_cm_assurance_specs_for_event` | Reads Event Response rows. GRAC-ADMIN's Raise Event and the people auto-raise keep working unchanged. |

**API (Control Management)**

| Item | Change |
| --- | --- |
| `RegulatoryRepositoryService` | 52837 / 52845 / 52846 / 52847 are returned as readable messages. |
| `ObligationEventResponse` model | Adds `EventTypeId`, `EventName`, `EventDomainId`, `EventDomainName` and `SlaDays`. |

**Payload: `POST obligation-composite`**

When `obligationTypeCode` is `"EventResponse"`, `typedDetail` takes this shape:

```json
{ "eventTypeId": 7, "responseAction": "...", "slaDays": 7,
  "triggerEvent": null, "escalationPath": null }
```

When `obligationTypeCode` is `"Assurance"`:

```json
{ "verificationMethod": "...", "assuranceFrequencyId": 12,
  "scope": null, "assuranceParty": null }
```

`triggerMode`, `eventTypeId` and `slaDays` are no longer sent for an Assurance. If an older client sends an event, the request is refused with 52837.

**Files**

- `database/086_event_driven_to_event_response.sql`
- `database/086_event_driven_to_event_response_rollback.sql`
- `src/ControlManagement.Web/wwwroot/js/obligation-master-form.js`
- `src/ControlManagement.Web/wwwroot/js/raise-event-form.js`
- `src/ControlManagement.Api/Services/RegulatoryRepositoryService.cs`
- `src/ControlManagement.Api/Models/RepositoryModels.cs`

## Practice Management — migration 513

1. **Refreshes the views over the obligation detail.**
   - `vw_pm_obligation_typed_detail` builds its JSON with `er.*`, so it is refreshed to pick up the new columns.
   - Every view that depends on the two detail tables is refreshed too, one level up.
   - The organization copies and the Operationalize card then carry `event_type_id` and `sla_days`.
2. **Re-issues `vw_pm_event_driven_obligation` (from 394).**
   - Configure Checklists, the Checklists tab, coverage and the event raise all read this view.
   - A catalogue obligation is event driven when its organization copy carries an Event Response with an event, **or** a pre-086 Event Driven assurance spec.
   - The second case matters because organization copies change only when the organization approves the update in **Repository Updates** (rule since 395). Checklists therefore keep working before and after that approval.
   - Custom branches 2 and 3 are unchanged.
3. **Re-issues `sp_resolve_local_obligation_save` (412) and `sp_practice_obligation_save` (464).**
   - For an Event Response, the event is taken from the typed detail (`$[0].event_type_id`) when the caller does not pass `@event_type_id`. Any other type stores no event.
   - Before 513, no caller passed `@event_type_id`, so a custom obligation's event never reached the event-driven checklists. This fixes that.
4. **Data, backed up in `grac_practice.migration_513_obligation_backup`:**
   - Custom obligations typed Assurance with an Event Driven detail become Event Response. This covers practice level, instance level and the instance copies of a practice-level obligation. The detail is rebuilt in the Event Response shape and the `event_type_id` column is filled.
   - Adopted catalogue obligations that 086 converted are re-typed EventResponse on the instance.
   - Instance "Due within" overrides are converted to days.

**API (Practice Management)**

There are no endpoint or model changes:

- `GET /practice/api/workflow/resolve/obligation-types/EventResponse/fields` now also returns `event_type_id` and `sla_days`. It reads `sys.columns`.
- `POST /practice/api/workflow/resolve/local-obligation` and `POST /practice/api/practice-obligations` accept the same body as before. For `obligationTypeCode = "EventResponse"`, `typedDetailJson` carries `[{ "event_type_id": 7, "response_action": "...", "sla_days": 7 }]`.
- The adopt payload's `slaUnit` is always `"Days"` when a "Due within" override is entered.

**Files**

- `database/513_event_driven_to_event_response.sql`
- `database/513_event_driven_to_event_response_rollback.sql`
- `src/PracticeManagement.Web/wwwroot/js/Shared/obligation-form.js`
- `src/PracticeManagement.Web/Views/Practice/Partials/resolve-workspace.cshtml`
- `src/PracticeManagement.Web/Views/Practice/Partials/tasks.cshtml`
- `src/PracticeManagement.Web/wwwroot/js/scope-checklist-editor.js`
- `src/PracticeManagement.Web/Views/Practice/Partials/workflow-scope-mapping.cshtml`

## Run order (UAT)

1. Control Management: `086_event_driven_to_event_response.sql`. Read its reports:
   - **086-a**: what was converted.
   - **086-b**: what could not be converted.
   - **086-c**: Event Responses that still need an event picked.
   - **086-d**: approval bundles to send back.
2. Practice Management: `513_event_driven_to_event_response.sql`. The 513-b and 513-c checks should read PASS.
3. Rebuild and publish both modules (API and Web), then restart.
4. Let repository change detection run, or trigger it. Each subscribed organization then sees one "Changed" item per converted obligation in Repository Updates.

**Rollback:** run `513_…_rollback.sql` first, then `086_…_rollback.sql`.

## Test checklist

1. **GRAC-ADMIN → Obligation Master → Assurance:** there is no Trigger Mode, and Assurance Frequency is required.
2. **GRAC-ADMIN → Event Response:**
   1. Applies To = People → Event lists Onboarding / Offboarding.
   2. Applies To = Asset → Event lists Commissioning / Decommissioning.
   3. Due Within takes days.
   4. Save, then edit: People/Asset and the event come back pre-selected.
3. **A converted obligation** (086-a) opens as Event Response with its event and days.
4. **Practice Management → Event Profiles → Configure Checklists → Onboarding:**
   1. The converted obligation is still listed and still ticked.
   2. Onboarding an employee who matches the profile raises it.
5. **Practice View / Operationalize → add a custom Event Response** (People → Onboarding). It appears in Event Profiles → Checklists and can be ticked for a profile.
6. **Scheduled Assurance obligations** still generate their tasks as before.
7. **Repository Updates:** approve the change for a converted obligation. Configure Checklists still lists it, now from the Event Response copy.

## Known boundaries

- **Pending approval bundles:** a Control Management bundle submitted before 086 that sets an assurance to Event Driven fails on approval with 52837's message. Report 086-d lists them; send them back.
- **Old catalogue loaders:** 054 / 063 / 066 / 081 / 084, `Migration/063_iso27001_v13_assurance.sql`, and `tools/generate_iso27002_id_upsert.py` still describe the pre-086 shape. Re-running a loader stops on `ck_cm_assurance_spec_scheduled_only`. Regenerate before reuse.
- **`ObligationTypeDetail` page:** Control Management's older `ObligationTypeDetail` page (`obligation-type-detail-form.js`) has no menu link and no event picker. It was not changed, and saving an Event Response there is refused with 52845.
- **Old free-text Event Responses:** Event Responses written before 086 with only free text (report 086-c) are not raised by any event until someone picks one.
