# Pagination audit — every list in the module

Step 4 of the grid normalization. This is the **inventory**, not the fix:
what each unpaginated list does today, what its procedure supports, and
which of the three outcomes it needs. Nothing here has been changed yet.

Method: for each screen, the chain was followed end to end — the JS that
builds the query string, the Web controller that forwards it, the API
service that binds the parameters, and the procedure's own defaults.
Screen inventory came from `<tbody>` counts; five screens keep their JS
in `wwwroot/js/`, not in the `.cshtml`, and were read there.

---

## A. Silently truncated — rows the user cannot reach

These have **no pager**, and a procedure that pages anyway. The
procedure's default becomes an invisible ceiling: the grid looks
complete, and the rows past the cap simply are not drawn. This is a
correctness bug, not a missing convenience.

| Screen | Procedure | Ceiling | Returns `TotalRows`? |
|---|---|---|---|
| ~~**Operationalize**~~ **FIXED — migration 290** | `sp_resolve_instance_list` | ~~200~~ paged | Yes, as of 290 |
| ~~Exception Centre~~ **FIXED — UI only** | `sp_exception_request_list` | ~~25~~ paged | Yes |
| ~~Document Acknowledgements (batches)~~ **FIXED — UI only** | `sp_document_ack_list` | ~~25~~ paged | Yes |
| Document Acknowledgements (pending picker) | `sp_document_ack_pending_list` | 50 | Yes |
| Workflow Checklists | `sp_checklist_list` | 25 | No |
| Workflow Event Mappings | `sp_event_checklist_mapping_list` | 200 | No |
| SLA Configuration | `sp_org_sla_config_list` | 25 | No |

**Operationalize is the one to fix first.** It is a primary working
screen, and it hides the problem in a way the others do not — rather
than accepting the 25 default it asks for `&pageSize=200`:

```js
+ '&pageSize=200',          // resolve.cshtml:257
```

The procedure then clamps anything larger back down:

```sql
IF @page_size > 200 SET @page_size = 200;
```

So 200 is a hard ceiling on both sides. An organisation with 201
practice instances has one that no filter, sort, or scroll will reveal —
and because the list is a work queue, an invisible instance is an
instance nobody actions. `sp_resolve_instance_list` also returns no
`COUNT(*) OVER () AS TotalRows`, so even the count that would expose the
gap is not there. Fixing it needs a migration, not just UI.

Exception Centre, by contrast, sends no page parameters at all —

```js
const qs = new URLSearchParams({ organizationId: state.organizationId });
```

— the Web controller forwards the query string verbatim
(`ExceptionCentreController` line 73), the API service falls back to
`pageSize <= 0 ? 25 : pageSize`, and the procedure pages at 25. Its
procedure already returns `TotalRows`, so this one is **UI-only**: mount
a pager, send the page, read the total. No migration.

**SLA Configuration is moot** — migration 289 set that menu row
`Inactive`, so the screen is unreachable. Left in the table for
completeness; fix it only if the menu is ever restored.

## B. Bounded child panels — should not page

Each of these lists the children of one selected parent. A pager under a
list that will never have a second page is noise, and the same reasoning
already applied to the Risk Centre tiles.

| Screen | What it lists |
|---|---|
| `_related-tasks-panel` | tasks for one source item |
| `resolve-workspace` | obligations of one instance |
| `practice-view` | instances of one practice |
| `org-assurance-evidence-config` | evidence config of one definition |
| `org-assurance-scoring-config` | scoring config of one definition |
| `org-assurance-triggers` | triggers of one definition |
| `org-assurance-workflow-config` | workflow config of one definition |
| `workflow-stages` | stages of one workflow |
| `workflow-entity-types` | a small fixed master |
| `risk-acceptance-authority` | a settings matrix — `_get` / `_save`, not a list at all |

Three of these (`practice-view`, `resolve-workspace`,
`workflow-stages`) do send a large fixed `pageSize` — 200, and 1000 and
500 in `resolve-workspace`. Those are **not** ceilings in the Group A
sense, because the parent bounds the child set; they are belt-and-braces
against a runaway query. Worth leaving alone, but worth knowing they are
not evidence that the screen wants paging.

## C. Procedures with no paging at all

These return everything. Correct today, and a latent problem only if the
underlying table grows without bound. Paging any of them means a
migration first — `@page_number` / `@page_size` and
`COUNT(*) OVER () AS TotalRows` — then the UI.

| Procedure | Screen | Growth risk |
|---|---|---|
| `sp_event_checklist_inbox_list` | Event Inbox, `_event-assurance-panel` | **grows with events** — the real candidate |
| `sp_event_scope_mapping_list` | Workflow Scope Mapping | grows with obligations |
| `sp_event_obligation_mapping_list` | Workflow Scope Mapping | grows with obligations |
| `sp_document_ack_user_batches` | My Acknowledgements | grows with batches per user |
| `sp_entity_type_list` | Workflow Entity Types | fixed master |
| `sp_workflow_stage_list` | Workflow Stages | bounded by parent |
| `sp_risk_treatment_task_list` | Risk Centre tiles | bounded by design |

---

## Recommended order

1. ~~**Operationalize**~~ — **done.** Migration 290 added
   `COUNT(*) OVER () AS TotalRows` to `sp_resolve_instance_list`;
   `resolve.cshtml` now mounts `pm-grid` and the `pageSize=200` is gone.
   Details in `docs/practice-instance-form-slimming.md`, "What 290 adds".
2. ~~**Exception Centre and Document Acknowledgements**~~ — **done, and
   UI-only as predicted.** Both procedures already returned `TotalRows`,
   both API controllers already returned the whole result record, and
   both Web controllers already forwarded the query string verbatim — so
   nothing outside the browser changed. Each screen mounts `pm-grid`,
   sends the page, and resets to page 1 on a filter change (organisation,
   status and type on Exception Centre; organisation on Document
   Acknowledgements). Refresh deliberately does not reset.

   **Their query parameter is `page`, not `pageNumber`** — unlike
   Operationalize. Both spellings exist across the API and neither is
   wrong, but a grid that sends the other one is silently ignored and
   stays on page 1 forever, which looks exactly like a working pager.
   Check the controller signature before wiring the next screen.

   *Correction to an earlier draft of this audit:* **My Acknowledgements
   was listed here in error.** It runs `sp_document_ack_user_batches`,
   which has no `OFFSET` at all — the screen has never been truncated. It
   belongs in Group C, and is listed there now. The mistake came from
   matching the screen to `sp_document_ack_pending_list` by name; that
   procedure backs the *pending-documents picker* inside Document
   Acknowledgements' New Batch view, which is a different list on a
   different screen.
3. ~~**The generic grid family**~~ — **done, migration 300.** Not in the
   tables above, because it is not one screen: `Manage.cshtml` +
   `practice.js` back roughly thirty entity types, from Organizations and
   Users through Organization Controls, Practices and Practice Instances.

   It was a **Group A case in reverse**: the procedure paged correctly
   and the pager was the part that did not work. With no total,
   `renderPager` had to guess —

   ```js
   nextPage.disabled = state.records.length < state.pageSize;
   ```

   — which leaves Next enabled on a full last page, and the label could
   never say more than `Page 2`.

   Two things were fixed together. `300_generic_grid_total_rows.sql` adds
   `COUNT(*) OVER () AS TotalRows` to all thirty-seven paged branches of
   `dbo.pm_get_practice_repository` (and the five C# fallback queries that
   shadow them), and `Manage.cshtml` / `practice.js` drop the hand-wired
   pager for `pm-grid`.

   **300 also re-lands the paging itself.** Organization Controls was
   observed returning all 93 rows for a `pageSize=25` request, which the
   002 baseline cannot produce — the deployed procedure had drifted
   behind the repository. Because CREATE OR ALTER replaces a procedure
   whole, re-emitting it makes the deployed definition known rather than
   assumed. If a generic-grid screen still over-returns after 300 is
   applied, the fault is no longer in the procedure.

4. **Workflow Checklists, Workflow Event Mappings** — need `TotalRows`
   added before the UI can show a range or disable Next correctly.
5. **Source Statements** — both its lists (release summary and statement
   tree) are served by C# queries with no `OFFSET` at all
   (`QuerySubscribedFrameworksAsync`, `QueryReleaseStatementsAsync`). The
   summary hides it the way Operationalize used to, by asking for
   `pageSize: 500` and filtering in the browser. Group C in substance,
   though it sits behind the generic grid.
6. **Event Inbox** — the one Group C list with genuine growth. Needs
   paging designed into the procedure, so it is its own piece of work.

Group B needs nothing. SLA Configuration needs nothing while its menu
stays hidden.
