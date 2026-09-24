-- =====================================================================
-- Diagnostic: Gap Analysis saved, but no Task and no Risk appeared
--
-- WHY IT IS SILENT
--   sp_custom_gap_analysis_save spawns the downstream artefacts through
--   three auto-triggers, and ALL THREE are best-effort:
--
--       IF @remediation_possible = 'Y'
--       BEGIN
--           BEGIN TRY  EXEC grac_practice.sp_custom_gap_task_create ...
--           END TRY
--           BEGIN CATCH
--               PRINT CONCAT(N'... task auto-create warning: ', ERROR_MESSAGE());
--           END CATCH
--       END
--
--   The CATCH only PRINTs. A PRINT never reaches the API, so the save
--   reports success and the UI says it saved -- while the Task and the
--   Risk were never created. That is deliberate (analysis must stay
--   durable even if a downstream proc fails) but it means a missing or
--   failing procedure is completely invisible from the screen.
--
--   So "it worked in DEV, first run in UAT" almost always means UAT is
--   missing one of the objects below, and the CATCH ate the 2812
--   "Could not find stored procedure".
--
-- Section 1 is the answer for a fresh environment: any FAIL row is a
-- migration that has not been run.
-- Section 4 REPRODUCES the failure and shows the real error text that
-- the CATCH is hiding.
--
-- READ-ONLY except section 4, which is opt-in and writes only what a
-- normal save would. Sections 1-3 write nothing.
-- =====================================================================
SET NOCOUNT ON;

PRINT '===== 1. Are all the procedures in the chain deployed? =====';
SELECT v.ObjectName,
       v.NeededBy,
       CASE WHEN OBJECT_ID(v.ObjectName, 'P') IS NOT NULL THEN 'PASS' ELSE 'FAIL -- NOT DEPLOYED' END AS Result
FROM (VALUES
    ('grac_practice.sp_custom_gap_analysis_save',  'the analysis save itself (latest: 252)'),
    ('grac_practice.sp_custom_gap_analysis_get',   'the Analysis tab read (latest: 252)'),
    ('grac_practice.sp_custom_gap_task_create',    'Task trigger, remediation_possible = Y (latest: 253)'),
    ('grac_practice.sp_risk_candidate_create',     'Risk trigger, business_risk_present = Y (latest: 207)'),
    ('grac_practice.sp_exception_request_create',  'Exception trigger, remediation_possible = N (latest: 258)'),
    ('grac_practice.sp_custom_gap_apply_sla',      'SLA match on save (184)')
) AS v(ObjectName, NeededBy)
ORDER BY Result DESC, v.ObjectName;

PRINT '';
PRINT '===== 2. Does the save procedure actually CARRY the triggers? =====';
PRINT '      A database stuck on migration 249 has a save proc rebuilt from';
PRINT '      157 -- the pre-decision-model body -- with the triggers and the';
PRINT '      two decision parameters silently dropped. 252 restores them.';
SELECT CASE WHEN m.definition LIKE '%@remediation_possible%'
            THEN 'PASS' ELSE 'FAIL -- run 252' END AS AcceptsRemediationPossible,
       CASE WHEN m.definition LIKE '%@business_risk_present%'
            THEN 'PASS' ELSE 'FAIL -- run 252' END AS AcceptsBusinessRiskPresent,
       CASE WHEN m.definition LIKE '%sp_custom_gap_task_create%'
            THEN 'PASS' ELSE 'FAIL -- run 174/252' END AS HasTaskTrigger,
       CASE WHEN m.definition LIKE '%sp_risk_candidate_create%'
            THEN 'PASS' ELSE 'FAIL -- run 172/252' END AS HasRiskTrigger,
       CASE WHEN m.definition LIKE '%sp_exception_request_create%'
            THEN 'PASS' ELSE 'FAIL -- run 174/252' END AS HasExceptionTrigger
FROM   sys.sql_modules m
WHERE  m.object_id = OBJECT_ID('grac_practice.sp_custom_gap_analysis_save');

PRINT '';
PRINT '===== 2b. Master data the two triggers need =====';
PRINT '      Both procedures resolve a code from a master table and THROW';
PRINT '      when it is absent or inactive -- and the CATCH in the save';
PRINT '      proc then hides it. This is the usual reason a chain that is';
PRINT '      fully deployed still produces nothing on a fresh environment.';

-- The risk trigger derives source_type_code = N'Gap' from the gap and
-- THROWs 56202 "unknown or inactive source_type_code" if that row is not
-- in risk_source_master and active. Seeded by migration 204.
-- The predicate is sp_risk_candidate_create's own, character for character:
-- status = N'Active'. This table has NO is_active column -- it carries
-- status NVARCHAR(20) (204_risk_scoring_masters.sql).
SELECT 'risk_source_master has an Active ''Gap'' row' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.risk_source_master
                          WHERE source_type_code = N'Gap' AND status = N'Active')
            THEN 'PASS'
            ELSE 'FAIL -- risk trigger THROWs 56202; run migration 204' END AS Result;

-- Everything risk_source_master actually holds, so an inactive or
-- renamed row is visible rather than inferred. The name column is
-- source_name, not source_type_name.
SELECT source_type_code, source_name, source_centre_code, status
FROM   grac_practice.risk_source_master
ORDER  BY source_type_code;

-- The task trigger calls sp_task_open with @task_type_code = N'Rectification'.
-- If that type is not in the task-type master, sp_task_open THROWs, the
-- gap proc re-raises it as 55502, and the outer CATCH swallows it.
-- The column is type_code, not task_type_code (037_task_engine.sql line 62).
-- Seeded by 037 and again by 272.
SELECT 'task_type_master has an active ''Rectification'' row' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.task_type_master
                          WHERE type_code = N'Rectification' AND is_active = 1)
            THEN 'PASS'
            ELSE 'FAIL -- task trigger THROWs 55502; run migration 037 / 272' END AS Result;

SELECT type_code, type_name, is_system_only, is_active
FROM   grac_practice.task_type_master
ORDER  BY display_order, type_code;

-- sp_task_open resolves the Open status through the state machine and
-- THROWs 53722 when the Task lifecycle is not seeded. That seed is
-- migration 035, which is separate from the task-type master above -- an
-- environment can have every task type and still fail here.
SELECT 'Task lifecycle seeded (fn_get_entity_status_id Task/Open)' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.fn_get_entity_status_id', 'FN') IS NULL
                 THEN 'FAIL -- function missing; run migration 035'
            WHEN grac_practice.fn_get_entity_status_id(N'Task', N'Open') IS NULL
                 THEN 'FAIL -- task trigger THROWs 53722; run migration 035'
            ELSE 'PASS' END AS Result;

PRINT '';
PRINT '===== 3. What was actually stored for the gap you analysed? =====';
PRINT '      Set @custom_gap_id. Y/N here proves the UI sent the answers;';
PRINT '      the artefact columns show whether anything was spawned.';
DECLARE @custom_gap_id BIGINT = NULL;   -- <<< set me

IF @custom_gap_id IS NULL
    SELECT 'Set @custom_gap_id at the top of section 3.' AS Note;
ELSE
BEGIN
    SELECT a.custom_gap_id,
           a.remediation_possible      AS RemediationPossible_ShouldBe_Y_for_Task,
           a.business_risk_present     AS BusinessRiskPresent_ShouldBe_Y_for_Risk,
           a.recommend_task,
           a.recommend_risk,
           a.recommend_exception,
           a.analysed_by_employee_id,
           a.updated_dt
    FROM   grac_practice.custom_gap_analysis a
    WHERE  a.custom_gap_id = @custom_gap_id;

    -- The per-gap inputs the two triggers read off the gap itself.
    --
    -- sp_task_open THROWs 53720 when organization_id or the subject title
    -- is NULL, and sp_custom_gap_task_create takes both straight from the
    -- gap row. sp_risk_candidate_create THROWs 55401 when the gap is not
    -- found and 56201 when it cannot resolve an organization. So a gap
    -- with a NULL organization_id or a blank title fails BOTH triggers
    -- while the analysis itself saves perfectly well.
    -- The column is title, not gap_title (054_custom_gap_schema.sql line 7);
    -- severity_code was added later, by 109.
    SELECT g.custom_gap_id,
           g.organization_id,
           CASE WHEN g.organization_id IS NULL
                THEN 'FAIL -- both triggers THROW without an organization'
                ELSE 'OK' END                          AS OrganizationCheck,
           g.title,
           CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(g.title, N''))), N'') IS NULL
                THEN 'FAIL -- sp_task_open THROWs 53720 without a subject title'
                ELSE 'OK' END                          AS TitleCheck,
           g.severity_code,
           g.status
    FROM   grac_practice.custom_gap g
    WHERE  g.custom_gap_id = @custom_gap_id;

    -- Whatever the triggers did or did not create, by source gap.
    --
    -- A gap task is NOT its own table: sp_custom_gap_task_create writes a
    -- practice_task row tagged subject_entity_type = 'CustomGap' with the
    -- gap id in subject_entity_id (253). Risk and Exception do carry a
    -- custom_gap_id column of their own.
    SELECT 'Task (practice_task)' AS Artefact, COUNT(*) AS Rows_
    FROM   grac_practice.practice_task
    WHERE  subject_entity_type = N'CustomGap'
      AND  subject_entity_id   = @custom_gap_id
    UNION ALL
    SELECT 'Risk candidate', COUNT(*)
    FROM   grac_practice.risk_candidate     WHERE custom_gap_id = @custom_gap_id
    UNION ALL
    SELECT 'Exception request', COUNT(*)
    FROM   grac_practice.exception_request  WHERE custom_gap_id = @custom_gap_id;
END

PRINT '';
PRINT '===== 4. REPRODUCE the swallowed error (opt-in, WRITES) =====';
PRINT '      Set @repro_gap_id AND @repro_employee_id to run the two';
PRINT '      triggers OUTSIDE the TRY/CATCH, so the real error is raised';
PRINT '      instead of PRINTed. It creates exactly what a normal save';
PRINT '      would -- run it on the gap that failed, not a healthy one.';
DECLARE @repro_gap_id      BIGINT = NULL;   -- <<< set me to reproduce
DECLARE @repro_employee_id BIGINT = NULL;   -- <<< the analyst

IF @repro_gap_id IS NULL OR @repro_employee_id IS NULL
    SELECT 'Optional. Set both variables in section 4 to reproduce.' AS Note;
ELSE
BEGIN
    PRINT '--- Task trigger ---';
    EXEC grac_practice.sp_custom_gap_task_create
         @custom_gap_id           = @repro_gap_id,
         @assigned_to_employee_id = @repro_employee_id,
         @caller_display_name     = N'diagnostic';

    PRINT '--- Risk trigger ---';
    EXEC grac_practice.sp_risk_candidate_create
         @custom_gap_id            = @repro_gap_id,
         @candidate_title          = NULL,
         @candidate_summary        = N'Reproduced from _diag_gap_analysis_triggers.sql',
         @severity_code            = NULL,
         @severity_name            = NULL,
         @impact_summary           = NULL,
         @likelihood_summary       = NULL,
         @requested_by_employee_id = @repro_employee_id,
         @caller_display_name      = N'diagnostic';
END
GO
