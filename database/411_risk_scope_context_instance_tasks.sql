-- =====================================================================
-- 411 Risk Existing Controls: tasks per practice INSTANCE
--
-- WHAT AND WHY
-- ------------
-- Existing Controls (Risk Treatment grid + card popup, 410) lists one row
-- per mapped practice INSTANCE, but the tasks under each came from
-- sp_risk_scope_practice_context keyed by PRACTICE (linked_practice_id).
-- Two instances of one practice therefore showed the same tasks and the
-- same count. Tasks must follow the instance.
--
-- CHANGE: sp_risk_scope_practice_context result set 2 is now one row per
-- (task, mapped instance), with a new PracticeInstanceId column. A task
-- belongs to a mapped instance when
--   * practice_task.linked_instance_id = the instance, or
--   * it was raised from a gap on the instance -- gap source is the
--     instance, or a Custom Gap mapped to it (the rule
--     sp_risk_treatment_state uses, 387/388).
-- A mapping row that is still practice-level (no active instance) keeps
-- the old practice-wide rule.
--
-- The risk's OWN treatment tasks (raised by the treatment option, 263)
-- carry the practice but no instance, so they are no longer repeated on
-- every control row; they stay listed under "Treatment tasks" on the
-- same page.
--
-- Result set 1 is 393's, verbatim. The procedure is otherwise 393's body.
--
-- Re-runnable. ASCII only. Depends on 387 (risk_practice_map
-- .practice_instance_id), 388 (custom_gap_practice_map.practice_instance_id),
-- 393.
-- Rollback: 411_risk_scope_context_instance_tasks_rollback.sql (393 body).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_risk_scope_practice_context','P') IS NULL
BEGIN
    PRINT 'ABORT (411): sp_risk_scope_practice_context missing (run 284 / 393 first).';
    SET NOEXEC ON;
END
GO

-- The re-issued body reads these columns; guard them rather than let the
-- CREATE fail half way.
IF COL_LENGTH('grac_practice.risk_practice_map','practice_instance_id') IS NULL
   OR COL_LENGTH('grac_practice.custom_gap_practice_map','practice_instance_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_task','linked_instance_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_task','source_type_code') IS NULL
   OR COL_LENGTH('grac_practice.practice_task','source_record_id') IS NULL
   OR COL_LENGTH('grac_practice.custom_gap','source_reference_type') IS NULL
BEGIN
    PRINT 'ABORT (411): instance columns missing (run 387 and 388 first).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_risk_scope_practice_context (393 body; result set 2 per instance)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_scope_practice_context
    @organization_id   BIGINT,
    @risk_register_id  BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @risk_register_id IS NULL
        THROW 57101, 'sp_risk_scope_practice_context: organization_id and risk_register_id are required.', 1;

    -- The practices this risk has mapped. Sourced from the same table the
    -- scope panel already reads, so this procedure can never disagree
    -- with the list the user sees.
    DECLARE @practices TABLE(practice_id BIGINT PRIMARY KEY);

    -- risk_practice_map (261) carries no `status` column -- active is
    -- expressed through record_status_id, so filter on that.
    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master
          WHERE status_code = N'Active');

    INSERT INTO @practices(practice_id)
    SELECT DISTINCT rp.practice_id
    FROM   grac_practice.risk_practice_map rp
    WHERE  rp.risk_register_id = @risk_register_id
      AND  rp.organization_id  = @organization_id
      AND  (@active_rs IS NULL OR rp.record_status_id = @active_rs);

    -- ---- Result set 1: practice + provenance -------------------------
    ;WITH node_root AS (
        -- Walk each structure node up to its top-level parent. MAXRECURSION
        -- is bounded by the tree depth, not the row count.
        SELECT n.structure_node_id, n.structure_node_id AS root_id,
               n.parent_node_id, n.node_title, 0 AS lvl
        FROM   grac_practice.fn_org_source_structure_node(@organization_id) n
        WHERE  n.status = N'Active'
        UNION ALL
        SELECT c.structure_node_id, p.structure_node_id, p.parent_node_id, p.node_title, c.lvl + 1
        FROM   node_root c
        JOIN   grac_practice.fn_org_source_structure_node(@organization_id) p
               ON p.structure_node_id = c.parent_node_id
              AND p.status = N'Active'
    ),
    top_root AS (
        SELECT structure_node_id, root_id, node_title,
               ROW_NUMBER() OVER (PARTITION BY structure_node_id ORDER BY lvl DESC) AS rn
        FROM   node_root
    ),
    provenance AS (
        SELECT p.practice_id,
               MIN(oc.release_id)                  AS release_id,
               MIN(tr.root_id)                     AS structure_root_id,
               MIN(sp.framework_statement_id)      AS framework_statement_id
        FROM   @practices pr
        JOIN   grac_practice.practice p            ON p.practice_id = pr.practice_id
        JOIN   grac_practice.organization_requirement q
               ON q.organization_requirement_id = p.organization_requirement_id
        LEFT JOIN grac_practice.organization_control_requirement ocr
               ON ocr.organization_requirement_id = q.organization_requirement_id
              AND ocr.status = N'Active'
        LEFT JOIN grac_practice.organization_control oc
               ON oc.organization_control_id = ocr.organization_control_id
              AND oc.organization_id = @organization_id
              AND oc.status = N'Active'
        LEFT JOIN grac_practice.fn_org_source_control_map(@organization_id) scm
               ON scm.control_id = oc.repository_control_id AND scm.status = N'Active'
        LEFT JOIN top_root tr
               ON tr.structure_node_id = scm.structure_node_id AND tr.rn = 1
        -- Statement is optional: a control-reached practice with no
        -- statement mapping still belongs in the list.
        LEFT JOIN grac_practice.organization_statement_practice_mapping sp
               ON sp.org_practice_id = q.organization_requirement_id
              AND sp.organization_id = @organization_id
              AND sp.status = N'Active'
        GROUP BY p.practice_id
    )
    SELECT p.practice_id                       AS PracticeId,
           p.practice_code                     AS PracticeCode,
           p.practice_name                     AS PracticeName,
           COALESCE(a.artifact_code + N' ' + r.version_no,
                    a.artifact_name + N' ' + r.version_no,
                    r.version_no,
                    N'Organization Defined')   AS FrameworkName,
           rootn.node_title                    AS StructureRootName,
           fs.statement_reference              AS StatementReference,
           fs.statement_title                  AS StatementTitle,
           (SELECT COUNT(*) FROM grac_practice.practice_task t
             WHERE t.linked_practice_id = p.practice_id
               AND t.organization_id = @organization_id) AS TaskCount
    FROM   provenance pv
    JOIN   grac_practice.practice p ON p.practice_id = pv.practice_id
    LEFT JOIN grac_new.release  r ON r.release_id  = pv.release_id
    LEFT JOIN grac_new.artifact a ON a.artifact_id = r.artifact_id
    LEFT JOIN grac_practice.fn_org_source_structure_node(@organization_id) rootn ON rootn.structure_node_id = pv.structure_root_id
    LEFT JOIN grac_practice.fn_org_framework_statement(@organization_id) fs      ON fs.framework_statement_id = pv.framework_statement_id
    ORDER BY FrameworkName, StructureRootName, p.practice_code
    OPTION (MAXRECURSION 100);

    -- ---- Result set 2: tasks, per mapped practice INSTANCE (411) -------
    -- A task belongs to a mapped instance when it is linked to that
    -- instance (practice_task.linked_instance_id -- implementation and
    -- other instance tasks), or when it was raised from a gap on that
    -- instance: a gap whose source is the instance, or a Custom Gap
    -- mapped to it -- the same rule sp_risk_treatment_state (387/388)
    -- uses. Previously every task with linked_practice_id = the practice
    -- was listed, so two instances of one practice showed the same tasks.
    --
    -- A row still practice-level (no active instance) keeps the old
    -- practice-wide rule, with PracticeInstanceId NULL.
    DECLARE @map TABLE(practice_id BIGINT, practice_instance_id BIGINT NULL);
    INSERT INTO @map(practice_id, practice_instance_id)
    SELECT DISTINCT rp.practice_id, rp.practice_instance_id
    FROM   grac_practice.risk_practice_map rp
    WHERE  rp.risk_register_id = @risk_register_id
      AND  rp.organization_id  = @organization_id
      AND  (@active_rs IS NULL OR rp.record_status_id = @active_rs);

    SELECT t.task_id                  AS TaskId,
           m.practice_id              AS PracticeId,
           m.practice_instance_id     AS PracticeInstanceId,
           t.subject_title            AS Title,
           es.status_name             AS StatusName,
           t.priority                 AS Priority,
           t.sla_due_at               AS DueAt,
           emp.employee_name          AS AssignedTo
    FROM   @map m
    JOIN   grac_practice.practice_task t
           ON t.organization_id = @organization_id
          AND (
                -- practice-level row: the pre-411 rule
                (m.practice_instance_id IS NULL AND t.linked_practice_id = m.practice_id)
                -- instance row: linked to the instance ...
             OR (m.practice_instance_id IS NOT NULL AND t.linked_instance_id = m.practice_instance_id)
                -- ... or raised from a gap on the instance
             OR (m.practice_instance_id IS NOT NULL
                 AND t.source_type_code = N'Gap'
                 AND EXISTS (SELECT 1
                               FROM grac_practice.custom_gap g
                              WHERE g.custom_gap_id = t.source_record_id
                                AND (   (g.source_reference_type = N'PracticeInstance'
                                         AND g.source_reference_id = m.practice_instance_id)
                                     OR EXISTS (SELECT 1
                                                  FROM grac_practice.custom_gap_practice_map gm
                                                  JOIN grac_practice.record_status_master rs
                                                    ON rs.record_status_id = gm.record_status_id
                                                   AND rs.status_code = N'Active'
                                                 WHERE gm.custom_gap_id        = g.custom_gap_id
                                                   AND gm.practice_instance_id = m.practice_instance_id))))
              )
    LEFT JOIN grac_practice.entity_status_master es
           ON es.entity_status_id = t.current_status_id
    LEFT JOIN grac_practice.organization_employee emp
           ON emp.employee_id = t.assigned_to_employee_id
    ORDER BY m.practice_id, m.practice_instance_id, t.sla_due_at, t.task_id;
END
GO
PRINT '411: sp_risk_scope_practice_context now returns tasks per practice instance.';
GO

SELECT '411-a scope context returns PracticeInstanceId on tasks' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_scope_practice_context','P'))
                 LIKE '%AS PracticeInstanceId%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '411-b result set 1 intact (StatementReference)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_scope_practice_context','P'))
                 LIKE '%AS StatementReference%'
            THEN 'PASS' ELSE 'FAIL' END;
GO

SET NOEXEC OFF;
GO
PRINT 'Migration 411_risk_scope_context_instance_tasks applied. Restart the API.';
GO
