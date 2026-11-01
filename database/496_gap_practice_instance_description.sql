-- =====================================================================
-- 496 Gap Details: Practice Instance name + description
--
-- Change request 2026-10-27: the Gap Details page (and Gap View) shows
-- each Practice Instance the gap concerns -- its name, linking to the
-- instance's view page, and its description.
--
-- A practice instance has no description column of its own
-- (grac_practice.practice_instance, 001 onwards); the description it
-- carries is its practice's, grac_practice.practice.description -- the
-- Description on the Practice form. That is what is returned.
--
-- WHAT THIS SCRIPT DOES (both bodies verbatim otherwise)
--   1. sp_custom_gap_header (491 body) + PracticeInstanceDescription for
--      the instance a gap was materialized from (Implementation gaps).
--   2. sp_custom_gap_practice_map_list (388 body) +
--      PracticeInstanceDescription for each mapped instance (Custom gaps).
--   The API reads both columns only when present.
--
-- Requires 388 and 491. SAFE TO RE-RUN. ASCII-only.
-- Rollback: 496_gap_practice_instance_description_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('grac_practice.custom_gap','current_state') IS NULL
   OR COL_LENGTH('grac_practice.custom_gap_practice_map','practice_instance_id') IS NULL
BEGIN
    PRINT 'ABORT (496): run 388 and 491 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_custom_gap_header (491 body; 496 edits marked)
-- =====================================================================
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
        g.entered_dt                AS IdentifiedDate,
        -- Migration 367: whether the linked Practice Instance is
        -- currently Operationalized -- NULL when there is none (Custom/
        -- Assurance/Exception/Risk gaps). Same live dependency-
        -- resolution rule as the 55145 guard in sp_custom_gap_analysis_
        -- save and as dbo.pm_get_practice_repository /
        -- PracticeRepositoryService.QueryResolveFallbackAsync.
        CASE
            WHEN pi.practice_instance_id IS NULL THEN NULL
            WHEN pi.status IN (N'Inactive', N'Retired') OR pirs.status_code IN (N'Inactive', N'Retired') THEN CAST(0 AS BIT)
            WHEN ISNULL(dep.TotalDependencyCategories, 0) = 0 THEN CAST(0 AS BIT)
            WHEN ISNULL(res.ResolvedDependenciesCount, 0) >= ISNULL(dep.TotalDependencyCategories, 0) THEN CAST(1 AS BIT)
            ELSE CAST(0 AS BIT)
        END                          AS IsPracticeOperationalized,
        -- Migration 491: the Add Gap narrative -- Current State / As-Is,
        -- Gap Identified / Finding, and Comments / Management Response
        -- (the remarks column, relabelled).
        g.current_state              AS CurrentState,
        g.gap_finding                AS GapFinding,
        g.remarks                    AS Remarks,
        -- Migration 496: the linked Practice Instance's description. A
        -- practice instance has no description of its own; it carries
        -- its practice's (practice.description). NULL without an instance.
        ppi.description              AS PracticeInstanceDescription
      FROM grac_practice.custom_gap g
 LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
 LEFT JOIN grac_practice.custom_gap p                 ON p.custom_gap_id      = g.duplicate_of_gap_id
 LEFT JOIN grac_practice.practice_instance pi          ON pi.practice_instance_id = g.source_reference_id
                                                       AND g.source_reference_type = N'PracticeInstance'
                                                       AND pi.organization_id      = g.organization_id
 LEFT JOIN grac_practice.record_status_master pirs     ON pirs.record_status_id   = pi.record_status_id
 LEFT JOIN grac_practice.practice ppi                  ON ppi.practice_id         = pi.practice_id      -- 496
 OUTER APPLY (SELECT COUNT(DISTINCT d.dependency_type_id) AS TotalDependencyCategories
                FROM grac_practice.practice_instance_dependency d
               WHERE d.practice_instance_id = pi.practice_instance_id
                 AND d.status               = N'Active'
                 AND d.dependency_type_id  IS NOT NULL) dep
 OUTER APPLY (SELECT COUNT(*) AS ResolvedDependenciesCount
                FROM grac_practice.practice_dependency_resolution r
               WHERE r.practice_instance_id = pi.practice_instance_id
                 AND r.is_active            = 1) res
     WHERE g.custom_gap_id = @custom_gap_id;
END
GO

-- =====================================================================
-- 2. sp_custom_gap_practice_map_list (388 body; 496 edit marked)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_practice_map_list
    @custom_gap_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.custom_gap_practice_map_id CustomGapPracticeMapId,
           m.custom_gap_id              CustomGapId,
           m.practice_id                PracticeId,
           COALESCE(p.practice_name, m.practice_name) PracticeName,
           COALESCE(p.practice_code, m.practice_code) PracticeCode,
           m.mapped_dt                  MappedDt,
           m.practice_instance_id       PracticeInstanceId,
           COALESCE(pi.instance_name, m.practice_instance_name) PracticeInstanceName,
           COALESCE(pi.instance_code, m.practice_instance_code) PracticeInstanceCode,
           -- Migration 496: the instance's description -- its practice's
           -- (a practice instance has none of its own).
           p.description                PracticeInstanceDescription
      FROM grac_practice.custom_gap_practice_map m
      LEFT JOIN grac_practice.practice p ON p.practice_id = m.practice_id
      LEFT JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = m.practice_instance_id
      JOIN grac_practice.record_status_master rs ON rs.record_status_id = m.record_status_id
     WHERE m.custom_gap_id = @custom_gap_id
       AND rs.status_code = N'Active'
     ORDER BY COALESCE(p.practice_name, m.practice_name),
              COALESCE(pi.instance_name, m.practice_instance_name);
END
GO

SELECT '496 header + map list return PracticeInstanceDescription' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_header')) LIKE '%PracticeInstanceDescription%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_practice_map_list')) LIKE '%PracticeInstanceDescription%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
PRINT '496 complete. Deploy API + Web next.';
GO

SET NOEXEC OFF;
GO
