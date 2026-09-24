-- =====================================================================
-- 331 ROLLBACK -- restore the pre-Profile mapping, coverage and resolver
--
-- Re-issues the four procedures exactly as 137 / 128 / 130 / 131 left
-- them. Nothing is dropped: these procedures existed before 331 and must
-- exist after it, or every event raise in the product stops.
--
-- Run this BEFORE 330's rollback (which drops the matcher this file's
-- replacement bodies no longer call) and before 329's.
--
-- Profile-scoped applicability rows, if any exist, become inert: the
-- restored resolver does not look at profile_id. They are not deleted --
-- 329's rollback refuses while they exist, which is the point at which
-- the operator decides what to do with them.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V') IS NULL
BEGIN
    RAISERROR('331 rollback: vw_pm_event_driven_obligation missing. Run 127 and 129 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_event_obligation_mapping_list -- 137's body, verbatim
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

    ;WITH v AS (
        SELECT *
        FROM   grac_practice.vw_pm_event_driven_obligation
        WHERE  organization_id = @organization_id
          AND  (@event_type_id   IS NULL OR event_type_id   = @event_type_id)
          AND  (@event_type_code IS NULL OR event_type_code = @event_type_code)
    ),
    agg AS (
        SELECT obligation_id, event_type_id,
               MAX(CAST(is_subscribed AS INT))             AS any_subscribed,
               COUNT(DISTINCT organization_requirement_id) AS requirement_paths,
               COUNT(DISTINCT practice_id)                 AS practice_count
        FROM   v
        GROUP BY obligation_id, event_type_id
    ),
    codes AS (
        SELECT DISTINCT obligation_id, event_type_id, practice_code
        FROM   v WHERE practice_code IS NOT NULL
    ),
    code_agg AS (
        SELECT obligation_id, event_type_id,
               STRING_AGG(practice_code, N', ') WITHIN GROUP (ORDER BY practice_code) AS practice_codes
        FROM   codes GROUP BY obligation_id, event_type_id
    ),
    pick AS (
        SELECT v.*,
               ROW_NUMBER() OVER (
                   PARTITION BY v.obligation_id, v.event_type_id
                   ORDER BY v.is_subscribed DESC,
                            CASE WHEN v.PracticeApplicability    = N'Applicable' THEN 0 ELSE 1 END,
                            CASE WHEN v.RequirementApplicability = N'Applicable' THEN 0 ELSE 1 END,
                            v.practice_id, v.organization_requirement_id) AS rn
        FROM v
    )
    SELECT
        p.obligation_id                     AS ObligationId,
        p.obligation_label                  AS ObligationLabel,
        p.obligation_text                   AS ObligationText,
        p.practice_id                       AS PracticeId,
        COALESCE(ca.practice_codes, p.practice_code) AS PracticeCode,
        p.practice_name                     AS PracticeName,
        p.requirement_code                  AS RequirementCode,
        p.requirement_name                  AS RequirementName,
        p.event_type_id                     AS EventTypeId,
        p.event_type_code                   AS EventTypeCode,
        p.event_type_name                   AS EventTypeName,
        p.subject_entity                    AS SubjectEntity,
        p.release_id                        AS ReleaseId,
        CAST(a.any_subscribed AS BIT)       AS IsSubscribed,
        p.PracticeApplicability             AS PracticeApplicability,
        p.RequirementApplicability          AS RequirementApplicability,

        ap.applicability_id                 AS ApplicabilityId,
        ap.is_applicable                    AS IsApplicable,
        ap.rationale                        AS Rationale,
        ap.owner_role_id                    AS OwnerRoleId,
        r.role_name                         AS OwnerRoleName,
        ap.due_days                         AS DueDays,
        ap.status                           AS MappingStatus,

        CASE
            WHEN ap.applicability_id IS NULL THEN N'Unmapped'
            WHEN ap.status <> N'Active'      THEN N'Inactive'
            WHEN ap.is_applicable = 0        THEN N'NotApplicable'
            ELSE N'Mapped'
        END                                 AS MappingState
    FROM       pick p
    JOIN       agg a
           ON  a.obligation_id = p.obligation_id AND a.event_type_id = p.event_type_id
    LEFT JOIN  code_agg ca
           ON  ca.obligation_id = p.obligation_id AND ca.event_type_id = p.event_type_id
    LEFT JOIN  grac_practice.event_obligation_applicability ap
           ON  ap.organization_id = @organization_id
          AND  ap.obligation_id   = p.obligation_id
          AND  ap.event_type_id   = p.event_type_id
          AND  (   (@scope_dimension = N'ORG_ROLE'       AND @scope_role_id           IS NOT NULL
                        AND ap.scope_role_id           = @scope_role_id)
                OR (@scope_dimension = N'ASSET_CATEGORY' AND @scope_asset_category_id IS NOT NULL
                        AND ap.scope_asset_category_id = @scope_asset_category_id))
    LEFT JOIN  grac_practice.organization_role r
           ON  r.role_id = ap.owner_role_id
    WHERE      p.rn = 1
      AND      (@include_unsubscribed = 1 OR a.any_subscribed = 1)
    ORDER BY   p.event_type_code, COALESCE(ca.practice_codes, p.practice_code), p.obligation_id;
END;
GO


-- =====================================================================
-- 2. sp_event_obligation_applicability_save -- 128's body, verbatim
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
-- 3. sp_event_obligation_coverage_list -- 130's body, verbatim
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
    IF @scope_dimension NOT IN (N'ORG_ROLE', N'ASSET_CATEGORY')
        THROW 67321, 'sp_event_obligation_coverage_list: scope_dimension must be ORG_ROLE or ASSET_CATEGORY.', 1;

    DECLARE @total INT = (
        SELECT COUNT(DISTINCT obligation_id)
        FROM   grac_practice.vw_pm_event_driven_obligation
        WHERE  organization_id = @organization_id
          AND  is_subscribed   = 1
          AND  (@event_type_id IS NULL OR event_type_id = @event_type_id));

    IF @scope_dimension = N'ORG_ROLE'
        SELECT N'ORG_ROLE'                      AS ScopeDimension,
               r.role_id                        AS ScopeValueId,
               r.role_name                      AS ScopeValueName,
               @total                           AS TotalObligations,
               COUNT(DISTINCT a.obligation_id)  AS DecidedObligations,
               @total - COUNT(DISTINCT a.obligation_id) AS UndecidedObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 1 THEN a.obligation_id END)
                                                AS ApplicableObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 0 THEN a.obligation_id END)
                                                AS ExcludedObligations
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
    ELSE
        SELECT N'ASSET_CATEGORY'                AS ScopeDimension,
               ac.asset_category_id             AS ScopeValueId,
               ac.asset_category_name           AS ScopeValueName,
               @total                           AS TotalObligations,
               COUNT(DISTINCT a.obligation_id)  AS DecidedObligations,
               @total - COUNT(DISTINCT a.obligation_id) AS UndecidedObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 1 THEN a.obligation_id END)
                                                AS ApplicableObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 0 THEN a.obligation_id END)
                                                AS ExcludedObligations
        FROM      grac_practice.dependency_asset_category_master ac
        LEFT JOIN grac_practice.event_obligation_applicability a
               ON a.organization_id         = @organization_id
              AND a.scope_asset_category_id = ac.asset_category_id
              AND a.status                  = N'Active'
              AND (@event_type_id IS NULL OR a.event_type_id = @event_type_id)
        WHERE     ac.is_active = 1
        GROUP BY  ac.asset_category_id, ac.asset_category_name
        ORDER BY  UndecidedObligations DESC, ac.asset_category_name;
END;
GO


-- =====================================================================
-- 4. sp_event_obligation_raise -- 131's body, verbatim
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_obligation_raise
    @organization_id     BIGINT,
    @event_type_id       BIGINT        = NULL,
    @event_type_code     NVARCHAR(60)  = NULL,
    @event_definition_id BIGINT        = NULL,
    @subject_entity      NVARCHAR(60),
    @subject_record_id   BIGINT,
    @effective_date      DATE          = NULL,
    @trigger_source      NVARCHAR(60)  = N'Manual',
    @actor_employee_id   BIGINT        = NULL,
    @out_raised_count    INT           OUTPUT
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
        SELECT role_id, MIN(role_name)
        FROM   grac_practice.fn_pm_employee_role_ids(@subject_record_id)
        GROUP BY role_id;
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

    DECLARE @event_def BIGINT = @event_definition_id;
    IF @event_def IS NULL
        SELECT TOP 1 @event_def = event_definition_id
        FROM   grac_practice.event_definition
        WHERE  organization_id = @organization_id AND status = N'Active'
        ORDER BY CASE WHEN event_code = @event_type_code THEN 0 ELSE 1 END, event_definition_id;

    IF (@subject_entity = N'EMPLOYEE' AND NOT EXISTS (SELECT 1 FROM @roles))
       OR (@subject_entity = N'ASSET' AND @asset_cat IS NULL)
    BEGIN
        INSERT INTO grac_practice.event_mapping_resolution
            (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
             subject_label, effective_date, decision, reason_code, reason_detail, entered_by, entered_dt)
        VALUES
            (@organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
             @subject_label, @effective_date, N'Excluded', N'SubjectScopeMissing',
             CASE WHEN @subject_entity = N'EMPLOYEE'
                  THEN N'Employee has no active role, in either organization_employee.role_id or organization_employee_role.'
                  ELSE N'Asset has no category assigned.' END,
             @actor, SYSUTCDATETIME());
        RETURN;
    END

    DECLARE @cand TABLE (
        obligation_id    BIGINT PRIMARY KEY,
        obligation_label NVARCHAR(400),
        obligation_text  NVARCHAR(MAX),
        applicability_id BIGINT,
        owner_role_id    BIGINT,
        due_days         INT,
        decision         NVARCHAR(20),
        reason_code      NVARCHAR(60)
    );

    ;WITH raw AS (
        SELECT v.obligation_id, v.obligation_label, v.obligation_text,
               a.applicability_id, a.owner_role_id, a.due_days,
               CASE WHEN a.applicability_id IS NULL THEN N'Excluded'
                    WHEN a.status <> N'Active'      THEN N'Excluded'
                    WHEN a.is_applicable = 0        THEN N'Excluded'
                    ELSE N'Included' END AS decision,
               CASE WHEN a.applicability_id IS NULL THEN N'ObligationUnmapped'
                    WHEN a.status <> N'Active'      THEN N'MappingInactive'
                    WHEN a.is_applicable = 0        THEN N'ObligationNotApplicable'
                    ELSE N'ObligationApplicable' END AS reason_code
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
          AND      v.is_subscribed   = 1
    ),
    ranked AS (
        SELECT *, ROW_NUMBER() OVER (
                     PARTITION BY obligation_id
                     ORDER BY CASE WHEN decision = N'Included' THEN 0 ELSE 1 END,
                              CASE WHEN due_days IS NULL THEN 1 ELSE 0 END,
                              due_days, applicability_id) AS rn
        FROM raw
    )
    INSERT INTO @cand
        (obligation_id, obligation_label, obligation_text, applicability_id,
         owner_role_id, due_days, decision, reason_code)
    SELECT obligation_id, obligation_label, obligation_text, applicability_id,
           owner_role_id, due_days, decision, reason_code
    FROM   ranked WHERE rn = 1;

    IF NOT EXISTS (SELECT 1 FROM @cand WHERE decision = N'Included')
    BEGIN
        IF EXISTS (SELECT 1 FROM @cand)
            INSERT INTO grac_practice.event_mapping_resolution
                (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
                 subject_label, effective_date, obligation_id, obligation_label, applicability_id,
                 scope_role_id, scope_asset_category_id, decision, reason_code, entered_by, entered_dt)
            SELECT @organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
                   @subject_label, @effective_date, c.obligation_id, c.obligation_label, c.applicability_id,
                   (SELECT TOP 1 role_id FROM @roles ORDER BY role_id), @asset_cat,
                   N'Excluded', c.reason_code, @actor, SYSUTCDATETIME()
            FROM   @cand c;
        ELSE
            INSERT INTO grac_practice.event_mapping_resolution
                (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
                 subject_label, effective_date, decision, reason_code, reason_detail, entered_by, entered_dt)
            VALUES
                (@organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
                 @subject_label, @effective_date, N'Excluded', N'NoMappingForEvent',
                 N'No event-driven obligation of this event type reaches this organization.',
                 @actor, SYSUTCDATETIME());
        RETURN;
    END

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
        VALUES
            (@organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
             @subject_label, @effective_date, N'Excluded', N'AlreadyOpen',
             N'An open obligation instance already exists for this subject and event.',
             @actor, SYSUTCDATETIME());
        RETURN;
    END

    IF @event_def IS NULL
        THROW 67336, 'sp_event_obligation_raise: organization has no active event_definition. Run migration 126.', 1;

    DECLARE @due_days INT = (SELECT MIN(due_days) FROM @cand WHERE decision = N'Included');
    DECLARE @owner_role BIGINT = (
        SELECT TOP 1 owner_role_id FROM @cand
         WHERE decision = N'Included' AND owner_role_id IS NOT NULL
         ORDER BY CASE WHEN due_days IS NULL THEN 1 ELSE 0 END, due_days);

    DECLARE @owner_emp BIGINT = NULL, @owner_nm NVARCHAR(240) = NULL;
    IF @owner_role IS NOT NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id = @organization_id, @role_id = @owner_role,
             @employee_id_out = @owner_emp OUTPUT, @employee_name_out = @owner_nm OUTPUT;

    DECLARE @scope_role BIGINT = (SELECT TOP 1 role_id FROM @roles ORDER BY role_id);
    DECLARE @scope_role_nm NVARCHAR(120) = (SELECT TOP 1 role_name FROM @roles ORDER BY role_id);

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
           c.applicability_id, ROW_NUMBER() OVER (ORDER BY c.obligation_id),
           1, N'Pending', SYSUTCDATETIME()
    FROM   @cand c WHERE c.decision = N'Included';

    SET @out_raised_count = @@ROWCOUNT;

    INSERT INTO grac_practice.event_mapping_resolution
        (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
         subject_label, effective_date, obligation_id, obligation_label, applicability_id,
         scope_role_id, scope_asset_category_id,
         decision, reason_code, event_instance_id, entered_by, entered_dt)
    SELECT @organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
           @subject_label, @effective_date, c.obligation_id, c.obligation_label, c.applicability_id,
           @scope_role, @asset_cat, c.decision, c.reason_code,
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


SELECT 'pre-331 bodies restored' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_obligation_raise')) NOT LIKE '%fn_pm_event_profile_matches%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_obligation_mapping_list')) NOT LIKE '%N''PROFILE''%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '331 rollback complete -- 137 / 128 / 130 / 131 bodies restored.';
PRINT 'NEXT: 330 rollback, then 329 rollback.';
GO

SET NOEXEC OFF;
GO
