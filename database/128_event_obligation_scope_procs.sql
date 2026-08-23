-- =====================================================================
-- 128 Event Assurance -- obligation-based scoping procedures
--
-- Depends on 066/067, 117, 123, 126, 127.
--
-- Procedures:
--   sp_event_obligation_mapping_list        Mapping workspace (the screen)
--   sp_event_obligation_applicability_save  Record / clear one decision
--   sp_event_obligation_coverage_list       Coverage per role / asset category
--   sp_event_obligation_raise               Resolver: event -> instance + obligations
--   sp_event_raise_people_lifecycle         ALTERED -- now raises both paths
--   sp_event_raise_asset_lifecycle          ALTERED -- now raises both paths
--
-- WHY THE WRAPPERS RAISE BOTH PATHS
-- --------------------------------
-- 124's wrappers called only the checklist resolver. An organization can
-- legitimately have both: obligations inherited from a subscribed release
-- AND its own hand-authored checklists. Making the wrapper do one or the
-- other would force a per-organization configuration switch that nobody
-- would remember to set. They now call both and return the combined count,
-- so existing API and UI callers need no change.
--
-- ERROR CODES: 67300-67399.
--
-- Rollback: 128_event_obligation_scope_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.event_obligation_applicability','U') IS NULL
   OR OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V') IS NULL
BEGIN
    RAISERROR('128: run 127 schema first.', 16, 1);
    RETURN;
END
GO


-- =====================================================================
-- sp_event_obligation_mapping_list
--
-- THE screen query. Returns every event-driven obligation that reaches
-- this organization for the chosen event type, LEFT JOINed to the decision
-- recorded for the chosen scope value -- so obligations with NO decision
-- still appear, as MappingState = 'Unmapped'. A screen that lists only
-- decided rows cannot show a gap, and the gap is the point.
--
-- Column aliases deliberately mirror sp_event_scope_mapping_list where the
-- meaning is the same, so the existing grid needs only its id/label fields
-- repointed rather than a rewrite.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_obligation_mapping_list
    @organization_id         BIGINT,
    @event_type_id           BIGINT       = NULL,
    @event_type_code         NVARCHAR(60) = NULL,
    @scope_dimension         NVARCHAR(40),
    @scope_role_id           BIGINT       = NULL,
    @scope_asset_category_id INT          = NULL,
    @include_unsubscribed    BIT          = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 67300, 'sp_event_obligation_mapping_list: organization_id is required.', 1;
    IF @scope_dimension NOT IN (N'ORG_ROLE', N'ASSET_CATEGORY')
        THROW 67301, 'sp_event_obligation_mapping_list: scope_dimension must be ORG_ROLE or ASSET_CATEGORY.', 1;
    IF @scope_dimension = N'ORG_ROLE' AND @scope_role_id IS NULL
        THROW 67302, 'sp_event_obligation_mapping_list: scope_role_id is required for ORG_ROLE.', 1;
    IF @scope_dimension = N'ASSET_CATEGORY' AND @scope_asset_category_id IS NULL
        THROW 67303, 'sp_event_obligation_mapping_list: scope_asset_category_id is required for ASSET_CATEGORY.', 1;

    SELECT
        v.obligation_id                     AS ObligationId,
        v.obligation_label                  AS ObligationLabel,
        v.obligation_text                   AS ObligationText,
        v.practice_id                       AS PracticeId,
        v.practice_code                     AS PracticeCode,
        v.practice_name                     AS PracticeName,
        v.requirement_code                  AS RequirementCode,
        v.requirement_name                  AS RequirementName,
        v.event_type_id                     AS EventTypeId,
        v.event_type_code                   AS EventTypeCode,
        v.event_type_name                   AS EventTypeName,
        v.subject_entity                    AS SubjectEntity,
        v.release_id                        AS ReleaseId,
        v.is_subscribed                     AS IsSubscribed,
        v.PracticeApplicability             AS PracticeApplicability,
        v.RequirementApplicability          AS RequirementApplicability,

        a.applicability_id                  AS ApplicabilityId,
        a.is_applicable                     AS IsApplicable,
        a.rationale                         AS Rationale,
        a.owner_role_id                     AS OwnerRoleId,
        r.role_name                         AS OwnerRoleName,
        a.due_days                          AS DueDays,
        a.status                            AS MappingStatus,

        CASE
            WHEN a.applicability_id IS NULL          THEN N'Unmapped'
            WHEN a.status <> N'Active'               THEN N'Inactive'
            WHEN a.is_applicable = 0                 THEN N'NotApplicable'
            ELSE N'Mapped'
        END                                 AS MappingState
    FROM       grac_practice.vw_pm_event_driven_obligation v
    LEFT JOIN  grac_practice.event_obligation_applicability a
           ON  a.organization_id = v.organization_id
          AND  a.obligation_id   = v.obligation_id
          AND  a.event_type_id   = v.event_type_id
          AND  (   (@scope_dimension = N'ORG_ROLE'       AND a.scope_role_id           = @scope_role_id)
                OR (@scope_dimension = N'ASSET_CATEGORY' AND a.scope_asset_category_id = @scope_asset_category_id))
    LEFT JOIN  grac_practice.organization_role r
           ON  r.role_id = a.owner_role_id
    WHERE      v.organization_id = @organization_id
      AND      (@event_type_id   IS NULL OR v.event_type_id   = @event_type_id)
      AND      (@event_type_code IS NULL OR v.event_type_code = @event_type_code)
      -- Only obligations the organization actually subscribes to, unless the
      -- caller explicitly wants to see the rest (useful for diagnosis).
      AND      (@include_unsubscribed = 1 OR v.is_subscribed = 1)
    ORDER BY   v.practice_code, v.obligation_id;
END;
GO


-- =====================================================================
-- sp_event_obligation_applicability_save
--
-- Upsert one decision. @is_applicable = 0 requires a rationale -- the
-- schema enforces it, this returns a readable error instead of a
-- constraint violation.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_obligation_applicability_save
    @organization_id         BIGINT,
    @obligation_id           BIGINT,
    @event_type_id           BIGINT,
    @scope_dimension         NVARCHAR(40),
    @scope_role_id           BIGINT        = NULL,
    @scope_asset_category_id INT           = NULL,
    @is_applicable           BIT           = 1,
    @rationale               NVARCHAR(1000) = NULL,
    @owner_role_id           BIGINT        = NULL,
    @due_days                INT           = NULL,
    @status                  NVARCHAR(30)  = N'Active',
    @actor_employee_id       BIGINT        = NULL,
    @out_applicability_id    BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @obligation_id IS NULL OR @event_type_id IS NULL
        THROW 67310, 'sp_event_obligation_applicability_save: organization_id, obligation_id and event_type_id are required.', 1;
    IF @scope_dimension NOT IN (N'ORG_ROLE', N'ASSET_CATEGORY')
        THROW 67311, 'sp_event_obligation_applicability_save: scope_dimension must be ORG_ROLE or ASSET_CATEGORY.', 1;
    IF @status NOT IN (N'Active', N'Inactive') SET @status = N'Active';

    IF @scope_dimension = N'ORG_ROLE'
    BEGIN
        SET @scope_asset_category_id = NULL;
        IF @scope_role_id IS NULL
            THROW 67312, 'sp_event_obligation_applicability_save: scope_role_id is required for ORG_ROLE.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_role
                        WHERE role_id = @scope_role_id AND organization_id = @organization_id)
            THROW 67313, 'sp_event_obligation_applicability_save: scope_role_id does not belong to this organization.', 1;
    END
    ELSE
    BEGIN
        SET @scope_role_id = NULL;
        IF @scope_asset_category_id IS NULL
            THROW 67314, 'sp_event_obligation_applicability_save: scope_asset_category_id is required for ASSET_CATEGORY.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_category_master
                        WHERE asset_category_id = @scope_asset_category_id AND is_active = 1)
            THROW 67315, 'sp_event_obligation_applicability_save: unknown or inactive asset category.', 1;
    END

    IF @is_applicable = 0 AND (@rationale IS NULL OR LEN(LTRIM(RTRIM(@rationale))) = 0)
        THROW 67316, 'sp_event_obligation_applicability_save: a rationale is required when marking an obligation not applicable.', 1;

    IF @owner_role_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role
                        WHERE role_id = @owner_role_id AND organization_id = @organization_id)
        THROW 67317, 'sp_event_obligation_applicability_save: owner_role_id does not belong to this organization.', 1;

    -- The obligation must genuinely be event-driven for this event and reach
    -- this organization. Without this a typo silently creates a mapping that
    -- can never fire, and the coverage screen would report it as configured.
    DECLARE @label NVARCHAR(400), @code NVARCHAR(60), @release BIGINT;
    SELECT TOP 1 @label = v.obligation_label, @code = v.event_type_code, @release = v.release_id
    FROM   grac_practice.vw_pm_event_driven_obligation v
    WHERE  v.organization_id = @organization_id
      AND  v.obligation_id   = @obligation_id
      AND  v.event_type_id   = @event_type_id;

    IF @label IS NULL
        THROW 67318, 'sp_event_obligation_applicability_save: this obligation is not an event-driven obligation of this event type for this organization.', 1;

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    UPDATE grac_practice.event_obligation_applicability
       SET is_applicable    = @is_applicable,
           rationale        = @rationale,
           owner_role_id    = @owner_role_id,
           due_days         = @due_days,
           status           = @status,
           obligation_label = @label,
           event_type_code  = @code,
           release_id       = @release,
           updated_by       = @actor,
           updated_dt       = SYSUTCDATETIME(),
           @out_applicability_id = applicability_id
     WHERE organization_id = @organization_id
       AND obligation_id   = @obligation_id
       AND event_type_id   = @event_type_id
       AND ISNULL(scope_role_id, -1)           = ISNULL(@scope_role_id, -1)
       AND ISNULL(scope_asset_category_id, -1) = ISNULL(@scope_asset_category_id, -1);

    IF @@ROWCOUNT = 0
    BEGIN
        INSERT INTO grac_practice.event_obligation_applicability
            (organization_id, obligation_id, obligation_label, event_type_id, event_type_code,
             release_id, scope_dimension, scope_role_id, scope_asset_category_id,
             is_applicable, rationale, owner_role_id, due_days, status, entered_by, entered_dt)
        VALUES
            (@organization_id, @obligation_id, @label, @event_type_id, @code,
             @release, @scope_dimension, @scope_role_id, @scope_asset_category_id,
             @is_applicable, @rationale, @owner_role_id, @due_days, @status, @actor, SYSUTCDATETIME());
        SET @out_applicability_id = SCOPE_IDENTITY();
    END

    INSERT INTO grac_practice.event_audit
        (organization_id, entity_type, entity_id, action, actor, new_value, entered_dt)
    VALUES
        (@organization_id, N'Mapping', @out_applicability_id, N'Update', @actor,
         CONCAT(N'obligation_id=', @obligation_id,
                N';event_type_id=', @event_type_id,
                N';scope=', @scope_dimension,
                N';role=', ISNULL(CAST(@scope_role_id AS NVARCHAR(20)), N'-'),
                N';asset_category=', ISNULL(CAST(@scope_asset_category_id AS NVARCHAR(20)), N'-'),
                N';applicable=', CAST(@is_applicable AS NVARCHAR(1))),
         SYSUTCDATETIME());
END;
GO


-- =====================================================================
-- sp_event_obligation_coverage_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_obligation_coverage_list
    @organization_id BIGINT,
    @scope_dimension NVARCHAR(40),
    @event_type_id   BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @scope_dimension IS NULL
        THROW 67320, 'sp_event_obligation_coverage_list: organization_id and scope_dimension are required.', 1;

    -- Denominator = event-driven obligations actually reaching this org.
    DECLARE @total INT = (
        SELECT COUNT(DISTINCT obligation_id)
        FROM   grac_practice.vw_pm_event_driven_obligation
        WHERE  organization_id = @organization_id
          AND  is_subscribed   = 1
          AND  (@event_type_id IS NULL OR event_type_id = @event_type_id));

    IF @scope_dimension = N'ORG_ROLE'
        SELECT N'ORG_ROLE'                     AS ScopeDimension,
               r.role_id                       AS ScopeValueId,
               r.role_name                      AS ScopeValueName,
               @total                           AS TotalObligations,
               COUNT(DISTINCT a.obligation_id)  AS DecidedObligations,
               @total - COUNT(DISTINCT a.obligation_id) AS UndecidedObligations
        FROM      grac_practice.organization_role r
        LEFT JOIN grac_practice.event_obligation_applicability a
               ON a.organization_id = r.organization_id
              AND a.scope_role_id   = r.role_id
              AND a.status          = N'Active'
              AND (@event_type_id IS NULL OR a.event_type_id = @event_type_id)
        WHERE     r.organization_id = @organization_id
          AND     r.status          = N'Active'
        GROUP BY  r.role_id, r.role_name
        ORDER BY  UndecidedObligations DESC, r.role_name;
    ELSE IF @scope_dimension = N'ASSET_CATEGORY'
        SELECT N'ASSET_CATEGORY'               AS ScopeDimension,
               ac.asset_category_id            AS ScopeValueId,
               ac.asset_category_name          AS ScopeValueName,
               @total                          AS TotalObligations,
               COUNT(DISTINCT a.obligation_id) AS DecidedObligations,
               @total - COUNT(DISTINCT a.obligation_id) AS UndecidedObligations
        FROM      grac_practice.dependency_asset_category_master ac
        LEFT JOIN grac_practice.event_obligation_applicability a
               ON a.organization_id         = @organization_id
              AND a.scope_asset_category_id = ac.asset_category_id
              AND a.status                  = N'Active'
              AND (@event_type_id IS NULL OR a.event_type_id = @event_type_id)
        WHERE     ac.is_active = 1
        GROUP BY  ac.asset_category_id, ac.asset_category_name
        ORDER BY  UndecidedObligations DESC, ac.asset_category_name;
    ELSE
        THROW 67321, 'sp_event_obligation_coverage_list: scope_dimension must be ORG_ROLE or ASSET_CATEGORY.', 1;
END;
GO


-- =====================================================================
-- sp_event_obligation_raise
--
-- One event_instance per (event, subject) with one event_instance_obligation
-- row per applicable obligation.
--
-- Unlike the checklist path -- where each mapping is a separate deliverable
-- with its own owner and SLA, hence one instance each -- obligations under
-- one event are the SAME deliverable seen at line-item level. Splitting
-- them would give the operator N one-line checklists to close instead of
-- one coherent onboarding pack.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_obligation_raise
    @organization_id   BIGINT,
    @event_type_id     BIGINT        = NULL,
    @event_type_code   NVARCHAR(60)  = NULL,
    @event_definition_id BIGINT      = NULL,   -- 066 event_definition for the header
    @subject_entity    NVARCHAR(60),
    @subject_record_id BIGINT,
    @effective_date    DATE          = NULL,
    @trigger_source    NVARCHAR(60)  = N'Manual',
    @actor_employee_id BIGINT        = NULL,
    @out_raised_count  INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @out_raised_count = 0;

    IF @organization_id IS NULL
        THROW 67330, 'sp_event_obligation_raise: organization_id is required.', 1;
    IF @subject_entity NOT IN (N'EMPLOYEE', N'ASSET')
        THROW 67331, 'sp_event_obligation_raise: subject_entity must be EMPLOYEE or ASSET.', 1;
    IF @subject_record_id IS NULL
        THROW 67332, 'sp_event_obligation_raise: subject_record_id is required.', 1;

    IF @event_type_id IS NULL AND @event_type_code IS NOT NULL
        SELECT @event_type_id = event_type_id
        FROM   GRAC_New.event_type_master
        WHERE  event_code = @event_type_code AND status = N'Active';

    IF @event_type_id IS NULL
        THROW 67333, 'sp_event_obligation_raise: event type not resolved.', 1;

    SELECT @event_type_code = event_code
    FROM   GRAC_New.event_type_master WHERE event_type_id = @event_type_id;

    SET @effective_date = ISNULL(@effective_date, CAST(SYSUTCDATETIME() AS DATE));
    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    -- ---- subject snapshot (frozen; see 123 ADR-05) -------------------
    DECLARE @subject_label NVARCHAR(300),
            @asset_cat     INT = NULL,
            @asset_cat_nm  NVARCHAR(160) = NULL;
    DECLARE @roles TABLE (role_id BIGINT PRIMARY KEY, role_name NVARCHAR(120));

    IF @subject_entity = N'EMPLOYEE'
    BEGIN
        SELECT @subject_label = LEFT(CONCAT(employee_name, N' (', employee_code, N')'), 300)
        FROM   grac_practice.organization_employee
        WHERE  employee_id = @subject_record_id AND organization_id = @organization_id;
        IF @subject_label IS NULL
            THROW 67334, 'sp_event_obligation_raise: employee not found in this organization.', 1;

        INSERT INTO @roles(role_id, role_name)
        SELECT er.role_id, r.role_name
        FROM   grac_practice.organization_employee_role er
        JOIN   grac_practice.organization_role r ON r.role_id = er.role_id
        WHERE  er.employee_id = @subject_record_id
          AND  er.status = N'Active' AND r.status = N'Active';
    END
    ELSE
    BEGIN
        SELECT @subject_label = LEFT(a.asset_name, 300),
               @asset_cat     = a.asset_category_id,
               @asset_cat_nm  = ac.asset_category_name
        FROM   grac_practice.organization_dependency_asset a
        LEFT JOIN grac_practice.dependency_asset_category_master ac
               ON ac.asset_category_id = a.asset_category_id
        WHERE  a.asset_id = @subject_record_id AND a.organization_id = @organization_id;
        IF @subject_label IS NULL
            THROW 67335, 'sp_event_obligation_raise: asset not found in this organization.', 1;
    END

    IF (@subject_entity = N'EMPLOYEE' AND NOT EXISTS (SELECT 1 FROM @roles))
       OR (@subject_entity = N'ASSET' AND @asset_cat IS NULL)
    BEGIN
        INSERT INTO grac_practice.event_mapping_resolution
            (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
             subject_label, effective_date, decision, reason_code, reason_detail, entered_by, entered_dt)
        SELECT @organization_id,
               COALESCE(@event_definition_id,
                        (SELECT MIN(event_definition_id) FROM grac_practice.event_definition
                          WHERE organization_id = @organization_id AND status = N'Active')),
               @event_type_id, @subject_entity, @subject_record_id,
               @subject_label, @effective_date, N'Excluded', N'SubjectScopeMissing',
               CASE WHEN @subject_entity = N'EMPLOYEE'
                    THEN N'Employee has no active role assignment.'
                    ELSE N'Asset has no category assigned.' END,
               @actor, SYSUTCDATETIME();
        RETURN;
    END

    -- ---- candidate obligations --------------------------------------
    DECLARE @cand TABLE (
        obligation_id   BIGINT PRIMARY KEY,
        obligation_label NVARCHAR(400),
        obligation_text NVARCHAR(MAX),
        applicability_id BIGINT,
        owner_role_id   BIGINT,
        due_days        INT,
        decision        NVARCHAR(20),
        reason_code     NVARCHAR(60)
    );

    INSERT INTO @cand
    SELECT DISTINCT
        v.obligation_id, v.obligation_label, v.obligation_text,
        a.applicability_id, a.owner_role_id, a.due_days,
        CASE WHEN a.applicability_id IS NULL           THEN N'Excluded'
             WHEN a.status <> N'Active'                THEN N'Excluded'
             WHEN a.is_applicable = 0                  THEN N'Excluded'
             ELSE N'Included' END,
        CASE WHEN a.applicability_id IS NULL           THEN N'ObligationUnmapped'
             WHEN a.status <> N'Active'                THEN N'MappingInactive'
             WHEN a.is_applicable = 0                  THEN N'ObligationNotApplicable'
             ELSE N'ObligationApplicable' END
    FROM       grac_practice.vw_pm_event_driven_obligation v
    LEFT JOIN  grac_practice.event_obligation_applicability a
           ON  a.organization_id = v.organization_id
          AND  a.obligation_id   = v.obligation_id
          AND  a.event_type_id   = v.event_type_id
          AND  (   (@subject_entity = N'EMPLOYEE'
                        AND a.scope_role_id IN (SELECT role_id FROM @roles))
                OR (@subject_entity = N'ASSET'
                        AND a.scope_asset_category_id = @asset_cat))
    WHERE      v.organization_id = @organization_id
      AND      v.event_type_id   = @event_type_id
      AND      v.is_subscribed   = 1;

    IF NOT EXISTS (SELECT 1 FROM @cand WHERE decision = N'Included')
    BEGIN
        -- Record every candidate anyway: "no obligation was mapped for this
        -- role" has to be a stored fact, not an absence.
        INSERT INTO grac_practice.event_mapping_resolution
            (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
             subject_label, effective_date, obligation_id, obligation_label, applicability_id,
             scope_role_id, scope_asset_category_id,
             decision, reason_code, entered_by, entered_dt)
        SELECT @organization_id,
               COALESCE(@event_definition_id,
                        (SELECT MIN(event_definition_id) FROM grac_practice.event_definition
                          WHERE organization_id = @organization_id AND status = N'Active')),
               @event_type_id, @subject_entity, @subject_record_id,
               @subject_label, @effective_date, c.obligation_id, c.obligation_label, c.applicability_id,
               (SELECT TOP 1 role_id FROM @roles), @asset_cat,
               N'Excluded', c.reason_code, @actor, SYSUTCDATETIME()
        FROM   @cand c;
        RETURN;
    END

    -- ---- idempotency -------------------------------------------------
    IF EXISTS (SELECT 1 FROM grac_practice.event_instance
                WHERE organization_id   = @organization_id
                  AND origin_kind       = N'OBLIGATION'
                  AND event_type_id     = @event_type_id
                  AND subject_entity    = @subject_entity
                  AND subject_record_id = @subject_record_id
                  AND status NOT IN (N'Completed', N'Cancelled'))
    BEGIN
        INSERT INTO grac_practice.event_mapping_resolution
            (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
             subject_label, effective_date, decision, reason_code, reason_detail, entered_by, entered_dt)
        SELECT @organization_id,
               COALESCE(@event_definition_id,
                        (SELECT MIN(event_definition_id) FROM grac_practice.event_definition
                          WHERE organization_id = @organization_id AND status = N'Active')),
               @event_type_id, @subject_entity, @subject_record_id,
               @subject_label, @effective_date, N'Excluded', N'AlreadyOpen',
               N'An open obligation instance already exists for this subject and event.',
               @actor, SYSUTCDATETIME();
        RETURN;
    END

    -- ---- materialise -------------------------------------------------
    DECLARE @event_def BIGINT = @event_definition_id;
    IF @event_def IS NULL
        SELECT TOP 1 @event_def = event_definition_id
        FROM   grac_practice.event_definition
        WHERE  organization_id = @organization_id AND status = N'Active'
        ORDER BY CASE WHEN event_code = @event_type_code THEN 0 ELSE 1 END, event_definition_id;

    IF @event_def IS NULL
        THROW 67336, 'sp_event_obligation_raise: organization has no active event_definition. Run migration 126.', 1;

    -- Owner + SLA come from the most demanding decision in the pack: the
    -- earliest due date wins, otherwise one lax obligation would hide a
    -- strict one behind a later date.
    DECLARE @due_days INT = (SELECT MIN(due_days) FROM @cand WHERE decision = N'Included');
    DECLARE @owner_role BIGINT = (
        SELECT TOP 1 owner_role_id FROM @cand
         WHERE decision = N'Included' AND owner_role_id IS NOT NULL
         ORDER BY due_days);

    DECLARE @owner_emp BIGINT = NULL, @owner_nm NVARCHAR(240) = NULL;
    IF @owner_role IS NOT NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id = @organization_id, @role_id = @owner_role,
             @employee_id_out = @owner_emp OUTPUT, @employee_name_out = @owner_nm OUTPUT;

    DECLARE @scope_role BIGINT = (SELECT TOP 1 role_id FROM @roles);
    DECLARE @scope_role_nm NVARCHAR(120) = (SELECT TOP 1 role_name FROM @roles);

    BEGIN TRAN;

    INSERT INTO grac_practice.event_instance
        (organization_id, event_definition_id, entity_type_id, entity_reference,
         entity_display_name, checklist_id, trigger_source,
         owner_employee_id, due_date, status,
         origin_kind, event_type_id, event_type_code,
         subject_entity, subject_record_id,
         scope_role_id, scope_role_name,
         scope_asset_category_id, scope_asset_category_name,
         effective_date, entered_by, entered_dt)
    VALUES
        (@organization_id, @event_def, NULL, CAST(@subject_record_id AS NVARCHAR(200)),
         @subject_label, NULL, ISNULL(@trigger_source, N'Manual'),
         @owner_emp,
         CASE WHEN @due_days IS NULL THEN NULL ELSE DATEADD(DAY, @due_days, @effective_date) END,
         N'Pending',
         N'OBLIGATION', @event_type_id, @event_type_code,
         @subject_entity, @subject_record_id,
         CASE WHEN @subject_entity = N'EMPLOYEE' THEN @scope_role ELSE NULL END,
         CASE WHEN @subject_entity = N'EMPLOYEE' THEN @scope_role_nm ELSE NULL END,
         CASE WHEN @subject_entity = N'ASSET' THEN @asset_cat ELSE NULL END,
         CASE WHEN @subject_entity = N'ASSET' THEN @asset_cat_nm ELSE NULL END,
         @effective_date, @actor, SYSUTCDATETIME());

    DECLARE @instance BIGINT = SCOPE_IDENTITY();

    INSERT INTO grac_practice.event_instance_obligation
        (event_instance_id, organization_id, obligation_id, obligation_label, obligation_text,
         applicability_id, item_sequence, is_mandatory, item_status, entered_dt)
    SELECT @instance, @organization_id, c.obligation_id, c.obligation_label, c.obligation_text,
           c.applicability_id,
           ROW_NUMBER() OVER (ORDER BY c.obligation_id),
           1, N'Pending', SYSUTCDATETIME()
    FROM   @cand c
    WHERE  c.decision = N'Included';

    SET @out_raised_count = @@ROWCOUNT;

    -- Trace: included and excluded alike.
    INSERT INTO grac_practice.event_mapping_resolution
        (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
         subject_label, effective_date, obligation_id, obligation_label, applicability_id,
         scope_role_id, scope_asset_category_id,
         decision, reason_code, event_instance_id, entered_by, entered_dt)
    SELECT @organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
           @subject_label, @effective_date, c.obligation_id, c.obligation_label, c.applicability_id,
           @scope_role, @asset_cat,
           c.decision, c.reason_code,
           CASE WHEN c.decision = N'Included' THEN @instance ELSE NULL END,
           @actor, SYSUTCDATETIME()
    FROM   @cand c;

    INSERT INTO grac_practice.event_audit
        (organization_id, event_instance_id, entity_type, entity_id, action, actor, new_value, entered_dt)
    VALUES
        (@organization_id, @instance, N'EventInstance', @instance, N'Trigger', @actor,
         CONCAT(N'origin=OBLIGATION;event_type=', @event_type_code,
                N';subject=', @subject_entity, N':', @subject_record_id,
                N';obligations=', @out_raised_count,
                N';effective_date=', CONVERT(NVARCHAR(10), @effective_date, 23)),
         SYSUTCDATETIME());

    COMMIT TRAN;

    SELECT @out_raised_count AS RaisedCount, @instance AS EventInstanceId;
END;
GO


-- =====================================================================
-- sp_event_raise_people_lifecycle  (ALTERED from 124)
--   Now raises the obligation path as well as the checklist path.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_raise_people_lifecycle
    @organization_id   BIGINT,
    @employee_id       BIGINT,
    @lifecycle_action  NVARCHAR(20),
    @effective_date    DATE          = NULL,
    @event_code        NVARCHAR(60)  = NULL,
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
                               WHEN N'ONBOARD' THEN N'PEOPLE_ONBOARDING'
                               ELSE N'PEOPLE_OFFBOARDING' END;

    IF @lifecycle_action = N'ONBOARD'
        UPDATE grac_practice.organization_employee
           SET onboarded_dt = ISNULL(onboarded_dt, @effective_date),
               status = N'Active', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE employee_id = @employee_id AND organization_id = @organization_id;
    ELSE
        UPDATE grac_practice.organization_employee
           SET offboarded_dt = @effective_date,
               status = N'Inactive', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE employee_id = @employee_id AND organization_id = @organization_id;

    DECLARE @checklist_count INT = 0, @obligation_count INT = 0;

    EXEC grac_practice.sp_event_instance_raise_scoped
         @organization_id = @organization_id, @event_code = @event_code,
         @subject_entity = N'EMPLOYEE', @subject_record_id = @employee_id,
         @effective_date = @effective_date, @trigger_source = @trigger_source,
         @actor_employee_id = @actor_employee_id,
         @out_raised_count = @checklist_count OUTPUT;

    -- The obligation event type code mirrors the 066 event code, so the same
    -- string resolves in both taxonomies. If GRAC-ADMIN uses a different
    -- code, pass @event_code explicitly.
    IF EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                WHERE event_code = @event_code AND status = N'Active')
        EXEC grac_practice.sp_event_obligation_raise
             @organization_id = @organization_id, @event_type_code = @event_code,
             @subject_entity = N'EMPLOYEE', @subject_record_id = @employee_id,
             @effective_date = @effective_date, @trigger_source = @trigger_source,
             @actor_employee_id = @actor_employee_id,
             @out_raised_count = @obligation_count OUTPUT;

    SET @out_raised_count = ISNULL(@checklist_count, 0) + ISNULL(@obligation_count, 0);
END;
GO


-- =====================================================================
-- sp_event_raise_asset_lifecycle  (ALTERED from 124)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_raise_asset_lifecycle
    @organization_id   BIGINT,
    @asset_id          BIGINT,
    @lifecycle_action  NVARCHAR(20),
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

    DECLARE @current NVARCHAR(30);
    SELECT @current = lifecycle_status
    FROM   grac_practice.organization_dependency_asset
    WHERE  asset_id = @asset_id AND organization_id = @organization_id;
    IF @@ROWCOUNT = 0
        THROW 67241, 'sp_event_raise_asset_lifecycle: asset not found in this organization.', 1;
    IF @lifecycle_action = N'DECOMMISSION' AND @current = N'Decommissioned'
        THROW 67242, 'sp_event_raise_asset_lifecycle: asset is already decommissioned.', 1;
    IF @lifecycle_action = N'COMMISSION' AND @current = N'Commissioned'
        THROW 67243, 'sp_event_raise_asset_lifecycle: asset is already commissioned.', 1;

    IF @event_code IS NULL
        SET @event_code = CASE @lifecycle_action
                               WHEN N'COMMISSION' THEN N'ASSET_COMMISSIONING'
                               ELSE N'ASSET_DECOMMISSIONING' END;

    IF @lifecycle_action = N'COMMISSION'
        UPDATE grac_practice.organization_dependency_asset
           SET lifecycle_status = N'Commissioned', commissioned_dt = @effective_date,
               decommissioned_dt = NULL, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE asset_id = @asset_id AND organization_id = @organization_id;
    ELSE
        UPDATE grac_practice.organization_dependency_asset
           SET lifecycle_status = N'Decommissioned', decommissioned_dt = @effective_date,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE asset_id = @asset_id AND organization_id = @organization_id;

    DECLARE @checklist_count INT = 0, @obligation_count INT = 0;

    EXEC grac_practice.sp_event_instance_raise_scoped
         @organization_id = @organization_id, @event_code = @event_code,
         @subject_entity = N'ASSET', @subject_record_id = @asset_id,
         @effective_date = @effective_date, @trigger_source = @trigger_source,
         @actor_employee_id = @actor_employee_id,
         @out_raised_count = @checklist_count OUTPUT;

    IF EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                WHERE event_code = @event_code AND status = N'Active')
        EXEC grac_practice.sp_event_obligation_raise
             @organization_id = @organization_id, @event_type_code = @event_code,
             @subject_entity = N'ASSET', @subject_record_id = @asset_id,
             @effective_date = @effective_date, @trigger_source = @trigger_source,
             @actor_employee_id = @actor_employee_id,
             @out_raised_count = @obligation_count OUTPUT;

    SET @out_raised_count = ISNULL(@checklist_count, 0) + ISNULL(@obligation_count, 0);
END;
GO


-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'sp_event_obligation_mapping_list'       AS Check_, CASE WHEN OBJECT_ID('grac_practice.sp_event_obligation_mapping_list','P')       IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'sp_event_obligation_applicability_save', CASE WHEN OBJECT_ID('grac_practice.sp_event_obligation_applicability_save','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_obligation_coverage_list',      CASE WHEN OBJECT_ID('grac_practice.sp_event_obligation_coverage_list','P')      IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_obligation_raise',              CASE WHEN OBJECT_ID('grac_practice.sp_event_obligation_raise','P')              IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

PRINT '128 Obligation-based event scoping procedures deployed.';
GO
