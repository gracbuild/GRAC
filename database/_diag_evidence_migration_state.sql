-- =====================================================================
-- _diag_evidence_migration_state.sql
--
-- WHY THIS EXISTS
--   306 failed with Msg 207 "Invalid column name 'evidence_name'",
--   which means this database never applied 254. Before running 254 it
--   is worth knowing whether 254's OWN prerequisites are present too --
--   its procedure body reads columns that 140 and 232 added, and if one
--   of those is also missing, 254 fails exactly the same way and the
--   next error message names a different column.
--
--   Read-only. Nothing here changes anything.
--
-- HOW TO READ IT
--   Section 1  every column the 254 body touches, with the migration
--              that owns it. Any MISSING row = run that migration first.
--   Section 2  which body is deployed right now, per procedure.
--   Section 3  the one-line verdict: what to run next.
--
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
GO

PRINT '=== 1. Columns the 254 / 306 procedure body reads ===';

SELECT  x.Owner_        AS OwnedByMigration,
        x.Column_       AS Column_,
        CASE WHEN COL_LENGTH('grac_practice.practice_instance_evidence', x.Column_) IS NULL
             THEN 'MISSING' ELSE 'present' END AS State_
FROM (VALUES
        (N'001', N'evidence_type_id'),
        (N'001', N'evidence_description'),
        (N'001', N'evidence_location'),
        (N'001', N'evidence_locator'),
        (N'001', N'evidence_owner'),
        (N'001', N'retention_period'),
        (N'001', N'alignment_status_id'),
        (N'001', N'inherited_from_repository'),
        (N'001', N'organization_modified'),
        (N'140', N'source_obligation_id'),
        (N'140', N'source_obligation_evidence_id'),
        (N'232', N'source_practice_instance_obligation_id'),
        (N'254', N'evidence_name')
     ) AS x(Owner_, Column_)
ORDER BY CASE WHEN COL_LENGTH('grac_practice.practice_instance_evidence', x.Column_) IS NULL
              THEN 0 ELSE 1 END,
         x.Owner_, x.Column_;

PRINT '';
PRINT '=== 2. Which body is deployed ===';

DECLARE @list NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_list','P'));
DECLARE @save NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_save','P'));

SELECT 'sp_resolve_evidence_list' AS Procedure_,
       CASE WHEN @list IS NULL                            THEN 'not deployed -- run 143'
            WHEN @list LIKE '%AS EvidenceRemarks%'        THEN '306 (remark projected)'
            WHEN @list LIKE '%AS EvidenceName%'           THEN '254 (name, no remark)'
            WHEN @list LIKE '%@practice_instance_obligation_id%' THEN '232 (local-obligation filter)'
            ELSE '143 (original)' END AS DeployedBody
UNION ALL
SELECT 'sp_resolve_evidence_save',
       CASE WHEN @save IS NULL                     THEN 'not deployed -- run 143'
            WHEN @save LIKE '%@evidence_name%'     THEN '254 (accepts the name)'
            ELSE '143 (no name parameter)' END;

PRINT '';
PRINT '=== 3. What to run next ===';

SELECT CASE
    WHEN COL_LENGTH('grac_practice.practice_instance_evidence','source_obligation_evidence_id') IS NULL
        THEN 'Run 140_resolve_workspace_schema.sql, then 232, then 254, then 306.'
    WHEN COL_LENGTH('grac_practice.practice_instance_evidence','source_practice_instance_obligation_id') IS NULL
        THEN 'Run 232_local_obligation_evidence.sql, then 254, then 306.'
    WHEN COL_LENGTH('grac_practice.practice_instance_evidence','evidence_name') IS NULL
        THEN 'Run 254_evidence_name.sql, then re-run 306.'
    -- NULL NOT LIKE anything is NULL, not true, so an undeployed
    -- procedure would fall through to "nothing to do" without this.
    WHEN @list IS NULL
        THEN 'Run 143_resolve_evidence_procs.sql, then 232, 254, 306.'
    WHEN @list NOT LIKE '%AS EvidenceRemarks%'
        THEN 'Re-run 306_evidence_remarks_on_resolve_rows.sql -- 254 is in place now.'
    ELSE 'Nothing. 254 and 306 are both applied.'
END AS NextStep;

PRINT '';
PRINT '=== 4. Is there a published remark to show at all? ===';
--
-- Even with 306 applied, the card shows nothing when the authority
-- published no remark for that evidence -- which is correct behaviour and
-- looks identical to the migration not being applied. So this counts
-- them, before anyone goes looking for a bug that is not there.
--
-- Deliberately does NOT reference evidence_name: this script has to run
-- on a database that never applied 254.
IF OBJECT_ID('GRAC_New.requirement_obligation_evidence','U') IS NULL
    PRINT 'GRAC_New.requirement_obligation_evidence not reachable -- cannot tell.';
ELSE
BEGIN
    SELECT 'Published evidence rows carrying a remark' AS Check_,
           COUNT(*) AS WithRemark
    FROM   GRAC_New.requirement_obligation_evidence roe
    WHERE  roe.status = N'Active'
      AND  NULLIF(LTRIM(RTRIM(CAST(roe.remarks AS NVARCHAR(4000)))), N'') IS NOT NULL;

    -- Narrowed to the instance evidence that actually exists here, which
    -- is what the workspace would render.
    SELECT TOP 20
           'Instance evidence and its published remark' AS Check_,
           pie.practice_instance_id AS PracticeInstanceId,
           pie.evidence_id          AS EvidenceId,
           et.evidence_type_name    AS EvidenceType,
           CASE WHEN NULLIF(LTRIM(RTRIM(CAST(roe.remarks AS NVARCHAR(4000)))), N'') IS NULL
                THEN '(none published)'
                ELSE LEFT(CAST(roe.remarks AS NVARCHAR(4000)), 120) END AS RemarkStart
    FROM   grac_practice.practice_instance_evidence pie
    LEFT   JOIN grac_practice.evidence_type_master et
           ON et.evidence_type_id = pie.evidence_type_id
    LEFT   JOIN GRAC_New.requirement_obligation_evidence roe
           ON roe.obligation_evidence_id = pie.source_obligation_evidence_id
          AND roe.status = N'Active'
    WHERE  pie.status = N'Active'
    ORDER  BY pie.evidence_id DESC;
END

PRINT '';
PRINT 'Reminder: Msg 207 aborts the CREATE OR ALTER but NOT the script, so';
PRINT 'a run that printed its success line may still have changed nothing.';
PRINT 'Section 2 above is what is actually deployed.';
GO
