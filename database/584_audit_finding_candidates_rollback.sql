-- 584 rollback  Audit Intelligence -- audit findings to Gap and Risk candidates
-- Drops the traceability trigger, the raise-risk and audit-source
-- procedures and the finding-subject function; restores
-- sp_custom_gap_generate_from_assurance_observation to its 116b body.
-- Kept: risk candidates already raised and the RISK mappings the trigger
-- made (they are ordinary data; Framework & Practice Mapping can deactivate
-- them).
SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.trg_pm_risk_candidate_audit_subject_map','TR') IS NOT NULL DROP TRIGGER grac_practice.trg_pm_risk_candidate_audit_subject_map;
IF OBJECT_ID('grac_practice.sp_org_assurance_finding_raise_risk','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_finding_raise_risk;
IF OBJECT_ID('grac_practice.sp_custom_gap_audit_source','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_custom_gap_audit_source;
IF OBJECT_ID('grac_practice.fn_org_assurance_observation_subjects') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_observation_subjects;
GO
-- sp_custom_gap_generate_from_assurance_observation: the 116b body.
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_generate_from_assurance_observation
    @organization_id BIGINT,
    @observation_id  BIGINT,
    @actor           NVARCHAR(100) = 'system',
    @custom_gap_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @observation_id IS NULL
        THROW 55010, 'organization_id and observation_id are required.', 1;

    DECLARE @obs_org BIGINT, @obs_status NVARCHAR(60), @existing_gap_id BIGINT,
            @sev_code NVARCHAR(30), @sev_name NVARCHAR(120),
            @exec_code NVARCHAR(120), @exec_name NVARCHAR(300),
            @dim_code NVARCHAR(60),   @dim_name NVARCHAR(160),
            @ent_code NVARCHAR(120),  @ent_name NVARCHAR(240),
            @obs_code NVARCHAR(120),  @obs_title NVARCHAR(300),
            @obs_desc NVARCHAR(MAX),
            @owner_id BIGINT,         @owner_name NVARCHAR(240),
            @owner_role_id BIGINT,    @owner_role_name NVARCHAR(120),
            @reviewer_id BIGINT,      @reviewer_name NVARCHAR(240),
            @reviewer_role_id BIGINT, @reviewer_role_name NVARCHAR(120),
            @due_dt DATE;

    SELECT @obs_org         = o.organization_id,
           @obs_status      = st.status_code,
           @existing_gap_id = o.gap_id,
           @sev_code        = o.severity_code,
           @sev_name        = o.severity_name,
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
           @owner_role_id   = o.assigned_owner_role_id,
           @owner_role_name = o.assigned_owner_role_name,
           @reviewer_id     = o.assigned_reviewer_employee_id,
           @reviewer_name   = o.assigned_reviewer_display_name,
           @reviewer_role_id   = o.assigned_reviewer_role_id,
           @reviewer_role_name = o.assigned_reviewer_role_name,
           @due_dt          = o.due_date
    FROM grac_practice.org_assurance_observation o
    JOIN grac_practice.org_assurance_observation_status_master st
         ON st.org_assurance_observation_status_id = o.observation_status_id
    WHERE o.org_assurance_observation_id = @observation_id AND o.is_active = 1;

    IF @obs_org IS NULL       THROW 55011, 'Observation not found.', 1;
    IF @obs_org <> @organization_id
        THROW 55012, 'Observation belongs to a different organization.', 1;
    IF @obs_status <> N'Accepted'
        THROW 55013, 'Only Accepted observations can generate a gap.', 1;

    -- Idempotent junction check.
    DECLARE @junction_gap_id BIGINT = (
        SELECT TOP 1 custom_gap_id
        FROM grac_practice.custom_gap_observation
        WHERE org_assurance_observation_id = @observation_id
          AND organization_id              = @organization_id
          AND is_active = 1
        ORDER BY linked_dt DESC, custom_gap_observation_id DESC);
    IF @junction_gap_id IS NOT NULL
    BEGIN
        SET @custom_gap_id_out = @junction_gap_id;
        RETURN;
    END

    -- Legacy pointer -- back-fill missing junction if pointer valid.
    IF @existing_gap_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM grac_practice.custom_gap
                   WHERE custom_gap_id = @existing_gap_id
                     AND organization_id = @organization_id
                     AND status <> N'Cancelled')
    BEGIN
        SET @custom_gap_id_out = @existing_gap_id;
        IF NOT EXISTS (
            SELECT 1 FROM grac_practice.custom_gap_observation
            WHERE custom_gap_id                = @existing_gap_id
              AND org_assurance_observation_id = @observation_id
              AND is_active = 1)
            INSERT INTO grac_practice.custom_gap_observation(
                custom_gap_id, org_assurance_observation_id, organization_id,
                link_source, linked_by, linked_dt, is_active)
            VALUES(
                @existing_gap_id, @observation_id, @organization_id,
                N'AUTO', @actor, SYSUTCDATETIME(), 1);
        RETURN;
    END

    DECLARE @priority NVARCHAR(30) =
        CASE @sev_code
            WHEN N'Critical'      THEN N'Critical'
            WHEN N'High'          THEN N'High'
            WHEN N'Medium'        THEN N'Medium'
            WHEN N'Low'           THEN N'Low'
            WHEN N'Informational' THEN N'Low'
            ELSE N'Medium'
        END;

    DECLARE @gap_title NVARCHAR(250) =
        LEFT(N'Gap: ' + ISNULL(@obs_title, N'(observation)'), 250);

    BEGIN TRAN;

    INSERT INTO grac_practice.custom_gap(
        organization_id, gap_type_code,
        gap_source_module_code, source_reference_type, source_reference_id,
        title, description, priority, severity_code, severity_name,
        owner_employee_id, owner_display_name,
        owner_role_id, owner_role_name,
        assigned_reviewer_employee_id, assigned_reviewer_display_name,
        assigned_reviewer_role_id, assigned_reviewer_role_name,
        due_date, target_resolution_date, status, opened_dt,
        execution_code, execution_name,
        entity_dimension_code, entity_dimension_name,
        entity_code, entity_name,
        observation_code, observation_title,
        entered_by, entered_dt)
    VALUES(
        @organization_id, N'Assurance',
        N'Assurance', N'AssuranceObservation', @observation_id,
        @gap_title, @obs_desc, @priority, @sev_code, @sev_name,
        @owner_id, @owner_name,
        @owner_role_id, @owner_role_name,
        @reviewer_id, @reviewer_name,
        @reviewer_role_id, @reviewer_role_name,
        @due_dt, @due_dt, N'Open', SYSUTCDATETIME(),
        @exec_code, @exec_name,
        @dim_code, @dim_name,
        @ent_code, @ent_name,
        @obs_code, @obs_title,
        @actor, SYSUTCDATETIME());

    SET @custom_gap_id_out = SCOPE_IDENTITY();

    INSERT INTO grac_practice.custom_gap_observation(
        custom_gap_id, org_assurance_observation_id, organization_id,
        link_source, linked_by, linked_dt, is_active)
    VALUES(
        @custom_gap_id_out, @observation_id, @organization_id,
        N'AUTO', @actor, SYSUTCDATETIME(), 1);

    UPDATE grac_practice.org_assurance_observation
    SET gap_id     = @custom_gap_id_out,
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_observation_id = @observation_id;

    INSERT INTO grac_practice.custom_gap_history(
        custom_gap_id, organization_id, action_code,
        from_status_code, to_status_code,
        reason_text, actor_display_name, entered_by)
    VALUES(
        @custom_gap_id_out, @organization_id, N'AUTO_GENERATED',
        NULL, N'Open',
        N'Auto-generated from Assurance Observation #' + CAST(@observation_id AS NVARCHAR(20)),
        @actor, @actor);

    COMMIT;
END
GO

PRINT '584 rolled back: trigger, procedures and function dropped; the gap generator back to 116b.';
GO
