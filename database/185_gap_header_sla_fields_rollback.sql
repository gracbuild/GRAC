-- =====================================================================
-- 185 gap header SLA fields -- ROLLBACK
--
-- Restores sp_custom_gap_header to the 177 shape, sp_custom_gap_apply_sla
-- to the 184 shape, and drops the sla_master_name column.
-- =====================================================================
SET NOCOUNT ON;
GO

-- Restore 177 header shape.
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
        g.invalid_reason           AS InvalidReason
      FROM grac_practice.custom_gap g
 LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
 LEFT JOIN grac_practice.custom_gap p                 ON p.custom_gap_id      = g.duplicate_of_gap_id
     WHERE g.custom_gap_id = @custom_gap_id;
END
GO

-- Restore 184 apply-sla shape (no sla_master_name snapshot).
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_apply_sla
    @custom_gap_id       BIGINT,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @custom_gap_id IS NULL
        THROW 55310, 'custom_gap_id is required.', 1;

    DECLARE @organization_id BIGINT, @severity_code NVARCHAR(30),
            @current_source NVARCHAR(30), @gap_entered_dt DATETIME2;
    SELECT @organization_id = organization_id,
           @severity_code   = severity_code,
           @current_source  = sla_source_code,
           @gap_entered_dt  = entered_dt
    FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id;

    IF @organization_id IS NULL THROW 55311, 'gap not found.', 1;
    IF @current_source = N'OVERRIDDEN' RETURN;
    IF @severity_code IS NULL OR LEN(LTRIM(RTRIM(@severity_code))) = 0 RETURN;

    DECLARE @out TABLE (
        OrgSlaConfigId BIGINT, SlaMasterId BIGINT, SlaMasterCode NVARCHAR(120),
        SlaMasterName NVARCHAR(200), TotalSlaDays INT,
        WarningPct DECIMAL(5,2), EscalationPct DECIMAL(5,2), TimeBasis NVARCHAR(60));
    INSERT @out
    EXEC grac_practice.sp_org_sla_match_for_severity @organization_id, @severity_code;

    DECLARE @sla_master_id BIGINT, @total_days INT;
    SELECT TOP 1 @sla_master_id = SlaMasterId, @total_days = TotalSlaDays FROM @out;
    IF @sla_master_id IS NULL OR @total_days IS NULL RETURN;

    UPDATE grac_practice.custom_gap
    SET sla_master_id      = @sla_master_id,
        sla_days_effective = @total_days,
        sla_source_code    = N'AUTO',
        due_date           = CASE
            WHEN due_date IS NULL
              OR due_date < DATEADD(DAY, @total_days, CAST(@gap_entered_dt AS DATE))
              THEN DATEADD(DAY, @total_days, CAST(@gap_entered_dt AS DATE))
            ELSE due_date
        END,
        updated_by         = @caller_display_name,
        updated_dt         = SYSUTCDATETIME()
    WHERE custom_gap_id = @custom_gap_id;
END
GO

-- Drop snapshot column.
IF COL_LENGTH('grac_practice.custom_gap','sla_master_name') IS NOT NULL
    ALTER TABLE grac_practice.custom_gap DROP COLUMN sla_master_name;
GO

PRINT '185 rolled back.';
GO
