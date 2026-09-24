# Unifying Repository + Custom Statements for Practice Mapping — Migration Plan

**Status:** Proposal — for review before any code is written.
**Author:** drafted from the current `grac_practice` schema and the Practice Management API/Web code.
**Goal:** make a Practice mappable to *both* subscribed-repository statements and organization-defined **custom** statements, through **one** organization-scoped statement store that every practice-module query reads from — the architecture originally intended.

---

## 1. Why this is needed

On the **Add / Edit Practice → Source Statement Mapping** screen, only subscribed *repository* releases appear (PCI-DSS, RBI-IT-GOV, RBI-KYC-MD). The **Organization / Custom** release and its statements never load. This is deliberate today: `practice.js` filters out `SubscriptionType == "Custom"` because a custom statement cannot be persisted by the current mapping and would silently drop on save.

The real cause is that statements live in **three disconnected stores**, not one.

---

## 2. Current state (verified in code)

| Concern | Where it actually lives | Key |
|---|---|---|
| Repository statement **content** | `grac_new.source_structure_node` + grac_new framework statements (read **live**, not copied) | `framework_statement_id` |
| Per-org **overlay** for repository statements (applicability, owner, reason) | `grac_practice.organization_framework_statements` | `org_statement_id` (PK); unique on `(organization_id, release_id, framework_statement_id)` |
| **Custom** statements (content + applicability) | `grac_practice.custom_release_statement` (own hierarchy via `custom_release_source_structure`) | `custom_statement_id` (PK); **no** `framework_statement_id`, **no** `org_statement_id` |
| Practice ↔ statement mapping | `grac_practice.organization_statement_practice_mapping` | `org_statement_id` (FK → `organization_framework_statements`) **and** `framework_statement_id` |

Consequences:

- `organization_framework_statements` is only an **overlay** — it holds `organization_id, release_id, framework_statement_id, applicability_status_id, owner_id, applicability_reason, updated_by/dt` but **no statement text**. Rows are created lazily (when an applicability/owner decision is made), not bulk-copied at subscribe time.
- The mapping table is keyed on `org_statement_id` **and** `framework_statement_id`. A custom statement has neither, so it **cannot be represented** in the mapping — hence the UI filter, and hence the "would silently drop on save" risk.
- Reads that resolve a practice's statements go through the mapping + `organization_framework_statements` + grac_new. Custom statements are entirely **outside** this pipeline (Repository Subscriptions counts, practice detail, applicability rollups).

Files/objects that touch these stores (blast radius):

- **Mapping writes:** `PracticeRepositoryService.cs` (INSERT ~L2121, ~L2369) and the `MERGE` in `002_practice_management_procedures.sql` (~L4606).
- **Mapping reads:** `PracticeRepositoryService.cs` `QueryPracticeStatementMappingsAsync` (~L1269), `QueryReleaseStatementsAsync` (~L1102), plus procs in `002`, `284_risk_scope_practice_context`, `301_practice_view_text_and_frameworks`, `303_practice_detail_implementation_status`, `316_practice_detail_source_statements`.
- **Custom statement serving:** `QueryCustomReleaseStatementsAsync` (`custom-release-statements` entity).
- **Web:** `wwwroot/js/practice.js` statement-mapping picker (~L5100–5520), the `SubscriptionType == "Custom"` filter (~L5513).

---

## 3. Target design

One organization-scoped statement identity that is **source-agnostic**, so the mapping and every reader work the same whether a statement came from a repository subscription or was custom-authored.

Two ways to get there. **Option A** is what the original design intended; **Option B** is a lighter bridge that reaches the same *functional* result with far less risk. Recommendation below.

### Option A — Full unification (original intent)

Introduce a single canonical per-org statement table (extend `organization_framework_statements` into a true statement table, or add `organization_statement`) that holds **one row per statement in scope for the org**, for both sources, copying repository content in from grac_new on subscribe:

- Columns: `org_statement_id (PK)`, `organization_id`, `release_id`, `subscription_id`, `source_type ('Repository'|'Custom')`, `framework_statement_id (NULL for custom)`, `custom_statement_id (NULL for repository)`, `structure_node_ref`, `statement_reference`, `statement_title`, `statement_text`, `applicability_status_id`, `owner_id`, `applicability_reason`, `status`, audit columns.
- Populate on **subscribe** (copy grac_new content into the org table) and on **custom statement create**.
- Repoint **every** reader (release-statements, practice detail, applicability, Repository Subscriptions counts) to this table instead of grac_new + the overlay.

Pros: exactly the intended architecture; grac_new becomes a pure master, org data self-contained; custom and repository are truly uniform.
Cons: largest change; touches the subscribe pipeline and every statement read; needs a careful backfill for existing orgs; re-sync story when grac_new master content changes.

### Option B — Source-agnostic mapping bridge (recommended first step)

Keep repository content reading from grac_new as-is, but give **custom statements an `org_statement_id` identity** so the *one* mapping table serves both:

1. Extend `organization_framework_statements` to represent a custom statement too: make `framework_statement_id` **nullable**, add `source_type ('Repository'|'Custom')` and nullable `custom_statement_id`, and relax the unique constraint to cover both shapes.
2. When a custom statement is created (or first mapped), ensure a matching `organization_framework_statements` row exists (`source_type='Custom'`, `custom_statement_id` set, `framework_statement_id` NULL).
3. Change the mapping table so `framework_statement_id` is **nullable** and the true key is `org_statement_id` (which now exists for both sources). Existing rows are unaffected.
4. Repoint the readers that resolve statement *content* to `LEFT JOIN` grac_new **for repository rows** and `custom_release_statement` **for custom rows** (a `source_type` switch), instead of assuming grac_new.

Pros: one mapping path for both sources; no subscribe-time bulk copy; much smaller, reversible; unblocks the actual user need (map a practice to custom statements) quickly.
Cons: repository content still read live from grac_new (not the "copy everything in" ideal); a `source_type` branch in the content-resolving reads.

**Recommendation:** do **Option B first** (it delivers the mapping the user is asking for, safely), and treat **Option A** (full copy-in on subscribe) as a follow-on if/when you want grac_new fully decoupled. Both share the same end-state mapping shape, so B is not throwaway work — A builds on it.

---

## 4. Work breakdown (Option B)

**DB (new migrations, next free numbers ≥ 347):**

1. `alter organization_framework_statements`: `framework_statement_id` → NULL; add `source_type NOT NULL DEFAULT 'Repository'`, `custom_statement_id NULL` (FK → `custom_release_statement`); add filtered unique indexes — one for Repository `(organization_id, release_id, framework_statement_id)` where source_type='Repository', one for Custom `(organization_id, subscription_id, custom_statement_id)` where source_type='Custom'.
2. `alter organization_statement_practice_mapping`: `framework_statement_id` → NULL; keep `org_statement_id` as the real key; keep the existing unique `(organization_id, org_statement_id, org_practice_id)`.
3. New proc `sp_pm_ensure_org_statement_for_custom(@custom_statement_id)` — idempotently creates/returns the `org_statement_id` overlay row for a custom statement.
4. Backfill: create overlay rows for existing `custom_release_statement` rows so already-authored custom statements become mappable.

**API (`PracticeRepositoryService.cs`):**

5. Mapping **save** (INSERT paths ~L2121/L2369 and the `002` MERGE): accept `org_statement_id` for both sources; for custom ids, call the ensure-proc; drop the hard `framework_statement_id` requirement.
6. Mapping **seed/read** (`QueryPracticeStatementMappingsAsync`): return `source_type` alongside ids so the picker can render both.
7. A statements feed for the mapping tree that includes the custom release: either extend `release-statements` to accept the custom (negative) release id via a `source_type` branch, or have the Web layer merge `custom-release-statements` into the tree. (Web-merge is smaller; see below.)

**Web (`wwwroot/js/practice.js`):**

8. Remove the `SubscriptionType == "Custom"` filter (~L5513); load the custom release as its own branch, fetching its statements from `custom-release-statements` and tagging rows with a stable id namespace (e.g. `crs-<custom_statement_id>`) distinct from framework rows.
9. On **Map / Save**, send the custom statements as `org_statement_id`-bound entries (via the ensure step) so they persist instead of dropping.

**Downstream (decision-gated — see §6):**

10. If custom statements must roll up like framework statements (Repository Subscriptions "Statement Overview" counts, practice detail, applicability), repoint `301`, `303`, `316`, `284`, and the counts query to read content by `source_type`.

---

## 5. Migration ordering & safety

- New migrations numbered from **347** upward; each with a matching `_rollback.sql` (schema alters are reversible; the backfill is idempotent and re-runnable).
- All `ALTER`s are **additive/relaxing** (nullable, new columns, new filtered indexes) — existing repository mappings and reads are untouched, so this is safe to deploy incrementally.
- Ship DB + API + Web together; the Web filter stays until the save path is proven, so there is never a window where a user can map a custom statement that the backend drops.
- Verification: after deploy, map a practice to the 2 statements under the Organization / Test Custom Release, save, reopen Edit — both must appear in the Mapped pane; and the mapping row must carry `source_type='Custom'`, `org_statement_id` set, `framework_statement_id` NULL.

---

## 6. Open decisions to confirm before coding

1. **Option A vs B.** Recommend B first (unblocks mapping safely), A later for full grac_new decoupling. Confirm.
2. **Downstream rollup scope.** Should a practice's custom-statement mappings flow into the Repository Subscriptions "Statement Overview" counts, practice detail, and applicability — i.e. behave exactly like framework statements everywhere — or only be mappable/visible on the practice for now? This is the single biggest scope driver (item 10 above).
3. **Custom statement applicability.** `custom_release_statement` already has its own `applicability_status_id`. Do we keep applicability on the custom table, or move it onto the unified overlay row? (Affects where the applicability screens write.)
4. **Naming.** Extend `organization_framework_statements` in place, or introduce `organization_statement` and migrate? In-place is less churn; a rename reads cleaner long-term.

---

## 7. What I'd do on approval

On a "go" for **Option B**, I will write migrations `347+` (+rollbacks), the ensure-proc and backfill, the API save/seed changes, and the `practice.js` picker change — verified end-to-end against the Organization / Test Custom Release — and hold the downstream rollup (item 10) for a separate change gated on decision #2.
