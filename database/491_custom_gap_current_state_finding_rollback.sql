-- =====================================================================
-- 491_custom_gap_current_state_finding_rollback.sql
-- Restores sp_custom_gap_open (382) and sp_custom_gap_header (367)
-- verbatim, then drops custom_gap.current_state / gap_finding -- the text
-- entered in them is LOST (copy it out first if it is needed).
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_open
    @organization_id        BIGINT,
    @title                  NVARCHAR(250),
    @description            NVARCHAR(MAX) = NULL,
    @priority               NVARCHAR(30)  = N'Medium',
    @owner_employee_id      BIGINT        = NULL,
    @due_date               DATE          = NULL,
    @status                 NVARCHAR(30)  = N'Open',
    @remarks                NVARCHAR(1000) = NULL,
    @gap_type_code          NVARCHAR(60)  = N'Custom',
    @actor_employee_id      BIGINT        = NULL,
    @severity_code          NVARCHAR(30)  = NULL,
    @severity_name          NVARCHAR(120) = NULL,
    @detection_method_code  NVARCHAR(60)  = NULL,
    @detection_method_name  NVARCHAR(200) = NULL,
    -- Migration 382: optional JSON array of practice ids to map to this
    -- gap, e.g. '[12,15]'. NULL/empty leaves the gap with no mappings, so
    -- every pre-382 caller is unaffected.
    @practice_ids_json      NVARCHAR(MAX) = NULL,
    @custom_gap_id          BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @title IS NULL OR LTRIM(RTRIM(@title)) = N''
        THROW 54010, 'sp_custom_gap_open: organization_id and title are required.', 1;

    IF @priority NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @priority = N'Medium';

    IF @status NOT IN (N'Open', N'InProgress', N'Closed', N'Cancelled')
        SET @status = N'Open';

    IF @severity_code IS NOT NULL AND @severity_code NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @severity_code = NULL;
    IF @severity_code IS NULL
        SET @severity_code = @priority;
    IF @severity_name IS NULL
        SET @severity_name = @severity_code;

    DECLARE @owner_display_name NVARCHAR(240) = NULL;
    IF @owner_employee_id IS NOT NULL
        SELECT @owner_display_name = employee_name
          FROM grac_practice.organization_employee
         WHERE employee_id = @owner_employee_id;

    DECLARE @new_state_id INT =
        (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'New');

    INSERT INTO grac_practice.custom_gap
        (organization_id, gap_type_code, title, description, priority,
         owner_employee_id, owner_display_name, due_date, status, remarks,
         severity_code, severity_name,
         detection_method_code, detection_method_name,
         lifecycle_state_id,
         opened_dt,
         entered_by, entered_dt)
    VALUES
        (@organization_id, ISNULL(@gap_type_code, N'Custom'),
         @title, @description, @priority,
         @owner_employee_id, @owner_display_name, @due_date, @status, @remarks,
         @severity_code, @severity_name,
         NULLIF(LTRIM(RTRIM(@detection_method_code)), N''),
         NULLIF(LTRIM(RTRIM(@detection_method_name)), N''),
         @new_state_id,
         SYSUTCDATETIME(),
         COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api'),
         SYSUTCDATETIME());

    SET @custom_gap_id = SCOPE_IDENTITY();

    -- Migration 382: map the selected practices. Only practices that
    -- belong to the same organization are mapped; name/code are frozen
    -- from grac_practice.practice at map time.
    IF @practice_ids_json IS NOT NULL AND LTRIM(RTRIM(@practice_ids_json)) <> N''
       AND ISJSON(@practice_ids_json) = 1
    BEGIN
        DECLARE @active_rs INT =
            (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

        INSERT INTO grac_practice.custom_gap_practice_map
            (organization_id, custom_gap_id, practice_id, practice_name, practice_code,
             mapped_by_employee_id, record_status_id, mapped_dt)
        SELECT DISTINCT
            @organization_id, @custom_gap_id, p.practice_id, p.practice_name, p.practice_code,
            @actor_employee_id, @active_rs, SYSUTCDATETIME()
        FROM OPENJSON(@practice_ids_json) WITH (practice_id BIGINT N'$') j
        JOIN grac_practice.practice p
              ON p.practice_id = j.practice_id
             AND p.organization_id = @organization_id;
    END
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
        END                          AS IsPracticeOperationalized
      FROM grac_practice.custom_gap g
 LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
 LEFT JOIN grac_practice.custom_gap p                 ON p.custom_gap_id      = g.duplicate_of_gap_id
 LEFT JOIN grac_practice.practice_instance pi          ON pi.practice_instance_id = g.source_reference_id
                                                       AND g.source_reference_type = N'PracticeInstance'
                                                       AND pi.organization_id      = g.organization_id
 LEFT JOIN grac_practice.record_status_master pirs     ON pirs.record_status_id   = pi.record_status_id
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

IF COL_LENGTH('grac_practice.custom_gap','current_state') IS NOT NULL
    ALTER TABLE grac_practice.custom_gap DROP COLUMN current_state;
GO
IF COL_LENGTH('grac_practice.custom_gap','gap_finding') IS NOT NULL
    ALTER TABLE grac_practice.custom_gap DROP COLUMN gap_finding;
GO
SELECT '491 rollback' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.custom_gap','current_state') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_open')) NOT LIKE '%@current_state%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
GO
