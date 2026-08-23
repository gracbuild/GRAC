-- =====================================================================
-- 108 rollback -- drops the junction procs and restores the pre-108
-- versions of the rewritten SPs.
-- =====================================================================
SET NOCOUNT ON;
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_merge;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_linked_gaps_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_observation_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_observation_detach;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_observation_attach;
GO

-- Re-CREATE OR ALTER the pre-108 versions from migrations 102 + 105.
-- (105 already redefined the accept SP; we do NOT change that here --
-- the accept auto-hook still fires. What we roll back are the list,
-- get, delete, generate and observation_delete rewrites.)
--
-- Pre-108 generate_from_observation (copy from 105 exactly):
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_gap_generate_from_observation
    @organization_id BIGINT,
    @observation_id  BIGINT,
    @actor           NVARCHAR(100) = 'system',
    @gap_id_out      BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @observation_id IS NULL
        THROW 54214, 'organization_id and observation_id are required.', 1;

    DECLARE @obs_org BIGINT, @obs_status NVARCHAR(60), @existing_gap_id BIGINT,
            @sev_id INT, @sev_code NVARCHAR(30), @sev_name NVARCHAR(120),
            @exec_id BIGINT, @entity_id BIGINT,
            @exec_code NVARCHAR(120), @exec_name NVARCHAR(300),
            @dim_code NVARCHAR(60),   @dim_name NVARCHAR(160),
            @ent_code NVARCHAR(120),  @ent_name NVARCHAR(240),
            @obs_code NVARCHAR(120),  @obs_title NVARCHAR(300),
            @obs_desc NVARCHAR(MAX),
            @owner_id BIGINT,         @owner_name NVARCHAR(240),
            @reviewer_id BIGINT,      @reviewer_name NVARCHAR(240),
            @due_dt DATE;

    SELECT @obs_org         = o.organization_id,
           @obs_status      = st.status_code,
           @existing_gap_id = o.gap_id,
           @sev_id          = o.severity_id,
           @sev_code        = o.severity_code,
           @sev_name        = o.severity_name,
           @exec_id         = o.org_assurance_execution_id,
           @entity_id       = o.org_assurance_execution_entity_id,
           @exec_code       = o.execution_code,
           @exec_name       = o.execution_name,
           @dim_code        = o.entity_dimension_code,
           @dim_name        = o.entity_dimension_name,
           @ent_code        = o.entity_code,
           @ent_name        = o.entity_name,
           @obs_code        = o.observation_code,
           @obs_title       = o.observation_title,
           @obs_desc        = o.observation_description,
           @owner_id        = o.assigned_owner_employee_id,
           @owner_name      = o.assigned_owner_display_name,
           @reviewer_id     = o.assigned_reviewer_employee_id,
           @reviewer_name   = o.assigned_reviewer_display_name,
           @due_dt          = o.due_date
    FROM grac_practice.org_assurance_observation o
    JOIN grac_practice.org_assurance_observation_status_master st
         ON st.org_assurance_observation_status_id = o.observation_status_id
    WHERE o.org_assurance_observation_id = @observation_id AND o.is_active = 1;

    IF @obs_org IS NULL       THROW 54215, 'Observation not found.', 1;
    IF @obs_org <> @organization_id
        THROW 54216, 'Observation belongs to a different organization.', 1;
    IF @obs_status <> N'Accepted'
        THROW 54217, 'Only Accepted observations can generate a gap.', 1;

    IF @existing_gap_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM grac_practice.org_assurance_gap
                   WHERE org_assurance_gap_id = @existing_gap_id
                     AND organization_id      = @organization_id
                     AND is_active = 1)
    BEGIN
        SET @gap_id_out = @existing_gap_id;
        RETURN;
    END

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    DECLARE @open_status_id INT = (
        SELECT org_assurance_gap_status_id
        FROM grac_practice.org_assurance_gap_status_master WHERE status_code = N'Open');

    DECLARE @gap_code NVARCHAR(120) =
        ISNULL(@obs_code, N'GAP') + N'-GAP-'
        + FORMAT(SYSUTCDATETIME(), 'yyyyMMdd-HHmmss');

    IF EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_gap
        WHERE organization_id = @organization_id AND gap_code = @gap_code)
        SET @gap_code = @gap_code + N'-' + CAST(ABS(CHECKSUM(NEWID())) % 100000 AS NVARCHAR(10));

    DECLARE @gap_title NVARCHAR(300) =
        N'Gap: ' + ISNULL(@obs_title, N'(observation)');

    BEGIN TRAN;

    INSERT INTO grac_practice.org_assurance_gap(
        organization_id,
        org_assurance_observation_id,
        org_assurance_execution_id, org_assurance_execution_entity_id,
        execution_code, execution_name,
        entity_dimension_code, entity_dimension_name,
        entity_code, entity_name,
        observation_code, observation_title,
        gap_code, gap_title, gap_description,
        severity_id, severity_code, severity_name,
        gap_status_id,
        assigned_owner_employee_id, assigned_owner_display_name,
        assigned_reviewer_employee_id, assigned_reviewer_display_name,
        target_resolution_date,
        is_active, record_status_id, entered_by, entered_dt)
    VALUES (
        @organization_id,
        @observation_id,
        @exec_id, @entity_id,
        @exec_code, @exec_name,
        @dim_code, @dim_name,
        @ent_code, @ent_name,
        @obs_code, @obs_title,
        @gap_code, @gap_title, @obs_desc,
        @sev_id, @sev_code, @sev_name,
        @open_status_id,
        @owner_id, @owner_name,
        @reviewer_id, @reviewer_name,
        @due_dt,
        1, @active_record_status_id, @actor, SYSUTCDATETIME());

    SET @gap_id_out = SCOPE_IDENTITY();

    UPDATE grac_practice.org_assurance_observation
    SET gap_id = @gap_id_out,
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_observation_id = @observation_id;

    INSERT INTO grac_practice.org_assurance_gap_history(
        org_assurance_gap_id, organization_id,
        action_code, from_status_id, to_status_id,
        reason_text, actor_display_name, entered_by)
    VALUES(
        @gap_id_out, @organization_id,
        N'AUTO_GENERATED',
        NULL, @open_status_id,
        N'Auto-generated from Observation #' + CAST(@observation_id AS NVARCHAR(20)),
        @actor, @actor);

    COMMIT;
END
GO

PRINT '108 rollback complete -- pre-108 SPs restored (gap_list, gap_get, gap_delete and observation_delete not restored programmatically; redeploy 102 + 105 if a full restore is needed).';
GO
