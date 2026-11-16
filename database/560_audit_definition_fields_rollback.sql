-- =====================================================================
-- 560 ROLLBACK  Audit Definition refinements
--
-- Puts sp_org_assurance_definition_save and
-- sp_org_assurance_definition_version_copy_config back to their 551 bodies
-- and sp_org_assurance_definition_get back to its 119 body, and drops
-- sp_org_assurance_approach_list.
-- KEPT: org_assurance_approach_master, org_assurance_mandate_master,
-- org_assurance_definition_framework
-- and the new definition version columns, so nothing saved is lost; the
-- page simply stops showing and saving them. Re-run 560 to bring them back.
-- Deploy with the previous Api / Web build. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_approach_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_approach_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_mandate_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_mandate_list;
GO

-- save: 551 body
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_save
    @organization_id            BIGINT,
    @definition_id              BIGINT        = NULL,
    @definition_code            NVARCHAR(80),
    @definition_name            NVARCHAR(240),
    @owner_role_id              BIGINT        = NULL,   -- 119
    @owner_role_name            NVARCHAR(120) = NULL,   -- 119
    @owner_employee_id          BIGINT        = NULL,
    @owner_display_name         NVARCHAR(240) = NULL,
    @description                NVARCHAR(MAX) = NULL,
    @objective                  NVARCHAR(MAX) = NULL,
    @effective_date             DATE          = NULL,
    @assurance_category_id      BIGINT        = NULL,
    @assurance_category_code    NVARCHAR(120) = NULL,
    @assurance_category_name    NVARCHAR(200) = NULL,
    @actor                      NVARCHAR(100) = 'system',
    @definition_id_out          BIGINT OUTPUT,
    @definition_version_id_out  BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 53601, 'organization_id is required.', 1;
    IF @definition_code IS NULL OR LEN(LTRIM(RTRIM(@definition_code))) = 0
        THROW 53603, 'definition_code is required.', 1;
    IF @definition_name IS NULL OR LEN(LTRIM(RTRIM(@definition_name))) = 0
        THROW 53604, 'definition_name is required.', 1;

    -- ==========================================================
    -- 119 hybrid ownership resolver -- Owner (single owner field)
    -- ==========================================================
    IF @owner_role_id IS NOT NULL
       AND (@owner_role_name IS NULL OR LEN(LTRIM(RTRIM(@owner_role_name))) = 0)
        SELECT @owner_role_name = role_name
        FROM grac_practice.organization_role
        WHERE role_id = @owner_role_id AND organization_id = @organization_id;

    IF @owner_role_id IS NOT NULL AND @owner_employee_id IS NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id   = @organization_id,
             @role_id           = @owner_role_id,
             @employee_id_out   = @owner_employee_id  OUTPUT,
             @employee_name_out = @owner_display_name OUTPUT;

    IF @owner_employee_id IS NOT NULL AND @owner_role_id IS NULL
    BEGIN
        SELECT @owner_role_id   = e.role_id,
               @owner_role_name = r.role_name
        FROM grac_practice.organization_employee e
        LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
        WHERE e.employee_id = @owner_employee_id
          AND e.organization_id = @organization_id;
    END

    IF @owner_employee_id IS NOT NULL
       AND (@owner_display_name IS NULL OR LEN(LTRIM(RTRIM(@owner_display_name))) = 0)
        SELECT @owner_display_name = employee_name
        FROM grac_practice.organization_employee
        WHERE employee_id = @owner_employee_id;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    DECLARE @draft_status_id INT = (
        SELECT org_assurance_status_id
        FROM grac_practice.org_assurance_status_master
        WHERE status_code = N'Draft');

    BEGIN TRAN;

    IF @definition_id IS NULL
    BEGIN
        -- New definition
        IF EXISTS (
            SELECT 1 FROM grac_practice.org_assurance_definition
            WHERE organization_id = @organization_id
              AND definition_code = @definition_code
              AND is_active = 1)
        BEGIN
            ROLLBACK;
            THROW 53605, 'A definition with this code already exists in the organization.', 1;
        END

        INSERT INTO grac_practice.org_assurance_definition
            (organization_id, definition_code, definition_name,
             owner_role_id, owner_role_name,
             owner_employee_id, owner_display_name,
             current_version_id, current_status_id, active_version_id,
             is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@organization_id, @definition_code, @definition_name,
             @owner_role_id, @owner_role_name,
             @owner_employee_id, @owner_display_name,
             NULL, @draft_status_id, NULL,
             1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @definition_id_out = SCOPE_IDENTITY();

        INSERT INTO grac_practice.org_assurance_definition_version
            (org_assurance_definition_id, organization_id, version_number, version_label,
             description, objective, effective_date,
             assurance_category_id, assurance_category_code, assurance_category_name,
             status_id, is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@definition_id_out, @organization_id, 1, N'1.0',
             @description, @objective, @effective_date,
             @assurance_category_id, @assurance_category_code, @assurance_category_name,
             @draft_status_id, 1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @definition_version_id_out = SCOPE_IDENTITY();

        UPDATE grac_practice.org_assurance_definition
        SET current_version_id = @definition_version_id_out,
            updated_by = @actor,
            updated_dt = SYSUTCDATETIME()
        WHERE org_assurance_definition_id = @definition_id_out;

        INSERT INTO grac_practice.org_assurance_definition_history
            (org_assurance_definition_id, org_assurance_definition_version_id,
             organization_id, action_code, from_status_id, to_status_id,
             actor_display_name, entered_by)
        VALUES
            (@definition_id_out, @definition_version_id_out, @organization_id,
             N'CREATE', NULL, @draft_status_id, @actor, @actor);
    END
    ELSE
    BEGIN
        -- Existing definition -- validate org ownership + branch on version status
        DECLARE @current_version_id BIGINT,
                @current_status_code NVARCHAR(60),
                @current_status_id   INT,
                @next_version_number INT,
                @def_org             BIGINT;

        SELECT @def_org             = d.organization_id,
               @current_version_id  = d.current_version_id,
               @current_status_id   = d.current_status_id,
               @current_status_code = s.status_code
        FROM grac_practice.org_assurance_definition d
        JOIN grac_practice.org_assurance_status_master s
             ON s.org_assurance_status_id = d.current_status_id
        WHERE d.org_assurance_definition_id = @definition_id
          AND d.is_active = 1;

        IF @def_org IS NULL
        BEGIN
            ROLLBACK;
            THROW 53606, 'Definition not found.', 1;
        END
        IF @def_org <> @organization_id
        BEGIN
            ROLLBACK;
            THROW 53607, 'Definition belongs to a different organization.', 1;
        END

        SET @definition_id_out = @definition_id;

        IF @current_status_code IN (N'UnderReview', N'Approved')
        BEGIN
            ROLLBACK;
            THROW 53608, 'Cannot edit a definition that is Under Review or Approved. Withdraw the review first or activate + create a new draft.', 1;
        END

        IF @current_status_code = N'Draft'
        BEGIN
            -- In-place update of the existing draft version.
            UPDATE grac_practice.org_assurance_definition_version
            SET description             = @description,
                objective               = @objective,
                effective_date          = @effective_date,
                assurance_category_id   = @assurance_category_id,
                assurance_category_code = @assurance_category_code,
                assurance_category_name = @assurance_category_name,
                updated_by              = @actor,
                updated_dt              = SYSUTCDATETIME()
            WHERE org_assurance_definition_version_id = @current_version_id;

            UPDATE grac_practice.org_assurance_definition
            SET definition_name    = @definition_name,
                owner_role_id      = @owner_role_id,        -- 119
                owner_role_name    = @owner_role_name,      -- 119
                owner_employee_id  = @owner_employee_id,
                owner_display_name = @owner_display_name,
                updated_by         = @actor,
                updated_dt         = SYSUTCDATETIME()
            WHERE org_assurance_definition_id = @definition_id;

            SET @definition_version_id_out = @current_version_id;

            INSERT INTO grac_practice.org_assurance_definition_history
                (org_assurance_definition_id, org_assurance_definition_version_id,
                 organization_id, action_code, from_status_id, to_status_id,
                 actor_display_name, entered_by)
            VALUES
                (@definition_id, @current_version_id, @organization_id,
                 N'EDIT', @current_status_id, @current_status_id, @actor, @actor);
        END
        ELSE
        BEGIN
            -- Active or Retired -- create a new Draft version.
            SELECT @next_version_number = ISNULL(MAX(version_number), 0) + 1
            FROM grac_practice.org_assurance_definition_version
            WHERE org_assurance_definition_id = @definition_id;

            INSERT INTO grac_practice.org_assurance_definition_version
                (org_assurance_definition_id, organization_id, version_number,
                 version_label, description, objective, effective_date,
                 assurance_category_id, assurance_category_code, assurance_category_name,
                 status_id, is_active, record_status_id, entered_by, entered_dt)
            VALUES
                (@definition_id, @organization_id, @next_version_number,
                 CAST(@next_version_number AS NVARCHAR(20)) + N'.0',
                 @description, @objective, @effective_date,
                 @assurance_category_id, @assurance_category_code, @assurance_category_name,
                 @draft_status_id, 1, @active_record_status_id, @actor, SYSUTCDATETIME());

            SET @definition_version_id_out = SCOPE_IDENTITY();

            -- 551: the new Draft version carries the configuration of the
            -- version it revises (scope, question sets, workflow, scoring);
            -- it started empty before.
            EXEC grac_practice.sp_org_assurance_definition_version_copy_config
                 @organization_id = @organization_id,
                 @from_version_id = @current_version_id,
                 @to_version_id   = @definition_version_id_out,
                 @actor           = @actor;

            UPDATE grac_practice.org_assurance_definition
            SET definition_name    = @definition_name,
                owner_role_id      = @owner_role_id,        -- 119
                owner_role_name    = @owner_role_name,      -- 119
                owner_employee_id  = @owner_employee_id,
                owner_display_name = @owner_display_name,
                current_version_id = @definition_version_id_out,
                current_status_id  = @draft_status_id,
                updated_by         = @actor,
                updated_dt         = SYSUTCDATETIME()
            WHERE org_assurance_definition_id = @definition_id;

            INSERT INTO grac_practice.org_assurance_definition_history
                (org_assurance_definition_id, org_assurance_definition_version_id,
                 organization_id, action_code, from_status_id, to_status_id,
                 actor_display_name, entered_by)
            VALUES
                (@definition_id, @definition_version_id_out, @organization_id,
                 N'CREATE', @current_status_id, @draft_status_id, @actor, @actor);
        END
    END

    COMMIT;
END
GO

-- get: 119 body
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_get
    @organization_id BIGINT,
    @definition_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;

    SELECT d.org_assurance_definition_id AS DefinitionId,
           d.organization_id             AS OrganizationId,
           d.definition_code             AS DefinitionCode,
           d.definition_name             AS DefinitionName,
           d.owner_role_id               AS OwnerRoleId,
           d.owner_role_name             AS OwnerRoleName,
           d.owner_employee_id           AS OwnerEmployeeId,
           d.owner_display_name          AS OwnerDisplayName,
           d.current_version_id          AS CurrentVersionId,
           d.active_version_id           AS ActiveVersionId,
           s.status_code                 AS CurrentStatusCode,
           s.status_name                 AS CurrentStatusName,
           s.is_terminal                 AS CurrentStatusIsTerminal,
           v.version_number              AS CurrentVersionNumber,
           v.version_label               AS CurrentVersionLabel,
           v.description                 AS Description,
           v.objective                   AS Objective,
           v.effective_date              AS EffectiveDate,
           v.assurance_category_id       AS AssuranceCategoryId,
           v.assurance_category_code     AS AssuranceCategoryCode,
           v.assurance_category_name     AS AssuranceCategoryName,
           v.submitted_by                AS SubmittedBy,
           v.submitted_dt                AS SubmittedDt,
           v.approved_by                 AS ApprovedBy,
           v.approved_dt                 AS ApprovedDt,
           v.activated_by                AS ActivatedBy,
           v.activated_dt                AS ActivatedDt,
           v.retired_by                  AS RetiredBy,
           v.retired_dt                  AS RetiredDt,
           d.entered_by                  AS EnteredBy,
           d.entered_dt                  AS EnteredDt,
           d.updated_by                  AS UpdatedBy,
           d.updated_dt                  AS UpdatedDt
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    LEFT JOIN grac_practice.org_assurance_definition_version v
         ON v.org_assurance_definition_version_id = d.current_version_id
    WHERE d.organization_id = @organization_id
      AND d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;
END
GO

-- copy_config: 551 body
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_version_copy_config
    @organization_id  BIGINT,
    @from_version_id  BIGINT,
    @to_version_id    BIGINT,
    @swap_root_set_id BIGINT        = NULL,
    @swap_to_set_id   BIGINT        = NULL,
    @actor            NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @from_version_id IS NULL OR @to_version_id IS NULL OR @from_version_id = @to_version_id
        THROW 53849, 'Copy failed: two different versions are required.', 1;

    CREATE TABLE #cfg_group (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);
    CREATE TABLE #cfg_cond  (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);
    CREATE TABLE #cfg_wf    (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);
    CREATE TABLE #cfg_sc    (old_id BIGINT NOT NULL, new_id BIGINT NOT NULL);

    -- Scope
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scope_group', @key_column = N'scope_group_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @map_table = N'#cfg_group', @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scope_condition', @key_column = N'scope_condition_id',
         @where = N'src.is_active = 1',
         @source_join = N'JOIN #cfg_group m ON m.old_id = src.scope_group_id', @source_extra = N', m.new_id AS parent_new_id',
         @overrides = N'{"scope_group_id":"src.parent_new_id"}',
         @map_table = N'#cfg_cond', @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scope_condition_value', @key_column = N'scope_condition_value_id',
         @where = N'src.is_active = 1',
         @source_join = N'JOIN #cfg_cond m ON m.old_id = src.scope_condition_id', @source_extra = N', m.new_id AS parent_new_id',
         @overrides = N'{"scope_condition_id":"src.parent_new_id"}',
         @p_actor = @actor;

    -- Question sets (one family optionally moved to a new set version)
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_definition_question_set', @key_column = N'org_assurance_definition_question_set_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @source_join = N'LEFT JOIN grac_practice.org_assurance_question_set f ON f.org_assurance_question_set_id = src.org_assurance_question_set_id',
         @source_extra = N', f.root_question_set_id AS set_root_id',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version","org_assurance_question_set_id":"CASE WHEN @p_root IS NOT NULL AND src.set_root_id = @p_root THEN @p_set ELSE src.org_assurance_question_set_id END"}',
         @p_source = @from_version_id, @p_version = @to_version_id,
         @p_root = @swap_root_set_id, @p_set = @swap_to_set_id, @p_actor = @actor;

    -- Workflow
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_workflow_config', @key_column = N'org_assurance_workflow_config_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @map_table = N'#cfg_wf', @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_workflow_stage', @key_column = N'org_assurance_workflow_stage_id',
         @where = N'src.is_active = 1',
         @source_join = N'JOIN #cfg_wf m ON m.old_id = src.org_assurance_workflow_config_id', @source_extra = N', m.new_id AS parent_new_id',
         @overrides = N'{"org_assurance_workflow_config_id":"src.parent_new_id","org_assurance_definition_version_id":"@p_version"}',
         @p_version = @to_version_id, @p_actor = @actor;

    -- Scoring
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scoring_config', @key_column = N'org_assurance_scoring_config_id',
         @where = N'src.org_assurance_definition_version_id = @p_source AND src.is_active = 1',
         @overrides = N'{"org_assurance_definition_version_id":"@p_version"}',
         @map_table = N'#cfg_sc', @p_source = @from_version_id, @p_version = @to_version_id, @p_actor = @actor;
    EXEC grac_practice.sp_org_assurance_clone_rows
         @table = N'org_assurance_scoring_band', @key_column = N'org_assurance_scoring_band_id',
         @where = N'src.is_active = 1',
         @source_join = N'JOIN #cfg_sc m ON m.old_id = src.org_assurance_scoring_config_id', @source_extra = N', m.new_id AS parent_new_id',
         @overrides = N'{"org_assurance_scoring_config_id":"src.parent_new_id","org_assurance_definition_version_id":"@p_version"}',
         @p_version = @to_version_id, @p_actor = @actor;
END
GO

PRINT '560 rollback: procedures back to 551 / 119; approach and mandate lists dropped (tables and columns kept).';
GO
SET NOEXEC OFF;
GO
