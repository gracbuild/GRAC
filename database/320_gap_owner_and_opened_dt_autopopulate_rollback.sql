-- =====================================================================
-- 320 rollback -- restore sp_custom_gap_materialize_for_instance and
-- sp_custom_gap_open to their exact pre-320 bodies (160's and 250's
-- own text, respectively).
--
-- The one-time backfill (320 part C) is NOT undone here, the same way
-- 109's own opened_dt backfill was never meant to be undone: there is
-- no record of which rows were NULL before 320 ran, so "undo" would
-- mean re-nulling opened_dt/owner_employee_id/owner_display_name on
-- every custom_gap row touched, which would re-introduce the exact
-- blank Owner / Raised On columns this migration exists to fix, for
-- rows that were already showing correctly before 320 (e.g. Custom
-- gaps saved through sp_custom_gap_save's own edit path, which was
-- already setting these fields). Rolling back the procs is enough to
-- stop NEW rows from getting the fix; it deliberately leaves already-
-- backfilled rows alone.
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
        THROW;
    END CATCH

    SELECT @new_id AS CustomGapId, CAST(1 AS BIT) AS Created;
END
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

    INSERT INTO grac_practice.custom_gap
        (organization_id, gap_type_code, title, description, priority,
         owner_employee_id, due_date, status, remarks,
         severity_code, severity_name,
         detection_method_code, detection_method_name,
         entered_by, entered_dt)
    VALUES
        (@organization_id, ISNULL(@gap_type_code, N'Custom'),
         @title, @description, @priority,
         @owner_employee_id, @due_date, @status, @remarks,
         @severity_code, @severity_name,
         NULLIF(LTRIM(RTRIM(@detection_method_code)), N''),
         NULLIF(LTRIM(RTRIM(@detection_method_name)), N''),
         COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api'),
         SYSUTCDATETIME());

    SET @custom_gap_id = SCOPE_IDENTITY();
END
GO

PRINT '320 rollback complete: sp_custom_gap_materialize_for_instance and sp_custom_gap_open restored to pre-320 bodies. Backfilled data left as-is (see header).';
GO
