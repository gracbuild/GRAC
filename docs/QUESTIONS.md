# GRAC Workflow Layer — Open Questions Log

Format per charter §19. Entries move from `Awaiting decision` to `Resolved` with a date and rationale.

---

## Q001 — Migration numbering collision at `034_`
- Date: 2026-07-14
- Work item: §12.1.1 (and every subsequent Wave 1–5 migration)
- Question: Charter §3 says "you continue from `034_`" but this repo already has `034_simplified_role_model.sql`. Should new migrations start at `035_` and shift every charter-proposed number by +1?
- Options: 1) Start at `035_` (recommended). 2) Insert as `034a_…`. 3) Rename existing `034_` (violates §5).
- Recommended: Option 1 — cleanest, honours §5 non-negotiable.
- Awaiting decision from: product owner
- Resolution: **RESOLVED 2026-07-14 — Option 1 approved with TDD sign-off. Wave 1 begins at `035_state_machine_framework.sql`.**

## Q002 — Hangfire NuGet package
- Date: 2026-07-14
- Work item: §12.1.3 (Task engine) and every downstream scheduler
- Question: Charter §4.3 locks Hangfire as the scheduler; §5 requires stop-and-ask before introducing any new NuGet. Confirm addition of `Hangfire.AspNetCore` + `Hangfire.SqlServer`?
- Options: 1) Approve Hangfire. 2) Use `IHostedService` + `System.Threading.Channels`.
- Recommended: Option 1 — charter §4.3 locks this in.
- Awaiting decision from: product owner
- Resolution: **RESOLVED 2026-07-14 — Option 1 approved with TDD sign-off. Package additions will be raised in a dedicated PR that touches `.csproj` only.**

## Q003 — PDF/Excel report library
- Date: 2026-07-14
- Work item: §12.5.8 (Framework gap report)
- Question: New NuGets required for PDF + Excel generation. Which stack?
- Options: 1) DinkToPdf + ClosedXML. 2) QuestPDF + EPPlus. 3) Server-side headless Chromium.
- Recommended: Option 1 — permissive licensing, on-prem-friendly, no browser dependency.
- Awaiting decision from: product owner
- Resolution: **RESOLVED 2026-07-14 — Option 1 approved with TDD sign-off. Introduced only when Wave 5 §12.5.8 begins.**

## Q004 — audit_trail vs practice_audit_trace coexistence
- Date: 2026-07-14
- Work item: cross-cutting (charter §7)
- Question: Charter §7 refers to a canonical `audit_trail` table. Repo already has `grac_practice.practice_audit_trace` (immutable trigger). Coexist, replace, or alias?
- Options: 1) Coexist — new procs write to both during transition. 2) Replace `practice_audit_trace` (violates §5). 3) Alias `practice_audit_trace` as a view over `audit_trail`.
- Recommended: Option 1 — safest; deprecation is a follow-up.
- Awaiting decision from: product owner
- Resolution: **RESOLVED 2026-07-14 — Option 1 approved with TDD sign-off. §12.1.1 uses existing `practice_audit_trace` as the audit sink; canonical `audit_trail` deferred to migration `062_audit_trail.sql`.**

## Q005 — Working repo confirmation
- Date: 2026-07-14
- Work item: pre-flight
- Question: Charter §2 excludes `PracticeManagement` from edits; project instructions declare this folder the primary working copy.
- Options: 1) Trust project instructions. 2) Pause until confirmed.
- Recommended: Option 1.
- Awaiting decision from: product owner
- Resolution: **RESOLVED 2026-07-14 — Option 1 approved with TDD sign-off. This folder is the single source of truth per project instructions.**

## Q006 — Feature-flag scope (org vs org+user)
- Date: 2026-07-14
- Work item: cross-cutting §7 / §9
- Question: `feature_flag` scope — org-only or org+user override?
- Options: 1) Org-only. 2) Org + user override.
- Recommended: Option 1 — matches charter §7 wording ("org-scoped").
- Awaiting decision from: product owner
- Resolution: pending sign-off; not blocking §12.1.1 or §12.1.6 (no screens).

## Q007 — Gateway route style
- Date: 2026-07-14
- Work item: §12.1.6 onwards
- Question: Explicit per-feature routes in `PracticeManagementGatewayController` or extend `{entityType}` fan-out?
- Options: 1) Explicit routes. 2) Extend fan-out.
- Recommended: Option 1 — matches charter §7 API convention `/api/practice/{feature}/{action}`.
- Awaiting decision from: product owner
- Resolution: **RESOLVED 2026-07-14 — Option 1 approved with TDD sign-off.**

## Q008 — Default NA expiry ceiling
- Date: 2026-07-14
- Work item: §12.2.5
- Question: Maximum NA expiry — 6, 12, or per-org configurable?
- Options: 1) 6 months. 2) 12 months. 3) Configurable per org (default 12).
- Recommended: Option 3.
- Awaiting decision from: product owner
- Resolution: pending; not blocking §12.1.1 or §12.1.6.

## Q009 — Snapshot payload granularity
- Date: 2026-07-14
- Work item: §12.3.1
- Question: Snapshot the entire `practice_adoption` at Ticket generation, or only adapter-needed fields?
- Options: 1) Full JSON. 2) Selected fields.
- Recommended: Option 1 — matches charter §7 wording.
- Awaiting decision from: product owner
- Resolution: pending; not blocking Wave 1.

## Q010 — Escalation SLA multipliers
- Date: 2026-07-14
- Work item: §12.3.8
- Question: Hard-code 1.5×/2× or make configurable?
- Options: 1) Hard-coded. 2) Configurable per criticality (default 1.5×/2×).
- Recommended: Option 2.
- Awaiting decision from: product owner
- Resolution: pending; not blocking Wave 1.

## Q011 — Bulk reassignment audit granularity
- Date: 2026-07-14
- Work item: §12.4.4
- Question: One audit row per moved assignment or one summary row?
- Options: 1) One per assignment. 2) Summary + child.
- Recommended: Option 1.
- Awaiting decision from: product owner
- Resolution: pending; not blocking Wave 1.

## Q012 — Two-gate escape hatch
- Date: 2026-07-14
- Work item: §12.2.3
- Question: Provide `sp_two_gate_bypass_with_reason` for GRAC Admin?
- Options: 1) Yes, admin-only, fully audited. 2) No.
- Recommended: Option 1.
- Awaiting decision from: product owner
- Resolution: pending; not blocking Wave 1.

## Q013 — Implementation-status value set for Practice Instance
- Date: 2026-07-14
- Work item: Practice-Instance "Add Implementation Task" flow (adjacent to §12.2.2)
- Question: Requirement lists `Not Implemented / Implemented / Partially Implemented / N/A`; seeded values were `Not Started / In Progress / Implemented / Active / Inactive`. Add or replace?
- Options: 1) Add new values, migrate legacy at instance level, keep master rows. 2) Replace legacy. 3) Fork a new master.
- Recommended: Option 1.
- Awaiting decision from: product owner
- Resolution: **RESOLVED 2026-07-14 — Option 1 approved. Migration `043_practice_instance_impl_status.sql` seeds the three new values, backfills `practice_instance.implementation_status_id` (new FK column) from legacy NVARCHAR values, and preserves legacy master rows for backward compat with `PracticeRepositoryService.cs` insert paths.**

## Q014 — Remarks field on the Implementation Task
- Date: 2026-07-14
- Work item: Practice-Instance "Add Implementation Task" flow
- Question: New `remarks` column on `practice_task` or reuse existing `reason_text`?
- Options: 1) Reuse `reason_text` (label as "Remarks" in UI). 2) Add distinct `remarks NVARCHAR(2000)`.
- Recommended: Option 1.
- Awaiting decision from: product owner
- Resolution: **RESOLVED 2026-07-14 — Option 1 approved. Modal labels the field "Remarks"; stored in `practice_task.reason_text` (1000 chars).**

## Q015 — Where the "Add Implementation Task" action lives
- Date: 2026-07-14
- Work item: Practice-Instance "Add Implementation Task" flow
- Question: Row-level 3-dot action, header button, or both?
- Options: 1) Row-level only. 2) Header only. 3) Both.
- Recommended: Option 3.
- Awaiting decision from: product owner
- Resolution: **RESOLVED 2026-07-14 — Option 3 approved. `practice-instance-implementation-task.js` injects a header button unconditionally and a best-effort inline link on rows whose `ImplementationStatus` text matches `Not Implemented`.**
