-- =====================================================================
-- 124 Event Assurance -- scope-aware mapping, raise and inbox procedures
--
-- Depends on 066 (schema), 067 (base procs), 117 (role holder helper),
-- 123 (scope columns + event_mapping_resolution).
--
-- Procedures:
--   sp_event_checklist_mapping_save        ALTERED -- scope params appended
--   sp_event_scope_mapping_list            Mapping workspace for one scope value
--   sp_event_scope_coverage_list           Coverage ring per role / asset category
--   sp_event_instance_raise_scoped         NEW resolver + raiser (multi-mapping)
--   sp_event_raise_people_lifecycle        Onboard / offboard wrapper
--   sp_event_raise_asset_lifecycle         Commission / decommission wrapper
--   sp_event_checklist_inbox_list          "My open event checklists"
--   sp_event_instance_detail_get           Popup: header + items (2 result sets)
--   sp_event_resolution_trace_list         Auditor view + coverage gap queue
--
-- Submission is NOT re-implemented here. 067 already ships
-- sp_event_instance_item_save and sp_event_instance_complete; the popup
-- calls those unchanged.
--
-- WHY A NEW RAISE PROC INSTEAD OF CHANGING sp_event_instance_trigger
-- ------------------------------------------------------------------
-- 067's trigger proc does SELECT TOP 1 ... ORDER BY mapping_id DESC: one
-- event yields exactly one checklist. Once mappings are scoped by role
-- that is wrong -- a Software Engineer joining legitimately matches an
-- HR checklist, an IT checklist and a Facilities checklist, and all three
-- must appear. Changing TOP 1 to a set would silently alter the row count
-- returned to every existing caller of that proc. So the scoped resolver
-- is a new proc and sp_event_instance_trigger is left exactly as it is.
--
-- WHY ONE INSTANCE PER MAPPING AND NOT ONE PER EVENT
-- --------------------------------------------------
-- Those three checklists have three different owners, three different SLAs
-- and three different completion states. Folding them into one instance
-- would mean Facilities cannot close their part until HR closes theirs.
-- 123's uq_pm_event_instance_open_subject is keyed on source_mapping_id
-- for the same reason.
--
-- ERROR CODES: 67200-67299 (067 owns 67000-67099).
--
-- Rollback: 124_event_scope_mapping_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF COL_LENGTH('grac_practice.event_checklist_mapping','scope_dimension') IS NULL
   OR OBJECT_ID('grac_practice.event_mapping_resolution','U') IS NULL
BEGIN
    RAISERROR('124: run 123 schema first.', 16, 1);
    RETURN;
END
GO


-- =====================================================================
-- sp_event_checklist_mapping_save  (ALTERED from 067)
--
-- Scope parameters are appended and defaulted, so every existing caller
-- keeps working and produces an unscoped mapping exactly as before.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_checklist_mapping_save
    @mapping_id              BIGINT = NULL,
    @organization_id         BIGINT,
    @entity_type_id          BIGINT,
    @event_definition_id     BIGINT,
    @checklist_id            BIGINT,
    @default_owner_role      NVARCHAR(100) = NULL,
    @default_due_period_days INT           = NULL,
    @status                  NVARCHAR(30)  = N'Active',
    @actor_employee_id       BIGINT        = NULL,
    -- ---- 124 additions ----
    @scope_dimension         NVARCHAR(40)  = NULL,   -- ORG_ROLE / ASSET_CATEGORY / NULL
    @scope_role_id           BIGINT        = NULL,
    @scope_asset_category_id INT           = NULL,
    @release_id              BIGINT        = NULL,
    @default_owner_role_id   BIGINT        = NULL,
    @out_mapping_id          BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @entity_type_id IS NULL
       OR @event_definition_id IS NULL OR @checklist_id IS NULL
        THROW 67070, 'sp_event_checklist_mapping_save: organization_id, entity_type_id, event_definition_id and checklist_id are required.', 1;

    IF @status NOT IN (N'Active', N'Inactive') SET @status = N'Active';

    -- Normalise the scope triple before it reaches ck_pm_event_checklist_mapping_scope,
    -- so a caller that sends a role id without the dimension still gets a sane row
    -- rather than a constraint violation.
    IF @scope_dimension IS NULL AND @scope_role_id IS NOT NULL
        SET @scope_dimension = N'ORG_ROLE';
    IF @scope_dimension IS NULL AND @scope_asset_category_id IS NOT NULL
        SET @scope_dimension = N'ASSET_CATEGORY';

    IF @scope_dimension = N'ORG_ROLE'
    BEGIN
        SET @scope_asset_category_id = NULL;
        IF @scope_role_id IS NULL
            THROW 67200, 'sp_event_checklist_mapping_save: scope_role_id is required when scope_dimension is ORG_ROLE.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_role
                       WHERE role_id = @scope_role_id AND organization_id = @organization_id)
            THROW 67201, 'sp_event_checklist_mapping_save: scope_role_id does not belong to this organization.', 1;
    END
    ELSE IF @scope_dimension = N'ASSET_CATEGORY'
    BEGIN
        SET @scope_role_id = NULL;
        IF @scope_asset_category_id IS NULL
            THROW 67202, 'sp_event_checklist_mapping_save: scope_asset_category_id is required when scope_dimension is ASSET_CATEGORY.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_category_master
                       WHERE asset_category_id = @scope_asset_category_id AND is_active = 1)
            THROW 67203, 'sp_event_checklist_mapping_save: unknown or inactive asset category.', 1;
    END
    ELSE IF @scope_dimension IS NOT NULL
        THROW 67204, 'sp_event_checklist_mapping_save: scope_dimension must be ORG_ROLE, ASSET_CATEGORY or NULL.', 1;

    IF @default_owner_role_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role
                       WHERE role_id = @default_owner_role_id AND organization_id = @organization_id)
        THROW 67205, 'sp_event_checklist_mapping_save: default_owner_role_id does not belong to this organization.', 1;

    -- release_id is validated against the org's subscriptions, not against a
    -- release master -- the Event engine deliberately holds no FK into the
    -- Obligation engine (066 boundary, retained in 123).
    IF @release_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.repository_subscription
                       WHERE organization_id = @organization_id
                         AND release_id      = @release_id
                         AND subscription_status = N'Active'
                         AND status              = N'Active')
        THROW 67206, 'sp_event_checklist_mapping_save: organization has no active subscription to this release.', 1;

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    IF @mapping_id IS NULL
    BEGIN
        INSERT INTO grac_practice.event_checklist_mapping
            (organization_id, entity_type_id, event_definition_id, checklist_id,
             default_owner_role, default_due_period_days, status,
             scope_dimension, scope_role_id, scope_asset_category_id,
             release_id, default_owner_role_id,
             entered_by, entered_dt)
        VALUES
            (@organization_id, @entity_type_id, @event_definition_id, @checklist_id,
             @default_owner_role, @default_due_period_days, @status,
             @scope_dimension, @scope_role_id, @scope_asset_category_id,
             @release_id, @default_owner_role_id,
             @actor, SYSUTCDATETIME());
        SET @out_mapping_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.event_checklist_mapping
           SET entity_type_id          = @entity_type_id,
               event_definition_id     = @event_definition_id,
               checklist_id            = @checklist_id,
               default_owner_role      = @default_owner_role,
               default_due_period_days = @default_due_period_days,
               status                  = @status,
               scope_dimension         = @scope_dimension,
               scope_role_id           = @scope_role_id,
               scope_asset_category_id = @scope_asset_category_id,
               release_id              = @release_id,
               default_owner_role_id   = @default_owner_role_id,
               updated_by              = @actor,
               updated_dt              = SYSUTCDATETIME()
         WHERE mapping_id      = @mapping_id
           AND organization_id = @organization_id;

        IF @@ROWCOUNT = 0
            THROW 67207, 'sp_event_checklist_mapping_save: mapping not found for this organization.', 1;

        SET @out_mapping_id = @mapping_id;
    END

    INSERT INTO grac_practice.event_audit
        (organization_id, entity_type, entity_id, action, actor, new_value, entered_dt)
    VALUES
        (@organization_id, N'Mapping', @out_mapping_id,
         CASE WHEN @mapping_id IS NULL THEN N'Create' ELSE N'Update' END, @actor,
         CONCAT(N'event_definition_id=', @event_definition_id,
                N';checklist_id=', @checklist_id,
                N';scope=', ISNULL(@scope_dimension, N'ALL'),
                N';role=', ISNULL(CAST(@scope_role_id AS NVARCHAR(20)), N'-'),
                N';asset_category=', ISNULL(CAST(@scope_asset_category_id AS NVARCHAR(20)), N'-'),
                N';release=', ISNULL(CAST(@release_id AS NVARCHAR(20)), N'-')),
         SYSUTCDATETIME());
END;
GO


-- =====================================================================
-- sp_event_scope_mapping_list
--
-- The mapping workspace. Returns EVERY active checklist for the event
-- alongside its mapping state for this scope value, including the ones
-- that are not mapped. A screen that only lists what is already mapped
-- cannot show a gap, and the gap is the thing that matters.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_scope_mapping_list
    @organization_id         BIGINT,
    @event_definition_id     BIGINT       = NULL,
    @scope_dimension         NVARCHAR(40) = NULL,
    @scope_role_id           BIGINT       = NULL,
    @scope_asset_category_id INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 67210, 'sp_event_scope_mapping_list: organization_id is required.', 1;

    SELECT
        c.checklist_id                                   AS ChecklistId,
        c.checklist_code                                 AS ChecklistCode,
        c.checklist_name                                 AS ChecklistName,
        c.version                                        AS ChecklistVersion,
        ed.event_definition_id                           AS EventDefinitionId,
        ed.event_code                                    AS EventCode,
        ed.event_name                                    AS EventName,
        m.mapping_id                                     AS MappingId,
        m.entity_type_id                                 AS EntityTypeId,
        m.scope_dimension                                AS ScopeDimension,
        m.scope_role_id                                  AS ScopeRoleId,
        m.scope_asset_category_id                        AS ScopeAssetCategoryId,
        m.release_id                                     AS ReleaseId,
        m.default_owner_role_id                          AS DefaultOwnerRoleId,
        r.role_name                                      AS DefaultOwnerRoleName,
        m.default_due_period_days                        AS DefaultDuePeriodDays,
        m.status                                         AS MappingStatus,
        CASE
            WHEN m.mapping_id IS NULL              THEN N'Unmapped'
            WHEN m.status <> N'Active'             THEN N'Inactive'
            WHEN m.scope_dimension IS NULL         THEN N'AppliesToAll'
            ELSE N'Mapped'
        END                                              AS MappingState,
        (SELECT COUNT(*) FROM grac_practice.checklist_item ci
          WHERE ci.checklist_id = c.checklist_id AND ci.status = N'Active')
                                                         AS ActiveItemCount
    FROM       grac_practice.checklist c
    CROSS JOIN grac_practice.event_definition ed
    LEFT JOIN  grac_practice.event_checklist_mapping m
           ON  m.organization_id     = c.organization_id
          AND  m.checklist_id        = c.checklist_id
          AND  m.event_definition_id = ed.event_definition_id
          AND  (   (@scope_dimension IS NULL AND m.scope_dimension IS NULL)
                OR (@scope_dimension = N'ORG_ROLE'       AND m.scope_role_id           = @scope_role_id)
                OR (@scope_dimension = N'ASSET_CATEGORY' AND m.scope_asset_category_id = @scope_asset_category_id))
    LEFT JOIN  grac_practice.organization_role r
           ON  r.role_id = m.default_owner_role_id
    WHERE      c.organization_id  = @organization_id
      AND      c.status           = N'Active'
      AND      ed.organization_id = @organization_id
      AND      ed.status          = N'Active'
      AND      (@event_definition_id IS NULL OR ed.event_definition_id = @event_definition_id)
    ORDER BY   ed.event_code, c.checklist_name;
END;
GO


-- =====================================================================
-- sp_event_scope_coverage_list
--
-- One row per scope value with its mapped / unmapped counts -- the
-- coverage rings on the mapping workspace and the input to the gap queue.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_scope_coverage_list
    @organization_id     BIGINT,
    @scope_dimension     NVARCHAR(40),
    @event_definition_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @scope_dimension IS NULL
        THROW 67211, 'sp_event_scope_coverage_list: organization_id and scope_dimension are required.', 1;

    DECLARE @checklist_total INT =
        (SELECT COUNT(*) FROM grac_practice.checklist
          WHERE organization_id = @organization_id AND status = N'Active');

    IF @scope_dimension = N'ORG_ROLE'
    BEGIN
        SELECT
            N'ORG_ROLE'      AS ScopeDimension,
            r.role_id        AS ScopeValueId,
            r.role_name      AS ScopeValueName,
            @checklist_total AS TotalChecklists,
            COUNT(DISTINCT m.checklist_id) AS MappedChecklists,
            @checklist_total - COUNT(DISTINCT m.checklist_id) AS UnmappedChecklists
        FROM      grac_practice.organization_role r
        LEFT JOIN grac_practice.event_checklist_mapping m
               ON m.organization_id = r.organization_id
              AND m.scope_role_id   = r.role_id
              AND m.status          = N'Active'
              AND (@event_definition_id IS NULL OR m.event_definition_id = @event_definition_id)
        WHERE     r.organization_id = @organization_id
          AND     r.status          = N'Active'
        GROUP BY  r.role_id, r.role_name
        ORDER BY  UnmappedChecklists DESC, r.role_name;
    END
    ELSE IF @scope_dimension = N'ASSET_CATEGORY'
    BEGIN
        SELECT
            N'ASSET_CATEGORY'     AS ScopeDimension,
            ac.asset_category_id  AS ScopeValueId,
            ac.asset_category_name AS ScopeValueName,
            @checklist_total      AS TotalChecklists,
            COUNT(DISTINCT m.checklist_id) AS MappedChecklists,
            @checklist_total - COUNT(DISTINCT m.checklist_id) AS UnmappedChecklists
        FROM      grac_practice.dependency_asset_category_master ac
        LEFT JOIN grac_practice.event_checklist_mapping m
               ON m.organization_id         = @organization_id
              AND m.scope_asset_category_id = ac.asset_category_id
              AND m.status                  = N'Active'
              AND (@event_definition_id IS NULL OR m.event_definition_id = @event_definition_id)
        WHERE     ac.is_active = 1
        GROUP BY  ac.asset_category_id, ac.asset_category_name
        ORDER BY  UnmappedChecklists DESC, ac.asset_category_name;
    END
    ELSE
        THROW 67212, 'sp_event_scope_coverage_list: scope_dimension must be ORG_ROLE or ASSET_CATEGORY.', 1;
END;
GO


-- =====================================================================
-- sp_event_instance_raise_scoped
--
-- The resolver. Given an event and a subject it materialises one
-- event_instance per matching mapping, and writes a resolution row for
-- every candidate -- included and excluded alike.
--
-- The excluded rows are not diagnostics. "Why is the asset-disposal check
-- missing from this laptop's decommissioning?" has to be answerable from
-- stored fact months later, when the mappings have moved on.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_instance_raise_scoped
    @organization_id     BIGINT,
    @event_definition_id BIGINT        = NULL,
    @event_code          NVARCHAR(60)  = NULL,
    @subject_entity      NVARCHAR(60),                    -- EMPLOYEE / ASSET
    @subject_record_id   BIGINT,
    @effective_date      DATE          = NULL,
    @trigger_source      NVARCHAR(60)  = N'Manual',
    @payload_json        NVARCHAR(MAX) = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @out_raised_count    INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 67220, 'sp_event_instance_raise_scoped: organization_id is required.', 1;
    IF @subject_entity NOT IN (N'EMPLOYEE', N'ASSET')
        THROW 67221, 'sp_event_instance_raise_scoped: subject_entity must be EMPLOYEE or ASSET.', 1;
    IF @subject_record_id IS NULL
        THROW 67222, 'sp_event_instance_raise_scoped: subject_record_id is required.', 1;

    IF @event_definition_id IS NULL
        SELECT TOP 1 @event_definition_id = event_definition_id
        FROM   grac_practice.event_definition
        WHERE  organization_id = @organization_id
          AND  event_code      = @event_code
          AND  status          = N'Active';

    IF @event_definition_id IS NULL
        THROW 67223, 'sp_event_instance_raise_scoped: event definition not found for organization.', 1;

    SET @effective_date = ISNULL(@effective_date, CAST(SYSUTCDATETIME() AS DATE));
    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');
    SET @out_raised_count = 0;

    -- -----------------------------------------------------------------
    -- Subject snapshot. Frozen here, never re-read: an employee who
    -- changes role in November must not alter their May onboarding trail.
    -- -----------------------------------------------------------------
    DECLARE @subject_label      NVARCHAR(300),
            @asset_category_id  INT           = NULL,
            @asset_category_nm  NVARCHAR(160) = NULL;

    DECLARE @subject_roles TABLE (role_id BIGINT PRIMARY KEY, role_name NVARCHAR(120));

    IF @subject_entity = N'EMPLOYEE'
    BEGIN
        SELECT @subject_label = LEFT(CONCAT(employee_name, N' (', employee_code, N')'), 300)
        FROM   grac_practice.organization_employee
        WHERE  employee_id = @subject_record_id AND organization_id = @organization_id;

        IF @subject_label IS NULL
            THROW 67224, 'sp_event_instance_raise_scoped: employee not found in this organization.', 1;

        -- An employee may legitimately hold several roles; a mapping scoped
        -- to any one of them applies.
        INSERT INTO @subject_roles(role_id, role_name)
        SELECT er.role_id, r.role_name
        FROM   grac_practice.organization_employee_role er
        JOIN   grac_practice.organization_role r ON r.role_id = er.role_id
        WHERE  er.employee_id = @subject_record_id
          AND  er.status      = N'Active'
          AND  r.status       = N'Active';
    END
    ELSE
    BEGIN
        SELECT @subject_label     = LEFT(a.asset_name, 300),
               @asset_category_id = a.asset_category_id,
               @asset_category_nm = ac.asset_category_name
        FROM   grac_practice.organization_dependency_asset a
        LEFT JOIN grac_practice.dependency_asset_category_master ac
               ON ac.asset_category_id = a.asset_category_id
        WHERE  a.asset_id = @subject_record_id AND a.organization_id = @organization_id;

        IF @subject_label IS NULL
            THROW 67225, 'sp_event_instance_raise_scoped: asset not found in this organization.', 1;
    END

    -- A subject with no scope value is a configuration gap, not an error:
    -- record it and return, rather than raising an empty checklist that
    -- nobody can explain.
    IF (@subject_entity = N'EMPLOYEE' AND NOT EXISTS (SELECT 1 FROM @subject_roles))
       OR (@subject_entity = N'ASSET' AND @asset_category_id IS NULL)
    BEGIN
        INSERT INTO grac_practice.event_mapping_resolution
            (organization_id, event_definition_id, subject_entity, subject_record_id,
             subject_label, effective_date, decision, reason_code, reason_detail,
             entered_by, entered_dt)
        VALUES
            (@organization_id, @event_definition_id, @subject_entity, @subject_record_id,
             @subject_label, @effective_date, N'Excluded', N'SubjectScopeMissing',
             CASE WHEN @subject_entity = N'EMPLOYEE'
                  THEN N'Employee has no active role assignment.'
                  ELSE N'Asset has no category assigned.' END,
             @actor, SYSUTCDATETIME());
        RETURN;
    END

    -- -----------------------------------------------------------------
    -- Candidate mappings, each already classified.
    -- -----------------------------------------------------------------
    DECLARE @candidates TABLE (
        mapping_id      BIGINT PRIMARY KEY,
        checklist_id    BIGINT,
        entity_type_id  BIGINT,
        scope_dimension NVARCHAR(40),
        scope_role_id   BIGINT,
        scope_asset_cat INT,
        role_name       NVARCHAR(120),
        release_id      BIGINT,
        owner_role_id   BIGINT,
        due_days        INT,
        decision        NVARCHAR(20),
        reason_code     NVARCHAR(60)
    );

    INSERT INTO @candidates
    SELECT
        m.mapping_id, m.checklist_id, m.entity_type_id,
        m.scope_dimension, m.scope_role_id, m.scope_asset_category_id,
        sr.role_name, m.release_id, m.default_owner_role_id, m.default_due_period_days,
        d.decision, d.reason_code
    FROM  grac_practice.event_checklist_mapping m
    LEFT JOIN @subject_roles sr ON sr.role_id = m.scope_role_id
    LEFT JOIN grac_practice.checklist c ON c.checklist_id = m.checklist_id
    CROSS APPLY (
        SELECT decision, reason_code FROM (VALUES (
            CASE
                WHEN m.status <> N'Active'                       THEN N'Excluded'
                WHEN c.checklist_id IS NULL OR c.status <> N'Active' THEN N'Excluded'
                -- Release filter: NULL means an org-authored checklist that is
                -- always in scope; otherwise the org must actively subscribe.
                WHEN m.release_id IS NOT NULL
                     AND NOT EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
                                      WHERE s.organization_id     = @organization_id
                                        AND s.release_id          = m.release_id
                                        AND s.subscription_status = N'Active'
                                        AND s.status              = N'Active'
                                        AND (s.effective_dt IS NULL OR s.effective_dt <= @effective_date)
                                        AND (s.end_dt       IS NULL OR s.end_dt       >= @effective_date))
                                                                 THEN N'Excluded'
                WHEN m.scope_dimension IS NULL                   THEN N'Included'
                WHEN m.scope_dimension = N'ORG_ROLE'
                     AND sr.role_id IS NOT NULL                  THEN N'Included'
                WHEN m.scope_dimension = N'ASSET_CATEGORY'
                     AND m.scope_asset_category_id = @asset_category_id
                                                                 THEN N'Included'
                ELSE N'Excluded'
            END,
            CASE
                WHEN m.status <> N'Active'                       THEN N'MappingInactive'
                WHEN c.checklist_id IS NULL OR c.status <> N'Active' THEN N'ChecklistInactive'
                WHEN m.release_id IS NOT NULL
                     AND NOT EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
                                      WHERE s.organization_id     = @organization_id
                                        AND s.release_id          = m.release_id
                                        AND s.subscription_status = N'Active'
                                        AND s.status              = N'Active'
                                        AND (s.effective_dt IS NULL OR s.effective_dt <= @effective_date)
                                        AND (s.end_dt       IS NULL OR s.end_dt       >= @effective_date))
                                                                 THEN N'ReleaseNotSubscribed'
                WHEN m.scope_dimension IS NULL                   THEN N'UnscopedMapping'
                WHEN m.scope_dimension = N'ORG_ROLE'
                     AND sr.role_id IS NOT NULL                  THEN N'ScopeMatched'
                WHEN m.scope_dimension = N'ASSET_CATEGORY'
                     AND m.scope_asset_category_id = @asset_category_id
                                                                 THEN N'ScopeMatched'
                ELSE N'ScopeMismatch'
            END
        )) v(decision, reason_code)
    ) d
    WHERE m.organization_id     = @organization_id
      AND m.event_definition_id = @event_definition_id;

    -- Nothing mapped at all for this event: one explicit gap row, so the
    -- coverage queue can show it. Silence here is how compliance holes hide.
    IF NOT EXISTS (SELECT 1 FROM @candidates)
    BEGIN
        INSERT INTO grac_practice.event_mapping_resolution
            (organization_id, event_definition_id, subject_entity, subject_record_id,
             subject_label, effective_date, decision, reason_code, reason_detail,
             scope_role_id, scope_asset_category_id, entered_by, entered_dt)
        VALUES
            (@organization_id, @event_definition_id, @subject_entity, @subject_record_id,
             @subject_label, @effective_date, N'Excluded', N'NoMappingForEvent',
             N'No checklist is mapped to this event for this organization.',
             (SELECT TOP 1 role_id FROM @subject_roles), @asset_category_id,
             @actor, SYSUTCDATETIME());
        RETURN;
    END

    -- -----------------------------------------------------------------
    -- Materialise. One instance per included mapping.
    -- -----------------------------------------------------------------
    DECLARE @mapping_id     BIGINT, @checklist_id BIGINT, @entity_type_id BIGINT,
            @scope_dim      NVARCHAR(40), @m_role_id BIGINT, @m_asset_cat INT,
            @role_name      NVARCHAR(120), @release_id BIGINT,
            @owner_role_id  BIGINT, @due_days INT,
            @instance_id    BIGINT, @owner_emp_id BIGINT, @owner_emp_name NVARCHAR(240),
            @item_count     INT;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT mapping_id, checklist_id, entity_type_id, scope_dimension,
               scope_role_id, scope_asset_cat, role_name, release_id,
               owner_role_id, due_days
        FROM   @candidates
        WHERE  decision = N'Included';

    OPEN cur;
    FETCH NEXT FROM cur INTO @mapping_id, @checklist_id, @entity_type_id, @scope_dim,
                             @m_role_id, @m_asset_cat, @role_name, @release_id,
                             @owner_role_id, @due_days;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Idempotency guard. Mirrors uq_pm_event_instance_open_subject so a
        -- double-fired trigger or a retried API call cannot duplicate work.
        IF EXISTS (SELECT 1 FROM grac_practice.event_instance
                    WHERE organization_id     = @organization_id
                      AND event_definition_id = @event_definition_id
                      AND subject_entity      = @subject_entity
                      AND subject_record_id   = @subject_record_id
                      AND source_mapping_id   = @mapping_id
                      AND status NOT IN (N'Completed', N'Cancelled'))
        BEGIN
            INSERT INTO grac_practice.event_mapping_resolution
                (organization_id, event_definition_id, subject_entity, subject_record_id,
                 subject_label, effective_date, mapping_id, checklist_id,
                 scope_dimension, scope_role_id, scope_asset_category_id, release_id,
                 decision, reason_code, reason_detail, entered_by, entered_dt)
            VALUES
                (@organization_id, @event_definition_id, @subject_entity, @subject_record_id,
                 @subject_label, @effective_date, @mapping_id, @checklist_id,
                 @scope_dim, @m_role_id, @m_asset_cat, @release_id,
                 N'Excluded', N'AlreadyOpen',
                 N'An open instance already exists for this subject and mapping.',
                 @actor, SYSUTCDATETIME());

            FETCH NEXT FROM cur INTO @mapping_id, @checklist_id, @entity_type_id, @scope_dim,
                                     @m_role_id, @m_asset_cat, @role_name, @release_id,
                                     @owner_role_id, @due_days;
            CONTINUE;
        END

        SET @item_count = (SELECT COUNT(*) FROM grac_practice.checklist_item
                            WHERE checklist_id = @checklist_id AND status = N'Active');

        IF @item_count = 0
        BEGIN
            INSERT INTO grac_practice.event_mapping_resolution
                (organization_id, event_definition_id, subject_entity, subject_record_id,
                 subject_label, effective_date, mapping_id, checklist_id,
                 scope_dimension, scope_role_id, scope_asset_category_id, release_id,
                 decision, reason_code, reason_detail, entered_by, entered_dt)
            VALUES
                (@organization_id, @event_definition_id, @subject_entity, @subject_record_id,
                 @subject_label, @effective_date, @mapping_id, @checklist_id,
                 @scope_dim, @m_role_id, @m_asset_cat, @release_id,
                 N'Excluded', N'NoChecklistItems',
                 N'Checklist has no active items; nothing to execute.',
                 @actor, SYSUTCDATETIME());

            FETCH NEXT FROM cur INTO @mapping_id, @checklist_id, @entity_type_id, @scope_dim,
                                     @m_role_id, @m_asset_cat, @role_name, @release_id,
                                     @owner_role_id, @due_days;
            CONTINUE;
        END

        -- Hybrid ownership (115): the role is the permanent position, the
        -- employee is the holder at raise time.
        SET @owner_emp_id = NULL; SET @owner_emp_name = NULL;
        IF @owner_role_id IS NOT NULL
            EXEC grac_practice.sp_org_role_primary_holder_pick
                 @organization_id   = @organization_id,
                 @role_id           = @owner_role_id,
                 @employee_id_out   = @owner_emp_id   OUTPUT,
                 @employee_name_out = @owner_emp_name OUTPUT;

        BEGIN TRAN;

        INSERT INTO grac_practice.event_instance
            (organization_id, event_definition_id, entity_type_id, entity_reference,
             entity_display_name, checklist_id, trigger_source, payload_json,
             owner_employee_id, due_date, status,
             subject_entity, subject_record_id,
             scope_role_id, scope_role_name,
             scope_asset_category_id, scope_asset_category_name,
             release_id, source_mapping_id, effective_date,
             entered_by, entered_dt)
        VALUES
            (@organization_id, @event_definition_id, @entity_type_id,
             CAST(@subject_record_id AS NVARCHAR(200)),
             @subject_label, @checklist_id, ISNULL(@trigger_source, N'Manual'), @payload_json,
             @owner_emp_id,
             -- SLA runs from the effective date, not from now. A backdated
             -- event therefore lands already overdue, which is the truth.
             CASE WHEN @due_days IS NULL THEN NULL
                  ELSE DATEADD(DAY, @due_days, @effective_date) END,
             N'Pending',
             @subject_entity, @subject_record_id,
             CASE WHEN @scope_dim = N'ORG_ROLE' THEN @m_role_id ELSE NULL END,
             @role_name,
             CASE WHEN @scope_dim = N'ASSET_CATEGORY' THEN @m_asset_cat ELSE NULL END,
             CASE WHEN @scope_dim = N'ASSET_CATEGORY' THEN @asset_category_nm ELSE NULL END,
             @release_id, @mapping_id, @effective_date,
             @actor, SYSUTCDATETIME());

        SET @instance_id = SCOPE_IDENTITY();

        INSERT INTO grac_practice.event_instance_item
            (event_instance_id, checklist_item_id, item_status, entered_dt)
        SELECT @instance_id, ci.checklist_item_id, N'Pending', SYSUTCDATETIME()
        FROM   grac_practice.checklist_item ci
        WHERE  ci.checklist_id = @checklist_id AND ci.status = N'Active';

        INSERT INTO grac_practice.event_mapping_resolution
            (organization_id, event_definition_id, subject_entity, subject_record_id,
             subject_label, effective_date, mapping_id, checklist_id,
             scope_dimension, scope_role_id, scope_asset_category_id, release_id,
             decision, reason_code, event_instance_id, entered_by, entered_dt)
        VALUES
            (@organization_id, @event_definition_id, @subject_entity, @subject_record_id,
             @subject_label, @effective_date, @mapping_id, @checklist_id,
             @scope_dim, @m_role_id, @m_asset_cat, @release_id,
             N'Included',
             CASE WHEN @scope_dim IS NULL THEN N'UnscopedMapping' ELSE N'ScopeMatched' END,
             @instance_id, @actor, SYSUTCDATETIME());

        INSERT INTO grac_practice.event_audit
            (organization_id, event_instance_id, entity_type, entity_id,
             action, actor, new_value, entered_dt)
        VALUES
            (@organization_id, @instance_id, N'EventInstance', @instance_id,
             N'Trigger', @actor,
             CONCAT(N'event_definition_id=', @event_definition_id,
                    N';mapping_id=', @mapping_id,
                    N';checklist_id=', @checklist_id,
                    N';subject=', @subject_entity, N':', @subject_record_id,
                    N';effective_date=', CONVERT(NVARCHAR(10), @effective_date, 23)),
             SYSUTCDATETIME());

        COMMIT TRAN;

        SET @out_raised_count = @out_raised_count + 1;

        FETCH NEXT FROM cur INTO @mapping_id, @checklist_id, @entity_type_id, @scope_dim,
                                 @m_role_id, @m_asset_cat, @role_name, @release_id,
                                 @owner_role_id, @due_days;
    END

    CLOSE cur;
    DEALLOCATE cur;

    -- Excluded candidates, recorded in one set-based write.
    INSERT INTO grac_practice.event_mapping_resolution
        (organization_id, event_definition_id, subject_entity, subject_record_id,
         subject_label, effective_date, mapping_id, checklist_id,
         scope_dimension, scope_role_id, scope_asset_category_id, release_id,
         decision, reason_code, entered_by, entered_dt)
    SELECT @organization_id, @event_definition_id, @subject_entity, @subject_record_id,
           @subject_label, @effective_date, c.mapping_id, c.checklist_id,
           c.scope_dimension, c.scope_role_id, c.scope_asset_cat, c.release_id,
           N'Excluded', c.reason_code, @actor, SYSUTCDATETIME()
    FROM   @candidates c
    WHERE  c.decision = N'Excluded';

    SELECT @out_raised_count AS RaisedCount;
END;
GO


-- =====================================================================
-- sp_event_raise_people_lifecycle
--
-- Onboarding / offboarding. Stamps the lifecycle date on the employee and
-- raises the scoped checklists in one call, so the date the SLA is
-- measured from and the date recorded on the employee can never diverge.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_raise_people_lifecycle
    @organization_id   BIGINT,
    @employee_id       BIGINT,
    @lifecycle_action  NVARCHAR(20),                 -- ONBOARD / OFFBOARD
    @effective_date    DATE          = NULL,
    @event_code        NVARCHAR(60)  = NULL,         -- override the default code
    @trigger_source    NVARCHAR(60)  = N'Manual',
    @actor_employee_id BIGINT        = NULL,
    @out_raised_count  INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @lifecycle_action NOT IN (N'ONBOARD', N'OFFBOARD')
        THROW 67230, 'sp_event_raise_people_lifecycle: lifecycle_action must be ONBOARD or OFFBOARD.', 1;

    SET @effective_date = ISNULL(@effective_date, CAST(SYSUTCDATETIME() AS DATE));
    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                    WHERE employee_id = @employee_id AND organization_id = @organization_id)
        THROW 67231, 'sp_event_raise_people_lifecycle: employee not found in this organization.', 1;

    IF @event_code IS NULL
        SET @event_code = CASE @lifecycle_action
                               WHEN N'ONBOARD'  THEN N'PEOPLE_ONBOARDING'
                               ELSE N'PEOPLE_OFFBOARDING' END;

    IF @lifecycle_action = N'ONBOARD'
        UPDATE grac_practice.organization_employee
           SET onboarded_dt = ISNULL(onboarded_dt, @effective_date),
               status       = N'Active',
               updated_by   = @actor, updated_dt = SYSUTCDATETIME()
         WHERE employee_id = @employee_id AND organization_id = @organization_id;
    ELSE
        UPDATE grac_practice.organization_employee
           SET offboarded_dt = @effective_date,
               status        = N'Inactive',
               updated_by    = @actor, updated_dt = SYSUTCDATETIME()
         WHERE employee_id = @employee_id AND organization_id = @organization_id;

    -- Deliberately AFTER the role snapshot is still intact: offboarding must
    -- resolve against the roles the leaver held, so role assignments are not
    -- cleared here. Removing them is a separate, later administrative step.
    EXEC grac_practice.sp_event_instance_raise_scoped
         @organization_id   = @organization_id,
         @event_code        = @event_code,
         @subject_entity    = N'EMPLOYEE',
         @subject_record_id = @employee_id,
         @effective_date    = @effective_date,
         @trigger_source    = @trigger_source,
         @actor_employee_id = @actor_employee_id,
         @out_raised_count  = @out_raised_count OUTPUT;
END;
GO


-- =====================================================================
-- sp_event_raise_asset_lifecycle
--
-- Commissioning / decommissioning. lifecycle_status is the asset's state
-- in service; the record's own status column is left alone -- a
-- decommissioned asset stays an active row for its retention period.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_raise_asset_lifecycle
    @organization_id   BIGINT,
    @asset_id          BIGINT,
    @lifecycle_action  NVARCHAR(20),                 -- COMMISSION / DECOMMISSION
    @effective_date    DATE          = NULL,
    @event_code        NVARCHAR(60)  = NULL,
    @trigger_source    NVARCHAR(60)  = N'Manual',
    @actor_employee_id BIGINT        = NULL,
    @out_raised_count  INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @lifecycle_action NOT IN (N'COMMISSION', N'DECOMMISSION')
        THROW 67240, 'sp_event_raise_asset_lifecycle: lifecycle_action must be COMMISSION or DECOMMISSION.', 1;

    SET @effective_date = ISNULL(@effective_date, CAST(SYSUTCDATETIME() AS DATE));
    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    DECLARE @current_status NVARCHAR(30);
    SELECT @current_status = lifecycle_status
    FROM   grac_practice.organization_dependency_asset
    WHERE  asset_id = @asset_id AND organization_id = @organization_id;

    IF @@ROWCOUNT = 0
        THROW 67241, 'sp_event_raise_asset_lifecycle: asset not found in this organization.', 1;

    IF @lifecycle_action = N'DECOMMISSION' AND @current_status = N'Decommissioned'
        THROW 67242, 'sp_event_raise_asset_lifecycle: asset is already decommissioned.', 1;
    IF @lifecycle_action = N'COMMISSION' AND @current_status = N'Commissioned'
        THROW 67243, 'sp_event_raise_asset_lifecycle: asset is already commissioned.', 1;

    IF @event_code IS NULL
        SET @event_code = CASE @lifecycle_action
                               WHEN N'COMMISSION' THEN N'ASSET_COMMISSIONING'
                               ELSE N'ASSET_DECOMMISSIONING' END;

    IF @lifecycle_action = N'COMMISSION'
        UPDATE grac_practice.organization_dependency_asset
           SET lifecycle_status   = N'Commissioned',
               commissioned_dt    = @effective_date,
               decommissioned_dt  = NULL,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE asset_id = @asset_id AND organization_id = @organization_id;
    ELSE
        UPDATE grac_practice.organization_dependency_asset
           SET lifecycle_status   = N'Decommissioned',
               decommissioned_dt  = @effective_date,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE asset_id = @asset_id AND organization_id = @organization_id;

    EXEC grac_practice.sp_event_instance_raise_scoped
         @organization_id   = @organization_id,
         @event_code        = @event_code,
         @subject_entity    = N'ASSET',
         @subject_record_id = @asset_id,
         @effective_date    = @effective_date,
         @trigger_source    = @trigger_source,
         @actor_employee_id = @actor_employee_id,
         @out_raised_count  = @out_raised_count OUTPUT;
END;
GO


-- =====================================================================
-- sp_event_checklist_inbox_list
--
-- Overdue is DERIVED, never stored. Storing it would need a nightly job
-- that must run forever and will eventually drift out of step with the
-- due dates it is meant to describe.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_checklist_inbox_list
    @organization_id    BIGINT,
    @owner_employee_id  BIGINT       = NULL,
    @subject_entity     NVARCHAR(60) = NULL,
    @status_filter      NVARCHAR(200) = NULL,   -- CSV; NULL = all open states
    @overdue_only       BIT          = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 67250, 'sp_event_checklist_inbox_list: organization_id is required.', 1;

    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    SELECT
        ei.event_instance_id                     AS EventInstanceId,
        ed.event_code                            AS EventCode,
        ed.event_name                            AS EventName,
        ei.subject_entity                        AS SubjectEntity,
        ei.subject_record_id                     AS SubjectRecordId,
        ei.entity_display_name                   AS SubjectLabel,
        ei.scope_role_id                         AS ScopeRoleId,
        ei.scope_role_name                       AS ScopeRoleName,
        ei.scope_asset_category_id               AS ScopeAssetCategoryId,
        ei.scope_asset_category_name             AS ScopeAssetCategoryName,
        c.checklist_id                           AS ChecklistId,
        c.checklist_name                         AS ChecklistName,
        ei.owner_employee_id                     AS OwnerEmployeeId,
        oe.employee_name                         AS OwnerEmployeeName,
        ei.effective_date                        AS EffectiveDate,
        ei.due_date                              AS DueDate,
        ei.status                                AS InstanceStatus,
        CAST(CASE WHEN ei.due_date IS NOT NULL
                   AND ei.due_date < @today
                   AND ei.status NOT IN (N'Completed', N'Cancelled')
                  THEN 1 ELSE 0 END AS BIT)      AS IsOverdue,
        CASE WHEN ei.due_date IS NULL THEN NULL
             ELSE DATEDIFF(DAY, ei.due_date, @today) END AS DaysOverdue,
        (SELECT COUNT(*) FROM grac_practice.event_instance_item ii
          WHERE ii.event_instance_id = ei.event_instance_id)            AS ItemCount,
        (SELECT COUNT(*) FROM grac_practice.event_instance_item ii
          WHERE ii.event_instance_id = ei.event_instance_id
            AND ii.item_status IN (N'Passed', N'Failed', N'NotApplicable')) AS ItemsDone
    FROM       grac_practice.event_instance ei
    JOIN       grac_practice.event_definition ed
           ON  ed.event_definition_id = ei.event_definition_id
    LEFT JOIN  grac_practice.checklist c ON c.checklist_id = ei.checklist_id
    LEFT JOIN  grac_practice.organization_employee oe ON oe.employee_id = ei.owner_employee_id
    WHERE      ei.organization_id = @organization_id
      AND      ei.subject_record_id IS NOT NULL
      AND      (@owner_employee_id IS NULL OR ei.owner_employee_id = @owner_employee_id)
      AND      (@subject_entity    IS NULL OR ei.subject_entity    = @subject_entity)
      AND      (
                 (@status_filter IS NULL AND ei.status NOT IN (N'Completed', N'Cancelled'))
              OR (@status_filter IS NOT NULL
                  AND ei.status IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@status_filter, ',')))
               )
      AND      (@overdue_only = 0
                OR (ei.due_date IS NOT NULL AND ei.due_date < @today
                    AND ei.status NOT IN (N'Completed', N'Cancelled')))
    ORDER BY   CASE WHEN ei.due_date IS NULL THEN 1 ELSE 0 END, ei.due_date, ei.event_instance_id;
END;
GO


-- =====================================================================
-- sp_event_instance_detail_get
--
-- The popup. Result set 1 = header, result set 2 = items.
-- Submission goes through 067's sp_event_instance_item_save and
-- sp_event_instance_complete; nothing new is needed here.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_instance_detail_get
    @organization_id  BIGINT,
    @event_instance_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.event_instance
                    WHERE event_instance_id = @event_instance_id
                      AND organization_id   = @organization_id)
        THROW 67260, 'sp_event_instance_detail_get: instance not found for this organization.', 1;

    SELECT
        ei.event_instance_id           AS EventInstanceId,
        ed.event_code                  AS EventCode,
        ed.event_name                  AS EventName,
        ei.subject_entity              AS SubjectEntity,
        ei.subject_record_id           AS SubjectRecordId,
        ei.entity_display_name         AS SubjectLabel,
        ei.scope_role_id               AS ScopeRoleId,
        ei.scope_role_name             AS ScopeRoleName,
        ei.scope_asset_category_id     AS ScopeAssetCategoryId,
        ei.scope_asset_category_name   AS ScopeAssetCategoryName,
        ei.release_id                  AS ReleaseId,
        ei.source_mapping_id           AS SourceMappingId,
        c.checklist_id                 AS ChecklistId,
        c.checklist_name               AS ChecklistName,
        c.version                      AS ChecklistVersion,
        ei.owner_employee_id           AS OwnerEmployeeId,
        oe.employee_name               AS OwnerEmployeeName,
        ei.effective_date              AS EffectiveDate,
        ei.due_date                    AS DueDate,
        ei.status                      AS InstanceStatus,
        ei.completed_dt                AS CompletedDt,
        ei.comments                    AS Comments
    FROM       grac_practice.event_instance ei
    JOIN       grac_practice.event_definition ed ON ed.event_definition_id = ei.event_definition_id
    LEFT JOIN  grac_practice.checklist c ON c.checklist_id = ei.checklist_id
    LEFT JOIN  grac_practice.organization_employee oe ON oe.employee_id = ei.owner_employee_id
    WHERE      ei.event_instance_id = @event_instance_id;

    SELECT
        ii.event_instance_item_id  AS EventInstanceItemId,
        ci.checklist_item_id       AS ChecklistItemId,
        ci.item_sequence           AS ItemSequence,
        ci.item_text               AS ItemText,
        ci.item_type               AS ItemType,
        ci.is_mandatory            AS IsMandatory,
        ci.evidence_required       AS EvidenceRequired,
        ci.attachment_required     AS AttachmentRequired,
        ci.approval_required       AS ApprovalRequired,
        ci.responsible_role        AS ResponsibleRole,
        ii.item_status             AS ItemStatus,
        ii.evidence_url            AS EvidenceUrl,
        ii.remarks                 AS Remarks,
        ii.completed_by            AS CompletedBy,
        ii.completed_dt            AS CompletedDt
    FROM       grac_practice.event_instance_item ii
    JOIN       grac_practice.checklist_item ci ON ci.checklist_item_id = ii.checklist_item_id
    WHERE      ii.event_instance_id = @event_instance_id
    ORDER BY   ci.item_sequence, ci.checklist_item_id;
END;
GO


-- =====================================================================
-- sp_event_resolution_trace_list
--
-- Two modes:
--   @subject_record_id supplied  -> auditor view for one subject
--   @gaps_only = 1               -> coverage gap queue, deduplicated
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_resolution_trace_list
    @organization_id   BIGINT,
    @subject_entity    NVARCHAR(60) = NULL,
    @subject_record_id BIGINT       = NULL,
    @event_instance_id BIGINT       = NULL,
    @gaps_only         BIT          = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 67270, 'sp_event_resolution_trace_list: organization_id is required.', 1;

    IF @gaps_only = 1
    BEGIN
        -- The gap queue is a GROUP BY over the trace. One writer, one
        -- reader -- no second store that can fall out of step.
        SELECT
            r.reason_code                       AS ReasonCode,
            r.event_definition_id               AS EventDefinitionId,
            ed.event_code                       AS EventCode,
            r.subject_entity                    AS SubjectEntity,
            r.scope_role_id                     AS ScopeRoleId,
            orl.role_name                       AS ScopeRoleName,
            r.scope_asset_category_id           AS ScopeAssetCategoryId,
            ac.asset_category_name              AS ScopeAssetCategoryName,
            COUNT(*)                            AS OccurrenceCount,
            MIN(r.entered_dt)                   AS FirstSeenDt,
            MAX(r.entered_dt)                   AS LastSeenDt
        FROM       grac_practice.event_mapping_resolution r
        JOIN       grac_practice.event_definition ed ON ed.event_definition_id = r.event_definition_id
        LEFT JOIN  grac_practice.organization_role orl ON orl.role_id = r.scope_role_id
        LEFT JOIN  grac_practice.dependency_asset_category_master ac
               ON  ac.asset_category_id = r.scope_asset_category_id
        WHERE      r.organization_id = @organization_id
          AND      r.decision        = N'Excluded'
          AND      r.reason_code IN (N'NoMappingForEvent', N'SubjectScopeMissing',
                                     N'NoChecklistItems', N'ReleaseNotSubscribed')
        GROUP BY   r.reason_code, r.event_definition_id, ed.event_code, r.subject_entity,
                   r.scope_role_id, orl.role_name,
                   r.scope_asset_category_id, ac.asset_category_name
        ORDER BY   OccurrenceCount DESC, ed.event_code;
        RETURN;
    END

    SELECT
        r.resolution_id             AS ResolutionId,
        r.event_definition_id       AS EventDefinitionId,
        ed.event_code               AS EventCode,
        ed.event_name               AS EventName,
        r.subject_entity            AS SubjectEntity,
        r.subject_record_id         AS SubjectRecordId,
        r.subject_label             AS SubjectLabel,
        r.effective_date            AS EffectiveDate,
        r.mapping_id                AS MappingId,
        r.checklist_id              AS ChecklistId,
        c.checklist_name            AS ChecklistName,
        r.scope_dimension           AS ScopeDimension,
        r.scope_role_id             AS ScopeRoleId,
        orl.role_name               AS ScopeRoleName,
        r.scope_asset_category_id   AS ScopeAssetCategoryId,
        ac.asset_category_name      AS ScopeAssetCategoryName,
        r.release_id                AS ReleaseId,
        r.decision                  AS Decision,
        r.reason_code               AS ReasonCode,
        r.reason_detail             AS ReasonDetail,
        r.event_instance_id         AS EventInstanceId,
        r.entered_by                AS EnteredBy,
        r.entered_dt                AS EnteredDt
    FROM       grac_practice.event_mapping_resolution r
    JOIN       grac_practice.event_definition ed ON ed.event_definition_id = r.event_definition_id
    LEFT JOIN  grac_practice.checklist c ON c.checklist_id = r.checklist_id
    LEFT JOIN  grac_practice.organization_role orl ON orl.role_id = r.scope_role_id
    LEFT JOIN  grac_practice.dependency_asset_category_master ac
           ON  ac.asset_category_id = r.scope_asset_category_id
    WHERE      r.organization_id = @organization_id
      AND      (@subject_entity    IS NULL OR r.subject_entity    = @subject_entity)
      AND      (@subject_record_id IS NULL OR r.subject_record_id = @subject_record_id)
      AND      (@event_instance_id IS NULL OR r.event_instance_id = @event_instance_id)
    -- Included first: an auditor reads what fired, then what did not.
    ORDER BY   r.entered_dt DESC, r.decision, r.resolution_id;
END;
GO


-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'sp_event_instance_raise_scoped present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_event_instance_raise_scoped','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'sp_event_raise_people_lifecycle present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_event_raise_people_lifecycle','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'sp_event_raise_asset_lifecycle present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_event_raise_asset_lifecycle','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'sp_event_scope_mapping_list present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_event_scope_mapping_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'sp_event_scope_coverage_list present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_event_scope_coverage_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'sp_event_checklist_inbox_list present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_event_checklist_inbox_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'sp_event_instance_detail_get present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_event_instance_detail_get','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'sp_event_resolution_trace_list present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_event_resolution_trace_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'mapping_save carries scope params' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_event_checklist_mapping_save')
                            AND name = '@scope_role_id')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '124 Event scope mapping procedures deployed.';
GO
