-- =====================================================================
-- 325 Gap Header -- expose the gap's Identified Date
--
-- WHY
-- ---
-- The new Gap View page (Gap Centre -- read-only consolidated view of a
-- Gap plus the Task / Exception / Risk raised against it) needs an
-- "Identified Date" fact. custom_gap already carries this -- entered_dt,
-- stamped by sp_custom_gap_open / sp_custom_gap_save at creation (and,
-- since migration 324, always populated together with lifecycle_state_id)
-- -- but sp_custom_gap_header has never projected it. Everywhere else on
-- this page reuses an existing API/model as-is (linked-artefacts, the
-- Task/Exception/Risk Centres' own single-record reads); this one column
-- is the single, minimal, additive exception, following the same
-- tolerant-projection pattern 321 used for PracticeInstanceId.
--
-- WHAT THIS ADDS
-- --------------
-- sp_custom_gap_header (321's body, re-issued): one new projected
-- column, g.entered_dt AS IdentifiedDate. No table/column changes, no
-- backfill -- entered_dt already exists and is already populated for
-- every gap (324 made that reliably true at creation time; rows created
-- before 324 still carry whatever entered_dt sp_custom_gap_open/_save
-- stamped at the time -- that column itself is not new).
--
-- Depends on 159 (sp_custom_gap_header), 321 (its current live body).
-- Rollback: 325_gap_header_identified_date_rollback.sql.
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (325): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_instance','U') IS NULL
BEGIN
    PRINT 'ABORT (325): custom_gap / practice_instance missing.';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.custom_gap','entered_dt') IS NULL
BEGIN
    PRINT 'ABORT (325): custom_gap.entered_dt missing.';
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
        s.is_terminal               AS LifecycleIsTerminal,
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
        -- this gap.
        pi.practice_instance_id    AS PracticeInstanceId,
        pi.instance_code           AS PracticeInstanceCode,
        pi.instance_name           AS PracticeInstanceName,
        -- Migration 325: when the gap was identified/raised. Same value
        -- Gap Centre's own list already sorts new gaps by (entered_dt),
        -- simply not projected on the header until now. NULL only for a
        -- pre-existing legacy row that predates entered_dt being stamped
        -- at all.
        g.entered_dt                AS IdentifiedDate
      FROM grac_practice.custom_gap g
 LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
 LEFT JOIN grac_practice.custom_gap p                 ON p.custom_gap_id      = g.duplicate_of_gap_id
 LEFT JOIN grac_practice.practice_instance pi          ON pi.practice_instance_id = g.source_reference_id
                                                       AND g.source_reference_type = N'PracticeInstance'
                                                       AND pi.organization_id      = g.organization_id
     WHERE g.custom_gap_id = @custom_gap_id;
END
GO
PRINT '325: sp_custom_gap_header now projects IdentifiedDate (entered_dt).';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 325 verification ===';

SELECT '325-a header proc projects IdentifiedDate' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_header','P')) LIKE '%IdentifiedDate%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '325-b header proc still projects PracticeInstanceId (321 regression check)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_header','P')) LIKE '%PracticeInstanceId%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '325-c header proc still projects DetectionMethodCode (250 regression check)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_header','P')) LIKE '%DetectionMethodCode%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '325-d header proc still projects SlaOverridePending (185 regression check)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_header','P')) LIKE '%SlaOverridePending%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- 325 diagnostic: a few recent gaps and their IdentifiedDate ---';
SELECT TOP 5
       g.custom_gap_id, g.title, g.gap_source_module_code,
       g.entered_dt AS IdentifiedDate, g.lifecycle_state_id
  FROM grac_practice.custom_gap g
 ORDER BY g.custom_gap_id DESC;

PRINT '';
PRINT '325 complete. Gap View can now show Identified Date from the header alone.';
GO

SET NOEXEC OFF;
GO
