-- =====================================================================
-- 129 Event Assurance -- de-duplicate the obligation resolver
--
-- BUG THIS FIXES
-- --------------
-- The Scoped Obligation Mapping screen listed each obligation more than
-- once. grac_practice.vw_pm_event_driven_obligation is an EXPANSION -- it
-- deliberately returns one row per path an obligation takes to reach the
-- organization -- and 128 selected from it directly. SELECT DISTINCT did
-- not help, because the duplicated rows differ in the very columns that
-- make them distinct.
--
-- There are three independent fan-out sources:
--
--   1. organization_requirement. Migration 012 removed the
--      (organization_id, requirement_code) uniqueness precisely so that
--      "the same requirement can be imported under more than one
--      organization control". Two controls carrying the same requirement
--      therefore produce two rows -- this is the usual cause of seeing
--      exactly two copies.
--   2. practice. uq_pm_practice is
--      (organization_id, organization_requirement_id, practice_code), so a
--      requirement may legitimately have several practices.
--   3. obligation_requirement_release_map. One obligation can be mapped to
--      the same requirement across several releases.
--
-- The view is left as-is: that expansion is what makes it useful for
-- diagnosis ("which path is broken?"). The RESOLVER is what must collapse
-- it, because the unit of decision is
--     (organization, obligation, event type, scope value)
-- and the grid has to be keyed the same way. Otherwise ticking one copy
-- writes the row the other copy also represents, and the two disagree on
-- screen until a refresh.
--
-- ALSO FIXED -- a latent crash
-- ----------------------------
-- sp_event_obligation_raise inserted the candidate set into a table
-- variable whose PRIMARY KEY is obligation_id. With any of the fan-outs
-- above -- or simply an employee holding two roles that both map the same
-- obligation -- that INSERT would have thrown a primary key violation and
-- the raise would have failed outright. It now ranks and takes one row per
-- obligation, preferring an applicable decision.
--
-- Requires SQL Server 2017+ for STRING_AGG (the repo already targets 2019+).
--
-- Depends on 127, 128.
-- Rollback: 129_event_obligation_dedupe_procs_rollback.sql (restores 128).
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V') IS NULL
   OR OBJECT_ID('grac_practice.sp_event_obligation_raise','P') IS NULL
BEGIN
    RAISERROR('129: run 127 and 128 first.', 16, 1);
    RETURN;
END
GO


-- =====================================================================
-- sp_event_obligation_mapping_list  -- one row per (obligation, event type)
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

    ;WITH v AS (
        SELECT *
        FROM   grac_practice.vw_pm_event_driven_obligation
        WHERE  organization_id = @organization_id
          AND  (@event_type_id   IS NULL OR event_type_id   = @event_type_id)
          AND  (@event_type_code IS NULL OR event_type_code = @event_type_code)
    ),
    -- Subscribed via ANY path counts as subscribed. Reporting an obligation
    -- as unsubscribed because one of its two releases is not subscribed
    -- would hide work the organization genuinely owes.
    agg AS (
        SELECT obligation_id, event_type_id,
               MAX(CAST(is_subscribed AS INT))            AS any_subscribed,
               COUNT(DISTINCT organization_requirement_id) AS requirement_paths,
               COUNT(DISTINCT practice_id)                AS practice_count
        FROM   v
        GROUP BY obligation_id, event_type_id
    ),
    -- STRING_AGG has no DISTINCT, so de-duplicate first. Showing every
    -- practice an obligation arrives through matters: the user has to know
    -- one decision here governs all of them.
    codes AS (
        SELECT DISTINCT obligation_id, event_type_id, practice_code
        FROM   v WHERE practice_code IS NOT NULL
    ),
    code_agg AS (
        SELECT obligation_id, event_type_id,
               STRING_AGG(practice_code, N', ') WITHIN GROUP (ORDER BY practice_code) AS practice_codes
        FROM   codes GROUP BY obligation_id, event_type_id
    ),
    -- Representative row: prefer a subscribed path, then an applicable
    -- practice, so the context shown is the one that actually fires.
    pick AS (
        SELECT v.*,
               ROW_NUMBER() OVER (
                   PARTITION BY v.obligation_id, v.event_type_id
                   ORDER BY v.is_subscribed DESC,
                            CASE WHEN v.PracticeApplicability   = N'Applicable' THEN 0 ELSE 1 END,
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
          AND  (   (@scope_dimension = N'ORG_ROLE'       AND ap.scope_role_id           = @scope_role_id)
                OR (@scope_dimension = N'ASSET_CATEGORY' AND ap.scope_asset_category_id = @scope_asset_category_id))
    LEFT JOIN  grac_practice.organization_role r
           ON  r.role_id = ap.owner_role_id
    WHERE      p.rn = 1
      AND      (@include_unsubscribed = 1 OR a.any_subscribed = 1)
    ORDER BY   p.event_type_code, COALESCE(ca.practice_codes, p.practice_code), p.obligation_id;
END;
GO


-- =====================================================================
-- sp_event_obligation_raise  -- one candidate row per obligation
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

    -- ---- subject snapshot (frozen; see 123) --------------------------
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
        SELECT er.role_id, MIN(r.role_name)
        FROM   grac_practice.organization_employee_role er
        JOIN   grac_practice.organization_role r ON r.role_id = er.role_id
        WHERE  er.employee_id = @subject_record_id
          AND  er.status = N'Active' AND r.status = N'Active'
        GROUP BY er.role_id;
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
                  THEN N'Employee has no active role assignment.'
                  ELSE N'Asset has no category assigned.' END,
             @actor, SYSUTCDATETIME());
        RETURN;
    END

    -- ---- candidate obligations, exactly one row each -----------------
    --
    -- The rank prefers an Included decision: an employee holding two roles,
    -- one of which maps the obligation as applicable, owes the obligation.
    -- Ranking the other way round would let a single "not applicable" role
    -- suppress a requirement the person genuinely carries.
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
                              due_days,
                              applicability_id) AS rn
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
                   (SELECT TOP 1 role_id FROM @roles), @asset_cat,
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
        VALUES
            (@organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
             @subject_label, @effective_date, N'Excluded', N'AlreadyOpen',
             N'An open obligation instance already exists for this subject and event.',
             @actor, SYSUTCDATETIME());
        RETURN;
    END

    IF @event_def IS NULL
        THROW 67336, 'sp_event_obligation_raise: organization has no active event_definition. Run migration 126.', 1;

    -- Earliest due date wins, otherwise one lax obligation would hide a
    -- strict one behind a later date.
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
           c.applicability_id,
           ROW_NUMBER() OVER (ORDER BY c.obligation_id),
           1, N'Pending', SYSUTCDATETIME()
    FROM   @cand c
    WHERE  c.decision = N'Included';

    SET @out_raised_count = @@ROWCOUNT;

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
-- Sanity report -- duplication must be gone
-- =====================================================================
SELECT 'sp_event_obligation_mapping_list present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_event_obligation_mapping_list','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'sp_event_obligation_raise present',
       CASE WHEN OBJECT_ID('grac_practice.sp_event_obligation_raise','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

-- Where the fan-out comes from, per organization. Any count above 1 is a
-- path that WAS producing a duplicate row before this migration.
PRINT '--- Fan-out sources per obligation (expected: resolver now returns 1 row each) ---';
SELECT organization_id,
       obligation_id,
       MAX(obligation_label)                       AS ObligationLabel,
       event_type_code                             AS EventTypeCode,
       COUNT(*)                                    AS ViewRows,
       COUNT(DISTINCT organization_requirement_id) AS RequirementPaths,
       COUNT(DISTINCT practice_id)                 AS Practices,
       COUNT(DISTINCT release_id)                  AS Releases
FROM   grac_practice.vw_pm_event_driven_obligation
GROUP BY organization_id, obligation_id, event_type_code
HAVING COUNT(*) > 1
ORDER BY ViewRows DESC, organization_id, obligation_id;

PRINT '129 Obligation resolver de-duplication deployed.';
GO
