-- =====================================================================
-- 185 Expose SLA fields on the gap header (unblocks 184's Override UI)
--
-- BACKGROUND
--   Migration 184 added sla_master_id / sla_days_effective /
--   sla_source_code to custom_gap and taught the API to auto-apply an
--   SLA on gap create / analysis save. The gap-detail UI card
--   (`gapSlaCard`) reads these off the gap header response, but
--   sp_custom_gap_header (last rewritten in 177) does not return
--   them yet, so the card stays hidden and the Override button never
--   shows.
--
--   This migration:
--     * ADDs custom_gap.sla_master_name -- snapshot of the master's
--       classification / code at apply time, so the header proc does
--       not need to JOIN grac_new.sla_master at read time (keeps
--       Practice Management decoupled from Control Management on
--       hot reads).
--     * REWRITES sp_custom_gap_apply_sla to also snapshot the name.
--     * REWRITES sp_custom_gap_header to emit the SLA columns plus a
--       computed SlaOverridePending flag.
--
-- ROLLBACK: 185_gap_header_sla_fields_rollback.sql restores the 177
-- header proc and the 184 apply proc, and drops the snapshot column.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_sla_match_for_severity','P') IS NULL
BEGIN
    RAISERROR('185: run 178/184 first.', 16, 1);
    RETURN;
END
GO

-- 1. sla_master_name snapshot on custom_gap (idempotent).
IF COL_LENGTH('grac_practice.custom_gap','sla_master_name') IS NULL
    ALTER TABLE grac_practice.custom_gap ADD sla_master_name NVARCHAR(200) NULL;
GO

-- 2. sp_custom_gap_apply_sla -- also snapshot sla_master_name.
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
    FROM grac_practice.custom_gap
    WHERE custom_gap_id = @custom_gap_id;

    IF @organization_id IS NULL
        THROW 55311, 'gap not found.', 1;

    IF @current_source = N'OVERRIDDEN' RETURN;
    IF @severity_code IS NULL OR LEN(LTRIM(RTRIM(@severity_code))) = 0 RETURN;

    DECLARE @out TABLE (
        OrgSlaConfigId BIGINT, SlaMasterId BIGINT, SlaMasterCode NVARCHAR(120),
        SlaMasterName NVARCHAR(200), TotalSlaDays INT,
        WarningPct DECIMAL(5,2), EscalationPct DECIMAL(5,2), TimeBasis NVARCHAR(60));

    INSERT @out
    EXEC grac_practice.sp_org_sla_match_for_severity
        @organization_id = @organization_id,
        @severity_code   = @severity_code;

    DECLARE @sla_master_id BIGINT, @sla_master_name NVARCHAR(200), @total_days INT;
    SELECT TOP 1
        @sla_master_id   = SlaMasterId,
        @sla_master_name = SlaMasterName,
        @total_days      = TotalSlaDays
    FROM @out;

    IF @sla_master_id IS NULL OR @total_days IS NULL RETURN;

    UPDATE grac_practice.custom_gap
    SET sla_master_id      = @sla_master_id,
        sla_master_name    = @sla_master_name,
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

-- 3. sp_custom_gap_header -- extend with SLA columns + override-pending flag.
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
        g.invalid_reason           AS InvalidReason,
        -- Migration 185 -- SLA snapshot + override-pending flag so the
        -- gap-detail card can render the Override button.
        g.sla_master_id            AS SlaMasterId,
        g.sla_master_name          AS SlaMasterName,
        g.sla_days_effective       AS SlaDaysEffective,
        g.sla_source_code          AS SlaSourceCode,
        CAST(CASE WHEN EXISTS (
                SELECT 1 FROM grac_practice.exception_request er
                WHERE er.custom_gap_id     = g.custom_gap_id
                  AND er.request_type_code = N'SLA_CANDIDATE'
                  AND er.status_code       = N'Pending')
             THEN 1 ELSE 0 END AS BIT)  AS SlaOverridePending
      FROM grac_practice.custom_gap g
 LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
 LEFT JOIN grac_practice.custom_gap p                 ON p.custom_gap_id      = g.duplicate_of_gap_id
     WHERE g.custom_gap_id = @custom_gap_id;
END
GO

PRINT '185 gap header extended with SLA fields.';
GO
