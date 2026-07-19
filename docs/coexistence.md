# Ownership coexistence — denormalised caches vs authoritative Assignments

**Charter reference:** §12.1.4 (Assignment state machine)
**Status:** placeholder for §12.1.4 PR — this file is opened by §12.1.1 / §12.1.6 to establish the rule up-front.

---

## The rule

- **Existing** `repository_subscription.owner_id` and `custom_release_statement.owner_id` (introduced in migration 032) remain as **denormalised caches**.
- **Authoritative** ownership will live on the new `ownership_assignment` row whose `current_status_id = Active` (introduced in §12.1.4).
- A DB procedure keeps the cache in sync when an Assignment reaches `Active` or leaves it (`Vacated`, `Reassigned`, `Declined`).

## Why keep the caches

Query paths (list screens, tree, dashboards) filter by owner heavily. Joining every list query through the Assignment history would be expensive. The cache is a materialised view of "the current Active Assignment".

## Consequences

- Read paths may continue to `WHERE owner_id = @employee_id`.
- Write paths must NOT `UPDATE owner_id = …` directly. They call `sp_assignment_nominate` / `sp_assignment_accept`, which updates the cache as a side effect.
- The cache can be rebuilt at any time from `ownership_assignment` with `sp_owner_cache_rebuild` (to be added in §12.1.4). That procedure is idempotent and safe to run under load.

## Detection

`sp_owner_cache_verify` (to be added in §12.1.4) reconciles cache vs source and raises an audit-trail row per mismatch. A drift finding opens a Rectification Task automatically.

## Related

- §12.1.6 permission guards evaluate against `organization_role.data_scope` — unchanged. RBAC does not read `owner_id` directly.
- The `handover` screen (§12.4.4) calls `sp_bulk_reassign`, which writes new Assignment rows and updates all affected caches transactionally.
