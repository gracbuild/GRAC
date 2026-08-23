-- =====================================================================
-- 111 Data migration: org_assurance_gap* -> custom_gap*
--
-- Idempotent one-time copy that:
--   1. Populates a session-local mapping table of legacy gap_id ->
--      new custom_gap_id (keyed on gap_code so re-runs converge)
--   2. Inserts custom_gap rows for every active org_assurance_gap row
--      that hasn't been migrated yet (source_reference_type='OrgAssuranceGap',
--      source_reference_id=legacy id)
--   3. Copies actions, history, junctions -- de-duped by NOT EXISTS
--      guards on natural keys
--   4. Retargets observation.gap_id pointer to the new custom_gap_id
--      (backward-compat pointer used by legacy readers)
--
-- Safe to re-run. Never modifies custom_gap rows that already exist.
--
-- Rollback: 111_org_assurance_gap_data_migration_rollback.sql
--           (undoes copies -- destructive; only use for redo).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
   OR OBJECT_ID('grac_practice.custom_gap_observation','U') IS NULL
   OR OBJECT_ID('grac_practice.custom_gap_action','U') IS NULL
   OR OBJECT_ID('grac_practice.custom_gap_history','U') IS NULL
BEGIN
    RAISERROR('111: run 109 + 110 first.', 16, 1);
    SET NOEXEC ON;
END

-- If the legacy org_assurance_gap table was never created (fresh
-- install), migration 111 is a no-op.
IF OBJECT_ID('grac_practice.org_assurance_gap','U') IS NULL
BEGIN
    PRINT '111: org_assurance_gap not present -- migration skipped (fresh install).';
    RETURN;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Insert new custom_gap rows for every unmigrated legacy row.
--
-- Idempotency key: source_reference_type='OrgAssuranceGap',
--                  source_reference_id=legacy_id.
-- The unique code on custom_gap (gap_type_code + title has no
-- constraint; we use the source ref pair for de-dup).
-- =====================================================================
INSERT INTO grac_practice.custom_gap(
    organization_id, gap_type_code,
    gap_source_module_code, source_reference_type, source_reference_id,
    title, description, priority, severity_code, severity_name,
    owner_employee_id, owner_display_name, due_date, status,
    remarks, linked_task_id,
    execution_code, execution_name,
    entity_dimension_code, entity_dimension_name,
    entity_code, entity_name,
    observation_code, observation_title,
    assigned_reviewer_employee_id, assigned_reviewer_display_name,
    remediation_plan, resolution_notes, verification_notes, closure_notes,
    target_resolution_date,
    opened_dt, remediation_submitted_dt, verified_dt, closed_dt, reopened_dt,
    risk_id,
    entered_by, entered_dt, updated_by, updated_dt)
SELECT g.organization_id,
       N'Assurance',                                -- gap_type_code
       N'Assurance',                                -- gap_source_module_code
       N'OrgAssuranceGap',                          -- source_reference_type
       g.org_assurance_gap_id,                      -- source_reference_id
       g.gap_title, g.gap_description,
       -- Priority: map severity onto legacy 4-value scale.
       CASE g.severity_code
            WHEN N'Critical'      THEN N'Critical'
            WHEN N'High'          THEN N'High'
            WHEN N'Medium'        THEN N'Medium'
            WHEN N'Low'           THEN N'Low'
            WHEN N'Informational' THEN N'Low'
            ELSE N'Medium'
       END,
       g.severity_code, g.severity_name,
       g.assigned_owner_employee_id, g.assigned_owner_display_name,
       g.target_resolution_date,
       -- Direct status pass-through -- CHECK constraint now accepts
       -- the Assurance-lifecycle values (see migration 109).
       COALESCE(gsm.status_code, N'Open'),
       g.gap_code,                                  -- remarks -- store legacy code for traceability
       g.task_id,
       g.execution_code, g.execution_name,
       g.entity_dimension_code, g.entity_dimension_name,
       g.entity_code, g.entity_name,
       g.observation_code, g.observation_title,
       g.assigned_reviewer_employee_id, g.assigned_reviewer_display_name,
       g.remediation_plan, g.resolution_notes, g.verification_notes, g.closure_notes,
       g.target_resolution_date,
       ISNULL(g.opened_dt, g.entered_dt),
       g.remediation_submitted_dt, g.verified_dt, g.closed_dt, g.reopened_dt,
       g.risk_id,
       g.entered_by, g.entered_dt, g.updated_by, g.updated_dt
FROM grac_practice.org_assurance_gap g
LEFT JOIN grac_practice.org_assurance_gap_status_master gsm
       ON gsm.org_assurance_gap_status_id = g.gap_status_id
WHERE g.is_active = 1
  AND NOT EXISTS (
      SELECT 1 FROM grac_practice.custom_gap cg
      WHERE cg.source_reference_type = N'OrgAssuranceGap'
        AND cg.source_reference_id   = g.org_assurance_gap_id);

DECLARE @migrated_gaps INT = @@ROWCOUNT;
PRINT '111: ' + CAST(@migrated_gaps AS NVARCHAR(20)) + ' assurance gaps copied into custom_gap.';
GO

-- =====================================================================
-- 2. Build a mapping table (legacy_id -> new_custom_gap_id) that we
--    use for the remaining copies. Session-local -- discarded after.
-- =====================================================================
IF OBJECT_ID('tempdb..#gap_map') IS NOT NULL DROP TABLE #gap_map;
CREATE TABLE #gap_map(
    legacy_id    BIGINT NOT NULL PRIMARY KEY,
    custom_gap_id BIGINT NOT NULL
);
INSERT INTO #gap_map(legacy_id, custom_gap_id)
SELECT source_reference_id, custom_gap_id
FROM grac_practice.custom_gap
WHERE source_reference_type = N'OrgAssuranceGap'
  AND source_reference_id IS NOT NULL;
GO

-- =====================================================================
-- 3. Copy actions (idempotent on (custom_gap_id, action_order, title))
--    Older sources of truth used SCOPE_IDENTITY at insert time, so
--    exact one-to-one match is by (target gap, order, title). Legacy
--    action ids are not preserved.
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_gap_action','U') IS NOT NULL
BEGIN
    INSERT INTO grac_practice.custom_gap_action(
        custom_gap_id, organization_id,
        action_order, action_title, action_description,
        assigned_employee_id, assigned_display_name,
        due_date, completed_dt, action_status_code, task_id, notes,
        is_active, entered_by, entered_dt, updated_by, updated_dt)
    SELECT m.custom_gap_id, a.organization_id,
           a.action_order, a.action_title, a.action_description,
           a.assigned_employee_id, a.assigned_display_name,
           a.due_date, a.completed_dt, a.action_status_code, a.task_id, a.notes,
           a.is_active, a.entered_by, a.entered_dt, a.updated_by, a.updated_dt
    FROM grac_practice.org_assurance_gap_action a
    JOIN #gap_map m ON m.legacy_id = a.org_assurance_gap_id
    WHERE NOT EXISTS (
        SELECT 1 FROM grac_practice.custom_gap_action ca
        WHERE ca.custom_gap_id = m.custom_gap_id
          AND ca.action_order  = a.action_order
          AND ca.action_title  = a.action_title
          AND ca.entered_dt    = a.entered_dt);
    PRINT '111: ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' gap actions copied.';
END
GO

-- =====================================================================
-- 4. Copy history rows (idempotent on (custom_gap_id, entered_dt,
--    action_code)). We map from/to status IDs to their status_code
--    text so custom_gap_history stays FK-free of the retired status
--    master.
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_gap_history','U') IS NOT NULL
BEGIN
    INSERT INTO grac_practice.custom_gap_history(
        custom_gap_id, organization_id, action_code,
        from_status_code, to_status_code,
        reason_text, actor_display_name, entered_by, entered_dt)
    SELECT m.custom_gap_id, h.organization_id, h.action_code,
           fs.status_code, ts.status_code,
           h.reason_text, h.actor_display_name, h.entered_by, h.entered_dt
    FROM grac_practice.org_assurance_gap_history h
    JOIN #gap_map m ON m.legacy_id = h.org_assurance_gap_id
    LEFT JOIN grac_practice.org_assurance_gap_status_master fs ON fs.org_assurance_gap_status_id = h.from_status_id
    LEFT JOIN grac_practice.org_assurance_gap_status_master ts ON ts.org_assurance_gap_status_id = h.to_status_id
    WHERE NOT EXISTS (
        SELECT 1 FROM grac_practice.custom_gap_history ch
        WHERE ch.custom_gap_id = m.custom_gap_id
          AND ch.action_code   = h.action_code
          AND ch.entered_dt    = h.entered_dt
          AND ISNULL(ch.reason_text, N'') = ISNULL(h.reason_text, N''));
    PRINT '111: ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' gap history rows copied.';
END
GO

-- =====================================================================
-- 5. Copy junction rows (idempotent on active partial unique index
--    of (custom_gap_id, org_assurance_observation_id)).
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_gap_observation','U') IS NOT NULL
BEGIN
    INSERT INTO grac_practice.custom_gap_observation(
        custom_gap_id, org_assurance_observation_id, organization_id,
        link_source, linked_by, linked_dt,
        detach_by, detach_dt, detach_reason,
        notes, is_active)
    SELECT m.custom_gap_id, j.org_assurance_observation_id, j.organization_id,
           j.link_source, j.linked_by, j.linked_dt,
           j.detach_by, j.detach_dt, j.detach_reason,
           j.notes, j.is_active
    FROM grac_practice.org_assurance_gap_observation j
    JOIN #gap_map m ON m.legacy_id = j.org_assurance_gap_id
    WHERE NOT EXISTS (
        SELECT 1 FROM grac_practice.custom_gap_observation cj
        WHERE cj.custom_gap_id                = m.custom_gap_id
          AND cj.org_assurance_observation_id = j.org_assurance_observation_id
          AND cj.linked_dt                    = j.linked_dt
          AND ISNULL(cj.is_active, 0) = ISNULL(j.is_active, 0));
    PRINT '111: ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' junction rows copied.';
END
GO

-- =====================================================================
-- 6. Retarget observation.gap_id backward-compat pointer to the new
--    custom_gap_id so legacy readers keep working.
-- =====================================================================
UPDATE o
   SET o.gap_id     = m.custom_gap_id,
       o.updated_by = 'migration-111',
       o.updated_dt = SYSUTCDATETIME()
FROM grac_practice.org_assurance_observation o
JOIN #gap_map m ON m.legacy_id = o.gap_id;
PRINT '111: retargeted ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' observation.gap_id pointers.';
GO

COMMIT TRAN;
GO

IF OBJECT_ID('tempdb..#gap_map') IS NOT NULL DROP TABLE #gap_map;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'every active legacy gap has a custom_gap row' AS Check_,
       CASE WHEN NOT EXISTS (
           SELECT 1 FROM grac_practice.org_assurance_gap g
           WHERE g.is_active = 1
             AND NOT EXISTS (
                 SELECT 1 FROM grac_practice.custom_gap cg
                 WHERE cg.source_reference_type = N'OrgAssuranceGap'
                   AND cg.source_reference_id   = g.org_assurance_gap_id))
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '111 Data migration complete.';
GO

SET NOEXEC OFF;
GO
