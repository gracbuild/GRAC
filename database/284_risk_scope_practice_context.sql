-- =====================================================================
-- 284 Risk scope -- practice context + tasks ("Existing Controls")
--
-- WHY
--   The risk analysis page's scope panel listed a mapped practice by
--   name only. A reader could not tell which framework it came from, or
--   what is actually being done about it. This procedure returns, for
--   one risk, every mapped practice with its full provenance and the
--   tasks running under it.
--
-- RESULT SET 1 -- practices
--   Framework / Source structure root / Statement / Practice.
--
--   Framework + structure come from the SAME walk the Practice Picker
--   uses (282):
--       organization_control.release_id -> grac_new.release / artifact
--       source_control_map -> source_structure_node
--   "Source structure root" is the TOP of that node's branch, not the
--   node itself -- a leaf node name like "9.2.5" says nothing on its
--   own, whereas its root ("Access Control") is the heading a reader
--   recognises. The root is found by walking parent_node_id upward.
--
--   Statement comes from organization_statement_practice_mapping (031),
--   which is the only real statement -> practice edge in the schema.
--   It is LEFT joined: a practice reached through a control but not
--   mapped to a statement is still a legitimate mapped practice and must
--   still appear, with a NULL statement rather than being dropped.
--
--   A practice can sit under several statements or structure nodes --
--   genuinely true in the data. One row per practice is returned, taking
--   MIN() for provenance, because this panel is a summary and a practice
--   listed three times would read as three practices.
--
-- RESULT SET 2 -- tasks
--   grac_practice.practice_task rows whose linked_practice_id is one of
--   those practices, with the status name resolved from
--   entity_status_master. Grouped under their practice by the caller.
--
-- READ-ONLY. Nothing is written.
--
-- Re-runnable: yes (CREATE OR ALTER).
-- Rollback: database/284_risk_scope_practice_context_rollback.sql
-- DEPENDS ON: 001, 031, 037 (practice_task), 057, 261 (risk_practice_map), 282.
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.risk_practice_map','U') IS NULL
BEGIN
    PRINT 'ABORT (284): grac_practice.risk_practice_map missing. Run 261 first.';
    RAISERROR('284_risk_scope_practice_context: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

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
        FROM   grac_new.source_structure_node n
        WHERE  n.status = N'Active'
        UNION ALL
        SELECT c.structure_node_id, p.structure_node_id, p.parent_node_id, p.node_title, c.lvl + 1
        FROM   node_root c
        JOIN   grac_new.source_structure_node p
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
        LEFT JOIN grac_new.source_control_map scm
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
    LEFT JOIN grac_new.source_structure_node rootn ON rootn.structure_node_id = pv.structure_root_id
    LEFT JOIN grac_new.framework_statement fs      ON fs.framework_statement_id = pv.framework_statement_id
    ORDER BY FrameworkName, StructureRootName, p.practice_code
    OPTION (MAXRECURSION 100);

    -- ---- Result set 2: tasks under those practices -------------------
    SELECT t.task_id                  AS TaskId,
           t.linked_practice_id       AS PracticeId,
           t.subject_title            AS Title,
           es.status_name             AS StatusName,
           t.priority                 AS Priority,
           t.sla_due_at               AS DueAt,
           emp.employee_name          AS AssignedTo
    FROM   grac_practice.practice_task t
    JOIN   @practices pr ON pr.practice_id = t.linked_practice_id
    LEFT JOIN grac_practice.entity_status_master es
           ON es.entity_status_id = t.current_status_id
    LEFT JOIN grac_practice.organization_employee emp
           ON emp.employee_id = t.assigned_to_employee_id
    WHERE  t.organization_id = @organization_id
    ORDER BY t.linked_practice_id, t.sla_due_at, t.task_id;
END
GO

SELECT 'sp_risk_scope_practice_context' AS Proc_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_scope_practice_context','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '284 risk scope practice context complete.';
PRINT 'Smoke test:  EXEC grac_practice.sp_risk_scope_practice_context @organization_id = 4, @risk_register_id = <id>;';
GO
SET NOEXEC OFF;
GO
