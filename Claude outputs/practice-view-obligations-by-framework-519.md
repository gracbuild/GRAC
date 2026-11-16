
## Obligations of the selected framework only (migration 519, 2026-11-05)

> "practice nte view edukumbo framework select cheythu anu edukunnenkil aa framework nte
> applicable ayitulla obligations mathram list cheythal mathi. ipo vere framework nte
> obligations koodi kanikunnundu."

**Cause.** The Practices grid (`organization-requirements`) shows one framework release at
a time. A practice's repository requirement can still have obligations mapped under
several releases (`organization_obligation_requirement_map.release_id`), and
`sp_pm_view_obligations_typed` returned every one of them. The release selected on the
grid never reached the Practice View at all. Filtering in the browser would also have been
wrong: the proc returns **one** representative `FrameworkReleaseId` per obligation
(`TOP 1`), so an obligation shared by two frameworks could carry the other id and be
dropped.

**Change**

| Layer | File | What |
|---|---|---|
| SQL | `519_practice_view_obligations_by_framework.sql` (+ rollback = 494 body) | `sp_pm_view_obligations_typed` gains optional `@p_release_id`. `distinct_obligations` keeps only map rows of that release, and the representative-release `OUTER APPLY` picks that release, so the `FrameworkRelease` label matches. NULL = 494 behaviour, unchanged for Operationalize / Evidence Center. |
| Api | `PracticeRepositoryService.QueryObligationsTypedAsync` | Reads `releaseId` from the payload. Sends `@p_release_id` only when it is > 0 **and** the proc declares it. The new `ProcedureHasParameterAsync` checks this through the `ShimAvailability` cache, so SQL and Api can deploy in either order without the "too many arguments" failure (463). |
| Web | `practice.js`, Practice View action / row click | Passes the grid's selected framework (`#subscribedFrameworkFilter`) as `releaseId`. On a statement drill, where the filter is locked to "All", it passes the drill context's `releaseId`. The value goes inside the encrypted navigation code (`navigateWithContext`'s existing 10th argument), so no id appears in the URL. |
| Web | `practice-view.cshtml` | Reads `ctx.releaseId` and sends it as `releaseId` on `evidence-obligations-typed/query`. |

**API contract:** `POST /practice-management-gateway/evidence-obligations-typed/query` accepts
an optional `data.releaseId` (framework release id). When it is present and > 0, only
obligations mapped under that release are returned. The gateway passes it through
unchanged.

**Not filtered:**
* Practice-level (organization-defined, 307) obligations. They belong to the practice,
  not to a framework.
* Practice Instances.
* A custom release: its synthetic id is negative and has no repository mappings.

**Deploy:** run 519, then deploy Api and Web in any order, then hard-refresh the browser. After
a **rollback**, restart the Api, because the parameter probe is cached per process.
