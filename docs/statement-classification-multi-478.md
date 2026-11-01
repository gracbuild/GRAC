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
     (Active links only), through `fn_repo_statement_classification_ids` /
     `_names`.
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
- **Second run:** the same error. Two separate APPLYs were not enough,
  because the optimizer merged both ordered aggregates into one aggregation.
- **Third run:** the development database still failed, but UAT did not. The
  view could be read on its own, but the optimizer merges an ordered
  `STRING_AGG` in a view into the query that reads it. On development, the
  pending-change UPDATE and the GROUP BY verification then failed with
  Msg 8711. Whether it fails depends on the plan (data, statistics,
  compatibility level).
- **Fixes:**
  - Both lists now use `FOR XML PATH` concatenation, so the view contains no
    ordered aggregate at all. The text is unchanged: ids "1,5,9" by id, names
    "A, B" by display order then name, NULL when a statement has none.
  - The post-rebuild check also runs a join and GROUP BY over the view (the
    shape that failed).
  - The in-step capture reads the current view (skipped if it cannot be read)
    and also the 391-shaped view, which gives the hash every copy was stamped
    with before 478.
  - After the rebuild, the script reads the whole view (every row, every
    column, through CHECKSUM_AGG). If that fails, it puts
    the 391 shape back and stops with error 53990, so a broken view is never
    left in place.
- **Fourth run:** development still failed (UAT fine), now in the
  pending-change refresh and the per-organisation summary. `FOR XML PATH`
  with `ORDER BY` is also an ordered concatenation, and the optimizer still
  merged it into the bigger query (an `UPDATE ... FROM` with `FOR JSON`, a
  `GROUP BY`).
- **Fix (fourth run):**
  - The lists now come from two scalar functions,
    `grac_practice.fn_repo_statement_classification_ids` and
    `fn_repo_statement_classification_names`, created `WITH INLINE = OFF`
    on SQL Server 2019 and later. A function that is not inlined keeps its
    ordering in its own scope, so the view has none. The text is the same.
  - After the rebuild, the script reads the view once into a temp table
    (`#pm478_src`). The re-baseline, the pending-change refresh and the
    per-organisation summary all work from that copy, never from the view
    inside a bigger query. The in-step capture reads the old view the same
    way.
  - The post-rebuild check also runs a `FOR JSON` over the view (the shape
    Repository Updates detection uses).
  - The rollback reads the view into a temp table too, and drops the two
    functions.
- **Fifth run, the real cause:** the development view was still the
  first run's version (one APPLY with two ordered `STRING_AGG`s). SQL Server
  compiles a whole batch before running it. Section 3 + 5 named the view in
  plain statements, so the batch was compiled against that broken view, hit
  Msg 8711 while compiling, and nothing in it ran. The view was never
  replaced, and the summary in section 7 failed the same way. UAT's first run
  had left a view its plans could compile, so it was not affected.
- **Fix (fifth run):** section 3 + 5 is now four batches (3a to 3d):
  - 3a reads the current view only through dynamic SQL, then rebuilds it the
    391 way.
  - 3b captures the in-step copies, compiled against the rebuilt view.
  - 3c builds the classification view and checks it.
  - 3d re-baselines, and only runs when 3c succeeded.
  - The temp tables belong to the session, so they carry across the batches.
  - The rollback also starts a new batch after its view rebuild.
- **To repair:** re-run `478_statement_classification_multi.sql` as a whole.
