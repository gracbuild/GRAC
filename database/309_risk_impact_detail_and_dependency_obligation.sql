-- =====================================================================
-- WITHDRAWN -- DO NOT RUN. This script now aborts on purpose.
--
-- The feature it supports was withdrawn before this migration was ever
-- applied. "Impact Details" on the risk pages is the existing
-- by-Operationalize-category table of impacted assets, vendors and
-- people -- risk_dependency_map, migration 265 -- which 309 never
-- touched. The narrative impact records and the
-- dependency-to-obligation attribution are not wanted.
--
--   * If 309 was never applied (the expected case), nothing to do. The
--     abort below stops it if this file is run by mistake.
--   * If it WAS applied, run
--     309_risk_impact_detail_and_dependency_obligation_rollback.sql.
--
-- 309 remains the CLAIMED migration number: it is burnt, not reusable.
-- The next new migration is 310 (308 is still reserved for 307's
-- deferred obligation-guard re-issues).
--
-- To un-withdraw, delete the ABORT block below this banner and nothing
-- else -- the body is unchanged and still correct for what it builds.
-- =====================================================================
PRINT '';
PRINT 'ABORT (309): this migration is WITHDRAWN and was never applied.';
PRINT '             The Impact Details feature it backs was replaced by';
PRINT '             the existing risk_dependency_map table (265).';
PRINT '             Nothing was changed. See the file header.';
SET NOEXEC ON;
GO

-- =====================================================================
-- 309 Risk Centre -- Impact Details, and dependencies attributed to an
--     obligation
--
-- Phase 1 of docs/risk-obligation-structure.md, which was written after
-- inspecting the existing model and is where the reasoning lives. The
-- short version:
--
--   * A risk has no obligation LIST -- risk_register.linked_obligation_id
--     is one nullable column and the UI never renders it. The list is
--     DERIVED from the practices in risk_practice_map (decision 1), so
--     nothing here stores obligations.
--   * Nothing associates a dependency with an obligation, upstream or
--     here: Operationalize resolves dependencies per practice INSTANCE
--     per CATEGORY. So the attribution is new (decision 2).
--   * "Impact" today is a 1-10 SCORE (risk_impact_master) plus one
--     free-text box. Impact Details as addable records did not exist at
--     all, so this is a new feature, not a restructure (decision 3).
--
-- MIGRATION NUMBER
--   308 is reserved for the two obligation-guard procedure re-issues
--   that 307 deferred (see docs/practice-level-obligations.md). This is
--   309 so the two can land in either order.
--
-- ADDITIVE ONLY -- NO EXISTING PROCEDURE IS RE-ISSUED
--   Three new tables and five new procedures. risk_register,
--   risk_practice_map, risk_dependency_map and
--   risk_dependency_map_source keep their shapes and their data, and
--   every dependency mapped so far stays visible: with no attribution it
--   simply reads as "not attributed to an obligation", which is what the
--   UI groups it under. There is nothing to back-fill from -- the
--   association never existed -- so nothing is invented.
--
-- ERROR CODES 56800-56829. The Risk Centre owns 566xx-567xx (highest in
-- use: 56769); 568xx was free.
--
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
--
-- Idempotent: guarded CREATE TABLE, insert-only seed, CREATE OR ALTER
-- procedures. Safe to re-run.
--
-- DEPENDS ON: 204 (risk_impact_master), 205 (risk_register,
--             risk_register_history), 261 (risk_practice_map),
--             265 (risk_dependency_map + _source).
-- Rollback:   database/309_risk_impact_detail_and_dependency_obligation_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
-- WITHDRAWN (see the banner at the top of this file). This line was
-- 'SET NOEXEC OFF' -- a defensive reset in case a prior script left it
-- on -- and it is commented out precisely because it would cancel that
-- abort. Un-comment it only when un-withdrawing the migration.
-- SET NOEXEC OFF;
GO

-- ---------------------------------------------------------------------
-- Prerequisites. Columns as well as tables: a procedure below reads
-- every one of these, and on a database missing one, CREATE OR ALTER
-- fails with Msg 207 while the PRINTs after it still run -- a script
-- that looks half-applied and changed nothing.
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (309): schema grac_practice missing. Run base scripts first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
   OR OBJECT_ID('grac_practice.risk_register_history','U') IS NULL
BEGIN
    PRINT 'ABORT (309): risk_register / risk_register_history missing. Run 205 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.risk_impact_master','U') IS NULL
BEGIN
    PRINT 'ABORT (309): risk_impact_master missing. Run 204 first -- Impact Details';
    PRINT '             takes its severity levels from it rather than inventing a scale.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.risk_dependency_map','U') IS NULL
BEGIN
    PRINT 'ABORT (309): risk_dependency_map missing. Run 265 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN
    PRINT 'ABORT (309): record_status_master missing. Run 002 / 008 first.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.risk_register','status_code') IS NULL
BEGIN
    PRINT 'ABORT (309): risk_register.status_code missing. Run 205 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('309_risk_impact_detail_and_dependency_obligation: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. risk_dependency_obligation -- which obligation a mapped dependency
--    is attributed to
--
--    A JOIN TABLE, not a column on risk_dependency_map. That table's
--    grain is (risk, category, object) and its UNIQUE constraint is what
--    stops one dependency being listed twice when it arrives through two
--    practices -- 265's header calls that out by name. Putting
--    obligation_id into that key would either break the rule or force
--    exactly ONE obligation per dependency, and a dependency genuinely
--    can matter to several obligations of the same practice.
--
--    obligation_id is a SOFT reference, for the reason 265 gives for
--    dependency_object_id: the obligation may be a published one
--    (GRAC_New.requirement_obligation, another database) or an
--    organisation-defined one (practice_instance_obligation), and one
--    column cannot reference both. obligation_name is frozen alongside
--    it the way 261 freezes practice_name -- a rename upstream must not
--    silently rewrite what an audit trail said the risk touched.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_dependency_obligation','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.risk_dependency_obligation(
        risk_dependency_obligation_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_risk_dep_obl PRIMARY KEY,
        risk_dependency_map_id BIGINT NOT NULL
            CONSTRAINT fk_pm_risk_dep_obl_map
                REFERENCES grac_practice.risk_dependency_map(risk_dependency_map_id),

        -- Soft reference; see the header above.
        obligation_id          BIGINT NOT NULL,
        obligation_name        NVARCHAR(500) NULL,
        -- Which side the id belongs to, so a reader (and a future join)
        -- knows which table to look in. Published = GRAC_New,
        -- Organization = practice_instance_obligation / practice_obligation.
        obligation_origin_code NVARCHAR(20) NOT NULL
            CONSTRAINT df_pm_risk_dep_obl_origin DEFAULT N'Published'
            CONSTRAINT ck_pm_risk_dep_obl_origin
                CHECK (obligation_origin_code IN (N'Published', N'Organization')),

        attributed_dt          DATETIME2 NOT NULL
            CONSTRAINT df_pm_risk_dep_obl_dt DEFAULT SYSUTCDATETIME(),
        attributed_by_employee_id BIGINT NULL
            CONSTRAINT fk_pm_risk_dep_obl_actor
                REFERENCES grac_practice.organization_employee(employee_id),
        remarks                NVARCHAR(1000) NULL,

        record_status_id       INT NOT NULL
            CONSTRAINT fk_pm_risk_dep_obl_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_risk_dep_obl_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_risk_dep_obl_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL,

        CONSTRAINT uq_pm_risk_dependency_obligation
            UNIQUE (risk_dependency_map_id, obligation_id)
    );
    PRINT '309: grac_practice.risk_dependency_obligation created.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_dep_obl_obligation'
                  AND object_id = OBJECT_ID('grac_practice.risk_dependency_obligation'))
BEGIN
    -- The panel asks "which dependencies belong to THIS obligation?"
    -- once per obligation, so that is the leading column.
    CREATE INDEX ix_pm_risk_dep_obl_obligation
        ON grac_practice.risk_dependency_obligation(obligation_id, risk_dependency_map_id)
        INCLUDE (obligation_name, record_status_id);
    PRINT '309: ix_pm_risk_dep_obl_obligation created.';
END
GO

-- =====================================================================
-- 2. risk_impact_area_master -- the kind of impact
--
--    Organisation-scoped master rather than a CHECK constraint, for the
--    reason 265 refused to hard-code the dependency categories: an
--    organisation that recognises a tenth impact area should get it
--    without a migration. Seeded with nine, insert-only.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_impact_area_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.risk_impact_area_master(
        risk_impact_area_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_risk_impact_area PRIMARY KEY,
        organization_id     BIGINT NOT NULL
            CONSTRAINT fk_pm_risk_impact_area_org
                REFERENCES grac_practice.organization(organization_id),
        area_code           NVARCHAR(60)  NOT NULL,
        area_name           NVARCHAR(200) NOT NULL,
        display_order       INT NOT NULL
            CONSTRAINT df_pm_risk_impact_area_order DEFAULT 0,
        status              NVARCHAR(20) NOT NULL
            CONSTRAINT df_pm_risk_impact_area_status DEFAULT N'Active'
            CONSTRAINT ck_pm_risk_impact_area_status
                CHECK (status IN (N'Active', N'Inactive')),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_risk_impact_area_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_risk_impact_area_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL,

        CONSTRAINT uq_pm_risk_impact_area_org_code UNIQUE (organization_id, area_code)
    );
    PRINT '309: grac_practice.risk_impact_area_master created.';
END
GO

-- Seed, per active organisation, insert-only. An organisation that has
-- renamed one keeps its name; one that deactivated an area keeps it
-- deactivated. Re-running adds only what is missing -- including for an
-- organisation onboarded after this migration ran, if it is run again.
;WITH areas AS (
    SELECT * FROM (VALUES
        (N'Financial',      N'Financial',            10),
        (N'Operational',    N'Operational',          20),
        (N'Legal',          N'Legal & Regulatory',   30),
        (N'Reputational',   N'Reputational',         40),
        (N'Customer',       N'Customer',             50),
        (N'People',         N'People',               60),
        (N'InfoSec',        N'Information Security', 70),
        (N'Environmental',  N'Environmental',        80),
        (N'Other',          N'Other',                90)
    ) v(area_code, area_name, display_order)
)
INSERT grac_practice.risk_impact_area_master
    (organization_id, area_code, area_name, display_order, status, entered_by)
SELECT o.organization_id, a.area_code, a.area_name, a.display_order, N'Active', N'seed-309'
FROM   grac_practice.organization o
CROSS  JOIN areas a
WHERE  o.status = N'Active'
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.risk_impact_area_master m
                    WHERE m.organization_id = o.organization_id
                      AND m.area_code       = a.area_code);

PRINT '309: impact area rows seeded = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 3. risk_impact_detail -- one recorded consequence
--
--    obligation_id is NULLABLE on purpose: an impact recorded against
--    the risk as a whole is legitimate, and the panel groups those under
--    "not attributed to an obligation" exactly as it does for
--    dependencies. Soft reference and frozen name, as in section 1.
--
--    SEVERITY REUSES risk_impact_master. The code, name and level are
--    frozen onto the row the way 205 freezes the register's own
--    likelihood_name -- so "impact" means one thing in this product, the
--    modal reuses the dropdown feed the score already uses, and a later
--    edit to the master does not rewrite history.
--
--    added_stage_code is what makes "impacts added in Review must also
--    persist and display correctly" answerable: Review shows the
--    Analysis ones as existing and stamps its own, so the two are told
--    apart without a second table.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_impact_detail','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.risk_impact_detail(
        risk_impact_detail_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_risk_impact_detail PRIMARY KEY,
        organization_id       BIGINT NOT NULL
            CONSTRAINT fk_pm_risk_impact_detail_org
                REFERENCES grac_practice.organization(organization_id),
        risk_register_id      BIGINT NOT NULL
            CONSTRAINT fk_pm_risk_impact_detail_register
                REFERENCES grac_practice.risk_register(risk_register_id),

        obligation_id          BIGINT NULL,
        obligation_name        NVARCHAR(500) NULL,
        obligation_origin_code NVARCHAR(20) NULL
            CONSTRAINT ck_pm_risk_impact_detail_origin
                CHECK (obligation_origin_code IS NULL
                       OR obligation_origin_code IN (N'Published', N'Organization')),

        -- The approved field set.
        risk_impact_area_id   BIGINT NOT NULL
            CONSTRAINT fk_pm_risk_impact_detail_area
                REFERENCES grac_practice.risk_impact_area_master(risk_impact_area_id),
        area_name             NVARCHAR(200) NULL,   -- frozen
        impact_description    NVARCHAR(4000) NOT NULL,
        -- Severity, from risk_impact_master. Frozen triple.
        impact_code           NVARCHAR(60)  NULL,
        impact_name           NVARCHAR(200) NULL,
        impact_value          INT           NULL,
        affected_party        NVARCHAR(300) NULL,
        estimated_value       NVARCHAR(120) NULL,   -- free text: "2 days downtime"
        time_horizon_code     NVARCHAR(20)  NULL
            CONSTRAINT ck_pm_risk_impact_detail_horizon
                CHECK (time_horizon_code IS NULL
                       OR time_horizon_code IN (N'Immediate', N'ShortTerm',
                                                N'MediumTerm', N'LongTerm')),
        remarks               NVARCHAR(1000) NULL,

        added_stage_code      NVARCHAR(20) NOT NULL
            CONSTRAINT df_pm_risk_impact_detail_stage DEFAULT N'Analysis'
            CONSTRAINT ck_pm_risk_impact_detail_stage
                CHECK (added_stage_code IN (N'Analysis', N'Residual', N'Review')),
        added_by_employee_id  BIGINT NULL
            CONSTRAINT fk_pm_risk_impact_detail_actor
                REFERENCES grac_practice.organization_employee(employee_id),
        added_dt              DATETIME2 NOT NULL
            CONSTRAINT df_pm_risk_impact_detail_dt DEFAULT SYSUTCDATETIME(),

        record_status_id      INT NOT NULL
            CONSTRAINT fk_pm_risk_impact_detail_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        status                NVARCHAR(20) NOT NULL
            CONSTRAINT df_pm_risk_impact_detail_status DEFAULT N'Active'
            CONSTRAINT ck_pm_risk_impact_detail_status
                CHECK (status IN (N'Active', N'Retired')),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_risk_impact_detail_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_risk_impact_detail_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL
    );
    PRINT '309: grac_practice.risk_impact_detail created.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_impact_detail_risk'
                  AND object_id = OBJECT_ID('grac_practice.risk_impact_detail'))
BEGIN
    -- Every read is "this risk's impacts", then grouped by obligation.
    CREATE INDEX ix_pm_risk_impact_detail_risk
        ON grac_practice.risk_impact_detail(risk_register_id, status, obligation_id)
        INCLUDE (risk_impact_area_id, impact_value, added_stage_code);
    PRINT '309: ix_pm_risk_impact_detail_risk created.';
END
GO

-- =====================================================================
-- 4. sp_risk_impact_area_list -- the modal's Impact area dropdown
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_impact_area_list
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 56800, 'sp_risk_impact_area_list: organization_id is required.', 1;

    SELECT risk_impact_area_id AS RiskImpactAreaId,
           area_code           AS AreaCode,
           area_name           AS AreaName,
           display_order       AS DisplayOrder
    FROM   grac_practice.risk_impact_area_master
    WHERE  organization_id = @organization_id
      AND  status = N'Active'
    ORDER  BY display_order, area_name;
END;
GO

-- =====================================================================
-- 5. sp_risk_impact_detail_list
--
--    Every Active impact of one risk. @obligation_id narrows to one
--    obligation; omitted returns them all and the caller groups -- which
--    is what the pages do, in one round trip rather than one per
--    obligation.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_impact_detail_list
    @risk_register_id BIGINT,
    @obligation_id    BIGINT = NULL,
    @include_retired  BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56801, 'sp_risk_impact_detail_list: risk_register_id is required.', 1;

    SELECT d.risk_impact_detail_id  AS RiskImpactDetailId,
           d.risk_register_id       AS RiskRegisterId,
           d.obligation_id          AS ObligationId,
           d.obligation_name        AS ObligationName,
           d.obligation_origin_code AS ObligationOriginCode,
           d.risk_impact_area_id    AS RiskImpactAreaId,
           COALESCE(a.area_name, d.area_name) AS AreaName,
           a.area_code              AS AreaCode,
           d.impact_description     AS ImpactDescription,
           d.impact_code            AS ImpactCode,
           d.impact_name            AS ImpactName,
           d.impact_value           AS ImpactValue,
           d.affected_party         AS AffectedParty,
           d.estimated_value        AS EstimatedValue,
           d.time_horizon_code      AS TimeHorizonCode,
           d.remarks                AS Remarks,
           d.added_stage_code       AS AddedStageCode,
           d.added_by_employee_id   AS AddedByEmployeeId,
           e.employee_name          AS AddedByName,
           d.added_dt               AS AddedDt,
           d.status                 AS Status_
    FROM   grac_practice.risk_impact_detail d
    LEFT   JOIN grac_practice.risk_impact_area_master a
           ON a.risk_impact_area_id = d.risk_impact_area_id
    LEFT   JOIN grac_practice.organization_employee e
           ON e.employee_id = d.added_by_employee_id
    WHERE  d.risk_register_id = @risk_register_id
      AND (@include_retired = 1 OR d.status = N'Active')
      AND (@obligation_id IS NULL OR d.obligation_id = @obligation_id)
    ORDER  BY CASE WHEN d.obligation_id IS NULL THEN 1 ELSE 0 END,
              d.obligation_id,
              ISNULL(a.display_order, 999),
              d.added_dt;
END;
GO

-- =====================================================================
-- 6. sp_risk_impact_detail_save -- add or edit one impact
--
--    @risk_impact_detail_id = 0 adds; anything else edits that row, and
--    only if it belongs to this risk.
--
--    The closed/retired guard is the one every other Risk Centre writer
--    applies (see sp_risk_dependency_map_direct, 266): a closed risk is
--    reopened before its record changes.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_impact_detail_save
    @risk_register_id      BIGINT,
    @risk_impact_detail_id BIGINT        = 0,
    @obligation_id         BIGINT        = NULL,
    @obligation_name       NVARCHAR(500) = NULL,
    @obligation_origin_code NVARCHAR(20) = NULL,
    @risk_impact_area_id   BIGINT        = NULL,
    @impact_description    NVARCHAR(4000) = NULL,
    @impact_code           NVARCHAR(60)  = NULL,
    @affected_party        NVARCHAR(300) = NULL,
    @estimated_value       NVARCHAR(120) = NULL,
    @time_horizon_code     NVARCHAR(20)  = NULL,
    @remarks               NVARCHAR(1000) = NULL,
    @added_stage_code      NVARCHAR(20)  = N'Analysis',
    @actor_employee_id     BIGINT        = NULL,
    @caller_display_name   NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56802, 'sp_risk_impact_detail_save: risk_register_id is required.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30);
    SELECT @org_id = organization_id, @status = status_code
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56803, 'sp_risk_impact_detail_save: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56804, 'sp_risk_impact_detail_save: this risk is closed or retired -- reopen it before changing its impact details.', 1;

    SET @impact_description = NULLIF(LTRIM(RTRIM(@impact_description)), N'');
    IF @impact_description IS NULL
        THROW 56805, 'An impact description is required.', 1;

    IF @risk_impact_area_id IS NULL
        THROW 56806, 'An impact area is required.', 1;

    -- Area must belong to THIS organisation: the dropdown is org-scoped
    -- and an id from another tenant must not be writable by hand.
    DECLARE @area_name NVARCHAR(200);
    SELECT @area_name = area_name
      FROM grac_practice.risk_impact_area_master
     WHERE risk_impact_area_id = @risk_impact_area_id
       AND organization_id     = @org_id
       AND status              = N'Active';

    IF @area_name IS NULL
        THROW 56807, 'sp_risk_impact_detail_save: that impact area does not exist for this organization.', 1;

    -- Severity, resolved from the same master the score uses. Optional:
    -- an impact worth recording before it has been sized is a real
    -- state, and forcing a level would invite a guessed one.
    DECLARE @impact_name NVARCHAR(200), @impact_value INT;
    SET @impact_code = NULLIF(LTRIM(RTRIM(@impact_code)), N'');
    IF @impact_code IS NOT NULL
    BEGIN
        SELECT @impact_name = impact_name, @impact_value = level_value
          FROM grac_practice.risk_impact_master
         WHERE organization_id = @org_id
           AND impact_code     = @impact_code
           AND status          = N'Active';

        IF @impact_name IS NULL
            THROW 56808, 'sp_risk_impact_detail_save: unknown or inactive severity level.', 1;
    END

    IF @added_stage_code IS NULL OR @added_stage_code NOT IN (N'Analysis', N'Residual', N'Review')
        SET @added_stage_code = N'Analysis';

    IF @time_horizon_code IS NOT NULL
       AND @time_horizon_code NOT IN (N'Immediate', N'ShortTerm', N'MediumTerm', N'LongTerm')
        THROW 56809, 'sp_risk_impact_detail_save: time horizon must be Immediate, ShortTerm, MediumTerm or LongTerm.', 1;

    IF @obligation_origin_code IS NOT NULL
       AND @obligation_origin_code NOT IN (N'Published', N'Organization')
        THROW 56810, 'sp_risk_impact_detail_save: obligation origin must be Published or Organization.', 1;

    -- An origin with no obligation, or an obligation with no origin, is
    -- half a reference. Default the origin rather than refuse: the UI
    -- knows which list it picked from, and Published is what the risk
    -- pages show today.
    IF @obligation_id IS NOT NULL AND @obligation_origin_code IS NULL
        SET @obligation_origin_code = N'Published';
    IF @obligation_id IS NULL
        SET @obligation_origin_code = NULL;

    DECLARE @active_rs INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
         WHERE status_code = N'Active' OR status_code = N'ACTIVE' OR status_name = N'Active'
         ORDER BY record_status_id);
    IF @active_rs IS NULL SET @active_rs = 1;

    DECLARE @created BIT = 0;

    BEGIN TRY
        BEGIN TRAN;

        IF ISNULL(@risk_impact_detail_id, 0) = 0
        BEGIN
            INSERT INTO grac_practice.risk_impact_detail
                (organization_id, risk_register_id,
                 obligation_id, obligation_name, obligation_origin_code,
                 risk_impact_area_id, area_name, impact_description,
                 impact_code, impact_name, impact_value,
                 affected_party, estimated_value, time_horizon_code, remarks,
                 added_stage_code, added_by_employee_id, added_dt,
                 record_status_id, status, entered_by, entered_dt)
            VALUES
                (@org_id, @risk_register_id,
                 @obligation_id, @obligation_name, @obligation_origin_code,
                 @risk_impact_area_id, @area_name, @impact_description,
                 @impact_code, @impact_name, @impact_value,
                 @affected_party, @estimated_value, @time_horizon_code, @remarks,
                 @added_stage_code, @actor_employee_id, SYSUTCDATETIME(),
                 @active_rs, N'Active', @caller_display_name, SYSUTCDATETIME());

            SET @risk_impact_detail_id = SCOPE_IDENTITY();
            SET @created = 1;
        END
        ELSE
        BEGIN
            -- added_stage_code and added_by are NOT rewritten on an edit:
            -- they record who first raised it and at which stage, which
            -- a later correction does not change.
            UPDATE grac_practice.risk_impact_detail
               SET obligation_id          = @obligation_id,
                   obligation_name        = @obligation_name,
                   obligation_origin_code = @obligation_origin_code,
                   risk_impact_area_id    = @risk_impact_area_id,
                   area_name              = @area_name,
                   impact_description     = @impact_description,
                   impact_code            = @impact_code,
                   impact_name            = @impact_name,
                   impact_value           = @impact_value,
                   affected_party         = @affected_party,
                   estimated_value        = @estimated_value,
                   time_horizon_code      = @time_horizon_code,
                   remarks                = @remarks,
                   status                 = N'Active',
                   updated_by             = @caller_display_name,
                   updated_dt             = SYSUTCDATETIME()
             WHERE risk_impact_detail_id = @risk_impact_detail_id
               AND risk_register_id      = @risk_register_id;

            IF @@ROWCOUNT = 0
                THROW 56811, 'sp_risk_impact_detail_save: no impact detail with that id on this risk.', 1;
        END

        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_register_id,
             CASE WHEN @created = 1 THEN N'ImpactDetailAdded' ELSE N'ImpactDetailEdited' END,
             @status, @status,
             CONCAT(@area_name, N' impact ',
                    CASE WHEN @created = 1 THEN N'recorded' ELSE N'updated' END,
                    CASE WHEN @obligation_id IS NULL THEN N' against the risk.'
                         ELSE CONCAT(N' against obligation ',
                                     ISNULL(@obligation_name, CAST(@obligation_id AS NVARCHAR(20))), N'.') END),
             @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT CAST(1 AS BIT)        AS Success,
           @risk_impact_detail_id AS RiskImpactDetailId,
           @created              AS Created,
           CASE WHEN @created = 1 THEN N'Impact detail added.' ELSE N'Impact detail saved.' END AS Message;
END;
GO

-- =====================================================================
-- 7. sp_risk_impact_detail_retire
--
--    Retired, never deleted -- the same treatment the rest of this
--    module gives a withdrawn record, and the history row says who did
--    it.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_impact_detail_retire
    @risk_register_id      BIGINT,
    @risk_impact_detail_id BIGINT,
    @actor_employee_id     BIGINT        = NULL,
    @caller_display_name   NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL OR @risk_impact_detail_id IS NULL
        THROW 56812, 'sp_risk_impact_detail_retire: risk and impact detail are both required.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30);
    SELECT @org_id = organization_id, @status = status_code
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56813, 'sp_risk_impact_detail_retire: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56814, 'sp_risk_impact_detail_retire: this risk is closed or retired -- reopen it first.', 1;

    DECLARE @area NVARCHAR(200);

    BEGIN TRY
        BEGIN TRAN;

        SELECT @area = ISNULL(area_name, N'Impact')
          FROM grac_practice.risk_impact_detail
         WHERE risk_impact_detail_id = @risk_impact_detail_id
           AND risk_register_id      = @risk_register_id;

        UPDATE grac_practice.risk_impact_detail
           SET status     = N'Retired',
               updated_by = @caller_display_name,
               updated_dt = SYSUTCDATETIME()
         WHERE risk_impact_detail_id = @risk_impact_detail_id
           AND risk_register_id      = @risk_register_id
           AND status                = N'Active';

        IF @@ROWCOUNT = 0
            THROW 56815, 'sp_risk_impact_detail_retire: no active impact detail with that id on this risk.', 1;

        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_register_id, N'ImpactDetailRetired', @status, @status,
             CONCAT(@area, N' impact removed.'),
             @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT CAST(1 AS BIT)         AS Success,
           @risk_impact_detail_id AS RiskImpactDetailId,
           N'Impact detail removed.' AS Message;
END;
GO

-- =====================================================================
-- 8. sp_risk_dependency_obligation_set
--
--    Attributes a mapped dependency to an obligation, or takes the
--    attribution away (@attach = 0). The dependency row itself is never
--    touched: this only says which obligation it is about, so removing
--    an attribution can never remove a dependency from the risk.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_dependency_obligation_set
    @risk_register_id       BIGINT,
    @risk_dependency_map_id BIGINT,
    @obligation_id          BIGINT,
    @obligation_name        NVARCHAR(500) = NULL,
    @obligation_origin_code NVARCHAR(20)  = N'Published',
    @attach                 BIT           = 1,
    @remarks                NVARCHAR(1000) = NULL,
    @actor_employee_id      BIGINT        = NULL,
    @caller_display_name    NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL OR @risk_dependency_map_id IS NULL OR @obligation_id IS NULL
        THROW 56816, 'sp_risk_dependency_obligation_set: risk, dependency and obligation are all required.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30);
    SELECT @org_id = organization_id, @status = status_code
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56817, 'sp_risk_dependency_obligation_set: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56818, 'sp_risk_dependency_obligation_set: this risk is closed or retired -- reopen it before changing its dependency mapping.', 1;

    -- The dependency has to belong to THIS risk. Without this check an
    -- id from another risk could be attributed here, and the panel would
    -- show a dependency the risk does not have.
    DECLARE @type_name NVARCHAR(120), @object_name NVARCHAR(300);
    SELECT @type_name   = dependency_type_name,
           @object_name = dependency_object_name
      FROM grac_practice.risk_dependency_map
     WHERE risk_dependency_map_id = @risk_dependency_map_id
       AND risk_register_id       = @risk_register_id;

    IF @type_name IS NULL AND NOT EXISTS (
            SELECT 1 FROM grac_practice.risk_dependency_map
             WHERE risk_dependency_map_id = @risk_dependency_map_id
               AND risk_register_id       = @risk_register_id)
        THROW 56819, 'sp_risk_dependency_obligation_set: that dependency is not mapped to this risk.', 1;

    IF @obligation_origin_code IS NULL
        SET @obligation_origin_code = N'Published';
    IF @obligation_origin_code NOT IN (N'Published', N'Organization')
        THROW 56820, 'sp_risk_dependency_obligation_set: obligation origin must be Published or Organization.', 1;

    DECLARE @active_rs INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
         WHERE status_code = N'Active' OR status_code = N'ACTIVE' OR status_name = N'Active'
         ORDER BY record_status_id);
    IF @active_rs IS NULL SET @active_rs = 1;

    DECLARE @changed BIT = 0;

    BEGIN TRY
        BEGIN TRAN;

        IF @attach = 1
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_dependency_obligation
                            WHERE risk_dependency_map_id = @risk_dependency_map_id
                              AND obligation_id          = @obligation_id)
            BEGIN
                INSERT INTO grac_practice.risk_dependency_obligation
                    (risk_dependency_map_id, obligation_id, obligation_name,
                     obligation_origin_code, attributed_dt, attributed_by_employee_id,
                     remarks, record_status_id, entered_by, entered_dt)
                VALUES
                    (@risk_dependency_map_id, @obligation_id, @obligation_name,
                     @obligation_origin_code, SYSUTCDATETIME(), @actor_employee_id,
                     @remarks, @active_rs, @caller_display_name, SYSUTCDATETIME());

                SET @changed = 1;
            END
            ELSE
                -- Already attributed. Take the caller's label if the
                -- stored one is blank, so a re-attribution is never a
                -- silent no-op that leaves the row unnamed.
                UPDATE grac_practice.risk_dependency_obligation
                   SET obligation_name = COALESCE(obligation_name, @obligation_name),
                       updated_by      = @caller_display_name,
                       updated_dt      = SYSUTCDATETIME()
                 WHERE risk_dependency_map_id = @risk_dependency_map_id
                   AND obligation_id          = @obligation_id;
        END
        ELSE
        BEGIN
            DELETE FROM grac_practice.risk_dependency_obligation
             WHERE risk_dependency_map_id = @risk_dependency_map_id
               AND obligation_id          = @obligation_id;

            SET @changed = CASE WHEN @@ROWCOUNT > 0 THEN 1 ELSE 0 END;
        END

        IF @changed = 1
            INSERT INTO grac_practice.risk_register_history
                (risk_register_id, action_code, from_status_code, to_status_code,
                 remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
            VALUES
                (@risk_register_id,
                 CASE WHEN @attach = 1 THEN N'DependencyObligationSet' ELSE N'DependencyObligationCleared' END,
                 @status, @status,
                 CONCAT(ISNULL(@type_name, N'Dependency'), N' ',
                        ISNULL(@object_name, CAST(@risk_dependency_map_id AS NVARCHAR(20))),
                        CASE WHEN @attach = 1 THEN N' attributed to obligation ' ELSE N' no longer attributed to obligation ' END,
                        ISNULL(@obligation_name, CAST(@obligation_id AS NVARCHAR(20))), N'.'),
                 @actor_employee_id, @caller_display_name,
                 @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT CAST(1 AS BIT)          AS Success,
           @risk_dependency_map_id AS RiskDependencyMapId,
           @obligation_id          AS ObligationId,
           @attach                 AS Attached,
           @changed                AS Changed;
END;
GO

-- =====================================================================
-- 9. sp_risk_dependency_obligation_list
--
--    The attributions for one risk, so the panel can bucket the
--    dependencies sp_risk_mapping_get already returns without a second
--    call per dependency.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_dependency_obligation_list
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56821, 'sp_risk_dependency_obligation_list: risk_register_id is required.', 1;

    SELECT o.risk_dependency_obligation_id AS RiskDependencyObligationId,
           o.risk_dependency_map_id        AS RiskDependencyMapId,
           o.obligation_id                 AS ObligationId,
           o.obligation_name               AS ObligationName,
           o.obligation_origin_code        AS ObligationOriginCode,
           m.dependency_type_id            AS DependencyTypeId,
           m.dependency_type_name          AS DependencyTypeName,
           m.dependency_object_id          AS DependencyObjectId,
           m.dependency_object_name        AS DependencyObjectName,
           o.attributed_dt                 AS AttributedDt,
           e.employee_name                 AS AttributedByName
    FROM   grac_practice.risk_dependency_obligation o
    JOIN   grac_practice.risk_dependency_map m
           ON m.risk_dependency_map_id = o.risk_dependency_map_id
    LEFT   JOIN grac_practice.organization_employee e
           ON e.employee_id = o.attributed_by_employee_id
    WHERE  m.risk_register_id = @risk_register_id
    ORDER  BY o.obligation_id, m.dependency_type_name, m.dependency_object_name;
END;
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 309 verification ===';

SELECT '309-a risk_dependency_obligation' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_dependency_obligation','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '309-b risk_impact_area_master',
       CASE WHEN OBJECT_ID('grac_practice.risk_impact_area_master','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '309-c risk_impact_detail',
       CASE WHEN OBJECT_ID('grac_practice.risk_impact_detail','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '309-d sp_risk_impact_area_list',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_impact_area_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '309-e sp_risk_impact_detail_list',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_impact_detail_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '309-f sp_risk_impact_detail_save',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_impact_detail_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '309-g sp_risk_impact_detail_retire',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_impact_detail_retire','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '309-h sp_risk_dependency_obligation_set',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_dependency_obligation_set','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '309-i sp_risk_dependency_obligation_list',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_dependency_obligation_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Severity is the score's own master, not a second scale.
SELECT '309-j severity reuses risk_impact_master',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_impact_detail_save','P'))
                 LIKE '%risk_impact_master%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Regression guard: 265's grain and its no-duplicate rule are untouched.
SELECT '309-k risk_dependency_map UNIQUE intact',
       CASE WHEN EXISTS (SELECT 1 FROM sys.key_constraints
                          WHERE name = 'uq_pm_risk_dependency_map')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '309-l no obligation column added to risk_dependency_map',
       CASE WHEN COL_LENGTH('grac_practice.risk_dependency_map','obligation_id') IS NULL
            THEN 'PASS' ELSE 'FAIL' END;

-- Seed coverage, per organisation.
SELECT 'Impact areas per organisation' AS Check_,
       o.organization_id   AS OrganizationId,
       o.organization_code AS Organization,
       COUNT(a.risk_impact_area_id) AS Areas
FROM   grac_practice.organization o
LEFT   JOIN grac_practice.risk_impact_area_master a
       ON a.organization_id = o.organization_id AND a.status = N'Active'
WHERE  o.status = N'Active'
GROUP  BY o.organization_id, o.organization_code
ORDER  BY o.organization_id;

PRINT '';
PRINT '309 complete. Impact Details and dependency-to-obligation attribution exist.';
PRINT 'Nothing renders them yet -- that is Phase 2 (API) and Phase 4 (the panel).';
PRINT 'Every dependency mapped so far has no attribution and will read as';
PRINT '"not attributed to an obligation", which is the intended state.';
GO

SET NOEXEC OFF;
GO
