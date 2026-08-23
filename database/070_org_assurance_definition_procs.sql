-- =====================================================================
-- 070 Organization Assurance Management -- Stage 1 stored procedures
--
-- Depends on 069_org_assurance_definition_schema.sql.
--
-- Procedures:
--   sp_org_assurance_status_list             Dropdown feed
--   sp_org_assurance_definition_list         Paginated list per org
--   sp_org_assurance_definition_get          Single definition + current version
--   sp_org_assurance_definition_save         Insert new or update draft version
--   sp_org_assurance_definition_submit       Draft -> Under Review
--   sp_org_assurance_definition_approve      Under Review -> Approved
--   sp_org_assurance_definition_activate     Approved -> Active
--   sp_org_assurance_definition_retire       Active -> Retired
--   sp_org_assurance_definition_history_list Version transition audit log
--   sp_org_assurance_definition_version_list All versions for a definition
--
-- Every proc enforces:
--   * Organization isolation (mandatory @organization_id)
--   * Lifecycle transitions (illegal moves raise a THROW)
--   * Immutability of non-Draft versions (updates are blocked)
--
-- Naming follows the existing sp_task_* / sp_workflow_* / sp_custom_gap_*
-- conventions (schema-qualified, snake_case, single result set per proc
-- except list procs which emit a COUNT header followed by the rowset --
-- exactly like sp_task_list).
--
-- Rollback in database/070_org_assurance_definition_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_definition','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_definition_version','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_definition_history','U') IS NULL
BEGIN
    RAISERROR('070_org_assurance_definition_procs: run 069 schema first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_org_assurance_status_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_status_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT org_assurance_status_id AS StatusId,
           status_code               AS StatusCode,
           status_name               AS StatusName,
           display_order             AS DisplayOrder,
           is_terminal               AS IsTerminal
    FROM grac_practice.org_assurance_status_master
    WHERE is_active = 1
    ORDER BY display_order, org_assurance_status_id;
END
GO

-- =====================================================================
-- sp_org_assurance_definition_list
--   Paginated list, org-scoped, optional filter by status code + search.
--   Emits count header row (matches sp_task_list convention) followed
--   by the page rowset.
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
-- sp_org_assurance_definition_get
--   Returns one definition + its current version payload. Result set
--   layout matches the columns used by the Edit dialog on the Web tier.
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
--   * If @definition_id IS NULL -> insert a new definition + version 1
--     in Draft status.
--   * If @definition_id IS NOT NULL and current version is Draft ->
--     update that draft's payload in place.
--   * If @definition_id IS NOT NULL and current version is Active or
--     Retired -> create a NEW Draft version (next version_number) and
--     retarget current_version_id at it (active_version_id stays put).
--   * If current version is Under Review or Approved -> reject the
--     save; edits during review are not allowed.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_save
    @organization_id            BIGINT,
    @definition_id              BIGINT        = NULL,
    @definition_code            NVARCHAR(80),
    @definition_name            NVARCHAR(240),
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
             owner_employee_id, owner_display_name,
             current_version_id, current_status_id, active_version_id,
             is_active, record_status_id, entered_by, entered_dt)
        VALUES
            (@organization_id, @definition_code, @definition_name,
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

-- =====================================================================
-- Shared helper: sp_org_assurance_definition_transition
--   Internal-style proc: applies the state change on the current
--   version and definition rows + logs a history entry. Not exposed
--   directly to callers; the 4 lifecycle procs below use it.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_transition
    @organization_id     BIGINT,
    @definition_id       BIGINT,
    @expected_from_code  NVARCHAR(60),
    @to_code             NVARCHAR(60),
    @action_code         NVARCHAR(40),
    @reason_text         NVARCHAR(1000) = NULL,
    @actor               NVARCHAR(100)  = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53601, 'organization_id and definition_id are required.', 1;

    DECLARE @from_status_id INT, @to_status_id INT,
            @current_status_id INT, @current_status_code NVARCHAR(60),
            @current_version_id BIGINT, @def_org BIGINT,
            @active_version_id BIGINT;

    SELECT @from_status_id = org_assurance_status_id
      FROM grac_practice.org_assurance_status_master WHERE status_code = @expected_from_code;
    SELECT @to_status_id   = org_assurance_status_id
      FROM grac_practice.org_assurance_status_master WHERE status_code = @to_code;

    IF @from_status_id IS NULL OR @to_status_id IS NULL
        THROW 53609, 'Unknown status_code passed to transition helper.', 1;

    BEGIN TRAN;

    SELECT @def_org            = d.organization_id,
           @current_version_id = d.current_version_id,
           @active_version_id  = d.active_version_id,
           @current_status_id  = d.current_status_id,
           @current_status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @def_org IS NULL
    BEGIN ROLLBACK; THROW 53606, 'Definition not found.', 1; END
    IF @def_org <> @organization_id
    BEGIN ROLLBACK; THROW 53607, 'Definition belongs to a different organization.', 1; END
    IF @current_status_code <> @expected_from_code
    BEGIN
        ROLLBACK;
        THROW 53610, 'Illegal lifecycle transition -- current status does not match the expected source.', 1;
    END
    IF @current_version_id IS NULL
    BEGIN ROLLBACK; THROW 53611, 'Definition has no current version.', 1; END

    DECLARE @now DATETIME2 = SYSUTCDATETIME();

    UPDATE grac_practice.org_assurance_definition_version
    SET status_id     = @to_status_id,
        submitted_by  = CASE WHEN @to_code = N'UnderReview' THEN @actor      ELSE submitted_by  END,
        submitted_dt  = CASE WHEN @to_code = N'UnderReview' THEN @now        ELSE submitted_dt  END,
        approved_by   = CASE WHEN @to_code = N'Approved'    THEN @actor      ELSE approved_by   END,
        approved_dt   = CASE WHEN @to_code = N'Approved'    THEN @now        ELSE approved_dt   END,
        activated_by  = CASE WHEN @to_code = N'Active'      THEN @actor      ELSE activated_by  END,
        activated_dt  = CASE WHEN @to_code = N'Active'      THEN @now        ELSE activated_dt  END,
        retired_by    = CASE WHEN @to_code = N'Retired'     THEN @actor      ELSE retired_by    END,
        retired_dt    = CASE WHEN @to_code = N'Retired'     THEN @now        ELSE retired_dt    END,
        updated_by    = @actor,
        updated_dt    = @now
    WHERE org_assurance_definition_version_id = @current_version_id;

    UPDATE grac_practice.org_assurance_definition
    SET current_status_id = @to_status_id,
        active_version_id = CASE WHEN @to_code = N'Active'
                                 THEN @current_version_id
                                 ELSE @active_version_id END,
        updated_by        = @actor,
        updated_dt        = @now
    WHERE org_assurance_definition_id = @definition_id;

    INSERT INTO grac_practice.org_assurance_definition_history
        (org_assurance_definition_id, org_assurance_definition_version_id,
         organization_id, action_code, from_status_id, to_status_id,
         reason_text, actor_display_name, entered_by, entered_dt)
    VALUES
        (@definition_id, @current_version_id, @organization_id,
         @action_code, @from_status_id, @to_status_id,
         @reason_text, @actor, @actor, @now);

    COMMIT;
END
GO

-- =====================================================================
-- Public lifecycle procs
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_submit
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @reason_text     NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_definition_transition
        @organization_id    = @organization_id,
        @definition_id      = @definition_id,
        @expected_from_code = N'Draft',
        @to_code            = N'UnderReview',
        @action_code        = N'SUBMIT',
        @reason_text        = @reason_text,
        @actor              = @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_approve
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @reason_text     NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_definition_transition
        @organization_id    = @organization_id,
        @definition_id      = @definition_id,
        @expected_from_code = N'UnderReview',
        @to_code            = N'Approved',
        @action_code        = N'APPROVE',
        @reason_text        = @reason_text,
        @actor              = @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_activate
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @reason_text     NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_definition_transition
        @organization_id    = @organization_id,
        @definition_id      = @definition_id,
        @expected_from_code = N'Approved',
        @to_code            = N'Active',
        @action_code        = N'ACTIVATE',
        @reason_text        = @reason_text,
        @actor              = @actor;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_retire
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @reason_text     NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_definition_transition
        @organization_id    = @organization_id,
        @definition_id      = @definition_id,
        @expected_from_code = N'Active',
        @to_code            = N'Retired',
        @action_code        = N'RETIRE',
        @reason_text        = @reason_text,
        @actor              = @actor;
END
GO

-- =====================================================================
-- sp_org_assurance_definition_history_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_history_list
    @organization_id BIGINT,
    @definition_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;

    -- Verify ownership before returning rows.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_definition
        WHERE org_assurance_definition_id = @definition_id
          AND organization_id = @organization_id
    )
    BEGIN
        THROW 53607, 'Definition belongs to a different organization.', 1;
    END

    SELECT h.org_assurance_definition_history_id AS HistoryId,
           h.org_assurance_definition_id         AS DefinitionId,
           h.org_assurance_definition_version_id AS DefinitionVersionId,
           h.action_code                         AS ActionCode,
           fs.status_code                        AS FromStatusCode,
           fs.status_name                        AS FromStatusName,
           ts.status_code                        AS ToStatusCode,
           ts.status_name                        AS ToStatusName,
           h.reason_text                         AS ReasonText,
           h.actor_display_name                  AS ActorDisplayName,
           h.entered_by                          AS EnteredBy,
           h.entered_dt                          AS EnteredDt
    FROM grac_practice.org_assurance_definition_history h
    LEFT JOIN grac_practice.org_assurance_status_master fs ON fs.org_assurance_status_id = h.from_status_id
    LEFT JOIN grac_practice.org_assurance_status_master ts ON ts.org_assurance_status_id = h.to_status_id
    WHERE h.org_assurance_definition_id = @definition_id
    ORDER BY h.entered_dt DESC, h.org_assurance_definition_history_id DESC;
END
GO

-- =====================================================================
-- sp_org_assurance_definition_version_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_version_list
    @organization_id BIGINT,
    @definition_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_definition
        WHERE org_assurance_definition_id = @definition_id
          AND organization_id = @organization_id
    )
    BEGIN
        THROW 53607, 'Definition belongs to a different organization.', 1;
    END

    SELECT v.org_assurance_definition_version_id AS VersionId,
           v.org_assurance_definition_id         AS DefinitionId,
           v.version_number                      AS VersionNumber,
           v.version_label                       AS VersionLabel,
           v.description                         AS Description,
           v.objective                           AS Objective,
           v.effective_date                      AS EffectiveDate,
           v.assurance_category_id               AS AssuranceCategoryId,
           v.assurance_category_code             AS AssuranceCategoryCode,
           v.assurance_category_name             AS AssuranceCategoryName,
           s.status_code                         AS StatusCode,
           s.status_name                         AS StatusName,
           v.submitted_by                        AS SubmittedBy,
           v.submitted_dt                        AS SubmittedDt,
           v.approved_by                         AS ApprovedBy,
           v.approved_dt                         AS ApprovedDt,
           v.activated_by                        AS ActivatedBy,
           v.activated_dt                        AS ActivatedDt,
           v.retired_by                          AS RetiredBy,
           v.retired_dt                          AS RetiredDt,
           v.entered_by                          AS EnteredBy,
           v.entered_dt                          AS EnteredDt,
           v.updated_by                          AS UpdatedBy,
           v.updated_dt                          AS UpdatedDt
    FROM grac_practice.org_assurance_definition_version v
    JOIN grac_practice.org_assurance_status_master s ON s.org_assurance_status_id = v.status_id
    WHERE v.org_assurance_definition_id = @definition_id
    ORDER BY v.version_number DESC, v.org_assurance_definition_version_id DESC;
END
GO

PRINT '070 Organization Assurance -- Stage 1 procedures deployed.';
GO
