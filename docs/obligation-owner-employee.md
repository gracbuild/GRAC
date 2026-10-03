# Obligation Owner is an employee (Functional User) — migration 412

## Change

On **Operationalize** (the Resolve workspace obligation cards) and in the **organisation-defined obligation form** (instance level on Operationalize, practice level on Practice View), the obligation **Owner** used to be picked from Role Master and stored as the role *name* in `responsibility`.

It is now an **employee**, and only a **Functional User** (`organization_employee.is_functional_user = 1`, migration 341). This is the same rule and the same list (`owners` lookup, migration 342) that the Practice Instance Owner picker already uses.

## Data model

| Table | Column | Meaning |
| --- | --- | --- |
| `practice_instance_obligation` | `owner_employee_id` (new, FK `organization_employee`) | the owner employee |
| `practice_obligation` | `owner_employee_id` (new, FK) | the owner employee of a practice-level definition; fan-out copies it to every instance copy |
| both | `responsibility` (unchanged) | now holds the owner **employee's name**, written by the save procedures from the employee record |

Every reader that *shows* the owner already reads `responsibility`, so each one shows the employee with no further change:

- Practice View obligation cards
- View Obligations
- the assurance calendar / scheduler owner fallback
- the Resolve cards

## Write contract (all three save paths)

| `ownerEmployeeId` sent | Effect |
| --- | --- |
| absent / null | owner left as stored (older callers, or a save that did not touch Owner) |
| `0` | owner cleared (id and name) |
| `> 0` | must be an **Active Functional User of the obligation's organization**, otherwise refused. Error 52733 on Operationalize, 57214 at practice level. The name is taken from the employee. |

## "Subsequent queries"

Nothing in the database resolved an obligation's owner **role** to a person. Tasks, schedules and event checklists are assigned from other sources:

- the instance owner
- the schedule owner
- the Configure Checklists owner role

So no assignment query had to be repointed. Every place that displays the obligation owner now shows the employee, because it reads `responsibility`.

## Existing data

Rows saved before 412 keep their **role name** as text, with `owner_employee_id` NULL. Nothing guesses an employee from a role.

- Screens show the old value as a disabled "*<role>* (role - pick an employee)" placeholder in the Owner dropdown until someone picks an employee.
- 412's report lists how many such rows each organization has.

## Files

- **DB:** `database/412_obligation_owner_employee.sql` (+ `_rollback`, which restores the 394 / 396 / 340 bodies and drops the columns). It re-issues six procedures:
  - `sp_resolve_obligation_adopt`
  - `sp_resolve_obligation_list`
  - `sp_resolve_local_obligation_save`
  - `sp_practice_obligation_fan_out`
  - `sp_practice_obligation_save`
  - `sp_practice_obligation_list`
- **API:**
  - `OwnerEmployeeId` added to `ResolveObligationRow`, `ResolveObligationDecision`, `ResolveLocalObligationSaveRequest`, `PracticeObligationRow` and `PracticeObligationSaveRequest`. On a database without 412 it is read as optional.
  - `ResolveWorkspaceService` and `PracticeObligationService` pass the new value through.
- **UI:**
  - `resolve-workspace.cshtml`: the card Owner field becomes `ownerEmployeeId` (`obligationOwnerOptions`, `ownerPayload`), and the form gets `lookups.owners`.
  - `Shared/obligation-form.js`: the Owner select lists `lookups.owners` and sends `ownerEmployeeId`.
  - `practice-view.cshtml`: `pvLookups.owners` is filled from the `owners` feed, scoped to the organization.

Approval authority (hidden on the screens) stays a role.

## Run

Run 412 after 341, 340, 394 and 396. Restart the API, then hard-refresh the browser.
