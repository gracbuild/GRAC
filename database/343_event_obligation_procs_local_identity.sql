-- =====================================================================
-- 343 Event-obligation procedures learn the composite obligation identity
--
-- WHAT AND WHY
-- ------------
-- 342 made vw_pm_event_driven_obligation source a custom obligation
-- alongside a catalog one, and gave every row two new columns
-- (local_practice_obligation_id, local_instance_obligation_id) so a
-- custom row can be told apart from a catalog one and from every other
-- custom row. Nothing reads those two columns yet: sp_event_obligation_mapping_list,
-- sp_event_obligation_applicability_save, sp_event_obligation_coverage_list
-- and sp_event_obligation_raise (all four re-issued with a PROFILE branch
-- by 331 -- that is the body each is extended FROM here, not 128's or
-- 131's) still GROUP BY, PARTITION BY, JOIN and COUNT(DISTINCT) on
-- obligation_id alone. Since obligation_id is NULL on every custom row,
-- today's bodies would either silently merge every different custom
-- obligation of the same event type into one row (mapping_list),
-- undercount them entirely (coverage_list's COUNT(DISTINCT) ignores
-- NULL), or fail to insert them at all (raise's @cand table variable has
-- obligation_id as its PRIMARY KEY, and a table variable's key column
-- cannot hold NULL). This migration is the fix -- the four procedures
-- learn to key off whichever of the three identity columns a row actually
-- carries, using the same "exactly one is real" guarantee 341's CHECK
-- constraint already enforces on the table these procedures read.
--
-- THE ISNULL(-1) COMPOSITE-MATCH IDIOM
-- ----------------------------------------
-- Every place that used to compare obligation_id alone now compares all
-- three identity columns with the sentinel idiom this codebase already
-- uses for an optional scope value:
--
--     ISNULL(scope_role_id, -1) = ISNULL(@scope_role_id, -1)
--
-- (sp_event_obligation_applicability_save's own UPDATE, unchanged below).
-- Applied to all three obligation-identity columns together, two rows
-- match only when every one of the three lines up -- NULL with NULL,
-- real value with the same real value -- which is exactly "the same
-- obligation, whichever kind it is". -1 is a safe sentinel because every
-- identity column is an IDENTITY primary key elsewhere, always >= 1.
--
-- WHERE A SINGLE SCALAR KEY WAS UNAVOIDABLE
-- ----------------------------------------------
-- COUNT(DISTINCT expr) takes one expression, not three columns, so
-- sp_event_obligation_coverage_list's denominator needs a single string
-- that is still unique per obligation regardless of kind:
--
--     COALESCE('C' + CAST(obligation_id AS NVARCHAR(20)),
--              'P' + CAST(local_practice_obligation_id AS NVARCHAR(20)),
--              'I' + CAST(local_instance_obligation_id AS NVARCHAR(20)))
--
-- The letter prefix keeps a catalog id 5, a practice-level id 5 and an
-- instance-level id 5 from colliding into one COUNT.
--
-- SCHEMA: event_instance_obligation AND event_mapping_resolution EACH
-- NEED THE SAME TWO COLUMNS 341 GAVE event_obligation_applicability
-- ---------------------------------------------------------------------
-- The applicability DECISION is not the only place a custom obligation's
-- identity has to be recorded. Once sp_event_obligation_raise creates a
-- real checklist item (event_instance_obligation) or a trace row
-- (event_mapping_resolution), that row is the thing the Checklists tab
-- and View Mapped Profiles ultimately read -- so it needs to say which
-- custom obligation it is, not just carry a NULL obligation_id and an
-- applicability_id the reader has to chase back through a join.
--
--   event_instance_obligation.obligation_id: NOT NULL -> NULL (same
--     reason 341 relaxed event_obligation_applicability's), plus the same
--     two local-identity columns and the same exactly-one-of-three CHECK.
--     Every existing row is catalog-sourced (this table is obligation-path
--     only, per 127's own header contrasting it with event_instance_item),
--     so the CHECK holds on data already there.
--
--   event_mapping_resolution.obligation_id was already NULLable (127
--     added it as one of several optional trace columns; the table also
--     serves the checklist path, which never sets it). Gains the same two
--     local-identity columns, but the CHECK here is AT MOST one, not
--     exactly one -- a resolution row can legitimately name no obligation
--     at all (the SubjectScopeMissing / NoMappingForEvent early exits in
--     sp_event_obligation_raise, unchanged by this migration, insert rows
--     with obligation_id NULL today and are not going to start naming an
--     obligation just because this migration ran).
--
-- WHAT THIS MIGRATION DOES NOT TOUCH
-- ---------------------------------
-- sp_event_obligation_coverage_list's role/asset-category/profile
-- branches are otherwise unchanged -- the fix is confined to the
-- denominator and the two COUNT(DISTINCT a.obligation_id) numerators
-- inside each branch, using the same composite-key expression.
-- sp_event_obligation_raise's ranking logic (Included over Excluded,
-- shortest due_days), idempotency guard, owner pick and audit row are
-- 331's, byte for byte -- only the columns and join predicates that
-- assumed obligation_id was the whole identity change.
--
-- SAFE TO RE-RUN. Requires 127, 128, 131, 137, 329, 330, 331, 340, 341, 342.
-- ASCII-only.
--
-- DEPENDS ON: 331 (the four procedure bodies this migration extends),
--             342 (the view columns these bodies now read),
--             341 (the CHECK-guaranteed "exactly one" invariant this
--             migration's composite matches rely on).
-- Rollback:   database/343_event_obligation_procs_local_identity_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR SCHEMA_ID('GRAC_New') IS NULL
BEGIN
    PRINT 'ABORT (343): schema grac_practice or GRAC_New missing.';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.vw_pm_event_driven_obligation','local_practice_obligation_id') IS NULL
BEGIN
    PRINT 'ABORT (343): vw_pm_event_driven_obligation has no local identity columns (run 342 first).';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_event_obligation_raise','P') IS NULL
BEGIN
    PRINT 'ABORT (343): sp_event_obligation_raise missing (run 127/128/131/331 first).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Schema: event_instance_obligation gains the same local identity
--    shape 341 gave event_obligation_applicability.
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('grac_practice.event_instance_obligation')
             AND name = 'obligation_id'
             AND is_nullable = 0)
BEGIN
    ALTER TABLE grac_practice.event_instance_obligation
        ALTER COLUMN obligation_id BIGINT NULL;
    PRINT '343: event_instance_obligation.obligation_id relaxed to NULL-able.';
END
GO

IF COL_LENGTH('grac_practice.event_instance_obligation','local_practice_obligation_id') IS NULL
    ALTER TABLE grac_practice.event_instance_obligation
        ADD local_practice_obligation_id BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_instance_obl_local_practice_obl')
   AND COL_LENGTH('grac_practice.event_instance_obligation','local_practice_obligation_id') IS NOT NULL
    ALTER TABLE grac_practice.event_instance_obligation
        ADD CONSTRAINT fk_pm_event_instance_obl_local_practice_obl
            FOREIGN KEY (local_practice_obligation_id)
            REFERENCES grac_practice.practice_obligation(practice_obligation_id);
GO

IF COL_LENGTH('grac_practice.event_instance_obligation','local_instance_obligation_id') IS NULL
    ALTER TABLE grac_practice.event_instance_obligation
        ADD local_instance_obligation_id BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_instance_obl_local_instance_obl')
   AND COL_LENGTH('grac_practice.event_instance_obligation','local_instance_obligation_id') IS NOT NULL
    ALTER TABLE grac_practice.event_instance_obligation
        ADD CONSTRAINT fk_pm_event_instance_obl_local_instance_obl
            FOREIGN KEY (local_instance_obligation_id)
            REFERENCES grac_practice.practice_instance_obligation(practice_instance_obligation_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_instance_obl_obligation_kind')
   AND COL_LENGTH('grac_practice.event_instance_obligation','local_practice_obligation_id') IS NOT NULL
   AND COL_LENGTH('grac_practice.event_instance_obligation','local_instance_obligation_id') IS NOT NULL
    ALTER TABLE grac_practice.event_instance_obligation
        ADD CONSTRAINT ck_pm_event_instance_obl_obligation_kind CHECK (
            (CASE WHEN obligation_id                  IS NOT NULL THEN 1 ELSE 0 END
           + CASE WHEN local_practice_obligation_id    IS NOT NULL THEN 1 ELSE 0 END
           + CASE WHEN local_instance_obligation_id    IS NOT NULL THEN 1 ELSE 0 END) = 1);
GO
PRINT '343: event_instance_obligation carries local obligation identity.';
GO

-- =====================================================================
-- 2. Schema: event_mapping_resolution gains the same two columns, AT
--    MOST one set -- a resolution row can legitimately name no
--    obligation at all (see header).
-- =====================================================================
IF COL_LENGTH('grac_practice.event_mapping_resolution','local_practice_obligation_id') IS NULL
    ALTER TABLE grac_practice.event_mapping_resolution
        ADD local_practice_obligation_id BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_mapping_resolution_local_practice_obl')
   AND COL_LENGTH('grac_practice.event_mapping_resolution','local_practice_obligation_id') IS NOT NULL
    ALTER TABLE grac_practice.event_mapping_resolution
        ADD CONSTRAINT fk_pm_event_mapping_resolution_local_practice_obl
            FOREIGN KEY (local_practice_obligation_id)
            REFERENCES grac_practice.practice_obligation(practice_obligation_id);
GO

IF COL_LENGTH('grac_practice.event_mapping_resolution','local_instance_obligation_id') IS NULL
    ALTER TABLE grac_practice.event_mapping_resolution
        ADD local_instance_obligation_id BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_event_mapping_resolution_local_instance_obl')
   AND COL_LENGTH('grac_practice.event_mapping_resolution','local_instance_obligation_id') IS NOT NULL
    ALTER TABLE grac_practice.event_mapping_resolution
        ADD CONSTRAINT fk_pm_event_mapping_resolution_local_instance_obl
            FOREIGN KEY (local_instance_obligation_id)
            REFERENCES grac_practice.practice_instance_obligation(practice_instance_obligation_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_mapping_resolution_obligation_kind')
   AND COL_LENGTH('grac_practice.event_mapping_resolution','local_practice_obligation_id') IS NOT NULL
   AND COL_LENGTH('grac_practice.event_mapping_resolution','local_instance_obligation_id') IS NOT NULL
    ALTER TABLE grac_practice.event_mapping_resolution
        ADD CONSTRAINT ck_pm_event_mapping_resolution_obligation_kind CHECK (
            (CASE WHEN obligation_id                  IS NOT NULL THEN 1 ELSE 0 END
           + CASE WHEN local_practice_obligation_id    IS NOT NULL THEN 1 ELSE 0 END
           + CASE WHEN local_instance_obligation_id    IS NOT NULL THEN 1 ELSE 0 END) <= 1);
GO
PRINT '343: event_mapping_resolution carries local obligation identity.';
GO

-- =====================================================================
-- 3. sp_event_obligation_mapping_list -- 331's body, composite identity
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_obligation_mapping_list
    @organization_id         BIGINT,
    @event_type_id           BIGINT       = NULL,
    @event_type_code         NVARCHAR(60) = NULL,
    @scope_dimension         NVARCHAR(40),
    @scope_role_id           BIGINT       = NULL,
    @scope_asset_category_id INT          = NULL,
    @include_unsubscribed    BIT          = 0,
    @profile_id              BIGINT       = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 67300, 'sp_event_obligation_mapping_list: organization_id is required.', 1;
    IF @scope_dimension NOT IN (N'ORG_ROLE', N'ASSET_CATEGORY', N'PROFILE')
        THROW 67301, 'sp_event_obligation_mapping_list: scope_dimension must be ORG_ROLE, ASSET_CATEGORY or PROFILE.', 1;

    -- 137: the scope value is optional here. A NULL simply matches no
    -- applicability row, so every obligation returns as Unmapped -- which is
    -- what a record that does not exist yet actually has. That applies to a
    -- profile being created for the first time in exactly the same way.

    ;WITH v AS (
        SELECT *
        FROM   grac_practice.vw_pm_event_driven_obligation
        WHERE  organization_id = @organization_id
          AND  (@event_type_id   IS NULL OR event_type_id   = @event_type_id)
          AND  (@event_type_code IS NULL OR event_type_code = @event_type_code)
    ),
    -- Migration 343: every GROUP BY / PARTITION BY / JOIN below that used
    -- to key on obligation_id alone now keys on all three identity
    -- columns together -- see the migration header's ISNULL(-1) note.
    agg AS (
        SELECT obligation_id, local_practice_obligation_id, local_instance_obligation_id, event_type_id,
               MAX(CAST(is_subscribed AS INT))             AS any_subscribed,
               COUNT(DISTINCT organization_requirement_id) AS requirement_paths,
               COUNT(DISTINCT practice_id)                 AS practice_count
        FROM   v
        GROUP BY obligation_id, local_practice_obligation_id, local_instance_obligation_id, event_type_id
    ),
    codes AS (
        SELECT DISTINCT obligation_id, local_practice_obligation_id, local_instance_obligation_id, event_type_id, practice_code
        FROM   v WHERE practice_code IS NOT NULL
    ),
    code_agg AS (
        SELECT obligation_id, local_practice_obligation_id, local_instance_obligation_id, event_type_id,
               STRING_AGG(practice_code, N', ') WITHIN GROUP (ORDER BY practice_code) AS practice_codes
        FROM   codes GROUP BY obligation_id, local_practice_obligation_id, local_instance_obligation_id, event_type_id
    ),
    pick AS (
        SELECT v.*,
               ROW_NUMBER() OVER (
                   PARTITION BY v.obligation_id, v.local_practice_obligation_id, v.local_instance_obligation_id, v.event_type_id
                   ORDER BY v.is_subscribed DESC,
                            CASE WHEN v.PracticeApplicability    = N'Applicable' THEN 0 ELSE 1 END,
                            CASE WHEN v.RequirementApplicability = N'Applicable' THEN 0 ELSE 1 END,
                            v.practice_id, v.organization_requirement_id) AS rn
        FROM v
    )
    SELECT
        p.obligation_id                     AS ObligationId,
        -- Migration 343: which of the three identities this row carries,
        -- and a plain label so the client does not have to infer it from
        -- which of the two id columns is non-NULL.
        p.local_practice_obligation_id      AS LocalPracticeObligationId,
        p.local_instance_obligation_id      AS LocalInstanceObligationId,
        CASE WHEN p.obligation_id                 IS NOT NULL THEN N'Catalog'
             WHEN p.local_practice_obligation_id   IS NOT NULL THEN N'PracticeLevel'
             ELSE N'InstanceOnly' END        AS ObligationKind,
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
           ON  ISNULL(a.obligation_id,-1)                = ISNULL(p.obligation_id,-1)
          AND  ISNULL(a.local_practice_obligation_id,-1) = ISNULL(p.local_practice_obligation_id,-1)
          AND  ISNULL(a.local_instance_obligation_id,-1) = ISNULL(p.local_instance_obligation_id,-1)
          AND  a.event_type_id = p.event_type_id
    LEFT JOIN  code_agg ca
           ON  ISNULL(ca.obligation_id,-1)                = ISNULL(p.obligation_id,-1)
          AND  ISNULL(ca.local_practice_obligation_id,-1) = ISNULL(p.local_practice_obligation_id,-1)
          AND  ISNULL(ca.local_instance_obligation_id,-1) = ISNULL(p.local_instance_obligation_id,-1)
          AND  ca.event_type_id = p.event_type_id
    LEFT JOIN  grac_practice.event_obligation_applicability ap
           ON  ap.organization_id = @organization_id
          AND  ISNULL(ap.obligation_id,-1)                = ISNULL(p.obligation_id,-1)
          AND  ISNULL(ap.local_practice_obligation_id,-1) = ISNULL(p.local_practice_obligation_id,-1)
          AND  ISNULL(ap.local_instance_obligation_id,-1) = ISNULL(p.local_instance_obligation_id,-1)
          AND  ap.event_type_id   = p.event_type_id
          AND  (   (@scope_dimension = N'ORG_ROLE'       AND @scope_role_id           IS NOT NULL
                        AND ap.scope_role_id           = @scope_role_id)
                OR (@scope_dimension = N'ASSET_CATEGORY' AND @scope_asset_category_id IS NOT NULL
                        AND ap.scope_asset_category_id = @scope_asset_category_id)
                OR (@scope_dimension = N'PROFILE'        AND @profile_id              IS NOT NULL
                        AND ap.profile_id              = @profile_id))
    LEFT JOIN  grac_practice.organization_role r
           ON  r.role_id = ap.owner_role_id
    WHERE      p.rn = 1
      AND      (@include_unsubscribed = 1 OR a.any_subscribed = 1)
    ORDER BY   p.event_type_code, COALESCE(ca.practice_codes, p.practice_code),
               COALESCE(p.obligation_id, p.local_practice_obligation_id, p.local_instance_obligation_id);
END;
GO
PRINT '343: sp_event_obligation_mapping_list keys on the composite obligation identity.';
GO

-- =====================================================================
-- 4. sp_event_obligation_applicability_save -- 331's body, composite
--    identity. @obligation_id becomes optional; @local_practice_obligation_id
--    and @local_instance_obligation_id are new, exactly one of the three
--    required.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_obligation_applicability_save
    @organization_id         BIGINT,
    @obligation_id           BIGINT        = NULL,
    -- Migration 343: the other two obligation identities. Exactly one of
    -- these three must be supplied -- validated below, same rule 341's
    -- CHECK enforces on the table this proc writes.
    @local_practice_obligation_id BIGINT   = NULL,
    @local_instance_obligation_id BIGINT   = NULL,
    @event_type_id           BIGINT,
    @scope_dimension         NVARCHAR(40),
    @scope_role_id           BIGINT        = NULL,
    @scope_asset_category_id INT           = NULL,
    @is_applicable            BIT           = 1,
    @rationale                NVARCHAR(1000) = NULL,
    @owner_role_id            BIGINT        = NULL,
    @due_days                 INT           = NULL,
    @status                   NVARCHAR(30)  = N'Active',
    @actor_employee_id        BIGINT        = NULL,
    @profile_id               BIGINT        = NULL,
    @out_applicability_id     BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @event_type_id IS NULL
        THROW 67310, 'sp_event_obligation_applicability_save: organization_id and event_type_id are required.', 1;

    -- Migration 343: exactly one obligation identity.
    IF (CASE WHEN @obligation_id                 IS NOT NULL THEN 1 ELSE 0 END
      + CASE WHEN @local_practice_obligation_id   IS NOT NULL THEN 1 ELSE 0 END
      + CASE WHEN @local_instance_obligation_id   IS NOT NULL THEN 1 ELSE 0 END) <> 1
        THROW 67322, 'sp_event_obligation_applicability_save: name exactly one of obligation_id, local_practice_obligation_id or local_instance_obligation_id.', 1;

    IF @scope_dimension NOT IN (N'ORG_ROLE', N'ASSET_CATEGORY', N'PROFILE')
        THROW 67311, 'sp_event_obligation_applicability_save: scope_dimension must be ORG_ROLE, ASSET_CATEGORY or PROFILE.', 1;
    IF @status NOT IN (N'Active', N'Inactive') SET @status = N'Active';

    IF @scope_dimension = N'ORG_ROLE'
    BEGIN
        SET @scope_asset_category_id = NULL;
        SET @profile_id              = NULL;
        IF @scope_role_id IS NULL
            THROW 67312, 'sp_event_obligation_applicability_save: scope_role_id is required for ORG_ROLE.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_role
                        WHERE role_id = @scope_role_id AND organization_id = @organization_id)
            THROW 67313, 'sp_event_obligation_applicability_save: scope_role_id does not belong to this organization.', 1;
    END
    ELSE IF @scope_dimension = N'ASSET_CATEGORY'
    BEGIN
        SET @scope_role_id = NULL;
        SET @profile_id    = NULL;
        IF @scope_asset_category_id IS NULL
            THROW 67314, 'sp_event_obligation_applicability_save: scope_asset_category_id is required for ASSET_CATEGORY.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_category_master
                        WHERE asset_category_id = @scope_asset_category_id AND is_active = 1)
            THROW 67315, 'sp_event_obligation_applicability_save: unknown or inactive asset category.', 1;
    END
    ELSE
    BEGIN
        SET @scope_role_id           = NULL;
        SET @scope_asset_category_id = NULL;
        IF @profile_id IS NULL
            THROW 67319, 'sp_event_obligation_applicability_save: profile_id is required for PROFILE.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.event_profile
                        WHERE profile_id = @profile_id AND organization_id = @organization_id)
            THROW 67324, 'sp_event_obligation_applicability_save: profile_id does not belong to this organization.', 1;
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
    -- Migration 343: matches whichever identity was supplied.
    DECLARE @label NVARCHAR(400), @code NVARCHAR(60), @release BIGINT;
    SELECT TOP 1 @label = v.obligation_label, @code = v.event_type_code, @release = v.release_id
    FROM   grac_practice.vw_pm_event_driven_obligation v
    WHERE  v.organization_id = @organization_id
      AND  v.event_type_id   = @event_type_id
      AND  ISNULL(v.obligation_id,-1)                = ISNULL(@obligation_id,-1)
      AND  ISNULL(v.local_practice_obligation_id,-1) = ISNULL(@local_practice_obligation_id,-1)
      AND  ISNULL(v.local_instance_obligation_id,-1) = ISNULL(@local_instance_obligation_id,-1);

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
       AND ISNULL(obligation_id,-1)                = ISNULL(@obligation_id,-1)
       AND ISNULL(local_practice_obligation_id,-1) = ISNULL(@local_practice_obligation_id,-1)
       AND ISNULL(local_instance_obligation_id,-1) = ISNULL(@local_instance_obligation_id,-1)
       AND event_type_id   = @event_type_id
       AND ISNULL(scope_role_id, -1)           = ISNULL(@scope_role_id, -1)
       AND ISNULL(scope_asset_category_id, -1) = ISNULL(@scope_asset_category_id, -1)
       AND ISNULL(profile_id, -1)              = ISNULL(@profile_id, -1);

    IF @@ROWCOUNT = 0
    BEGIN
        INSERT INTO grac_practice.event_obligation_applicability
            (organization_id, obligation_id, local_practice_obligation_id, local_instance_obligation_id,
             obligation_label, event_type_id, event_type_code,
             release_id, scope_dimension, scope_role_id, scope_asset_category_id, profile_id,
             is_applicable, rationale, owner_role_id, due_days, status, entered_by, entered_dt)
        VALUES
            (@organization_id, @obligation_id, @local_practice_obligation_id, @local_instance_obligation_id,
             @label, @event_type_id, @code,
             @release, @scope_dimension, @scope_role_id, @scope_asset_category_id, @profile_id,
             @is_applicable, @rationale, @owner_role_id, @due_days, @status, @actor, SYSUTCDATETIME());
        SET @out_applicability_id = SCOPE_IDENTITY();
    END

    INSERT INTO grac_practice.event_audit
        (organization_id, entity_type, entity_id, action, actor, new_value, entered_dt)
    VALUES
        (@organization_id, N'Mapping', @out_applicability_id, N'Update', @actor,
         CONCAT(N'obligation_id=', ISNULL(CAST(@obligation_id AS NVARCHAR(20)), N'-'),
                N';local_practice_obligation_id=', ISNULL(CAST(@local_practice_obligation_id AS NVARCHAR(20)), N'-'),
                N';local_instance_obligation_id=', ISNULL(CAST(@local_instance_obligation_id AS NVARCHAR(20)), N'-'),
                N';event_type_id=', @event_type_id,
                N';scope=', @scope_dimension,
                N';role=', ISNULL(CAST(@scope_role_id AS NVARCHAR(20)), N'-'),
                N';asset_category=', ISNULL(CAST(@scope_asset_category_id AS NVARCHAR(20)), N'-'),
                N';profile=', ISNULL(CAST(@profile_id AS NVARCHAR(20)), N'-'),
                N';applicable=', CAST(@is_applicable AS NVARCHAR(1))),
         SYSUTCDATETIME());
END;
GO
PRINT '343: sp_event_obligation_applicability_save accepts local obligation identity.';
GO

-- =====================================================================
-- 5. sp_event_obligation_coverage_list -- 331's body, composite denominator
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
    IF @scope_dimension NOT IN (N'ORG_ROLE', N'ASSET_CATEGORY', N'PROFILE')
        THROW 67321, 'sp_event_obligation_coverage_list: scope_dimension must be ORG_ROLE, ASSET_CATEGORY or PROFILE.', 1;

    -- Denominator: distinct event-driven obligations actually reaching this
    -- organization. DISTINCT matters -- the view fans out per requirement /
    -- practice / release path (see 129).
    --
    -- Migration 343: COUNT(DISTINCT obligation_id) silently ignored every
    -- custom obligation (COUNT DISTINCT drops NULLs, and obligation_id is
    -- NULL on both new branches). A single composite key, letter-prefixed
    -- so a catalog id, a practice-level id and an instance-level id of the
    -- same number cannot collide, replaces it.
    DECLARE @total INT = (
        SELECT COUNT(DISTINCT
                 COALESCE('C' + CAST(obligation_id AS NVARCHAR(20)),
                          'P' + CAST(local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(local_instance_obligation_id AS NVARCHAR(20))))
        FROM   grac_practice.vw_pm_event_driven_obligation
        WHERE  organization_id = @organization_id
          AND  is_subscribed   = 1
          AND  (@event_type_id IS NULL OR event_type_id = @event_type_id));

    IF @scope_dimension = N'ORG_ROLE'
        SELECT N'ORG_ROLE'                     AS ScopeDimension,
               r.role_id                       AS ScopeValueId,
               r.role_name                      AS ScopeValueName,
               @total                           AS TotalObligations,
               COUNT(DISTINCT
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))))  AS DecidedObligations,
               @total - COUNT(DISTINCT
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20)))) AS UndecidedObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 1 THEN
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))) END)
                                                AS ApplicableObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 0 THEN
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))) END)
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
    ELSE IF @scope_dimension = N'ASSET_CATEGORY'
        SELECT N'ASSET_CATEGORY'                AS ScopeDimension,
               ac.asset_category_id             AS ScopeValueId,
               ac.asset_category_name           AS ScopeValueName,
               @total                           AS TotalObligations,
               COUNT(DISTINCT
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))))  AS DecidedObligations,
               @total - COUNT(DISTINCT
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20)))) AS UndecidedObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 1 THEN
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))) END)
                                                AS ApplicableObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 0 THEN
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))) END)
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
    ELSE
        SELECT N'PROFILE'                       AS ScopeDimension,
               p.profile_id                     AS ScopeValueId,
               p.profile_name                   AS ScopeValueName,
               @total                           AS TotalObligations,
               COUNT(DISTINCT
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))))  AS DecidedObligations,
               @total - COUNT(DISTINCT
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20)))) AS UndecidedObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 1 THEN
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))) END)
                                                AS ApplicableObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 0 THEN
                 COALESCE('C' + CAST(a.obligation_id AS NVARCHAR(20)),
                          'P' + CAST(a.local_practice_obligation_id AS NVARCHAR(20)),
                          'I' + CAST(a.local_instance_obligation_id AS NVARCHAR(20))) END)
                                                AS ExcludedObligations
        FROM      grac_practice.event_profile p
        LEFT JOIN grac_practice.event_obligation_applicability a
               ON a.organization_id = p.organization_id
              AND a.profile_id      = p.profile_id
              AND a.status          = N'Active'
              AND (@event_type_id IS NULL OR a.event_type_id = @event_type_id)
        WHERE     p.organization_id = @organization_id
          AND     p.subject_entity  = N'EMPLOYEE'
          AND     p.status          = N'Active'
        GROUP BY  p.profile_id, p.profile_name
        ORDER BY  UndecidedObligations DESC, p.profile_name;
END;
GO
PRINT '343: sp_event_obligation_coverage_list counts custom obligations too.';
GO

-- =====================================================================
-- 6. sp_event_obligation_raise -- 331's body, composite identity end to
--    end: candidate ranking, the @cand table variable, and the rows it
--    writes to event_instance_obligation and event_mapping_resolution.
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
    -- 331 (a)
    DECLARE @profiles TABLE (profile_id BIGINT PRIMARY KEY, profile_name NVARCHAR(200));

    IF @subject_entity = N'EMPLOYEE'
    BEGIN
        SELECT @subject_label = LEFT(CONCAT(employee_name, N' (', employee_code, N')'), 300)
        FROM   grac_practice.organization_employee
        WHERE  employee_id = @subject_record_id AND organization_id = @organization_id;
        IF @subject_label IS NULL
            THROW 67334, 'sp_event_obligation_raise: employee not found in this organization.', 1;

        -- BOTH role sources (131). The Employee form writes
        -- organization_employee.role_id; User Role Assignment writes
        -- organization_employee_role.
        INSERT INTO @roles(role_id, role_name)
        SELECT role_id, MIN(role_name)
        FROM   grac_practice.fn_pm_employee_role_ids(@subject_record_id)
        GROUP BY role_id;

        -- 331 (a): every Active profile whose criteria this employee
        -- satisfies. Evaluated live rather than stored, for the same
        -- reason 127 reads the obligation view live: a profile edited in
        -- GRAC must take effect on the next raise and cannot be allowed
        -- to drift behind a projection.
        INSERT INTO @profiles(profile_id, profile_name)
        SELECT m.profile_id, MIN(m.profile_name)
        FROM   grac_practice.fn_pm_event_profile_matches(
                   @organization_id, N'EMPLOYEE', @subject_record_id) m
        GROUP BY m.profile_id;
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

    -- 331 (b): an employee with no role used to be a dead end, because a
    -- role was the only thing a mapping could be scoped to. A profile can
    -- be scoped on Location and Department alone, so the exit now needs
    -- BOTH to be empty.
    IF (@subject_entity = N'EMPLOYEE'
            AND NOT EXISTS (SELECT 1 FROM @roles)
            AND NOT EXISTS (SELECT 1 FROM @profiles))
       OR (@subject_entity = N'ASSET' AND @asset_cat IS NULL)
    BEGIN
        INSERT INTO grac_practice.event_mapping_resolution
            (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
             subject_label, effective_date, decision, reason_code, reason_detail, entered_by, entered_dt)
        VALUES
            (@organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
             @subject_label, @effective_date, N'Excluded', N'SubjectScopeMissing',
             CASE WHEN @subject_entity = N'EMPLOYEE'
                  THEN N'Employee has no active role (in either organization_employee.role_id or organization_employee_role) and matches no active Profile.'
                  ELSE N'Asset has no category assigned.' END,
             @actor, SYSUTCDATETIME());
        RETURN;
    END

    -- Migration 343: obligation_id is no longer the row's only possible
    -- identity, so it can no longer be the PRIMARY KEY -- a table
    -- variable's key column cannot hold NULL, and a custom obligation's
    -- obligation_id is always NULL. cand_id is a plain surrogate; the
    -- uniqueness that mattered (one candidate row per obligation) is
    -- still enforced below by the ranked CTE's PARTITION BY + rn = 1
    -- filter, exactly as it was when obligation_id carried both jobs.
    DECLARE @cand TABLE (
        cand_id                     INT IDENTITY(1,1) PRIMARY KEY,
        obligation_id               BIGINT NULL,
        local_practice_obligation_id BIGINT NULL,
        local_instance_obligation_id BIGINT NULL,
        obligation_label            NVARCHAR(400),
        obligation_text             NVARCHAR(MAX),
        applicability_id            BIGINT,
        owner_role_id                BIGINT,
        due_days                     INT,
        decision                     NVARCHAR(20),
        reason_code                  NVARCHAR(60),
        profile_id                   BIGINT          -- 331 (c)
    );

    ;WITH raw AS (
        SELECT v.obligation_id, v.local_practice_obligation_id, v.local_instance_obligation_id,
               v.obligation_label, v.obligation_text,
               a.applicability_id, a.owner_role_id, a.due_days,
               a.profile_id,                                   -- 331 (c)
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
              -- Migration 343: match on whichever identity this row carries.
              AND  ISNULL(a.obligation_id,-1)                = ISNULL(v.obligation_id,-1)
              AND  ISNULL(a.local_practice_obligation_id,-1) = ISNULL(v.local_practice_obligation_id,-1)
              AND  ISNULL(a.local_instance_obligation_id,-1) = ISNULL(v.local_instance_obligation_id,-1)
              AND  a.event_type_id   = v.event_type_id
              AND  (   (@subject_entity = N'EMPLOYEE'
                            AND a.scope_role_id IN (SELECT role_id FROM @roles))
                    -- 331 (c): profile decisions sit beside role decisions,
                    -- never instead of them. The ranked window below settles
                    -- any disagreement the same way it has always settled a
                    -- disagreement between two of an employee's roles.
                    OR (@subject_entity = N'EMPLOYEE'
                            AND a.profile_id IN (SELECT profile_id FROM @profiles))
                    OR (@subject_entity = N'ASSET'
                            AND a.scope_asset_category_id = @asset_cat))
        WHERE      v.organization_id = @organization_id
          AND      v.event_type_id   = @event_type_id
          AND      v.is_subscribed   = 1
    ),
    ranked AS (
        SELECT *, ROW_NUMBER() OVER (
                     PARTITION BY obligation_id, local_practice_obligation_id, local_instance_obligation_id
                     ORDER BY CASE WHEN decision = N'Included' THEN 0 ELSE 1 END,
                              CASE WHEN due_days IS NULL THEN 1 ELSE 0 END,
                              due_days, applicability_id) AS rn
        FROM raw
    )
    INSERT INTO @cand
        (obligation_id, local_practice_obligation_id, local_instance_obligation_id,
         obligation_label, obligation_text, applicability_id,
         owner_role_id, due_days, decision, reason_code, profile_id)
    SELECT obligation_id, local_practice_obligation_id, local_instance_obligation_id,
           obligation_label, obligation_text, applicability_id,
           owner_role_id, due_days, decision, reason_code, profile_id
    FROM   ranked WHERE rn = 1;

    -- 331 (c): which profile, if any, produced the decisions being acted
    -- on. Picked from the Included rows so the snapshot names a profile
    -- that actually contributed, not merely one that matched.
    DECLARE @scope_profile    BIGINT = NULL,
            @scope_profile_nm NVARCHAR(200) = NULL;

    SELECT TOP 1 @scope_profile = c.profile_id
    FROM   @cand c
    WHERE  c.decision = N'Included' AND c.profile_id IS NOT NULL
    ORDER BY CASE WHEN c.due_days IS NULL THEN 1 ELSE 0 END, c.due_days, c.applicability_id;

    IF @scope_profile IS NULL
        SELECT TOP 1 @scope_profile = profile_id FROM @profiles ORDER BY profile_id;

    IF @scope_profile IS NOT NULL
        SELECT @scope_profile_nm = profile_name FROM @profiles WHERE profile_id = @scope_profile;

    IF NOT EXISTS (SELECT 1 FROM @cand WHERE decision = N'Included')
    BEGIN
        IF EXISTS (SELECT 1 FROM @cand)
            INSERT INTO grac_practice.event_mapping_resolution
                (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
                 subject_label, effective_date, obligation_id, local_practice_obligation_id, local_instance_obligation_id,
                 obligation_label, applicability_id,
                 scope_role_id, scope_asset_category_id, profile_id, profile_name,
                 decision, reason_code, entered_by, entered_dt)
            SELECT @organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
                   @subject_label, @effective_date, c.obligation_id, c.local_practice_obligation_id, c.local_instance_obligation_id,
                   c.obligation_label, c.applicability_id,
                   (SELECT TOP 1 role_id FROM @roles ORDER BY role_id), @asset_cat,
                   c.profile_id,
                   (SELECT TOP 1 p.profile_name FROM @profiles p WHERE p.profile_id = c.profile_id),
                   N'Excluded', c.reason_code, @actor, SYSUTCDATETIME()
            FROM   @cand c;
        ELSE
            INSERT INTO grac_practice.event_mapping_resolution
                (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
                 subject_label, effective_date, profile_id, profile_name,
                 decision, reason_code, reason_detail, entered_by, entered_dt)
            VALUES
                (@organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
                 @subject_label, @effective_date, @scope_profile, @scope_profile_nm,
                 N'Excluded', N'NoMappingForEvent',
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
             subject_label, effective_date, profile_id, profile_name,
             decision, reason_code, reason_detail, entered_by, entered_dt)
        VALUES
            (@organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
             @subject_label, @effective_date, @scope_profile, @scope_profile_nm,
             N'Excluded', N'AlreadyOpen',
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
         scope_profile_id, scope_profile_name,
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
         CASE WHEN @subject_entity = N'EMPLOYEE' THEN @scope_profile ELSE NULL END,
         CASE WHEN @subject_entity = N'EMPLOYEE' THEN @scope_profile_nm ELSE NULL END,
         @effective_date, @actor, SYSUTCDATETIME());

    DECLARE @instance BIGINT = SCOPE_IDENTITY();

    INSERT INTO grac_practice.event_instance_obligation
        (event_instance_id, organization_id, obligation_id, local_practice_obligation_id, local_instance_obligation_id,
         obligation_label, obligation_text,
         applicability_id, item_sequence, is_mandatory, item_status, entered_dt)
    SELECT @instance, @organization_id, c.obligation_id, c.local_practice_obligation_id, c.local_instance_obligation_id,
           c.obligation_label, c.obligation_text,
           c.applicability_id,
           ROW_NUMBER() OVER (ORDER BY COALESCE(c.obligation_id, c.local_practice_obligation_id, c.local_instance_obligation_id)),
           1, N'Pending', SYSUTCDATETIME()
    FROM   @cand c WHERE c.decision = N'Included';

    SET @out_raised_count = @@ROWCOUNT;

    -- Per-obligation trace. profile_id is the one that decided THAT
    -- obligation, not the instance-level snapshot -- with two profiles
    -- matching, "which profile put this check here?" has a different
    -- answer per row, and collapsing it to one would lose exactly the
    -- fact an auditor asks for.
    INSERT INTO grac_practice.event_mapping_resolution
        (organization_id, event_definition_id, event_type_id, subject_entity, subject_record_id,
         subject_label, effective_date, obligation_id, local_practice_obligation_id, local_instance_obligation_id,
         obligation_label, applicability_id,
         scope_role_id, scope_asset_category_id, profile_id, profile_name,
         decision, reason_code, event_instance_id, entered_by, entered_dt)
    SELECT @organization_id, @event_def, @event_type_id, @subject_entity, @subject_record_id,
           @subject_label, @effective_date, c.obligation_id, c.local_practice_obligation_id, c.local_instance_obligation_id,
           c.obligation_label, c.applicability_id,
           @scope_role, @asset_cat, c.profile_id,
           (SELECT TOP 1 p.profile_name FROM @profiles p WHERE p.profile_id = c.profile_id),
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
                N';profiles=', (SELECT COUNT(1) FROM @profiles),
                N';effective_date=', CONVERT(NVARCHAR(10), @effective_date, 23)),
         SYSUTCDATETIME());

    COMMIT TRAN;

    SELECT @out_raised_count AS RaisedCount, @instance AS EventInstanceId;
END;
GO
PRINT '343: sp_event_obligation_raise raises custom obligations, not only catalog ones.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 343 verification ===';

SELECT '343-a event_instance_obligation.obligation_id is NULL-able' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.event_instance_obligation')
                            AND name = 'obligation_id' AND is_nullable = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '343-b event_instance_obligation local identity columns + CHECK',
       CASE WHEN COL_LENGTH('grac_practice.event_instance_obligation','local_practice_obligation_id') IS NOT NULL
             AND COL_LENGTH('grac_practice.event_instance_obligation','local_instance_obligation_id') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_instance_obl_obligation_kind')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '343-c event_mapping_resolution local identity columns + CHECK',
       CASE WHEN COL_LENGTH('grac_practice.event_mapping_resolution','local_practice_obligation_id') IS NOT NULL
             AND COL_LENGTH('grac_practice.event_mapping_resolution','local_instance_obligation_id') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_event_mapping_resolution_obligation_kind')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '343-d sp_event_obligation_mapping_list projects ObligationKind',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_obligation_mapping_list','P'))
                 LIKE '%AS ObligationKind%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '343-e sp_event_obligation_applicability_save accepts local identity + validates exactly-one',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_event_obligation_applicability_save','P')
                            AND name = '@local_practice_obligation_id')
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_obligation_applicability_save','P'))
                 LIKE '%67322%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '343-f sp_event_obligation_coverage_list uses the composite key',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_obligation_coverage_list','P'))
                 LIKE '%local_practice_obligation_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '343-g sp_event_obligation_raise''s @cand no longer keys on obligation_id alone',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_obligation_raise','P'))
                 LIKE '%cand_id%IDENTITY%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '343-h sp_event_obligation_raise writes local identity onto event_instance_obligation',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_obligation_raise','P'))
                 LIKE '%c.local_practice_obligation_id, c.local_instance_obligation_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Regression guard: existing catalog-only rows in both tables must still
-- satisfy the new CHECKs.
SELECT '343-i existing event_instance_obligation rows satisfy the new CHECK',
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.event_instance_obligation
                 WHERE (CASE WHEN obligation_id                IS NOT NULL THEN 1 ELSE 0 END
                      + CASE WHEN local_practice_obligation_id  IS NOT NULL THEN 1 ELSE 0 END
                      + CASE WHEN local_instance_obligation_id  IS NOT NULL THEN 1 ELSE 0 END) <> 1)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '343-j existing event_mapping_resolution rows satisfy the new CHECK',
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.event_mapping_resolution
                 WHERE (CASE WHEN obligation_id                IS NOT NULL THEN 1 ELSE 0 END
                      + CASE WHEN local_practice_obligation_id  IS NOT NULL THEN 1 ELSE 0 END
                      + CASE WHEN local_instance_obligation_id  IS NOT NULL THEN 1 ELSE 0 END) > 1)
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '343 complete. Configure Checklists, the applicability save, the';
PRINT 'coverage dashboard and the raise resolver all recognise a custom';
PRINT 'obligation now. Next: 344 adds the two new procedures the';
PRINT 'Checklists tab and View Mapped Profiles read directly.';
GO

SET NOEXEC OFF;
GO
