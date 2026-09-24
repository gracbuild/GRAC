-- =====================================================================
-- 321 Gap Detail -- expose the linked Practice Instance on the header
--
-- WHY
-- ---
-- Gap Centre already lets you jump from a gap's ROW MENU to the linked
-- Practice Instance's read-only view (gaps.cshtml's "View Practice
-- Instance" action -> /Practice/Index/resolve-workspace?instanceId=..
-- &organizationId=..&mode=view). The gap DETAIL screen (gap-detail.cshtml
-- / Analysis + Metadata tabs) has no such link at all -- an analyst
-- working a gap has to go back to the list to see the instance behind
-- it.
--
-- This adds a third "Practice Instance" tab to gap-detail.cshtml that
-- embeds that exact same read-only screen in an iframe, so nothing about
-- the instance view itself is duplicated. To build the iframe's URL the
-- header needs to say WHICH instance (if any) this gap is linked to --
-- sp_custom_gap_header does not project that today.
--
-- WHAT THIS ADDS
-- --------------
-- sp_custom_gap_header (250's body, re-issued): one new LEFT JOIN to
-- practice_instance on the same source_reference_id / source_reference_
-- type = 'PracticeInstance' pair 160's materialize proc and 318's list
-- proc both already key off, projecting:
--   PracticeInstanceId, PracticeInstanceCode, PracticeInstanceName
-- All three NULL for a gap with no linked instance (Custom / Assurance
-- gaps, or a not-yet-materialized Implementation gap) -- the new tab
-- stays hidden in that case; gap-detail.js decides that client-side from
-- whether PracticeInstanceId came back non-null.
--
-- No table/column changes, no backfill -- this is a read-only projection
-- change only. 250.sql is left as-is, per this project's append-only
-- migration history.
--
-- Depends on 054, 109 (practice_instance), 159 (sp_custom_gap_header),
-- 250 (its current live body). Rollback:
-- 321_gap_header_practice_instance_link_rollback.sql.
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (321): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_instance','U') IS NULL
BEGIN
    PRINT 'ABORT (321): custom_gap / practice_instance missing.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_header
    @custom_gap_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @custom_gap_id IS NULL
        THROW 55160, 'sp_custom_gap_header: custom_gap_id is required.', 1;

    SELECT
        g.custom_gap_id            AS CustomGapId,
        g.organization_id          AS OrganizationId,
        g.title                    AS Title,
        g.description              AS Description,
        g.status                   AS StatusCode,
        g.priority                 AS Priority,
        g.severity_code            AS SeverityCode,
        g.severity_name            AS SeverityName,
        -- Migration 250: exposed on the header so the analysis form
        -- can pre-populate "auto" fields from the values the operator
        -- entered at Add Gap. Nullable -- absent on non-Custom gaps
        -- and on legacy rows.
        g.detection_method_code    AS DetectionMethodCode,
        g.detection_method_name    AS DetectionMethodName,
        g.owner_display_name       AS OwnerName,
        g.owner_employee_id        AS OwnerEmployeeId,
        g.due_date                 AS DueDate,
        s.state_code               AS LifecycleStateCode,
        s.state_name               AS LifecycleStateName,
        s.is_terminal              AS LifecycleIsTerminal,
        s.is_valid_terminal        AS LifecycleIsValidTerminal,
        g.gap_source_module_code   AS SourceModuleCode,
        g.duplicate_of_gap_id      AS DuplicateOfGapId,
        p.title                    AS DuplicateOfGapTitle,
        g.invalid_reason           AS InvalidReason,
        g.sla_master_id            AS SlaMasterId,
        g.sla_master_name          AS SlaMasterName,
        g.sla_days_effective       AS SlaDaysEffective,
        g.sla_source_code          AS SlaSourceCode,
        CAST(CASE WHEN EXISTS (
                SELECT 1 FROM grac_practice.exception_request er
                WHERE er.custom_gap_id     = g.custom_gap_id
                  AND er.request_type_code = N'SLA_CANDIDATE'
                  AND er.status_code       = N'Pending')
             THEN 1 ELSE 0 END AS BIT)  AS SlaOverridePending,
        -- Migration 321: which Practice Instance (if any) materialized
        -- this gap -- the same source_reference_id / source_reference_
        -- type = 'PracticeInstance' pair 160/318 already key off. NULL
        -- for Custom/Assurance gaps and for an un-materialized
        -- Implementation row (nothing to link to yet). The gap-detail
        -- screen's new Practice Instance tab hides itself when this is
        -- null instead of the proc deciding UI visibility.
        pi.practice_instance_id    AS PracticeInstanceId,
        pi.instance_code           AS PracticeInstanceCode,
        pi.instance_name           AS PracticeInstanceName
      FROM grac_practice.custom_gap g
 LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
 LEFT JOIN grac_practice.custom_gap p                 ON p.custom_gap_id      = g.duplicate_of_gap_id
 LEFT JOIN grac_practice.practice_instance pi          ON pi.practice_instance_id = g.source_reference_id
                                                       AND g.source_reference_type = N'PracticeInstance'
                                                       AND pi.organization_id      = g.organization_id
     WHERE g.custom_gap_id = @custom_gap_id;
END
GO
PRINT '321: sp_custom_gap_header projects the linked Practice Instance (id/code/name).';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 321 verification ===';

SELECT '321-a header proc projects PracticeInstanceId' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_header','P')) LIKE '%PracticeInstanceId%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '321-b header proc still projects DetectionMethodCode (250 regression check)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_header','P')) LIKE '%DetectionMethodCode%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '321-c header proc still projects SlaOverridePending (185 regression check)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_header','P')) LIKE '%SlaOverridePending%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- 321 diagnostic: a few automatic gaps and whether the header now resolves their instance ---';
SELECT TOP 5
       g.custom_gap_id, g.title, g.gap_source_module_code,
       g.source_reference_type, g.source_reference_id,
       pi.practice_instance_id, pi.instance_code, pi.instance_name
  FROM grac_practice.custom_gap g
  LEFT JOIN grac_practice.practice_instance pi
         ON pi.practice_instance_id = g.source_reference_id
        AND g.source_reference_type = N'PracticeInstance'
        AND pi.organization_id      = g.organization_id
 WHERE g.gap_source_module_code = N'Implementation'
 ORDER BY g.custom_gap_id DESC;

PRINT '';
PRINT '321 complete. Gap Detail can now build a Practice Instance tab from the header alone.';
GO

SET NOEXEC OFF;
GO
