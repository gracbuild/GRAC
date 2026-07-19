-- ============================================================================
-- ISO Controls Import to GRAC v1.0
-- Phase 4 -- Cleanup ISO organization data for a single organization
-- ============================================================================
-- Removes every row anchored to grac_practice.organization_control rows that
-- belong to this @organization_id + @release_id. Deletes traverse the full
-- FK chain children-first so no FK constraint fires:
--
--   organization_control
--     <- organization_requirement
--          <- organization_statement_practice_mapping
--          <- practice
--               <- practice_instance
--                    <- assurance_activity
--                         <- assurance_dependency_check
--                         <- assurance_evidence_check
--                         <- assurance_execution
--                         <- assurance_finding
--                         <- assurance_result
--                         <- assurance_signal
--                    <- assurance_schedule_rule
--                         <- assurance_schedule_override
--                    <- practice_dependency_resolution
--                    <- practice_instance_dependency
--                    <- practice_instance_evidence
--                         <- practice_instance_evidence_alignment
--                    <- practice_operationalization
--
-- Every DELETE is guarded by OBJECT_ID(...) IS NOT NULL so the script runs on
-- environments that don't have every optional module installed (assurance
-- calendar, statement<->practice mapping, etc.).
--
-- Filters by @release_id AND @organization_id -- other subscribed releases
-- are untouched.
-- ============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @release_id      BIGINT = /* <FILL_IN> */ NULL;
DECLARE @organization_id BIGINT = /* <FILL_IN> */ NULL;
DECLARE @actor           NVARCHAR(100) = 'iso-import-v1.0';

IF @release_id IS NULL OR @organization_id IS NULL
BEGIN
    RAISERROR('Set @release_id and @organization_id.', 16, 1);
    RETURN;
END

-- ============================================================================
-- Capture the target row-ids into temp tables so filtering stays exact
-- as we work our way down the FK chain.
-- ============================================================================
IF OBJECT_ID('tempdb..#target_oc')  IS NOT NULL DROP TABLE #target_oc;
IF OBJECT_ID('tempdb..#target_or')  IS NOT NULL DROP TABLE #target_or;
IF OBJECT_ID('tempdb..#target_pr')  IS NOT NULL DROP TABLE #target_pr;
IF OBJECT_ID('tempdb..#target_pi')  IS NOT NULL DROP TABLE #target_pi;
IF OBJECT_ID('tempdb..#target_aa')  IS NOT NULL DROP TABLE #target_aa;
IF OBJECT_ID('tempdb..#target_asr') IS NOT NULL DROP TABLE #target_asr;

CREATE TABLE #target_oc  (organization_control_id     BIGINT PRIMARY KEY);
CREATE TABLE #target_or  (organization_requirement_id BIGINT PRIMARY KEY);
CREATE TABLE #target_pr  (practice_id                 BIGINT PRIMARY KEY);
CREATE TABLE #target_pi  (practice_instance_id        BIGINT PRIMARY KEY);
CREATE TABLE #target_aa  (assurance_activity_id       BIGINT PRIMARY KEY);
CREATE TABLE #target_asr (schedule_rule_id            BIGINT PRIMARY KEY);

INSERT #target_oc (organization_control_id)
SELECT organization_control_id
FROM grac_practice.organization_control
WHERE organization_id = @organization_id AND release_id = @release_id;

INSERT #target_or (organization_requirement_id)
SELECT organization_requirement_id
FROM grac_practice.organization_requirement
WHERE organization_control_id IN (SELECT organization_control_id FROM #target_oc);

INSERT #target_pr (practice_id)
SELECT practice_id
FROM grac_practice.practice
WHERE organization_requirement_id IN (SELECT organization_requirement_id FROM #target_or);

INSERT #target_pi (practice_instance_id)
SELECT practice_instance_id
FROM grac_practice.practice_instance
WHERE practice_id IN (SELECT practice_id FROM #target_pr);

IF OBJECT_ID('grac_practice.assurance_activity','U') IS NOT NULL
    INSERT #target_aa (assurance_activity_id)
    SELECT assurance_activity_id
    FROM grac_practice.assurance_activity
    WHERE practice_instance_id IN (SELECT practice_instance_id FROM #target_pi);

IF OBJECT_ID('grac_practice.assurance_schedule_rule','U') IS NOT NULL
    INSERT #target_asr (schedule_rule_id)
    SELECT schedule_rule_id
    FROM grac_practice.assurance_schedule_rule
    WHERE practice_instance_id IN (SELECT practice_instance_id FROM #target_pi);

BEGIN TRAN;

-- ---------------------------------------------------------------------------
-- Level 5 -- grandchildren of practice_instance
-- ---------------------------------------------------------------------------
IF OBJECT_ID('grac_practice.assurance_dependency_check','U') IS NOT NULL
    DELETE FROM grac_practice.assurance_dependency_check
    WHERE assurance_activity_id IN (SELECT assurance_activity_id FROM #target_aa);

IF OBJECT_ID('grac_practice.assurance_evidence_check','U') IS NOT NULL
    DELETE FROM grac_practice.assurance_evidence_check
    WHERE assurance_activity_id IN (SELECT assurance_activity_id FROM #target_aa);

IF OBJECT_ID('grac_practice.assurance_execution','U') IS NOT NULL
    DELETE FROM grac_practice.assurance_execution
    WHERE assurance_activity_id IN (SELECT assurance_activity_id FROM #target_aa);

IF OBJECT_ID('grac_practice.assurance_finding','U') IS NOT NULL
    DELETE FROM grac_practice.assurance_finding
    WHERE assurance_activity_id IN (SELECT assurance_activity_id FROM #target_aa);

IF OBJECT_ID('grac_practice.assurance_result','U') IS NOT NULL
    DELETE FROM grac_practice.assurance_result
    WHERE assurance_activity_id IN (SELECT assurance_activity_id FROM #target_aa);

IF OBJECT_ID('grac_practice.assurance_signal','U') IS NOT NULL
    DELETE FROM grac_practice.assurance_signal
    WHERE assurance_activity_id IN (SELECT assurance_activity_id FROM #target_aa);

IF OBJECT_ID('grac_practice.assurance_schedule_override','U') IS NOT NULL
    DELETE FROM grac_practice.assurance_schedule_override
    WHERE schedule_rule_id IN (SELECT schedule_rule_id FROM #target_asr);

-- practice_instance_evidence_alignment references practice_instance directly
-- (via practice_instance_id) -- NOT the practice_instance_evidence PK.
IF OBJECT_ID('grac_practice.practice_instance_evidence_alignment','U') IS NOT NULL
    DELETE FROM grac_practice.practice_instance_evidence_alignment
    WHERE practice_instance_id IN (SELECT practice_instance_id FROM #target_pi);

-- ---------------------------------------------------------------------------
-- Level 4 -- direct children of practice_instance
-- ---------------------------------------------------------------------------
IF OBJECT_ID('grac_practice.assurance_activity','U') IS NOT NULL
    DELETE FROM grac_practice.assurance_activity
    WHERE practice_instance_id IN (SELECT practice_instance_id FROM #target_pi);

IF OBJECT_ID('grac_practice.assurance_schedule_rule','U') IS NOT NULL
    DELETE FROM grac_practice.assurance_schedule_rule
    WHERE practice_instance_id IN (SELECT practice_instance_id FROM #target_pi);

IF OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NOT NULL
    DELETE FROM grac_practice.practice_dependency_resolution
    WHERE practice_instance_id IN (SELECT practice_instance_id FROM #target_pi);

IF OBJECT_ID('grac_practice.practice_instance_dependency','U') IS NOT NULL
    DELETE FROM grac_practice.practice_instance_dependency
    WHERE practice_instance_id IN (SELECT practice_instance_id FROM #target_pi);

IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NOT NULL
    DELETE FROM grac_practice.practice_instance_evidence
    WHERE practice_instance_id IN (SELECT practice_instance_id FROM #target_pi);

IF OBJECT_ID('grac_practice.practice_operationalization','U') IS NOT NULL
    DELETE FROM grac_practice.practice_operationalization
    WHERE practice_instance_id IN (SELECT practice_instance_id FROM #target_pi);

-- ---------------------------------------------------------------------------
-- Level 3 -- practice_instance
-- ---------------------------------------------------------------------------
DELETE FROM grac_practice.practice_instance
WHERE practice_instance_id IN (SELECT practice_instance_id FROM #target_pi);

-- ---------------------------------------------------------------------------
-- Level 2 -- practice
-- ---------------------------------------------------------------------------
DELETE FROM grac_practice.practice
WHERE practice_id IN (SELECT practice_id FROM #target_pr);

-- ---------------------------------------------------------------------------
-- Level 1b -- statement<->practice mapping (sibling child of org_requirement)
-- ---------------------------------------------------------------------------
IF OBJECT_ID('grac_practice.organization_statement_practice_mapping','U') IS NOT NULL
    DELETE FROM grac_practice.organization_statement_practice_mapping
    WHERE org_practice_id IN (SELECT organization_requirement_id FROM #target_or);

-- ---------------------------------------------------------------------------
-- Level 1 -- organization_requirement (Practices)
-- ---------------------------------------------------------------------------
DELETE FROM grac_practice.organization_requirement
WHERE organization_requirement_id IN (SELECT organization_requirement_id FROM #target_or);

-- ---------------------------------------------------------------------------
-- Level 0 -- organization_control
-- ---------------------------------------------------------------------------
DELETE FROM grac_practice.organization_control
WHERE organization_control_id IN (SELECT organization_control_id FROM #target_oc);

COMMIT;

SELECT 'Phase 4 organization ISO data cleared' AS Result,
       @organization_id AS OrganizationId,
       @release_id      AS ReleaseId,
       (SELECT COUNT(*) FROM #target_oc)  AS ControlsDeleted,
       (SELECT COUNT(*) FROM #target_or)  AS RequirementsDeleted,
       (SELECT COUNT(*) FROM #target_pr)  AS PracticesDeleted,
       (SELECT COUNT(*) FROM #target_pi)  AS PracticeInstancesDeleted,
       (SELECT COUNT(*) FROM #target_aa)  AS AssuranceActivitiesDeleted,
       (SELECT COUNT(*) FROM #target_asr) AS AssuranceScheduleRulesDeleted;
GO
