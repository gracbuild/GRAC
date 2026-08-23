# Practice View page — developer notes

**Page:** `Web/Views/Practice/Partials/practice-view.cshtml` (full page, not a modal)
**Reached from:** Organization Practices (`organization-requirements`) and the older `practices` grid → 3-dot menu → **View**
**API:** `GET /api/practice/workflow/practice-configure/detail`
**Backend:** `Api/Controllers/PracticeConfigureController.GetPractice`, `Api/Services/PracticeConfigureService.GetPracticeDetailAsync`
**Procedure:** `grac_practice.sp_practice_detail_get` (migration 139, amended by 218)

---

## Two identifiers, one page

The Organization Practices grid is **one row per `organization_requirement`**. Its
`PracticeId` column comes from an `OUTER APPLY` over `grac_practice.practice`, so it is
**NULL whenever no practice row exists yet**. `practice.js` therefore navigates on
whichever id the row actually carries:

```js
const filterType = practiceId ? "Practice" : "OrganizationRequirement";
```

and the page forwards whichever it received. `sp_practice_detail_get` accepts both.

## Why a requirement can have no practice row

`grac_practice.practice` rows are materialised lazily, not at requirement creation:

| Trigger | Where |
| --- | --- |
| Saving the requirement (Mark Applicability included) | `pm_manage_practice_repository`, `organization-requirements` branch |
| Configuring an instance | same proc, `practice-instances` branch |
| Adding a practice by hand | same proc, `practices` branch |

A requirement created by the migration-010 sync from applicable controls and never
touched since has **no practice row**. Those untouched rows are exactly the ones still
sitting at applicability `Not Updated` — which is why the symptom looked like "View is
broken for practices that aren't marked Applicable".

Before migration 218 that state produced:

```
sp_practice_detail_get -> THROW 52500
  -> GetPracticeDetailAsync returns Success = false
  -> GetPractice returns NotFound()
  -> "This practice could not be loaded (HTTP 404)."
```

## The 218 fallback

When the requirement resolves to no practice, the procedure now answers from
`grac_practice.organization_requirement` instead of throwing. Field mapping:

| Response column | Practice path | Fallback path |
| --- | --- | --- |
| `PracticeId` | `p.practice_id` | **`0`** |
| `PracticeCode` / `PracticeName` | `p.practice_code` / `p.practice_name` | `q.requirement_code` / `q.requirement_name` |
| `Description` | `p.description` | `q.requirement_statement` |
| `OriginType` | `p.origin_type` | `q.origin_type` |
| `PracticeOwner` / `PracticeOwnerId` | `p.practice_owner*` | **`NULL`** (owner is a practice column) |
| `ApplicabilityStatus` | `p.applicability_status` | `COALESCE(aps.status_name, q.applicability_status)` |
| `ExclusionJustification` | `p.exclusion_justification` | `q.exclusion_justification` |
| `Status` | `p.status` | `COALESCE(rs.status_name, q.status)` |
| `RequirementCode` / `RequirementName` | joined `req.*` | `q.requirement_code` / `q.requirement_name` |
| `ActiveInstanceCount` | live count | **`0`** |

Two things to hold on to:

- **`PracticeId` is `0`, not `NULL`.** `PracticeConfigureService` reads it with
  `Convert.ToInt64`, which throws on `DBNull`. `0` is also what the page tests.
- **The two SELECTs must keep identical column names and types.** The reader binds by
  name; a column present in one branch and missing from the other is a runtime
  `IndexOutOfRangeException`, not a compile error.

The procedure does **not** materialise a practice row. It is a read path — a GET that
writes would create practice rows for Not Applicable requirements as a side effect of
somebody merely looking at one.

New error code: `52512` — requirement not found for this organization. (`52500` and
`52501` keep their existing meanings for the practice path; the 139 header reserves
52500–52512 for this file's procedures.)

## Configure button

`practice-view.cshtml` only shows Configure when `practiceId > 0`:

```js
document.getElementById('pvConfigureBtn').hidden = !(practiceId > 0);
```

Configure creates one `practice_instance` per selected team against a practice id
(`sp_practice_instance_configure`, which throws 52505 without a valid practice). With no
practice row there is nothing to hang instances on, and configuring instances for a
requirement nobody has marked Applicable would be wrong regardless. The page still
renders the full detail panel read-only.

## Obligations panel

This panel is why the **View Obligations** entry was removed from the Organization
Practices 3-dot menu. It opened a dialog showing the same obligations the View page
renders inline, so the menu carried two routes to one thing. Removed from
`actionDefinitions`, from the per-applicability override in `allowedActions`, and from
the action dispatcher, along with its now-unreferenced label and icon entries.

`showEvidenceObligations()` itself is **not** dead — the dialog is still opened from the
Practice Instance evidence section (`#viewEvidenceObligations`) and re-entered internally
when the user switches practice inside it.

Otherwise unaffected by all of the above — `loadObligations()` already sends
`organizationRequirementId` alongside `practiceId`, and
`sp_pm_view_obligations_typed` (migration 122) accepts either. A requirement with no
practice row still shows its published obligations.

## Rollback note

`218_practice_detail_requirement_fallback_rollback.sql` restores the 139 procedure body.
The Web change is safe to leave in place: with the fallback gone, `PracticeId` is always
a real id, so `!(practiceId > 0)` never hides anything it did not hide before.
