-- =====================================================================
-- 187 Materialize implementation gap with severity from practice_instance
--
-- Sir's ask (2026-08-13):
--   Save the gap's severity_code AT CREATE TIME (not during analysis)
--   so sp_custom_gap_apply_sla can fire immediately and warning /
--   escalation notifications are in force even if analysis is delayed.
--
--   Sources of severity at create time:
--     * Implementation gap  -> practice_instance.criticality
--     * Assurance gap       -> org_assurance_observation.severity_code
--                              (ALREADY handled by
--                               sp_custom_gap_generate_from_assurance_observation
--                               -- see 116b line 265; nothing to change)
--     * Custom gap          -> user provides severity in the create form
--                              (ALREADY handled by sp_custom_gap_save
--                               -- 116b lines 45/149)
--
--   This migration only touches sp_custom_gap_materialize_for_instance
--   because that's the sole path where severity was previously
--   unset at create time.
--
-- Behaviour after this migration:
--   * The materialize proc SELECTs pi.criticality alongside title /
--     description / impl_status.
--   * Row is inserted with severity_code := criticality, severity_name
--     := criticality (single-source vocabulary -- the operator can
--     still change severity via the Analysis form later).
--   * priority stays 'Medium' (unrelated to severity; priority is
--     operator-driven scheduling).
--
-- API layer note: after this proc returns, the API tier calls
-- sp_custom_gap_apply_sla so the matching org_sla_config for the
-- gap's severity_code applies immediately -- exactly the behaviour
-- the API already runs after sp_custom_gap_save and
-- sp_custom_gap_analysis_save.
--
-- Rollback: 187_..._rollback.sql restores the 160 shape (no severity).
-- =====================================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_materialize_for_instance
    @practice_instance_id BIGINT,
    @organization_id      BIGINT,
    @caller_employee_id   BIGINT        = NULL,
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 55170, 'sp_custom_gap_materialize_for_instance: practice_instance_id is required.', 1;
    IF @organization_id IS NULL
        THROW 55171, 'sp_custom_gap_materialize_for_instance: organization_id is required.', 1;

    -- Idempotent lookup (unchanged from 160).
    DECLARE @existing_id BIGINT =
        (SELECT TOP 1 custom_gap_id
           FROM grac_practice.custom_gap
          WHERE source_reference_type = N'PracticeInstance'
            AND source_reference_id   = @practice_instance_id
            AND organization_id       = @organization_id
          ORDER BY custom_gap_id DESC);

    IF @existing_id IS NOT NULL
    BEGIN
        SELECT @existing_id AS CustomGapId, CAST(0 AS BIT) AS Created;
        RETURN;
    END

    -- Pull title / description / impl_status AND criticality from the
    -- instance so the new gap carries a severity from birth.
    DECLARE @title       NVARCHAR(250),
            @desc        NVARCHAR(MAX),
            @impl_status NVARCHAR(60),
            @criticality NVARCHAR(60);
    SELECT @title = LEFT(COALESCE(pi.instance_name, pi.instance_code,
                                   CONCAT(N'Practice Instance #', @practice_instance_id)), 250),
           @desc  = CONCAT(
                        N'Implementation gap materialized from Practice Instance ',
                        COALESCE(pi.instance_code, CAST(@practice_instance_id AS NVARCHAR(20))),
                        CASE WHEN pi.instance_name IS NOT NULL THEN N' -- ' + pi.instance_name ELSE N'' END,
                        N'.'),
           @impl_status = pi.implementation_status,
           @criticality = pi.criticality
      FROM grac_practice.practice_instance pi
     WHERE pi.practice_instance_id = @practice_instance_id
       AND pi.organization_id      = @organization_id;

    IF @title IS NULL
        THROW 55172, 'sp_custom_gap_materialize_for_instance: practice instance not found in this organization.', 1;

    DECLARE @new_state_id INT =
        (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'New');
    IF @new_state_id IS NULL
        THROW 55173, 'sp_custom_gap_materialize_for_instance: state master missing the New state (run 158 seed).', 1;

    -- Severity: copy criticality verbatim. Vocabulary alignment (Critical
    -- / High / Standard vs Low / Medium / High / Critical) is the SLA
    -- master's job -- if no classification matches, apply_sla silently
    -- no-ops and the operator can retune severity via analysis.
    DECLARE @severity_code NVARCHAR(30)  = LEFT(ISNULL(@criticality, N''), 30);
    DECLARE @severity_name NVARCHAR(120) = @criticality;
    IF LEN(LTRIM(RTRIM(@severity_code))) = 0
    BEGIN
        SET @severity_code = NULL;
        SET @severity_name = NULL;
    END

    DECLARE @new_id BIGINT = NULL;

    BEGIN TRY
        BEGIN TRAN;

        INSERT INTO grac_practice.custom_gap
            (organization_id, gap_type_code, title, description,
             priority, status,
             severity_code, severity_name,
             gap_source_module_code, source_reference_type, source_reference_id,
             lifecycle_state_id,
             entered_by, entered_dt)
        VALUES
            (@organization_id, N'Implementation', @title, @desc,
             N'Medium', N'Open',
             @severity_code, @severity_name,
             N'Implementation', N'PracticeInstance', @practice_instance_id,
             @new_state_id,
             @caller_display_name, SYSUTCDATETIME());

        SET @new_id = SCOPE_IDENTITY();

        IF @new_id IS NOT NULL AND OBJECT_ID('grac_practice.custom_gap_history','U') IS NOT NULL
        BEGIN
            INSERT INTO grac_practice.custom_gap_history
                (custom_gap_id, organization_id, action_code,
                 from_status_code, to_status_code, reason_text,
                 actor_display_name, entered_by, entered_dt)
            VALUES
                (@new_id, @organization_id, N'Materialize',
                 NULL, N'New',
                 CONCAT(N'Materialized from PracticeInstance #', @practice_instance_id,
                        CASE WHEN @impl_status IS NOT NULL THEN N' (impl_status=' + @impl_status + N')' ELSE N'' END,
                        CASE WHEN @severity_code IS NOT NULL THEN N' (severity=' + @severity_code + N')' ELSE N'' END),
                 @caller_display_name, @caller_display_name, SYSUTCDATETIME());
        END

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @new_id AS CustomGapId, CAST(1 AS BIT) AS Created;
END
GO

PRINT '187 materialize proc: severity now copied from practice_instance.criticality.';
GO
