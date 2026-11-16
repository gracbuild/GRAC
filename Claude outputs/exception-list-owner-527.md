## Exception Centre list: Owner column showed the requester (migration 527, 2026-11-10)

> "exception center le list lum athil click cheythu pokumbo kanunna page lum oru exception
> nte owner ne different ayi kanikunnundu."

**Cause.** The list's **Owner** column printed `requestedByName`, the person who raised the
request (`requested_by_employee_id`). Exception View and Exception Analysis show the exception's
**owner** (`owner_employee_id`, `sp_exception_request_get`.`OwnerName`). New Exception and
Analysis set the owner separately from the requester, so the two pages disagreed whenever the
owner was not the requester. The column change of 2026-09-22 used the requester because
`sp_exception_request_list` returned no owner. The Issues & Actions dashboard's **No owner** drill
(414) already filters on `owner_employee_id`, so it opened a list whose Owner cells were all
filled in.

**Change**

| Layer | File | What |
|---|---|---|
| SQL | `527_exception_list_owner.sql` (+ rollback = 498 body) | `sp_exception_request_list` also returns `OwnerEmployeeId` and `OwnerName`. Otherwise it is the 498 body verbatim: same rows, filters, order and paging. |
| Api | `ExceptionCentreModels.cs`, `ExceptionCentreService.ListAsync` | `ExceptionRequestRow` gains trailing optional `OwnerEmployeeId` and `OwnerName`, read tolerantly, so an Api deployed before 527 still lists. |
| API contract | `GET /api/practice/exception-centre` (list) | Each row now also carries `ownerEmployeeId` and `ownerName`. `requestedByName` is unchanged. |
| Web | `exception-centre.js`, `exception-centre.cshtml` | The Owner cell shows `ownerName`. An unassigned owner reads `--`, like Approved By. |

The Gap View exception card is unchanged: it labels the requester **Requested By**, which is correct.

**Deploy:** run 527, then deploy the Api and Web, then hard-refresh the browser. No Api restart is needed.
