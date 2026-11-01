# Source Statement classification is multi-select (Control Management 079 -> PM 478, 2026-10-18)

## The change in Control Management (079)
- `GRAC_New.framework_statement_classification_map` (statement -> statement
  classification, status Active / Inactive) is the only source of truth for a
  statement's classifications. A statement can have several.
- `GRAC_New.framework_statement.classification_id` is **retired**: it is still
  there with its old value, but nothing writes or reads it. A new statement has
  NULL; an edited one keeps a stale value.

## Impact check in Practice Management
| Area | Reads classification? | Result |
|---|---|---|
| Statement applicability (single and bulk), Organization Practices, Source Statements, Practice View, practice picker, Operationalize, reports | No. Every query names its columns. | No change |
| Custom Release authoring (Statement Classification) | Uses PM's own `grac_practice.custom_statement_classification` (369), never the Control Management master | No change |
| Repository copy model (391/392/395): `vw_repo_src_framework_statement` | **Yes.** The view is generated from every column of `grac_new.framework_statement` | **Fixed by 478** |

The view problems were:
1. It carried the retired `classification_id` into the statement's
   `content_hash` and into the snapshot Repository Updates compares. That value
   is frozen or NULL, not the real classification.
2. A classification change in Control Management only changes the junction
   table, so the hash did not change. Repository Updates never raised the
   change, and the organisation's copy never got it.
3. If Control Management ever drops the retired column, the view breaks, and
   every statement subscribe, copy and detection fails.

## The fix: `478_statement_classification_multi.sql`
1. `sp_repo_build_source_view` takes an optional `@exclude_columns` (comma
   list). Existing calls are unchanged.
2. `organization_framework_statements` gets two new columns:
   - `classification_ids`: the active ids as "1,5,9", ordered by id (Control
     Management's ClassificationIds format).
   - `classification_names`: "A, B", by display order then name (Control
     Management's Classification format).
3. `vw_repo_src_framework_statement` is rebuilt:
   - The retired `classification_id` is left out.
   - `classification_ids` and `classification_names` come from the junction
     (Active links only).
   - Both are part of the content hash. A classification change now raises a
     **Changed** source statement in Repository Updates. On approval it reaches
     the organisation's copy, and the Details diff shows the old and new
     classifications.
4. `sp_repository_copy_statements` (subscribe, refresh, approval) copies the two
   new columns.
5. Re-baseline, the 473 way, so the rebuilt hash does not flood Repository
   Updates:
   - Copies that were in step before the rebuild get their classifications and
     the new hash directly.
   - Copies that were already behind keep their old hash and arrive through the
     normal approval, with their classifications.
   - Pending statement changes get the rebuilt snapshot and hash, so detection
     does not raise a second one for the same statement.
6. Views and functions over `organization_framework_statements` are refreshed.

No API or UI change: no screen shows a repository statement's classification
today.

## Order / rollback
- Run Control Management 079 first (478 stops if the junction table is
  missing).
- Then run 478. It ends with PASS / FAIL checks and, per organisation, the
  number of copies, how many have a classification, and how many are behind.
- 391 rebuilds the statement view without classifications. If 391 is ever
  re-run, re-run 478 straight after it (noted in the 391 header).
- Rollback: `478_statement_classification_multi_rollback.sql`. It restores the
  391 / 395 bodies and the 391-shaped view (keeping in-step copies in step),
  then drops the two columns. It does not touch Control Management.

## Fix after the first DEMO run (2026-10-18)
- **What failed:** the first version built both classification lists in one
  SELECT. SQL Server only refuses that when the view is read (Msg 8711:
  "Multiple ordered aggregate functions in the same scope have mutually
  incompatible orderings"). The view was created but could not be read, so the
  re-baseline and the pending-change refresh did not run.
- **Fixes:**
  - The two lists are now built in two separate APPLYs.
  - The in-step capture reads the current view (skipped if it cannot be read)
    and also the 391-shaped view, which gives the hash every copy was stamped
    with before 478.
  - After the rebuild, the script reads the view once. If that fails, it puts
    the 391 shape back and stops with error 53990, so a broken view is never
    left in place.
- **To repair:** re-run `478_statement_classification_multi.sql` as a whole.
