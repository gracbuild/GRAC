# Location — address fields and Time Zone (migrations 360, 361, 381)

**Screen:** `locations` (Organization Setup → Locations)
**Backend routing:** `PracticeRepositoryService.cs` — `entityType == "locations"` routes GET
to `grac_practice.sp_org_location_repository_get` and SAVE to
`grac_practice.sp_org_location_repository_manage` (both 361), instead of the
monolith `pm_get_practice_repository` / `pm_manage_practice_repository` (002)
that still serves every other simple entity screen.
**Frontend:** `Web/wwwroot/js/practice.js` — the Location form/grid fields.

This doc did not exist before migration 381; it is written now to cover 360
and 361 together with the fix, since none of the three had one.

## Why a separate gateway shim, not the monolith

`pm_get_practice_repository` / `pm_manage_practice_repository` (002, last
re-issued whole by 300) are 2000+ line procedures with one `ELSE IF
@p_entity_type='...'` branch per simple entity. `CREATE OR ALTER PROCEDURE`
replaces a procedure's entire body, so adding a handful of columns to one
branch means re-issuing the whole monolith — expensive and easy to get
wrong. Migration 134 established the alternative for `users`/`teams`: pull
just that one entity into its own dedicated save/list procedures, plus a
thin "gateway shim" pair that keeps the monolith's fixed 7-parameter
contract (so `PracticeRepositoryService` can route to it by name) while
everything that ISN'T a save (`RETIRE`, and anything added later) is passed
straight back to the monolith unchanged. Migration 361 gives `locations` the
same treatment, for the same reason: it needed new columns the monolith's
fixed projection doesn't know about.

Objects (361):

| Object | Role |
| --- | --- |
| `sp_org_location_save` | SAVE logic, including the 8 new columns |
| `sp_org_location_list` | The read/grid query, including the 8 new columns |
| `sp_org_location_repository_manage` | Gateway shim: SAVE → `sp_org_location_save`; everything else → the monolith |
| `sp_org_location_repository_get` | Gateway shim: unpacks the payload and calls `sp_org_location_list` |
| `sp_get_time_zone_lookup` | Feeds the Time Zone dropdown (`/lookups`, key `time-zones`) from `GRAC_New.time_zone_master` |

## The new columns (360)

`organization_location` gained 7 nullable columns, safe for existing rows
(no default, so an existing Location simply shows the new fields blank —
"Not set" — exactly like every other unset field on this screen, until an
admin edits the record):

| Column | Notes |
| --- | --- |
| `time_zone_id` | Nullable FK into `GRAC_New.time_zone_master` — see "Cross-module dependency" below. |
| `address_line1`, `address_line2`, `city`, `state_province`, `country`, `postal_code` | Plain user-entered text. No Country/State/City master exists anywhere in this codebase (checked before adding these — see 360's own header), so these are unvalidated text, the same treatment as the pre-existing `region` field. |

## Cross-module dependency: `GRAC_New.time_zone_master`

`time_zone_master` is owned by ControlManagement (its own migrations
058/059), not PracticeManagement — this module only references it. Because
the two modules deploy independently, 360's own header set the rule
explicitly: *an unapplied migration on the other side should degrade a
feature here, never break the Location screen*.

361 implemented that correctly in two of its three new procs:

* `sp_org_location_save` — guards with `OBJECT_ID('GRAC_New.time_zone_master','U') IS NOT NULL` before validating a submitted `time_zone_id`.
* `sp_get_time_zone_lookup` — guards with `IF OBJECT_ID(...) IS NULL` and returns an empty dropdown instead of erroring.

`sp_org_location_list` — the proc that actually runs the instant the
Location tab opens — did not. It had an unconditional
`LEFT JOIN GRAC_New.time_zone_master tz ON tz.time_zone_id = l.time_zone_id`
with no guard. On a database where 360's columns exist but ControlManagement's
own migration hasn't reached `GRAC_New.time_zone_master` yet, that JOIN
throws SQL error 208 ("Invalid object name") the moment the grid loads.

That SQL error class (207/208 — a script/schema mismatch) is caught by
`PracticeRepositoryService.cs`'s generic exception handler and surfaced to
the user as:

> PracticeManagement database scripts are not aligned with the current
> database. Reference: `<correlation id>`

This is a generic message for a whole class of error (any 207/208 anywhere
in the app reads this way), not specific to Location — but this was the one
confirmed, reproducible cause of it on the Location screen.

## Fix — migration 381

Re-issues `sp_org_location_list` with the same
`OBJECT_ID('GRAC_New.time_zone_master','U')` guard the other two procs
already use: the existing query, byte-for-byte, when the table is reachable;
the same query minus the `tz` JOIN — `TimeZoneName` / `IanaTimeZone` /
`UtcOffset` / `TimeZone` come back blank instead of erroring — when it is
not. No frontend or API change: the grid already renders a blank field as
"Not set", and the Time Zone dropdown already handles an empty
`GRAC_New.time_zone_master` gracefully via `sp_get_time_zone_lookup`.

**What this fix does NOT cover.** The same user-facing message can also
appear for a completely different reason: if migration 360 itself was never
run on a given database, `organization_location` has no `time_zone_id` /
`address_line1` / etc. columns at all, and `sp_org_location_list`'s
reference to `l.time_zone_id` throws SQL error 207 ("Invalid column name")
regardless of this fix. That is a genuine "the scripts have not fully
deployed here yet" situation — the fix is to run 360 (then 361, then 381)
in order, not a further code change. Migration 381's own guard checks for
this and aborts with a clear message rather than silently doing nothing;
its verification block (`381-d`) also reports which state a given database
is actually in.

## Diagnosing which case a given database is in

Two read-only checks, safe to run directly:

```sql
-- NULL  => migration 360 has not run on this database (run 360, then 361, then 381)
SELECT COL_LENGTH('grac_practice.organization_location', 'time_zone_id');

-- NULL  => GRAC_New.time_zone_master is not reachable from this database
--          (ControlManagement's own 058/059 haven't landed here yet --
--          after 381, the Location tab still works, with a blank Time Zone)
SELECT OBJECT_ID('GRAC_New.time_zone_master', 'U');
```
