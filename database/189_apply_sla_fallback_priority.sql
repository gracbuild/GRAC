-- =====================================================================
-- 189 sp_custom_gap_apply_sla: fall back to priority when severity_code is null
--
-- Sir's observation (2026-08-14):
--   Custom gap create form only asks for priority (Low/Medium/High/
--   Critical). severity_code stays NULL, so sp_custom_gap_apply_sla
--   has nothing to match on and no SLA is auto-assigned.
--
-- Instead of adding a second dropdown on the custom-gap create UI
-- (redundant with priority), have apply_sla treat priority as the
-- severity source when severity_code is missing. This also
-- retroactively rescues legacy gaps (created before 187/188) whose
-- severity was never populated.
--
-- Behaviour:
--   1. If severity_code is set on the gap -> use it (unchanged).
--   2. Else if priority is set -> use priority as the severity to
--      match. If a match lands, WRITE severity_code = priority back
--      to the gap so the header renders the right value on next
--      load and future re-runs skip the fallback branch.
--   3. sla_source_code = 'OVERRIDDEN' still short-circuits the
--      whole proc (operator overrides win).
--
-- Rollback: 189_..._rollback.sql restores the 187-shape apply_sla.
-- =====================================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_apply_sla
    @custom_gap_id       BIGINT,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @custom_gap_id IS NULL
        THROW 55310, 'custom_gap_id is required.', 1;

    DECLARE @organization_id BIGINT,
            @severity_code   NVARCHAR(30),
            @priority        NVARCHAR(30),
            @current_source  NVARCHAR(30),
            @gap_entered_dt  DATETIME2;

    SELECT @organization_id = organization_id,
           @severity_code   = severity_code,
           @priority        = priority,
           @current_source  = sla_source_code,
           @gap_entered_dt  = entered_dt
    FROM grac_practice.custom_gap
    WHERE custom_gap_id = @custom_gap_id;

    IF @organization_id IS NULL
        THROW 55311, 'gap not found.', 1;

    -- Operator override wins.
    IF @current_source = N'OVERRIDDEN' RETURN;

    -- Priority fallback: custom gap creates leave severity null but
    -- always set priority. Treat priority as the severity to match on.
    -- Track whether the value came from the fallback so we can
    -- backfill severity_code on the gap after a successful match.
    DECLARE @sev_for_match NVARCHAR(30) = @severity_code;
    DECLARE @used_priority_fallback BIT = 0;
    IF @sev_for_match IS NULL OR LEN(LTRIM(RTRIM(@sev_for_match))) = 0
    BEGIN
        SET @sev_for_match = @priority;
        SET @used_priority_fallback = 1;
    END

    -- Nothing to match on -> silent no-op.
    IF @sev_for_match IS NULL OR LEN(LTRIM(RTRIM(@sev_for_match))) = 0 RETURN;

    DECLARE @out TABLE (
        OrgSlaConfigId BIGINT, SlaMasterId BIGINT, SlaMasterCode NVARCHAR(120),
        SlaMasterName NVARCHAR(200), TotalSlaDays INT,
        WarningPct DECIMAL(5,2), EscalationPct DECIMAL(5,2), TimeBasis NVARCHAR(60));

    INSERT @out
    EXEC grac_practice.sp_org_sla_match_for_severity
        @organization_id = @organization_id,
        @severity_code   = @sev_for_match;

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
        -- Backfill severity_code from priority when that's what we
        -- matched on, so the gap header + future apply_sla runs see
        -- the concrete severity.
        severity_code      = CASE WHEN @used_priority_fallback = 1
                                    AND (severity_code IS NULL
                                      OR LEN(LTRIM(RTRIM(severity_code))) = 0)
                                  THEN @sev_for_match
                                  ELSE severity_code END,
        severity_name      = CASE WHEN @used_priority_fallback = 1
                                    AND (severity_name IS NULL
                                      OR LEN(LTRIM(RTRIM(severity_name))) = 0)
                                  THEN @sev_for_match
                                  ELSE severity_name END,
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

PRINT '189 sp_custom_gap_apply_sla: priority fallback wired.';
GO
