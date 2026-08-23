-- =====================================================================
-- 121 -- Plan Owner + Plan Item Auditor role+employee hybrid
--         (Q1-A + Q2 staged rollout, final Stage 4c stop)
--
-- Rewrites 5 procs from 090:
--   * sp_org_assurance_plan_list       -- adds OwnerRoleId + OwnerRoleName
--   * sp_org_assurance_plan_get        -- adds OwnerRoleId + OwnerRoleName
--   * sp_org_assurance_plan_save       -- 2 new owner-role params + hybrid resolver
--   * sp_org_assurance_plan_item_list  -- adds AuditorRoleId + AuditorRoleName
--   * sp_org_assurance_plan_item_save  -- 2 new auditor-role params + hybrid resolver
--
-- Resolver semantics (same as 116a / 119 / 120):
--   role_id given, role_name empty  -> lookup role_name from organization_role
--   role_id given, employee_id NULL -> auto-snapshot first active holder via
--                                       sp_org_role_primary_holder_pick
--   employee_id given, role_id NULL -> pull role from employee.role_id +
--                                       snapshot role_name from organization_role
--   employee_id given, display_name empty -> snapshot from employee_name
--
-- Column dependencies (must exist -- provided by 115):
--   grac_practice.org_assurance_plan.owner_role_id            BIGINT NULL
--   grac_practice.org_assurance_plan.owner_role_name          NVARCHAR(120) NULL
--   grac_practice.org_assurance_plan_item.assigned_auditor_role_id   BIGINT NULL
--   grac_practice.org_assurance_plan_item.assigned_auditor_role_name NVARCHAR(120) NULL
-- =====================================================================
SET NOCOUNT ON;
GO

IF COL_LENGTH('grac_practice.org_assurance_plan','owner_role_id') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_plan','owner_role_name') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_plan_item','assigned_auditor_role_id') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_plan_item','assigned_auditor_role_name') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_role_primary_holder_pick','P') IS NULL
BEGIN
    RAISERROR('121 preflight failed: apply 115 (schema) + 117 (helper SPs) first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_org_assurance_plan_list -- adds Owner role columns
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_list
    @organization_id BIGINT,
    @status_code     NVARCHAR(60) = NULL,
    @plan_type       NVARCHAR(30) = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 53901, 'organization_id is required.', 1;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    DECLARE @offset INT = (@page - 1) * @page_size;

    ;WITH base AS (
        SELECT p.org_assurance_plan_id,
               p.organization_id,
               p.plan_code,
               p.plan_name,
               p.plan_type,
               p.period_from,
               p.period_to,
               p.owner_role_id,        -- 121
               p.owner_role_name,      -- 121
               p.owner_employee_id,
               p.owner_display_name,
               s.status_code    AS status_code,
               s.status_name    AS status_name,
               s.is_terminal    AS status_is_terminal,
               p.version,
               p.entered_dt,
               p.updated_dt,
               (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_plan_item i
                 WHERE i.org_assurance_plan_id = p.org_assurance_plan_id
                   AND i.is_active = 1) AS item_count
        FROM grac_practice.org_assurance_plan p
        JOIN grac_practice.org_assurance_plan_status_master s
             ON s.org_assurance_plan_status_id = p.status_id
        WHERE p.organization_id = @organization_id
          AND p.is_active = 1
          AND (@status_code IS NULL OR s.status_code = @status_code)
          AND (@plan_type  IS NULL OR p.plan_type   = @plan_type)
          AND (@search IS NULL OR @search = ''
               OR p.plan_name LIKE N'%' + @search + N'%'
               OR p.plan_code LIKE N'%' + @search + N'%')
    )
    SELECT CAST(COUNT_BIG(1) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM base;

    ;WITH base AS (
        SELECT p.org_assurance_plan_id,
               p.organization_id,
               p.plan_code,
               p.plan_name,
               p.plan_type,
               p.period_from,
               p.period_to,
               p.owner_role_id,        -- 121
               p.owner_role_name,      -- 121
               p.owner_employee_id,
               p.owner_display_name,
               s.status_code    AS status_code,
               s.status_name    AS status_name,
               s.is_terminal    AS status_is_terminal,
               p.version,
               p.entered_dt,
               p.updated_dt,
               (SELECT COUNT_BIG(1) FROM grac_practice.org_assurance_plan_item i
                 WHERE i.org_assurance_plan_id = p.org_assurance_plan_id
                   AND i.is_active = 1) AS item_count
        FROM grac_practice.org_assurance_plan p
        JOIN grac_practice.org_assurance_plan_status_master s
             ON s.org_assurance_plan_status_id = p.status_id
        WHERE p.organization_id = @organization_id
          AND p.is_active = 1
          AND (@status_code IS NULL OR s.status_code = @status_code)
          AND (@plan_type  IS NULL OR p.plan_type   = @plan_type)
          AND (@search IS NULL OR @search = ''
               OR p.plan_name LIKE N'%' + @search + N'%'
               OR p.plan_code LIKE N'%' + @search + N'%')
    )
    SELECT org_assurance_plan_id AS PlanId,
           organization_id       AS OrganizationId,
           plan_code             AS PlanCode,
           plan_name             AS PlanName,
           plan_type             AS PlanType,
           period_from           AS PeriodFrom,
           period_to             AS PeriodTo,
           owner_role_id         AS OwnerRoleId,        -- 121
           owner_role_name       AS OwnerRoleName,      -- 121
           owner_employee_id     AS OwnerEmployeeId,
           owner_display_name    AS OwnerDisplayName,
           status_code           AS StatusCode,
           status_name           AS StatusName,
           status_is_terminal    AS StatusIsTerminal,
           version               AS Version,
           item_count            AS ItemCount,
           entered_dt            AS EnteredDt,
           updated_dt            AS UpdatedDt
    FROM base
    ORDER BY period_from DESC, plan_name, org_assurance_plan_id
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- sp_org_assurance_plan_get -- adds Owner role columns
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_get
    @organization_id BIGINT,
    @plan_id         BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @plan_id IS NULL
        THROW 53902, 'organization_id and plan_id are required.', 1;

    SELECT p.org_assurance_plan_id AS PlanId,
           p.organization_id       AS OrganizationId,
           p.plan_code             AS PlanCode,
           p.plan_name             AS PlanName,
           p.plan_type             AS PlanType,
           p.period_from           AS PeriodFrom,
           p.period_to             AS PeriodTo,
           p.owner_role_id         AS OwnerRoleId,      -- 121
           p.owner_role_name       AS OwnerRoleName,    -- 121
           p.owner_employee_id     AS OwnerEmployeeId,
           p.owner_display_name    AS OwnerDisplayName,
           s.status_code           AS StatusCode,
           s.status_name           AS StatusName,
           s.is_terminal           AS StatusIsTerminal,
           p.description           AS Description,
           p.version               AS Version,
           p.entered_by            AS EnteredBy,
           p.entered_dt            AS EnteredDt,
           p.updated_by            AS UpdatedBy,
           p.updated_dt            AS UpdatedDt
    FROM grac_practice.org_assurance_plan p
    JOIN grac_practice.org_assurance_plan_status_master s
         ON s.org_assurance_plan_status_id = p.status_id
    WHERE p.organization_id = @organization_id
      AND p.org_assurance_plan_id = @plan_id
      AND p.is_active = 1;
END
GO

-- =====================================================================
-- sp_org_assurance_plan_save -- adds 2 owner-role params + hybrid resolver
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_save
    @organization_id     BIGINT,
    @plan_id             BIGINT        = NULL,
    @plan_code           NVARCHAR(80),
    @plan_name           NVARCHAR(240),
    @plan_type           NVARCHAR(30),
    @period_from         DATE          = NULL,
    @period_to           DATE          = NULL,
    @owner_role_id       BIGINT        = NULL,   -- 121
    @owner_role_name     NVARCHAR(120) = NULL,   -- 121
    @owner_employee_id   BIGINT        = NULL,
    @owner_display_name  NVARCHAR(240) = NULL,
    @description         NVARCHAR(MAX) = NULL,
    @actor               NVARCHAR(100) = 'system',
    @plan_id_out         BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 53901, 'organization_id is required.', 1;
    IF @plan_code IS NULL OR LEN(LTRIM(RTRIM(@plan_code))) = 0
        THROW 53903, 'plan_code is required.', 1;
    IF @plan_name IS NULL OR LEN(LTRIM(RTRIM(@plan_name))) = 0
        THROW 53904, 'plan_name is required.', 1;
    IF @plan_type NOT IN (N'ANNUAL', N'QUARTERLY', N'MONTHLY', N'ONE_TIME')
        THROW 53905, 'plan_type must be ANNUAL / QUARTERLY / MONTHLY / ONE_TIME.', 1;

    -- ==========================================================
    -- 121 hybrid ownership resolver -- Owner
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
        SELECT org_assurance_plan_status_id
        FROM grac_practice.org_assurance_plan_status_master WHERE status_code = N'Draft');

    BEGIN TRAN;

    IF @plan_id IS NULL
    BEGIN
        IF EXISTS (
            SELECT 1 FROM grac_practice.org_assurance_plan
            WHERE organization_id = @organization_id
              AND plan_code = @plan_code
              AND is_active = 1)
        BEGIN
            ROLLBACK;
            THROW 53906, 'A plan with this code already exists in the organization.', 1;
        END

        INSERT INTO grac_practice.org_assurance_plan
            (organization_id, plan_code, plan_name, plan_type,
             period_from, period_to,
             owner_role_id, owner_role_name,           -- 121
             owner_employee_id, owner_display_name,
             status_id, description, version,
             is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@organization_id, @plan_code, @plan_name, @plan_type,
             @period_from, @period_to,
             @owner_role_id, @owner_role_name,         -- 121
             @owner_employee_id, @owner_display_name,
             @draft_status_id, @description, 1,
             1, @active_record_status_id, @actor, SYSUTCDATETIME());

        SET @plan_id_out = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        DECLARE @def_org BIGINT, @status_code NVARCHAR(60);
        SELECT @def_org     = p.organization_id,
               @status_code = s.status_code
        FROM grac_practice.org_assurance_plan p
        JOIN grac_practice.org_assurance_plan_status_master s
             ON s.org_assurance_plan_status_id = p.status_id
        WHERE p.org_assurance_plan_id = @plan_id AND p.is_active = 1;

        IF @def_org IS NULL BEGIN ROLLBACK; THROW 53907, 'Plan not found.', 1; END
        IF @def_org <> @organization_id
        BEGIN ROLLBACK; THROW 53908, 'Plan belongs to a different organization.', 1; END
        IF @status_code IN (N'Approved', N'Active', N'Closed')
        BEGIN ROLLBACK; THROW 53909, 'Plan cannot be edited in its current status.', 1; END

        UPDATE grac_practice.org_assurance_plan
        SET plan_name          = @plan_name,
            plan_type          = @plan_type,
            period_from        = @period_from,
            period_to          = @period_to,
            owner_role_id      = @owner_role_id,       -- 121
            owner_role_name    = @owner_role_name,     -- 121
            owner_employee_id  = @owner_employee_id,
            owner_display_name = @owner_display_name,
            description        = @description,
            updated_by         = @actor,
            updated_dt         = SYSUTCDATETIME()
        WHERE org_assurance_plan_id = @plan_id;

        SET @plan_id_out = @plan_id;
    END

    COMMIT;
END
GO

-- =====================================================================
-- sp_org_assurance_plan_item_list -- adds Auditor role columns
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_item_list
    @organization_id BIGINT,
    @plan_id         BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @plan_id IS NULL
        THROW 53902, 'organization_id and plan_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_plan
        WHERE org_assurance_plan_id = @plan_id
          AND organization_id       = @organization_id)
        THROW 53908, 'Plan belongs to a different organization.', 1;

    SELECT i.org_assurance_plan_item_id  AS PlanItemId,
           i.org_assurance_plan_id       AS PlanId,
           i.org_assurance_definition_id AS DefinitionId,
           i.definition_code             AS DefinitionCode,
           i.definition_name             AS DefinitionName,
           i.org_assurance_definition_version_id AS DefinitionVersionId,
           i.item_order                  AS ItemOrder,
           i.scheduled_from              AS ScheduledFrom,
           i.scheduled_to                AS ScheduledTo,
           i.assigned_auditor_role_id    AS AssignedAuditorRoleId,      -- 121
           i.assigned_auditor_role_name  AS AssignedAuditorRoleName,    -- 121
           i.assigned_auditor_employee_id AS AssignedAuditorEmployeeId,
           i.assigned_auditor_name       AS AssignedAuditorName,
           i.assigned_team_name          AS AssignedTeamName,
           i.assigned_department_id      AS AssignedDepartmentId,
           i.assigned_department_name    AS AssignedDepartmentName,
           i.assigned_branch_id          AS AssignedBranchId,
           i.assigned_branch_name        AS AssignedBranchName,
           i.notes                       AS Notes,
           i.entered_by                  AS EnteredBy,
           i.entered_dt                  AS EnteredDt,
           i.updated_by                  AS UpdatedBy,
           i.updated_dt                  AS UpdatedDt
    FROM grac_practice.org_assurance_plan_item i
    WHERE i.org_assurance_plan_id = @plan_id
      AND i.organization_id       = @organization_id
      AND i.is_active = 1
    ORDER BY i.item_order, i.org_assurance_plan_item_id;
END
GO

-- =====================================================================
-- sp_org_assurance_plan_item_save -- adds 2 auditor-role params + hybrid resolver
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_item_save
    @organization_id             BIGINT,
    @plan_id                     BIGINT,
    @plan_item_id                BIGINT        = NULL,
    @org_assurance_definition_id BIGINT,
    @definition_code             NVARCHAR(80)  = NULL,
    @definition_name             NVARCHAR(240) = NULL,
    @item_order                  INT           = 0,
    @scheduled_from              DATE          = NULL,
    @scheduled_to                DATE          = NULL,
    @assigned_auditor_role_id    BIGINT        = NULL,   -- 121
    @assigned_auditor_role_name  NVARCHAR(120) = NULL,   -- 121
    @assigned_auditor_employee_id BIGINT       = NULL,
    @assigned_auditor_name       NVARCHAR(240) = NULL,
    @assigned_team_name          NVARCHAR(200) = NULL,
    @assigned_department_id      BIGINT        = NULL,
    @assigned_department_name    NVARCHAR(200) = NULL,
    @assigned_branch_id          BIGINT        = NULL,
    @assigned_branch_name        NVARCHAR(200) = NULL,
    @notes                       NVARCHAR(MAX) = NULL,
    @actor                       NVARCHAR(100) = 'system',
    @plan_item_id_out            BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @plan_id IS NULL
        THROW 53902, 'organization_id and plan_id are required.', 1;
    IF @org_assurance_definition_id IS NULL
        THROW 53913, 'org_assurance_definition_id is required.', 1;

    -- Verify plan ownership.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_plan
        WHERE org_assurance_plan_id = @plan_id
          AND organization_id       = @organization_id
          AND is_active = 1)
        THROW 53908, 'Plan belongs to a different organization.', 1;

    -- Verify definition ownership.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_definition
        WHERE org_assurance_definition_id = @org_assurance_definition_id
          AND organization_id            = @organization_id
          AND is_active = 1)
        THROW 53914, 'Assurance definition not accessible in this organization.', 1;

    -- ==========================================================
    -- 121 hybrid ownership resolver -- Auditor
    -- ==========================================================
    IF @assigned_auditor_role_id IS NOT NULL
       AND (@assigned_auditor_role_name IS NULL OR LEN(LTRIM(RTRIM(@assigned_auditor_role_name))) = 0)
        SELECT @assigned_auditor_role_name = role_name
        FROM grac_practice.organization_role
        WHERE role_id = @assigned_auditor_role_id AND organization_id = @organization_id;

    IF @assigned_auditor_role_id IS NOT NULL AND @assigned_auditor_employee_id IS NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id   = @organization_id,
             @role_id           = @assigned_auditor_role_id,
             @employee_id_out   = @assigned_auditor_employee_id  OUTPUT,
             @employee_name_out = @assigned_auditor_name         OUTPUT;

    IF @assigned_auditor_employee_id IS NOT NULL AND @assigned_auditor_role_id IS NULL
    BEGIN
        SELECT @assigned_auditor_role_id   = e.role_id,
               @assigned_auditor_role_name = r.role_name
        FROM grac_practice.organization_employee e
        LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
        WHERE e.employee_id = @assigned_auditor_employee_id
          AND e.organization_id = @organization_id;
    END

    IF @assigned_auditor_employee_id IS NOT NULL
       AND (@assigned_auditor_name IS NULL OR LEN(LTRIM(RTRIM(@assigned_auditor_name))) = 0)
        SELECT @assigned_auditor_name = employee_name
        FROM grac_practice.organization_employee
        WHERE employee_id = @assigned_auditor_employee_id;

    BEGIN TRAN;

    IF @plan_item_id IS NULL
    BEGIN
        INSERT INTO grac_practice.org_assurance_plan_item
            (org_assurance_plan_id, organization_id,
             org_assurance_definition_id, definition_code, definition_name,
             item_order, scheduled_from, scheduled_to,
             assigned_auditor_role_id, assigned_auditor_role_name,       -- 121
             assigned_auditor_employee_id, assigned_auditor_name,
             assigned_team_name,
             assigned_department_id, assigned_department_name,
             assigned_branch_id, assigned_branch_name,
             notes, is_active, entered_by, entered_dt)
        VALUES
            (@plan_id, @organization_id,
             @org_assurance_definition_id, @definition_code, @definition_name,
             ISNULL(@item_order, 0), @scheduled_from, @scheduled_to,
             @assigned_auditor_role_id, @assigned_auditor_role_name,     -- 121
             @assigned_auditor_employee_id, @assigned_auditor_name,
             @assigned_team_name,
             @assigned_department_id, @assigned_department_name,
             @assigned_branch_id, @assigned_branch_name,
             @notes, 1, @actor, SYSUTCDATETIME());

        SET @plan_item_id_out = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        DECLARE @item_plan BIGINT;
        SELECT @item_plan = org_assurance_plan_id
        FROM grac_practice.org_assurance_plan_item
        WHERE org_assurance_plan_item_id = @plan_item_id
          AND is_active = 1;

        IF @item_plan IS NULL BEGIN ROLLBACK; THROW 53915, 'Plan item not found.', 1; END
        IF @item_plan <> @plan_id
        BEGIN ROLLBACK; THROW 53916, 'Plan item does not belong to the specified plan.', 1; END

        UPDATE grac_practice.org_assurance_plan_item
        SET org_assurance_definition_id = @org_assurance_definition_id,
            definition_code             = @definition_code,
            definition_name             = @definition_name,
            item_order                  = ISNULL(@item_order, 0),
            scheduled_from              = @scheduled_from,
            scheduled_to                = @scheduled_to,
            assigned_auditor_role_id    = @assigned_auditor_role_id,       -- 121
            assigned_auditor_role_name  = @assigned_auditor_role_name,     -- 121
            assigned_auditor_employee_id = @assigned_auditor_employee_id,
            assigned_auditor_name       = @assigned_auditor_name,
            assigned_team_name          = @assigned_team_name,
            assigned_department_id      = @assigned_department_id,
            assigned_department_name    = @assigned_department_name,
            assigned_branch_id          = @assigned_branch_id,
            assigned_branch_name        = @assigned_branch_name,
            notes                       = @notes,
            updated_by                  = @actor,
            updated_dt                  = SYSUTCDATETIME()
        WHERE org_assurance_plan_item_id = @plan_item_id;

        SET @plan_item_id_out = @plan_item_id;
    END

    COMMIT;
END
GO

PRINT '121: Plan Owner + Plan Item Auditor role+employee hybrid applied.';
GO
