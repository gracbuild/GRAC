-- =====================================================================
-- 119 -- Definition Owner role+employee hybrid (Q1-A + Q2 staged rollout)
--
-- Rewrites 3 procs from 070 to add role snapshot alongside employee:
--   * sp_org_assurance_definition_list  -- adds OwnerRoleId + OwnerRoleName
--   * sp_org_assurance_definition_get   -- adds OwnerRoleId + OwnerRoleName
--   * sp_org_assurance_definition_save  -- 2 new params + hybrid resolver
--
-- Resolver semantics (mirrors 116a Observation resolver):
--   * role_id given, role_name empty  -> lookup role_name from organization_role
--   * role_id given, employee_id NULL -> auto-snapshot first active holder
--     via sp_org_role_primary_holder_pick (Q1-A auto-fill)
--   * employee_id given, role_id NULL -> pull role from employee.role_id +
--     snapshot role_name from organization_role
--   * employee_id given, display_name empty -> snapshot from employee_name
--
-- Column dependencies (must exist -- provided by 115):
--   grac_practice.org_assurance_definition.owner_role_id     BIGINT NULL
--   grac_practice.org_assurance_definition.owner_role_name   NVARCHAR(120) NULL
--
-- Preflight guard: 115 + 117 must be applied.
-- =====================================================================
SET NOCOUNT ON;
GO

IF COL_LENGTH('grac_practice.org_assurance_definition','owner_role_id') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_definition','owner_role_name') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_role_primary_holder_pick','P') IS NULL
BEGIN
    RAISERROR('119 preflight failed: apply migration 115 (schema) and 117 (helper SPs) first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_org_assurance_definition_list -- adds Owner role columns
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_list
    @organization_id BIGINT,
    @status_code     NVARCHAR(60) = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 53601, 'organization_id is required.', 1;
    IF @page IS NULL OR @page < 1        SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200                  SET @page_size = 200;

    DECLARE @offset INT = (@page - 1) * @page_size;

    ;WITH base AS (
        SELECT d.org_assurance_definition_id,
               d.organization_id,
               d.definition_code,
               d.definition_name,
               d.owner_role_id,
               d.owner_role_name,
               d.owner_employee_id,
               d.owner_display_name,
               d.current_version_id,
               d.active_version_id,
               s.status_code AS current_status_code,
               s.status_name AS current_status_name,
               s.is_terminal AS current_status_is_terminal,
               v.version_number   AS current_version_number,
               v.version_label    AS current_version_label,
               v.effective_date   AS current_effective_date,
               v.assurance_category_code AS current_category_code,
               v.assurance_category_name AS current_category_name,
               d.entered_dt,
               d.updated_dt
        FROM grac_practice.org_assurance_definition d
        JOIN grac_practice.org_assurance_status_master s
             ON s.org_assurance_status_id = d.current_status_id
        LEFT JOIN grac_practice.org_assurance_definition_version v
             ON v.org_assurance_definition_version_id = d.current_version_id
        WHERE d.organization_id = @organization_id
          AND d.is_active = 1
          AND (@status_code IS NULL OR s.status_code = @status_code)
          AND (@search IS NULL OR @search = ''
               OR d.definition_name LIKE N'%' + @search + N'%'
               OR d.definition_code LIKE N'%' + @search + N'%')
    )
    SELECT CAST(COUNT_BIG(1) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM base;

    ;WITH base AS (
        SELECT d.org_assurance_definition_id,
               d.organization_id,
               d.definition_code,
               d.definition_name,
               d.owner_role_id,
               d.owner_role_name,
               d.owner_employee_id,
               d.owner_display_name,
               d.current_version_id,
               d.active_version_id,
               s.status_code AS current_status_code,
               s.status_name AS current_status_name,
               s.is_terminal AS current_status_is_terminal,
               v.version_number   AS current_version_number,
               v.version_label    AS current_version_label,
               v.effective_date   AS current_effective_date,
               v.assurance_category_code AS current_category_code,
               v.assurance_category_name AS current_category_name,
               d.entered_dt,
               d.updated_dt
        FROM grac_practice.org_assurance_definition d
        JOIN grac_practice.org_assurance_status_master s
             ON s.org_assurance_status_id = d.current_status_id
        LEFT JOIN grac_practice.org_assurance_definition_version v
             ON v.org_assurance_definition_version_id = d.current_version_id
        WHERE d.organization_id = @organization_id
          AND d.is_active = 1
          AND (@status_code IS NULL OR s.status_code = @status_code)
          AND (@search IS NULL OR @search = ''
               OR d.definition_name LIKE N'%' + @search + N'%'
               OR d.definition_code LIKE N'%' + @search + N'%')
    )
    SELECT org_assurance_definition_id AS DefinitionId,
           organization_id             AS OrganizationId,
           definition_code             AS DefinitionCode,
           definition_name             AS DefinitionName,
           owner_role_id               AS OwnerRoleId,
           owner_role_name             AS OwnerRoleName,
           owner_employee_id           AS OwnerEmployeeId,
           owner_display_name          AS OwnerDisplayName,
           current_version_id          AS CurrentVersionId,
           active_version_id           AS ActiveVersionId,
           current_status_code         AS CurrentStatusCode,
           current_status_name         AS CurrentStatusName,
           current_status_is_terminal  AS CurrentStatusIsTerminal,
           current_version_number      AS CurrentVersionNumber,
           current_version_label       AS CurrentVersionLabel,
           current_effective_date      AS CurrentEffectiveDate,
           current_category_code       AS CurrentCategoryCode,
           current_category_name       AS CurrentCategoryName,
           entered_dt                  AS EnteredDt,
           updated_dt                  AS UpdatedDt
    FROM base
    ORDER BY definition_name, org_assurance_definition_id
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- sp_org_assurance_definition_get -- adds Owner role columns
-- =====================================================================
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

-- =====================================================================
-- sp_org_assurance_definition_save
--   Same lifecycle branching as 070 -- adds 2 owner-role params + hybrid
--   auto-resolver (Q1-A). Full rewrite (SP is CREATE OR ALTER).
-- =====================================================================
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

PRINT '119: Definition Owner role+employee hybrid applied (list/get/save rewritten).';
GO
