# Evidence Automation (migration 530) -- plan Part A, Phase 1

Plan: *GRAC Evidence Automation & Storage Platform* v1.0 (21 Oct 2026).
Built 2026-11-12. Follows `evidence-center.md` (476 / 477 / 480) and
`task-recurring-evidence-482.md`.

An organization's own systems (a backup job, an access review, a scanner)
send evidence for an obligation **automatically**. GRAC stores what arrives
in the Evidence Center and puts it in front of a person for review. Nothing
is attached, completed or changed until that person accepts it.

## Decisions (sir, 2026-11-12)

| Topic | Decision |
|---|---|
| Scope | **Phase 1 only** -- intake, obligation binding, review, missing-evidence notices. **Phase 0 (moving file bytes to S3 / Azure Blob / MinIO) is not done**: received files are stored in SQL exactly like an upload today. |
| Channels | **Webhook / Intake API** and **File drop**. Intake email, the Zapier / Power Automate connector and pull connectors are later phases. The webhook is already what those platforms will call. |
| Auto-close | **Always propose.** Evidence is stored and its pass / fail recorded; a person accepts (attach) or rejects. No task, status or gap changes on its own. |
| Missing evidence | **Notice only** -- "not received" to the source owner and the obligation owner (My Notifications). No Gap Centre rows. |

## No change to existing modules

* **No existing table, procedure, view or function is altered.** 530 creates
  three new tables and new procedures only.
* It **calls** three existing procedures, unchanged and with their existing
  parameters: `sp_evidence_item_store` (476) to store a file,
  `sp_evidence_link_add` (476) and `sp_task_evidence_link_add` (482) to attach
  on Accept. An accepted item is therefore exactly what a manual upload +
  "Select from Evidence Center" produces: the Evidence Center, Operationalize,
  Task View, the completion gate and the expiry sweep see nothing new.
* Existing files touched are **additive only**: `Program.cs` (Api: one
  registration; Web: one rate-limit policy), `TaskNotificationWorker.cs` (two
  more passes, each in its own try/catch like the others), `appsettings.json`
  (new `EvidenceAutomation` section), `PracticeScreen.cs` / `Manage.cshtml`
  (screen registration), `my-notifications.cshtml` (a fourth section),
  `274_menu_master_seed.sql` (the menu row).
* With 530 not yet run, the new screen shows the procedure error, My
  Notifications hides the new section (404 / 2812), and the worker logs the
  sweep as skipped -- nothing else is affected.

## 1. Database (`530_evidence_automation_intake.sql`)

### Tables

| Table | What it holds |
|---|---|
| `evidence_automation_binding` | A **source**: one obligation (`practice_instance_obligation`), optionally the evidence row it answers (`practice_instance_evidence`), channel (Webhook / FileDrop), source system, control id in that system, independence (Self-attested / Independent -- plan 4.5), expected cadence (None / Daily / Weekly / Monthly / Quarterly / HalfYearly / Yearly) + grace days, validity days, evidence type, owner, classification, drop folder, **token hash** (SHA-256 only) + last 4 characters, status (Active / Paused / Retired), last received / period / result / refusal. |
| `evidence_automation_event` | Every evidence event received: channel, sender's event id (idempotency), period, result (Pass / Fail / Unknown), metric, summary, source system, file name, the Evidence Center **item and version** it was stored as, status (**Proposed** / Accepted / Rejected), the decision (target, link id, who, when, note) and the metadata received (never the bytes). |
| `evidence_automation_notice` | "Not received" notices: source, recipient, the period end evidence was expected for, read. One per source + recipient + period. |

### Functions

| Function | Purpose |
|---|---|
| `fn_pm_evidence_automation_can_manage` | Who may configure a source and decide its evidence: an organization admin, the source owner, or the obligation owner. |
| `fn_pm_evidence_automation_due` | Cadence arithmetic: the latest missed period end and the next period end. Period ends are `base + k x step`; evidence for an end E is due by E + grace days. Base = the latest period received, or the date the source became active (set again on Resume, so a pause never raises notices for the paused weeks). |

### Procedures

| Procedure | Purpose |
|---|---|
| `sp_evidence_automation_lookups` | Evidence types, employees. |
| `sp_evidence_automation_obligation_search` | Obligations the caller may bind (all for an admin, own otherwise; top 50). |
| `sp_evidence_automation_obligation_evidence` | Evidence rows of one obligation, with cadence (the 482 predicate). |
| `sp_evidence_automation_binding_list` | Sources grid: health (Overdue / Failing / Waiting / OnTrack / Paused / Retired), last received, missed / next period, waiting count, `TotalRows`. |
| `sp_evidence_automation_binding_get` | One source (never the token hash) + its 20 latest events. |
| `sp_evidence_automation_binding_save` | Create / edit. Validates the obligation, that the evidence row belongs to it, owner, cadence, folder (relative, plain characters, no `..`, not `_processed` / `_failed`, unique per organization). New source code `eab-<20 hex>`. |
| `sp_evidence_automation_binding_status` | Pause / Resume / Retire (Retire revokes the token). |
| `sp_evidence_automation_binding_token_set` | Stores a new token hash (Webhook only); the previous token stops working. |
| `sp_evidence_automation_binding_resolve_token` | Intake: the source a token hash belongs to. |
| `sp_evidence_automation_binding_error` | Intake: remembers why the last delivery was refused (shown on the screen). |
| `sp_evidence_automation_filedrop_bindings` | File-drop worker: folders to watch. |
| `sp_evidence_automation_ingest` | Stores the file through `sp_evidence_item_store` (title "<obligation> - automated <period>", type = source's or evidence row's, owner = source owner, valid from = period start, valid to = period end + validity days, tags `automated,<code>,<system>`, description with channel / result / period / independence) and records the event as **Proposed**. A repeated event id returns the first event. |
| `sp_evidence_automation_event_list` | Received evidence grid (status, result, source, search, paging). |
| `sp_evidence_automation_event_targets` | Where an item may be attached: the source's **one-time** evidence row (Operationalize), and the **open scheduled tasks** of the obligation (449), with `NotLinkableReason` (inactive, expired, not valid on the task period, already attached) and `Suggested` (task period inside the evidence period). |
| `sp_evidence_automation_event_accept` | Checks the rights and that the target is one offered, then calls `sp_evidence_link_add` / `sp_task_evidence_link_add` (or target None = keep in the Evidence Center only) and marks the event Accepted. The link procedure is called with the caller-is-admin flag set, because the visibility it would test was already established here (admin / source owner / obligation owner). |
| `sp_evidence_automation_event_reject` | Note required. Marks Rejected and retires the item it created when nothing links it. |
| `sp_evidence_automation_missing_sweep` | Raises the notices (application lock; idempotent). |
| `sp_evidence_automation_notice_list` / `_mark` | My Notifications. |

Every change writes `practice_audit_trace` (`evidence-automation-binding`:
CREATE, UPDATE, PAUSE, RESUME, RETIRE, TOKEN_ISSUE, TOKEN_ROTATE;
`evidence-automation-event`: RECEIVE, ACCEPT, REJECT; plus the existing
`evidence-item` / `evidence-link` rows the called procedures write).

Errors 58400-58425 are user-facing sentences.

### Menu
`evidence-automation` ("Evidence Automation", `Practice/Index/evidence-automation`,
display order 16, icon `plug`) under `nav-documents` (Policies & Documents),
next to Evidence Center. Full permissions for every active role of every
active organization, the 476 way; the procedures still decide which sources a
user manages. `274_menu_master_seed.sql` carries the row (Sections 1 and 2).

## 2. API

### Configuration and review -- `/api/practice/evidence-automation` (browser: `/practice/api/evidence-automation`)

Caller = `X-PM-Caller-Employee-Id` / `X-PM-Caller-Is-Admin`, stamped by the Web
tier from the session.

| Method | Route | Web permission | Body / result |
|---|---|---|---|
| GET | `lookups?organizationId` | VIEW | `{ evidenceTypes, employees, fileDropEnabled, maxFileBytes }` |
| GET | `obligations?organizationId&search` | VIEW | `{ data: [obligation] }` |
| GET | `obligations/{id}/evidence?organizationId` | VIEW | `{ data: [evidence row] }` |
| GET | `bindings?organizationId&search&channel&status&health&pageNumber&pageSize` | VIEW | `{ data, totalRows, page, pageSize, isAdmin }` |
| GET | `bindings/{id}?organizationId` | VIEW | `{ binding, recentEvents }`; 404 when not found / not managed |
| POST | `bindings` | ADD | save body -> `{ BindingId, BindingCode, DropFolder, Message, success }` |
| POST | `bindings/{id}/save` | EDIT | same |
| POST | `bindings/{id}/status` | EDIT (Pause / Resume), DELETE (Retire) | `{ organizationId, action }` |
| POST | `bindings/{id}/token` | EDIT | `{ organizationId }` -> `{ token, message }` -- **the only time the token is returned** |
| GET | `events?organizationId&bindingId&status&result&search&pageNumber&pageSize` | VIEW | `{ data, totalRows }` |
| GET | `events/{id}/targets?organizationId` | VIEW | `{ data: [target] }` |
| POST | `events/{id}/accept` | EDIT | `{ organizationId, targetType: InstanceEvidence / Task / None, targetId, note }` |
| POST | `events/{id}/reject` | EDIT | `{ organizationId, note }` |
| GET | `notices/me?organizationId&status&pageNumber&pageSize` | session | `{ data, totalRows, unreadCount }` |
| POST | `notices/me/mark` | session | `{ organizationId?, noticeId? }` -> `{ markedCount }` |

Save body: `{ organizationId, bindingName, practiceInstanceObligationId,
instanceEvidenceId, channel, sourceSystem, externalControlRef, independence,
expectedCadence, graceDays, validityDays, evidenceTypeId, ownerEmployeeId,
classification, dropFolder }`.

### Intake -- public: `POST {host}{PathBase}/intake/evidence`

Web: `EvidenceIntakeController` (no session; rate limit `evidence-intake`,
120 / minute per client address) forwards the body and the token unchanged to
Api `POST /api/practice/evidence-automation/intake`.

* **Credential:** `Authorization: Bearer <token>` (or `X-GRAC-Intake-Token`).
  The token (`grac_ei_` + 32 random bytes) identifies exactly one source and
  can do nothing but deliver evidence to it. Only its SHA-256 is stored.
* **JSON** (`application/json`):

  ```json
  {
    "eventId": "backup-2026-11-12",        // optional, idempotency
    "occurredAt": "2026-11-12T02:10:00Z",  // optional
    "periodFrom": "2026-11-12",            // optional, defaults to periodTo
    "periodTo": "2026-11-12",              // optional, defaults to occurredAt / today
    "result": "Pass",                      // Pass / Fail / Unknown (also passed, success, ok, failed, error)
    "metric": "0 failed jobs",             // optional
    "summary": "All 42 jobs completed",    // optional
    "sourceSystem": "Veeam",               // optional, defaults to the source's
    "file": { "name": "report.pdf", "contentType": "application/pdf", "contentBase64": "..." }
  }
  ```

* **multipart/form-data:** part `file` plus the same fields as form fields.
* **No file:** the event record itself (JSON) is stored as the evidence.
* **Responses:** 201 stored, 200 already received (same eventId), 400 invalid
  payload / period / result, 401 missing or unknown token, 409 source paused or
  retired, 413 file over 50 MB. A refusal for a known token is also written to
  the source (Last refused on the screen).

### File drop

`<EvidenceAutomation:FileDropRoot>/<organizationId>/<drop folder>/` on the API
server. Every `TaskNotification:EvidenceFileDropIntervalMinutes` (5) the worker
takes files that have not changed for `FileDropStableSeconds` (60), at most
`FileDropMaxFilesPerPass` (50) per source. An optional `<file>.json` sidecar
carries the intake fields. The event id defaults to name + size + time, so a
file stored but not moved is never stored twice. Stored files move to
`_processed/<yyyyMMdd>/`, refused ones to `_failed/` with `<file>.error.txt`.
**Nothing is deleted.** On SaaS the root is a share / SFTP landing folder
mounted on the API host; on-premise it is any local or UNC path.

## 3. UI

### Evidence Automation screen (`Partials/evidence-automation.cshtml`, `js/EvidenceAutomation/evidence-automation.js`)
Policies & Documents -> Evidence Automation. Evidence Center layout:
organization picker, `pm-tabs`, select filters, `pm-grid` pager, `pm-modal`
dialogs, `gracUi.confirm` for Retire / Reject / new token.

* **Received** (default; badge = waiting count): filters status (Waiting for
  review / Accepted / Rejected / All), result, source, search. **Review**
  shows source, obligation, period, result + metric, self-attested /
  independent, summary, the file (download through the Evidence Center), and
  the places it may be attached -- the matching task first -- or **Keep in
  the Evidence Center only**. Accept / Reject (reason required).
* **Sources**: filters channel, health, status, search; **New source**.
  Detail: settings, health, last refusal, **Connection** (webhook address +
  token status + **Issue token / Issue a new token** + a sample `curl`; or the
  drop folder), latest events, Edit / Pause / Resume / Retire, Show received.
  The token opens in a "copy it now" dialog and is never shown again.

### My Notifications (`my-notifications.cshtml`, `js/EvidenceAutomation/evidence-automation-notifications.js`)
Fourth section **Automated evidence notices**: source, obligation, why you
(source owner / obligation owner), missing for (period end), raised, mark read
/ mark all read; notes when evidence has arrived since. Hidden when the
sign-in has no employee or 530 is not deployed.

## 4. Configuration

Api `appsettings.json`:

```json
"EvidenceAutomation": {
  "FileDropRoot": "",               // empty = file drop off
  "FileDropStableSeconds": 60,
  "FileDropMaxFilesPerPass": 50,
  "MaxFileBytes": 52428800
}
```

`TaskNotification` (defaults shown, add only to change):
`EvidenceAutomationEnabled` true, `EvidenceAutomationIntervalMinutes` 60,
`EvidenceFileDropEnabled` true, `EvidenceFileDropIntervalMinutes` 5.
`EvidenceAutomationEnabled=false` leaves the sweep to SQL Agent:
`EXEC grac_practice.sp_evidence_automation_missing_sweep;`

The public intake address must be reachable by the customer's systems (SaaS:
the Web host; on-premise: the Web host on their network). Use HTTPS -- the
token travels in a header.

## 5. Deploy / rollback

1. `530_evidence_automation_intake.sql` (after 476, 477, 482, 449, 412). Ends
   with PASS / FAIL checks (tables, functions, procedures, the existing link
   procedures' parameters, cadence arithmetic, menu).
2. API + Web. Users sign out and in to see the menu (permissions are a login
   snapshot).

Rollback `530_evidence_automation_intake_rollback.sql`: drops the procedures
and functions, removes the menu row and permissions; drops the tables only if
nothing was ever received (otherwise keeps them as the record). Evidence Center
items created by received evidence stay (they are ordinary items). Remove the
`evidence-automation` rows from `274_menu_master_seed.sql`. Nothing that
existed before 530 needs restoring.

## 6. Test checklist

Automated:
* `database/test_530_evidence_automation.sql` (UAT / demo, SSMS) -- 21 checks
  through every procedure the API calls (create, token, ingest, idempotency,
  refusals, pause, folder validation, targets, accept, reject, overdue notice,
  rights, notices, existing procedures untouched); deletes everything it
  created at the end (marker `ZZ-530-TEST`).
* `tools/Test-EvidenceIntake.ps1 -BaseUrl <site> -Token <token>` -- six real
  HTTP calls to `/intake/evidence` (JSON, duplicate, no file, multipart, bad
  result, bad token).
* Done in development (2026-11-12): the cadence arithmetic ported and compared
  with a brute-force reference over 81,760 cases (0 mismatches); the screen
  scripts run in jsdom against a simulated API (41 checks).

Manual:

1. New source (Webhook) on an obligation with a recurring evidence row and an
   expected cadence; Issue token; copy.
2. `curl` JSON with a small base64 file -> 201; same eventId again -> 200
   `duplicate: true`; wrong token -> 401; Pause the source -> 409.
3. Received tab: the item waits; Evidence Center shows it (tag `automated`,
   owner = source owner, Used in = 0).
4. Review: the open scheduled task for that day is suggested; Accept -> Task
   View shows the evidence pinned to that version; the task's completion gate
   counts it.
5. A one-time evidence row source: Accept attaches it on Operationalize.
6. Reject with a reason -> the item is Retired in the Evidence Center.
7. File drop: set `FileDropRoot`, drop `report.pdf` (+ `report.pdf.json`) in
   `<root>/<orgId>/<folder>` -> after a minute and a pass it is received and
   moved to `_processed/`; a 0-byte or bad-sidecar file goes to `_failed/`.
8. Expected cadence Daily, grace 0, nothing sent for two days -> My
   Notifications shows "Not received" to the source owner and the obligation
   owner; the source shows Overdue.
9. Regression: manual upload on Operationalize, Complete Task with evidence,
   Evidence Center upload / new version / retire, expiry notices -- unchanged.

## Not done here (later phases of the plan)
Phase 0 storage externalization; intake email; Zapier / Make / Power Automate
/ n8n connector (it will call this same intake); first-party pull connectors;
on-premise collector agent; auto-satisfy for low-criticality obligations
(deliberately off -- always propose); auto-gap on missing evidence
(deliberately off -- notice only).

## Update 531 -- Intake email channel (`531_evidence_automation_email.sql`)

Request 2026-11-12: add email as a channel. Decisions (sir): **any mailbox over
IMAP**; each email source has an **allowed senders list**.

### How it works
* One intake mailbox per installation (a dedicated mailbox, e.g.
  `evidence@grac.in`), read over IMAP by a new `TaskNotificationWorker` pass
  every `TaskNotification:EvidenceEmailIntervalMinutes` (5).
* A source is reached at **`<local>+<source code>@<domain>`**
  (`evidence+eab-1a2b...@grac.in`, plus-addressing). Where the mail system drops
  the `+code`, the code in the subject works too: `[eab-1a2b...]`.
* The **From** address must be on the source's allowed list (full addresses or
  `@domain`, comma separated). Others are refused (58426) and shown on the
  source as "last refused". Mail whose `Authentication-Results` header says
  `dmarc=fail` or `spf=fail` is always refused; `RequireDmarcPass=true` also
  refuses mail without `dmarc=pass`.
* **Each attachment = one event** (id `mail:<Message-Id>[:n]`, so re-reading
  never duplicates). No attachment = the mail itself stored as `.eml`.
* **Result**: a `Result: Pass|Fail` line in the body; else the subject's words
  (`[Success]` / `[Failed]` ...); else Unknown. **Period**: `PeriodFrom:` /
  `PeriodTo:` (or `Period:`) lines as yyyy-mm-dd, else the mail date.
  `Metric:` line -> metric. Subject -> summary.
* Read mail is **moved**: stored -> `GRAC-Processed`, refused / unmatched ->
  `GRAC-Failed` (created if missing). Nothing is deleted.
* Then exactly as the other channels: Evidence Center item, **waiting for
  review**, accept / reject.

### Database (530 objects only)
* `evidence_automation_binding`: channel CHECK now allows `Email`; new
  `allowed_senders` (stored `,a@x.com,@y.org,`, compared with CHARINDEX -- never
  LIKE, since `_` / `%` are legal in addresses).
* Re-issued from the 530 bodies, additions only:
  `sp_evidence_automation_binding_save` (+ `@allowed_senders`, required and
  validated for Email -- 58427), `sp_evidence_automation_binding_get`
  (+ `AllowedSenders`), `sp_evidence_automation_ingest` (+ `@sender_address`;
  Email sources check the list -- 58426).
* New `sp_evidence_automation_email_bindings` (the worker's routing list).
* Rollback `531_..._rollback.sql`: retires Email sources, restores the 530
  bodies, drops the new procedure; restores the CHECK and drops the column only
  when no Email source exists.

### API
* `MailKit` 4.16.0 added (4.8.0 had GHSA-9j88-vvj5-vhgr, STARTTLS response injection; fixed in 4.16.0) to `PracticeManagement.Api.csproj` (.NET has no IMAP
  client). `IEvidenceAutomationService.RunEmailAsync`.
* Save body gains `allowedSenders`; it is bound only when the procedure declares
  it (`ProcParameterProbe`), so the Api runs against 530 without 531.
* `lookups` gains `emailEnabled`, `emailAddress`.

### Configuration (Api `appsettings.json`)
```json
"EvidenceAutomation": {
  "Email": {
    "Host": "imap.example.com", "Port": 993, "Security": "SslOnConnect",
    "Username": "evidence@example.com", "Password": "...",
    "Address": "evidence@example.com",
    "Folder": "INBOX", "ProcessedFolder": "GRAC-Processed", "FailedFolder": "GRAC-Failed",
    "MaxMessagesPerPass": 50, "RequireDmarcPass": false
  }
}
```
`Security`: SslOnConnect (993), StartTls (143), Auto. Host empty = email off.
Gmail / Google Workspace need an app password; Microsoft 365 no longer accepts
a plain IMAP password (OAuth only), so M365 mailboxes are not supported by this
channel.

### UI
Channel **Email** in the source form and the Sources filter; **Allowed
senders** field (required). The source shows its address
(`evidence+<code>@domain`), the accepted senders, the subject-code fallback and
the Result / PeriodTo / Metric line conventions.

### Tests
* Development: mail rules (result words, `Result:` line, +tag / subject routing,
  sender normalisation and matching incl. look-alike domain and `%` tricks) --
  20 / 20; screen with Email -- 49 / 49 (jsdom).
* UAT: `test_530_evidence_automation.sql` T22-T24 (bad list refused, allowed
  domain received, other sender refused).
* Manual: configure the mailbox, create an Email source, send a mail with an
  attachment from an allowed address to `evidence+<code>@...` -> it appears in
  Received within 5 minutes and moves to `GRAC-Processed`; send from another
  address -> `GRAC-Failed`, source shows "Last refused".
