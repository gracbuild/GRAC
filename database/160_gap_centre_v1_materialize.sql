-- =====================================================================
-- 160 Gap Centre v1 -- materialize custom_gap from a practice_instance
--
-- WHY THIS EXISTS
-- ---------------
-- The Gap Centre v1 lifecycle engine sits on custom_gap. But the
-- Implementation tab of the existing Gap Centre lists PRACTICE INSTANCE
-- rows (instances whose implementation_status is incomplete), which are
-- not custom_gap rows -- they never went through custom_gap because
-- Implementation is a live status, not a raised defect.
--
-- Per AES sec 2 all gap categories (Practice / Assurance / Obligation /
-- Custom) need lifecycle. This proc materializes the missing row the
-- first time an Implementation gap enters the lifecycle:
--   - If a custom_gap already exists for this practice_instance
--     (source_reference_type='PracticeInstance', source_reference_id=id),
--     return it -- idempotent, no duplicates.
--   - Otherwise create one with source traceability, initial state=New,
--     mirrored title/description from the instance for readability.
--
-- The returned CustomGapId is what the UI navigates to for gap-detail.
--
-- ERROR CODE RANGE: 55170-55179.
--
-- Depends on 054, 109, 110, 156. Rollback: 160_gap_centre_v1_materialize_rollback.sql.
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

    -- Idempotent lookup first. Match on the source-reference pair the
    -- 109 extension added -- that pair is the canonical "who raised
    -- this gap" pointer, independent of gap_source_module_code casing.
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

    -- Pull a sensible title and severity hint from the instance itself.
    -- LEFT JOIN so we still work if practice_instance doesn't have the
    -- optional columns in some future refactor.
    DECLARE @title NVARCHAR(250), @desc NVARCHAR(MAX), @impl_status NVARCHAR(60);
    SELECT @title = LEFT(COALESCE(pi.instance_name, pi.instance_code, CONCAT(N'Practice Instance #', @practice_instance_id)), 250),
           @desc  = CONCAT(
                        N'Implementation gap materialized from Practice Instance ',
                        COALESCE(pi.instance_code, CAST(@practice_instance_id AS NVARCHAR(20))),
                        CASE WHEN pi.instance_name IS NOT NULL THEN N' -- ' + pi.instance_name ELSE N'' END,
                        N'.'),
           @impl_status = pi.implementation_status
      FROM grac_practice.practice_instance pi
     WHERE pi.practice_instance_id = @practice_instance_id
       AND pi.organization_id      = @organization_id;

    IF @title IS NULL
        THROW 55172, 'sp_custom_gap_materialize_for_instance: practice instance not found in this organization.', 1;

    DECLARE @new_state_id INT =
        (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'New');
    IF @new_state_id IS NULL
        THROW 55173, 'sp_custom_gap_materialize_for_instance: state master missing the New state (run 158 seed).', 1;

    DECLARE @active_rs_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    -- gap_source_module_code must be one of the values enforced by
    -- ck_pm_custom_gap_source_module (Implementation / Assurance /
    -- Custom / Exception / Risk / Audit). For a practice-instance
    -- derived gap the correct code is Implementation.
    DECLARE @new_id BIGINT = NULL;

    BEGIN TRY
        BEGIN TRAN;

        INSERT INTO grac_practice.custom_gap
            (organization_id, gap_type_code, title, description,
             priority, status,
             gap_source_module_code, source_reference_type, source_reference_id,
             lifecycle_state_id,
             entered_by, entered_dt)
        VALUES
            (@organization_id, N'Implementation', @title, @desc,
             N'Medium', N'Open',
             N'Implementation', N'PracticeInstance', @practice_instance_id,
             @new_state_id,
             @caller_display_name, SYSUTCDATETIME());

        SET @new_id = SCOPE_IDENTITY();

        -- History only if the parent insert succeeded (SCOPE_IDENTITY
        -- would be NULL otherwise -- and history.custom_gap_id is NOT NULL).
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
                        CASE WHEN @impl_status IS NOT NULL THEN N' (impl_status=' + @impl_status + N')' ELSE N'' END),
                 @caller_display_name, @caller_display_name, SYSUTCDATETIME());
        END

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        -- Surface the underlying error to the caller so the UI can
        -- show what actually broke (CHECK constraint, missing column,
        -- FK violation, ...). No history row gets left behind.
        THROW;
    END CATCH

    SELECT @new_id AS CustomGapId, CAST(1 AS BIT) AS Created;
END
GO

PRINT '160 Gap Centre materialize proc ready.';
GO
