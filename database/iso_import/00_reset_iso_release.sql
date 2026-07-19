-- ============================================================================
-- ISO Controls FULL RESET for a single release + organization
--
-- Purpose:
--   `framework_statement_requirement_map` (fsrm) is over-populated
--   (554 / 367 / 366 / 139 / 54 rows per statement instead of the intended
--   leaf-level practices). Rather than surgically repair, this script nukes
--   every ISO artifact for the target release + organization and prepares
--   the DB for a clean re-run of Phase 2 -> Phase 3 -> Phase 6.
--
-- Order (respects FK chain, children first):
--   1. Cleanup organization-side data linked to this release + org
--      (org_control -> org_requirement -> practices -> instances -> ...)
--   2. Cleanup the release's framework layer
--      (framework_statement_requirement_map, framework_statement_control_map,
--       framework_statement)
--   3. Cleanup the release's control/requirement/source-map layer
--      (source_control_map, control_requirement_map, control, requirement)
--
--   Controls / requirements are shared repository objects. This script
--   deletes only those NOT referenced by any *other* release. If you want an
--   absolute nuke across all releases, set @nuke_shared = 1.
--
-- Prereqs:
--   * Set @release_id and @organization_id below.
--   * XACT_ABORT ON + BEGIN TRAN / COMMIT -- safe to abort mid-run.
--
-- After running this successfully, run in order:
--   02_insert_repository_controls_fixed.sql    (apostrophe-escaped)
--   03_insert_repository_practices_fixed.sql   (apostrophe-escaped)
--   06_insert_framework_statements.sql         (unchanged from repo)
--
-- ASCII-only. Every DELETE is guarded by OBJECT_ID(...) IS NOT NULL so
-- optional modules that aren't installed don't break the batch.
-- ============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ---------------------------------------------------------------------------
-- Parameters -- FILL THESE IN BEFORE RUNNING
-- ---------------------------------------------------------------------------
DECLARE @release_id      BIGINT = /* <FILL_IN> */ NULL;
DECLARE @organization_id BIGINT = /* <FILL_IN> */ NULL;
DECLARE @nuke_shared     BIT    = 0;  -- 1 = also delete controls/requirements
                                      --     even if OTHER releases reference them
DECLARE @actor           NVARCHAR(100) = 'iso-reset-v1.0';

IF @release_id IS NULL OR @organization_id IS NULL
BEGIN
    RAISERROR('Set @release_id and @organization_id.', 16, 1);
    RETURN;
END

PRINT CONCAT('Starting ISO reset. release_id=', @release_id,
             ' organization_id=', @organization_id,
             ' nuke_shared=', @nuke_shared);

-- ---------------------------------------------------------------------------
-- Capture target IDs into temp tables so filtering stays exact.
-- ---------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#target_oc')       IS NOT NULL DROP TABLE #target_oc;
IF OBJECT_ID('tempdb..#target_or')       IS NOT NULL DROP TABLE #target_or;
IF OBJECT_ID('tempdb..#target_pr')       IS NOT NULL DROP TABLE #target_pr;
IF OBJECT_ID('tempdb..#target_pi')       IS NOT NULL DROP TABLE #target_pi;
IF OBJECT_ID('tempdb..#target_aa')       IS NOT NULL DROP TABLE #target_aa;
IF OBJECT_ID('tempdb..#target_asr')      IS NOT NULL DROP TABLE #target_asr;
IF OBJECT_ID('tempdb..#target_fs')       IS NOT NULL DROP TABLE #target_fs;
IF OBJECT_ID('tempdb..#target_control')  IS NOT NULL DROP TABLE #target_control;
IF OBJECT_ID('tempdb..#target_req')      IS NOT NULL DROP TABLE #target_req;

CREATE TABLE #target_oc      (organization_control_id     BIGINT PRIMARY KEY);
CREATE TABLE #target_or      (organization_requirement_id BIGINT PRIMARY KEY);
CREATE TABLE #target_pr      (practice_id                 BIGINT PRIMARY KEY);
CREATE TABLE #target_pi      (practice_instance_id        BIGINT PRIMARY KEY);
CREATE TABLE #target_aa      (assurance_activity_id       BIGINT PRIMARY KEY);
CREATE TABLE #target_asr     (schedule_rule_id            BIGINT PRIMARY KEY);
CREATE TABLE #target_fs      (framework_statement_id      BIGINT PRIMARY KEY);
CREATE TABLE #target_control (control_id                  BIGINT PRIMARY KEY);
CREATE TABLE #target_req     (requirement_id              BIGINT PRIMARY KEY);

-- Organization-scoped targets ------------------------------------------------
INSERT #target_oc (organization_control_id)
SELECT organization_control_id
FROM grac_practice.organization_control
WHERE organization_id = @organization_id AND release_id = @release_id;

INSERT #target_or (organization_requirement_id)
SELECT organization_requirement_id
FROM grac_practice.organization_requirement
WHERE organization_control_id IN (SELECT organization_control_id FROM #target_oc)
   OR organization_requirement_id IN (
       SELECT org_practice_id
       FROM grac_practice.organization_statement_practice_mapping
       WHERE organization_id = @organization_id
   );

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

-- Release-scoped repository targets -----------------------------------------
INSERT #target_fs (framework_statement_id)
SELECT framework_statement_id
FROM grac_new.framework_statement
WHERE release_id = @release_id;

INSERT #target_control (control_id)
SELECT DISTINCT control_id
FROM grac_new.source_control_map
WHERE release_id = @release_id;

INSERT #target_req (requirement_id)
SELECT DISTINCT crm.requirement_id
FROM grac_new.control_requirement_map crm
WHERE crm.control_id IN (SELECT control_id FROM #target_control);

-- SQL Server disallows subqueries directly inside PRINT / CONCAT, so we
-- capture the counts into scalar variables first, then PRINT.
DECLARE @cnt_oc      INT = (SELECT COUNT(*) FROM #target_oc);
DECLARE @cnt_or      INT = (SELECT COUNT(*) FROM #target_or);
DECLARE @cnt_pr      INT = (SELECT COUNT(*) FROM #target_pr);
DECLARE @cnt_pi      INT = (SELECT COUNT(*) FROM #target_pi);
DECLARE @cnt_fs      INT = (SELECT COUNT(*) FROM #target_fs);
DECLARE @cnt_control INT = (SELECT COUNT(*) FROM #target_control);
DECLARE @cnt_req     INT = (SELECT COUNT(*) FROM #target_req);

PRINT CONCAT('Target counts: org_controls=',      @cnt_oc,
             ' org_requirements=',                @cnt_or,
             ' practices=',                       @cnt_pr,
             ' practice_instances=',              @cnt_pi,
             ' framework_statements=',            @cnt_fs,
             ' controls=',                        @cnt_control,
             ' requirements=',                    @cnt_req);

BEGIN TRAN;

-- ==========================================================================
-- Level 5 -- assurance grandchildren of practice_instance
-- ==========================================================================
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

IF OBJECT_ID('grac_practice.practice_instance_evidence_alignment','U') IS NOT NULL
    DELETE FROM grac_practice.practice_instance_evidence_alignment
    WHERE practice_instance_id IN (SELECT practice_instance_id FROM #target_pi);

-- ==========================================================================
-- Level 4 -- direct children of practice_instance
-- ==========================================================================
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

-- ==========================================================================
-- Level 3 -- practice_instance
-- ==========================================================================
DELETE FROM grac_practice.practice_instance
WHERE practice_instance_id IN (SELECT practice_instance_id FROM #target_pi);

-- ==========================================================================
-- Level 2 -- practice
-- ==========================================================================
DELETE FROM grac_practice.practice
WHERE practice_id IN (SELECT practice_id FROM #target_pr);

-- ==========================================================================
-- Level 1c -- organization_control_requirement (migration 057 mapping)
-- ==========================================================================
IF OBJECT_ID('grac_practice.organization_control_requirement','U') IS NOT NULL
    DELETE FROM grac_practice.organization_control_requirement
    WHERE organization_control_id     IN (SELECT organization_control_id     FROM #target_oc)
       OR organization_requirement_id IN (SELECT organization_requirement_id FROM #target_or);

-- ==========================================================================
-- Level 1b -- statement<->practice mapping (nuke org-scoped rows outright)
-- ==========================================================================
IF OBJECT_ID('grac_practice.organization_statement_practice_mapping','U') IS NOT NULL
    DELETE FROM grac_practice.organization_statement_practice_mapping
    WHERE organization_id = @organization_id
       OR org_practice_id IN (SELECT organization_requirement_id FROM #target_or);

-- ==========================================================================
-- Level 1 -- organization_requirement (Practices)
-- ==========================================================================
DELETE FROM grac_practice.organization_requirement
WHERE organization_requirement_id IN (SELECT organization_requirement_id FROM #target_or);

-- ==========================================================================
-- Level 0b -- organization_framework_statements + statement_applicability
--            (must go before framework_statement itself)
-- ==========================================================================
IF OBJECT_ID('grac_practice.organization_framework_statements','U') IS NOT NULL
    DELETE FROM grac_practice.organization_framework_statements
    WHERE organization_id = @organization_id AND release_id = @release_id;

IF OBJECT_ID('grac_practice.organization_statement_applicability','U') IS NOT NULL
    DELETE FROM grac_practice.organization_statement_applicability
    WHERE organization_id = @organization_id AND release_id = @release_id;

-- ==========================================================================
-- Level 0 -- organization_control
-- ==========================================================================
DELETE FROM grac_practice.organization_control
WHERE organization_control_id IN (SELECT organization_control_id FROM #target_oc);

-- ==========================================================================
-- Repository layer (grac_new) -- obligation chain FIRST
-- obligation_requirement_release_map references framework_statement,
-- requirement, and release. Other obligation tables (obligation,
-- requirement_obligation, requirement_obligation_evidence) may reference
-- framework_statement / requirement too. Delete the chain in dependency
-- order, guarded so it works whether or not each optional table exists.
-- ==========================================================================

-- Snapshot obligation ids whose evidence chain we may need to remove.
IF OBJECT_ID('tempdb..#target_obligation') IS NOT NULL DROP TABLE #target_obligation;
CREATE TABLE #target_obligation (obligation_id BIGINT PRIMARY KEY);

IF OBJECT_ID('GRAC_New.obligation_requirement_release_map','U') IS NOT NULL
    INSERT #target_obligation (obligation_id)
    SELECT DISTINCT obligation_id
    FROM GRAC_New.obligation_requirement_release_map
    WHERE (release_id = @release_id
       OR framework_statement_id IN (SELECT framework_statement_id FROM #target_fs)
       OR requirement_id         IN (SELECT requirement_id         FROM #target_req));

-- Some environments also have GRAC_New.obligation carrying framework_statement_id
-- (legacy obligation master); capture those obligation ids too.
IF OBJECT_ID('GRAC_New.obligation','U') IS NOT NULL
   AND COL_LENGTH('GRAC_New.obligation','framework_statement_id') IS NOT NULL
BEGIN
    INSERT #target_obligation (obligation_id)
    SELECT DISTINCT o.obligation_id
    FROM GRAC_New.obligation o
    LEFT JOIN #target_obligation t ON t.obligation_id = o.obligation_id
    WHERE o.framework_statement_id IN (SELECT framework_statement_id FROM #target_fs)
      AND t.obligation_id IS NULL;
END

-- Delete obligation evidence rows for those obligations.
IF OBJECT_ID('GRAC_New.requirement_obligation_evidence','U') IS NOT NULL
    DELETE FROM GRAC_New.requirement_obligation_evidence
    WHERE obligation_id IN (SELECT obligation_id FROM #target_obligation);

-- Delete the requirement<->obligation<->release mapping (this is the row
-- with framework_statement_id that triggered the original FK error).
IF OBJECT_ID('GRAC_New.obligation_requirement_release_map','U') IS NOT NULL
    DELETE FROM GRAC_New.obligation_requirement_release_map
    WHERE release_id = @release_id
       OR framework_statement_id IN (SELECT framework_statement_id FROM #target_fs)
       OR requirement_id         IN (SELECT requirement_id         FROM #target_req);

-- Delete obligation master rows (both modern and legacy tables if present).
IF OBJECT_ID('GRAC_New.requirement_obligation','U') IS NOT NULL
    DELETE FROM GRAC_New.requirement_obligation
    WHERE obligation_id IN (SELECT obligation_id FROM #target_obligation);

IF OBJECT_ID('GRAC_New.obligation','U') IS NOT NULL
    DELETE FROM GRAC_New.obligation
    WHERE obligation_id IN (SELECT obligation_id FROM #target_obligation);

-- ==========================================================================
-- Repository layer (grac_new) -- release-scoped
-- ==========================================================================
DELETE FROM grac_new.framework_statement_requirement_map
WHERE framework_statement_id IN (SELECT framework_statement_id FROM #target_fs);

DELETE FROM grac_new.framework_statement_control_map
WHERE framework_statement_id IN (SELECT framework_statement_id FROM #target_fs);

DELETE FROM grac_new.framework_statement
WHERE framework_statement_id IN (SELECT framework_statement_id FROM #target_fs);

DELETE FROM grac_new.source_control_map
WHERE release_id = @release_id;

-- ==========================================================================
-- Shared repository objects (grac_new.control / requirement / crm)
-- Only delete rows NOT referenced by other releases unless @nuke_shared = 1.
-- ==========================================================================
IF @nuke_shared = 1
BEGIN
    PRINT 'nuke_shared = 1 -> deleting ALL control_requirement_map / control / requirement rows that traced back through this release.';

    DELETE FROM grac_new.control_requirement_map
    WHERE control_id IN (SELECT control_id FROM #target_control);

    DELETE FROM grac_new.control
    WHERE control_id IN (SELECT control_id FROM #target_control);

    DELETE FROM grac_new.requirement
    WHERE requirement_id IN (SELECT requirement_id FROM #target_req);
END
ELSE
BEGIN
    PRINT 'nuke_shared = 0 -> preserving control / requirement rows still referenced by other releases.';

    -- Delete crm rows for controls that are only referenced by this release.
    DELETE FROM grac_new.control_requirement_map
    WHERE control_id IN (
        SELECT c.control_id FROM #target_control c
        WHERE NOT EXISTS (
            SELECT 1 FROM grac_new.source_control_map scm
            WHERE scm.control_id = c.control_id AND scm.release_id <> @release_id
        )
    );

    DELETE FROM grac_new.control
    WHERE control_id IN (
        SELECT c.control_id FROM #target_control c
        WHERE NOT EXISTS (
            SELECT 1 FROM grac_new.source_control_map scm
            WHERE scm.control_id = c.control_id AND scm.release_id <> @release_id
        )
    );

    -- Requirements are only deleted when NO crm row references them anywhere.
    DELETE FROM grac_new.requirement
    WHERE requirement_id IN (
        SELECT r.requirement_id FROM #target_req r
        WHERE NOT EXISTS (
            SELECT 1 FROM grac_new.control_requirement_map crm
            WHERE crm.requirement_id = r.requirement_id
        )
    );
END

COMMIT TRAN;

-- ---------------------------------------------------------------------------
-- Cleanup summary
-- ---------------------------------------------------------------------------
SELECT 'ISO reset complete'                                                      AS Result,
       @release_id                                                               AS ReleaseId,
       @organization_id                                                          AS OrganizationId,
       (SELECT COUNT_BIG(1) FROM grac_new.framework_statement
        WHERE release_id = @release_id)                                          AS RemainingFrameworkStatements,
       (SELECT COUNT_BIG(1) FROM grac_new.framework_statement_requirement_map m
        JOIN grac_new.framework_statement fs
             ON fs.framework_statement_id = m.framework_statement_id
        WHERE fs.release_id = @release_id)                                       AS RemainingFsrmRows,
       (SELECT COUNT_BIG(1) FROM grac_new.source_control_map
        WHERE release_id = @release_id)                                          AS RemainingSourceControlMap,
       (SELECT COUNT_BIG(1) FROM grac_practice.organization_control
        WHERE organization_id = @organization_id AND release_id = @release_id)   AS RemainingOrgControls,
       (SELECT COUNT_BIG(1) FROM grac_practice.organization_statement_practice_mapping
        WHERE organization_id = @organization_id)                                AS RemainingOrgStatementPracticeMappings;

PRINT 'Next steps:';
PRINT '  1. Run 02_insert_repository_controls_fixed.sql   (@release_id set)';
PRINT '  2. Run 03_insert_repository_practices_fixed.sql  (@release_id set)';
PRINT '  3. Run 06_insert_framework_statements.sql        (@release_id set)';
GO
