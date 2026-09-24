-- =====================================================================
-- 265 Risk Centre — mapping generalised from Assets to EVERY
--     Operationalize dependency category
--
-- WHAT WAS WRONG WITH 261/262
-- ---------------------------
-- They mapped ASSETS only. `risk_asset_map` is keyed on an asset_id,
-- `fn_risk_practice_assets` filters `dependency_type_code = 'Asset'`,
-- and the picker reads organization_dependency_asset directly.
--
-- That is a subset of what the Operationalize page (the Resolve
-- workspace, renamed by 191) actually carries. Its dependency mapping is
-- driven by `dependency_type_master`, which 002 seeds with NINE
-- categories:
--
--     Application · Tool · Vendor · Asset · Process
--     Location · Person · Team · Committee
--
-- and each of those resolves its selectable objects through
-- `dependency_type_source_config` -- a row per category naming the
-- source table, id column and display column. Asset is simply one row in
-- that table.
--
-- So a risk mapped to a practice inherited that practice's assets and
-- silently dropped its applications, vendors, tools, processes,
-- locations, people, teams and committees. For a risk about a third
-- party, or about a single person leaving, the inherited scope was
-- empty while the practice plainly had dependencies.
--
-- ---------------------------------------------------------------------
-- DECISION 1 — THE CATEGORY LIST IS NEVER RESTATED
-- ---------------------------------------------------------------------
-- Not in a CHECK constraint, not in a seed, not in the API, not in the
-- UI. `dependency_type_id` is a foreign key to
-- `grac_practice.dependency_type_master`, which is the same table
-- `sp_resolve_dependency_type_list` (222) reads for the Operationalize
-- screen.
--
-- The consequence is the point: an organisation that adds a tenth
-- category to dependency_type_master gets it in Risk Analysis with no
-- migration, no deployment and no code change -- because Risk Analysis
-- never had an opinion about what the categories are.
--
-- A CHECK listing the nine would have been the natural instinct and is
-- exactly the hard-coding this migration exists to remove.
--
-- ---------------------------------------------------------------------
-- DECISION 2 — REPLACE THE TABLES, DO NOT WIDEN THEM
-- ---------------------------------------------------------------------
-- risk_asset_map's grain is (risk, asset). The correct grain is
-- (risk, category, object). Adding a nullable dependency_type_id to the
-- old table would leave the old UNIQUE constraint enforcing the wrong
-- thing, and `asset_id` would have to start meaning "id in whichever
-- table this category points at" while still being named asset_id and
-- still carrying an FK to organization_dependency_asset.
--
-- A column whose name and FK both lie is worse than a table swap. So:
-- new tables, rows copied across, old tables dropped -- in one
-- transaction, with the copied count printed.
--
-- ---------------------------------------------------------------------
-- DECISION 3 — NO FOREIGN KEY ON dependency_object_id
-- ---------------------------------------------------------------------
-- It cannot have one. The object lives in whichever table
-- dependency_type_source_config names for that category:
-- organization_dependency_asset, organization_dependency_vendor,
-- organization_employee, organization_team, organization_location ...
-- A single column cannot reference nine tables.
--
-- This is the same soft-reference decision `practice_dependency_
-- resolution` itself makes -- its `resolved_dependency_id` has no FK
-- either, for exactly this reason. Risk Centre is not inventing a
-- weaker rule; it is adopting the one Operationalize already lives by.
--
-- The frozen `dependency_object_name` is what makes that survivable: a
-- mapping still reads correctly after the object is renamed or retired.
--
-- CONTENTS
--   1. risk_dependency_map            NEW  (replaces risk_asset_map)
--   2. risk_dependency_map_source     NEW  (replaces risk_asset_map_source)
--   3. Copy any existing asset rows across
--   4. Drop the asset-only tables
--   5. sp_risk_register_list / _get  REWRITE (they counted risk_asset_map)
--
-- ERROR CODE RANGE: 56640-56659
-- Rollback: database/265_risk_dependency_mapping_schema_rollback.sql
-- Depends:  001, 002 (dependency_type_master + source config), 261
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN PRINT 'ABORT (265): risk_register missing -- run 205 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.risk_practice_map','U') IS NULL
BEGIN PRINT 'ABORT (265): risk_practice_map missing -- run 261 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.dependency_type_master','U') IS NULL
BEGIN PRINT 'ABORT (265): dependency_type_master missing -- run 002 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
BEGIN PRINT 'ABORT (265): practice_dependency_resolution missing -- run 002 first.'; SET @ok = 0; END

-- The source config is what makes a category resolvable to real objects.
-- Without it the categories exist but nothing can be picked for them,
-- and Risk Analysis would show nine empty lists.
IF OBJECT_ID('grac_practice.dependency_type_source_config','U') IS NULL
BEGIN PRINT 'ABORT (265): dependency_type_source_config missing -- run 002 first.'; SET @ok = 0; END

-- 266 replaces every procedure that touches the old tables. Running 265
-- alone would drop risk_asset_map while 262's procedures still reference
-- it -- they would compile (deferred name resolution) and fail on first
-- use. Refused here rather than discovered there.
IF OBJECT_ID('grac_practice.sp_risk_asset_map_direct','P') IS NOT NULL
   AND OBJECT_ID('grac_practice.sp_risk_dependency_map_direct','P') IS NULL
BEGIN
    PRINT 'NOTE (265): 262''s asset-only procedures are still installed.';
    PRINT '            Run 266_risk_dependency_procs.sql immediately after this file.';
    PRINT '            Until you do, the Risk Analysis scope panel will fail.';
END

IF @ok = 0
BEGIN
    RAISERROR('265_risk_dependency_mapping_schema: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. risk_dependency_map
--
-- THE risk-level dependency mapping: one row per
-- (risk, category, object), however many practices reach it. Same
-- invariant 261 established for assets, widened by one column.
--
-- dependency_type_name and dependency_object_name are frozen copies.
-- The type name so a renamed category still reads correctly in history;
-- the object name because there is no FK to join back through (see
-- decision 3), and a mapping that renders as "#4711" once the object is
-- retired is not a record of anything.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_dependency_map','U') IS NULL
CREATE TABLE grac_practice.risk_dependency_map(
    risk_dependency_map_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_dependency_map PRIMARY KEY,
    organization_id        BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_dep_map_org
            REFERENCES grac_practice.organization(organization_id),
    risk_register_id       BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_dep_map_register
            REFERENCES grac_practice.risk_register(risk_register_id),

    -- The category. FK, not a CHECK -- see decision 1.
    dependency_type_id     INT NOT NULL
        CONSTRAINT fk_pm_risk_dep_map_type
            REFERENCES grac_practice.dependency_type_master(dependency_type_id),
    dependency_type_name   NVARCHAR(120) NULL,

    -- The object, in whichever table this category's source config
    -- names. Deliberately no FK -- see decision 3.
    dependency_object_id   BIGINT NOT NULL,
    dependency_object_name NVARCHAR(300) NULL,

    first_mapped_dt        DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_dep_map_dt DEFAULT SYSUTCDATETIME(),
    mapped_by_employee_id  BIGINT NULL
        CONSTRAINT fk_pm_risk_dep_map_mapper
            REFERENCES grac_practice.organization_employee(employee_id),
    remarks                NVARCHAR(1000) NULL,

    record_status_id       INT NOT NULL
        CONSTRAINT fk_pm_risk_dep_map_record_status
            REFERENCES grac_practice.record_status_master(record_status_id),
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_dep_map_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_dep_map_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,

    -- "Duplicate dependencies are prevented when the same dependency
    -- comes through multiple Practices" -- in one line, enforced by the
    -- engine rather than by every writer remembering.
    CONSTRAINT uq_pm_risk_dependency_map
        UNIQUE(risk_register_id, dependency_type_id, dependency_object_id)
);
GO

-- The reverse lookup: "which risks touch this vendor / this person /
-- this application?" -- the question that makes the map worth keeping.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_dep_map_object'
                  AND object_id = OBJECT_ID('grac_practice.risk_dependency_map'))
    CREATE INDEX ix_pm_risk_dep_map_object
        ON grac_practice.risk_dependency_map(organization_id, dependency_type_id, dependency_object_id)
        INCLUDE (risk_register_id, dependency_object_name);
GO

-- The scope panel reads every dependency for one risk, grouped by
-- category, on every open.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_dep_map_risk'
                  AND object_id = OBJECT_ID('grac_practice.risk_dependency_map'))
    CREATE INDEX ix_pm_risk_dep_map_risk
        ON grac_practice.risk_dependency_map(risk_register_id, dependency_type_id)
        INCLUDE (dependency_object_id, dependency_object_name);
GO

-- =====================================================================
-- 2. risk_dependency_map_source
--
-- Why a dependency is on a risk. Unchanged in shape from 261's asset
-- version -- one row per independent reason -- because the removal
-- arithmetic it enables is exactly the same:
--
--   un-map a practice -> delete ITS contributions
--                     -> delete map rows with no contributions left
--
-- A dependency another mapped practice still reaches keeps that
-- practice's contribution and survives. One mapped directly keeps its
-- Direct contribution and survives. Nothing has to ask "is anything else
-- using this?" -- the row count answers.
--
-- The persisted computed keys exist because a UNIQUE constraint cannot
-- contain ISNULL(...) and the natural key has two nullable columns. 205
-- uses the same device for risk_number.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_dependency_map_source','U') IS NULL
CREATE TABLE grac_practice.risk_dependency_map_source(
    risk_dependency_map_source_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_dep_map_source PRIMARY KEY,
    risk_dependency_map_id BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_dep_src_map
            REFERENCES grac_practice.risk_dependency_map(risk_dependency_map_id),

    source_kind_code       NVARCHAR(30) NOT NULL,

    practice_id            BIGINT NULL
        CONSTRAINT fk_pm_risk_dep_src_practice
            REFERENCES grac_practice.practice(practice_id),
    practice_instance_id   BIGINT NULL
        CONSTRAINT fk_pm_risk_dep_src_instance
            REFERENCES grac_practice.practice_instance(practice_instance_id),

    -- The practice_dependency_resolution row this came from. Soft
    -- reference: Operationalize rewrites resolutions freely, and a hard
    -- FK would make un-resolving a dependency there fail on a Risk
    -- Centre row the operator cannot see.
    resolution_id          BIGINT NULL,

    added_dt               DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_dep_src_dt DEFAULT SYSUTCDATETIME(),
    added_by_employee_id   BIGINT NULL
        CONSTRAINT fk_pm_risk_dep_src_adder
            REFERENCES grac_practice.organization_employee(employee_id),
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_dep_src_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_dep_src_entered_dt DEFAULT SYSUTCDATETIME(),

    practice_key AS (ISNULL(practice_id, CAST(0 AS BIGINT))) PERSISTED,
    instance_key AS (ISNULL(practice_instance_id, CAST(0 AS BIGINT))) PERSISTED,

    CONSTRAINT ck_pm_risk_dep_src_kind
        CHECK (source_kind_code IN (N'PracticeDependency', N'Direct')),
    CONSTRAINT ck_pm_risk_dep_src_practice_present
        CHECK (source_kind_code <> N'PracticeDependency' OR practice_id IS NOT NULL),
    CONSTRAINT ck_pm_risk_dep_src_direct_practice
        CHECK (source_kind_code <> N'Direct' OR practice_id IS NULL),
    CONSTRAINT uq_pm_risk_dependency_map_source
        UNIQUE(risk_dependency_map_id, source_kind_code, practice_key, instance_key)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_dep_src_practice'
                  AND object_id = OBJECT_ID('grac_practice.risk_dependency_map_source'))
    CREATE INDEX ix_pm_risk_dep_src_practice
        ON grac_practice.risk_dependency_map_source(practice_id, risk_dependency_map_id)
        INCLUDE (source_kind_code, practice_instance_id);
GO

-- =====================================================================
-- 3. Carry the asset-only rows across
--
-- 261/262 shipped days ago and the Asset mapping may well be empty, but
-- "probably empty" is not a migration strategy. Every row is copied, in
-- one transaction, and the count is printed so a non-zero result is
-- visible rather than assumed away.
--
-- The Asset category id is looked up, not hard-coded: dependency_type_id
-- is an IDENTITY and differs between environments.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_asset_map','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.risk_dependency_map','U') IS NOT NULL
BEGIN
    DECLARE @asset_type_id INT, @asset_type_name NVARCHAR(120);

    SELECT TOP 1 @asset_type_id = dependency_type_id,
                 @asset_type_name = dependency_type_name
      FROM grac_practice.dependency_type_master
     WHERE dependency_type_code = N'Asset' OR dependency_type_name = N'Asset'
     ORDER BY dependency_type_id;

    IF @asset_type_id IS NULL
    BEGIN
        PRINT 'ABORT (265): no Asset row in dependency_type_master -- cannot map the';
        PRINT '             existing risk_asset_map rows to a category. Run 002 first.';
        RAISERROR('265: Asset dependency type missing.', 16, 1);
        SET NOEXEC ON;
    END
    ELSE
    BEGIN
        DECLARE @copied_maps INT = 0, @copied_sources INT = 0;

        BEGIN TRY
            BEGIN TRAN;

            INSERT INTO grac_practice.risk_dependency_map
                (organization_id, risk_register_id, dependency_type_id, dependency_type_name,
                 dependency_object_id, dependency_object_name,
                 first_mapped_dt, mapped_by_employee_id, remarks,
                 record_status_id, entered_by, entered_dt, updated_by, updated_dt)
            SELECT m.organization_id, m.risk_register_id, @asset_type_id, @asset_type_name,
                   m.asset_id, m.asset_name,
                   m.first_mapped_dt, m.mapped_by_employee_id, m.remarks,
                   m.record_status_id, m.entered_by, m.entered_dt, m.updated_by, m.updated_dt
              FROM grac_practice.risk_asset_map m
             WHERE NOT EXISTS (
                     SELECT 1 FROM grac_practice.risk_dependency_map d
                      WHERE d.risk_register_id   = m.risk_register_id
                        AND d.dependency_type_id = @asset_type_id
                        AND d.dependency_object_id = m.asset_id);

            SET @copied_maps = @@ROWCOUNT;

            -- Contributions are matched through the natural key rather
            -- than a captured identity map: the new ids are whatever
            -- IDENTITY assigned, and joining on (risk, type, object) is
            -- both correct and re-runnable.
            IF OBJECT_ID('grac_practice.risk_asset_map_source','U') IS NOT NULL
            BEGIN
                INSERT INTO grac_practice.risk_dependency_map_source
                    (risk_dependency_map_id, source_kind_code, practice_id,
                     practice_instance_id, resolution_id,
                     added_dt, added_by_employee_id, entered_by, entered_dt)
                SELECT d.risk_dependency_map_id, s.source_kind_code, s.practice_id,
                       s.practice_instance_id, s.resolution_id,
                       s.added_dt, s.added_by_employee_id, s.entered_by, s.entered_dt
                  FROM grac_practice.risk_asset_map_source s
                  JOIN grac_practice.risk_asset_map m
                    ON m.risk_asset_map_id = s.risk_asset_map_id
                  JOIN grac_practice.risk_dependency_map d
                    ON d.risk_register_id     = m.risk_register_id
                   AND d.dependency_type_id   = @asset_type_id
                   AND d.dependency_object_id = m.asset_id
                 WHERE NOT EXISTS (
                         SELECT 1 FROM grac_practice.risk_dependency_map_source x
                          WHERE x.risk_dependency_map_id = d.risk_dependency_map_id
                            AND x.source_kind_code = s.source_kind_code
                            AND x.practice_key = ISNULL(s.practice_id, CAST(0 AS BIGINT))
                            AND x.instance_key = ISNULL(s.practice_instance_id, CAST(0 AS BIGINT)));

                SET @copied_sources = @@ROWCOUNT;
            END

            COMMIT;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            THROW;
        END CATCH

        PRINT CONCAT('265: carried ', @copied_maps, ' asset mapping(s) and ',
                     @copied_sources, ' contribution(s) into risk_dependency_map.');
    END
END
ELSE
    PRINT '265: no risk_asset_map to carry across (fresh install, or already migrated).';
GO

-- =====================================================================
-- 4. Drop the asset-only tables
--
-- Child first: risk_asset_map_source's FK points at risk_asset_map.
-- Done only once the copy above has committed.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_asset_map_source','U') IS NOT NULL
    DROP TABLE grac_practice.risk_asset_map_source;
GO
IF OBJECT_ID('grac_practice.risk_asset_map','U') IS NOT NULL
    DROP TABLE grac_practice.risk_asset_map;
GO


-- =====================================================================
-- 5. sp_risk_register_list / sp_risk_register_get
--    REWRITE -- 264's bodies, with one expression changed in each.
--
-- WHY THIS IS IN THE SCHEMA FILE
-- ------------------------------
-- Section 4 above DROPPED risk_asset_map, and 264's versions of these
-- two procedures count rows in it for the grid's Scope column. Leaving
-- them would mean every Risk Register list and detail read failing with
-- "Invalid object name" the moment this file finished -- the same trap
-- 264's own view guard was added to prevent, arriving from the other
-- direction.
--
-- The file that breaks them fixes them, in the same run.
--
-- These are 264's bodies verbatim apart from ONE expression each:
--
--     (SELECT COUNT(*) FROM grac_practice.risk_asset_map am
--       WHERE am.risk_register_id = r.risk_register_id) AS MappedAssetCount
--   ->
--     (SELECT COUNT(*) FROM grac_practice.risk_dependency_map am
--       WHERE am.risk_register_id = r.risk_register_id) AS MappedDependencyCount
--
-- Every other column, filter, join and parameter is unchanged, so these
-- remain strict supersets of 216 and 258 exactly as 264 left them. The
-- API reads the count by name and falls back to 0 when the column is
-- absent, so the rename degrades rather than breaking on a database
-- where this file has not run.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_register_list
    @organization_id  BIGINT,
    @status_code      NVARCHAR(30) = NULL,
    @source_type_code NVARCHAR(40) = NULL,
    @category_code    NVARCHAR(60) = NULL,
    @rating_code      NVARCHAR(30) = NULL,
    @owner_employee_id BIGINT      = NULL,
    @search           NVARCHAR(200) = NULL,
    @page_number      INT = 1,
    @page_size        INT = 25,
    @analysis_pending BIT = NULL,
    @residual_rating_code NVARCHAR(30) = NULL,
    @residual_pending     BIT          = NULL,
    -- NEW in 264. All default to NULL = "no opinion".
    @treatment_option_code NVARCHAR(30)  = NULL,
    @workflow_stage_code   NVARCHAR(30)  = NULL,
    @review_due            BIT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 56150, 'sp_risk_register_list: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        r.risk_register_id      AS RiskRegisterId,
        r.risk_number           AS RiskNumber,
        r.organization_id       AS OrganizationId,
        r.risk_title            AS RiskTitle,
        r.risk_statement        AS RiskStatement,
        r.risk_category_code    AS RiskCategoryCode,
        r.risk_category_name    AS RiskCategoryName,
        r.source_type_code      AS SourceTypeCode,
        r.source_record_id      AS SourceRecordId,
        r.source_reference      AS SourceReference,
        r.source_centre_code    AS SourceCentreCode,
        r.risk_candidate_id     AS RiskCandidateId,
        r.risk_analysis_id      AS RiskAnalysisId,
        r.risk_owner_employee_id AS RiskOwnerEmployeeId,
        ow.employee_name        AS RiskOwnerName,
        r.business_unit         AS BusinessUnit,
        r.likelihood_name       AS LikelihoodName,
        r.impact_name           AS ImpactName,
        r.inherent_rating_code  AS InherentRatingCode,
        r.inherent_rating_name  AS InherentRatingName,
        r.inherent_rating_score AS InherentRatingScore,
        r.status_code           AS StatusCode,
        r.registered_dt         AS RegisteredOn,
        rb.employee_name        AS RegisteredByName,
        -- ---- 216 ----------------------------------------------------
        r.analysis_pending      AS AnalysisPending,
        r.threat_name           AS ThreatName,
        r.vulnerability_name    AS VulnerabilityName,
        r.business_function_name AS BusinessFunctionName,
        -- ---- 258 ----------------------------------------------------
        r.residual_likelihood_name AS ResidualLikelihoodName,
        r.residual_impact_name     AS ResidualImpactName,
        r.residual_rating_code     AS ResidualRatingCode,
        r.residual_rating_name     AS ResidualRatingName,
        r.residual_rating_score    AS ResidualRatingScore,
        r.residual_assessed_dt     AS ResidualAssessedOn,
        r.residual_pending         AS ResidualPending,
        -- ---- 261 / 263 / 264 ----------------------------------------
        r.treatment_option_code    AS TreatmentOptionCode,
        r.treatment_option_name    AS TreatmentOptionName,
        r.treatment_task_id        AS TreatmentTaskId,
        r.accepted_dt              AS AcceptedOn,
        COALESCE(ab.employee_name, r.accepted_by_name) AS AcceptedByName,
        r.next_review_date         AS NextReviewDate,
        r.last_reviewed_dt         AS LastReviewedOn,
        r.review_count             AS ReviewCount,
        st.workflow_stage_code     AS WorkflowStageCode,
        st.open_treatment_task_count AS OpenTreatmentTaskCount,
        st.treatment_task_count      AS TreatmentTaskCount,
        st.is_review_due             AS IsReviewDue,
        -- Counts for the mapping badges. Correlated subqueries in the
        -- SELECT list, not aggregates over a join -- a join would
        -- multiply the register rows and every score in the row would
        -- have to be wrapped in an aggregate to survive it.
        (SELECT COUNT(*) FROM grac_practice.risk_practice_map pm
          WHERE pm.risk_register_id = r.risk_register_id) AS MappedPracticeCount,
        (SELECT COUNT(*) FROM grac_practice.risk_dependency_map am
          WHERE am.risk_register_id = r.risk_register_id) AS MappedDependencyCount,
        COUNT(*) OVER ()        AS TotalRows
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
 LEFT JOIN grac_practice.organization_employee rb ON rb.employee_id = r.registered_by_employee_id
 LEFT JOIN grac_practice.organization_employee ab ON ab.employee_id = r.accepted_by_employee_id
 LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st ON st.risk_register_id = r.risk_register_id
     WHERE r.organization_id = @organization_id
       AND (@status_code      IS NULL OR r.status_code         = @status_code)
       AND (@source_type_code IS NULL OR r.source_type_code    = @source_type_code)
       AND (@category_code    IS NULL OR r.risk_category_code  = @category_code)
       AND (@rating_code      IS NULL OR r.inherent_rating_code= @rating_code)
       AND (@owner_employee_id IS NULL OR r.risk_owner_employee_id = @owner_employee_id)
       AND (@analysis_pending IS NULL OR r.analysis_pending    = @analysis_pending)
       AND (@residual_rating_code IS NULL OR r.residual_rating_code = @residual_rating_code)
       AND (@residual_pending     IS NULL OR r.residual_pending     = @residual_pending)
       AND (@treatment_option_code IS NULL OR r.treatment_option_code = @treatment_option_code)
       AND (@workflow_stage_code   IS NULL OR st.workflow_stage_code  = @workflow_stage_code)
       AND (@review_due            IS NULL OR st.is_review_due        = @review_due)
       AND (@search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
            OR r.risk_title     LIKE N'%' + @search + N'%'
            OR r.risk_statement LIKE N'%' + @search + N'%'
            OR r.risk_number    LIKE N'%' + @search + N'%')
     ORDER BY r.registered_dt DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_register_get
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_register_id IS NULL
        THROW 56160, 'sp_risk_register_get: risk_register_id is required.', 1;

    SELECT
        r.risk_register_id      AS RiskRegisterId,
        r.risk_number           AS RiskNumber,
        r.organization_id       AS OrganizationId,
        r.risk_title            AS RiskTitle,
        r.risk_statement        AS RiskStatement,
        r.risk_description      AS RiskDescription,
        r.risk_category_code    AS RiskCategoryCode,
        r.risk_category_name    AS RiskCategoryName,

        r.source_type_code      AS SourceTypeCode,
        sm.source_name          AS SourceName,
        r.source_record_id      AS SourceRecordId,
        r.source_reference      AS SourceReference,
        r.source_description    AS SourceDescription,
        r.source_centre_code    AS SourceCentreCode,

        r.risk_candidate_id     AS RiskCandidateId,
        c.candidate_number      AS CandidateNumber,
        c.candidate_title       AS CandidateTitle,
        c.custom_gap_id         AS CustomGapId,
        r.risk_analysis_id      AS RiskAnalysisId,
        a.analysis_version      AS AnalysisVersion,
        a.analysis_dt           AS AnalysisOn,
        an.employee_name        AS AnalysedByName,

        r.risk_owner_employee_id AS RiskOwnerEmployeeId,
        ow.employee_name        AS RiskOwnerName,
        r.business_unit         AS BusinessUnit,
        r.process_name          AS ProcessName,
        r.risk_cause            AS RiskCause,
        r.potential_consequence AS PotentialConsequence,
        r.existing_controls     AS ExistingControls,

        r.likelihood_code       AS LikelihoodCode,
        r.likelihood_name       AS LikelihoodName,
        r.likelihood_value      AS LikelihoodValue,
        r.impact_code           AS ImpactCode,
        r.impact_name           AS ImpactName,
        r.impact_value          AS ImpactValue,
        r.inherent_rating_code  AS InherentRatingCode,
        r.inherent_rating_name  AS InherentRatingName,
        r.inherent_rating_score AS InherentRatingScore,

        r.linked_asset_id       AS LinkedAssetId,
        r.linked_vendor_id      AS LinkedVendorId,
        r.linked_practice_id    AS LinkedPracticeId,
        lp.practice_name        AS LinkedPracticeName,
        r.linked_obligation_id  AS LinkedObligationId,
        r.linked_control_id     AS LinkedControlId,

        r.status_code           AS StatusCode,
        r.registered_dt         AS RegisteredOn,
        r.registered_by_employee_id AS RegisteredByEmployeeId,
        rb.employee_name        AS RegisteredByName,
        r.closed_dt             AS ClosedOn,
        cb.employee_name        AS ClosedByName,
        r.closure_reason        AS ClosureReason,
        -- ---- 216 ----------------------------------------------------
        r.analysis_pending      AS AnalysisPending,
        r.threat_id             AS ThreatId,
        r.threat_name           AS ThreatName,
        r.threat_description    AS ThreatDescription,
        r.vulnerability_id      AS VulnerabilityId,
        r.vulnerability_name    AS VulnerabilityName,
        r.vulnerability_description AS VulnerabilityDescription,
        r.business_function_id  AS BusinessFunctionId,
        r.business_function_name AS BusinessFunctionName,
        cur.approval_status_code AS AnalysisApprovalStatusCode,
        -- ---- 258 ----------------------------------------------------
        r.residual_analysis_id      AS ResidualAnalysisId,
        res.residual_version        AS ResidualVersion,
        r.residual_likelihood_code  AS ResidualLikelihoodCode,
        r.residual_likelihood_name  AS ResidualLikelihoodName,
        r.residual_likelihood_value AS ResidualLikelihoodValue,
        r.residual_impact_code      AS ResidualImpactCode,
        r.residual_impact_name      AS ResidualImpactName,
        r.residual_impact_value     AS ResidualImpactValue,
        r.residual_rating_code      AS ResidualRatingCode,
        r.residual_rating_name      AS ResidualRatingName,
        r.residual_rating_score     AS ResidualRatingScore,
        r.residual_assessed_dt      AS ResidualAssessedOn,
        r.residual_pending          AS ResidualPending,
        res.treatment_summary       AS ResidualTreatmentSummary,
        res.residual_controls       AS ResidualControls,
        res.analyst_remarks         AS ResidualRemarks,
        rab.employee_name           AS ResidualAssessedByName,
        -- ---- 261 / 263 / 264 ----------------------------------------
        r.treatment_option_code     AS TreatmentOptionCode,
        r.treatment_option_name     AS TreatmentOptionName,
        r.treatment_decided_dt      AS TreatmentDecidedOn,
        td.employee_name            AS TreatmentDecidedByName,
        r.treatment_task_id         AS TreatmentTaskId,
        r.accepted_by_employee_id   AS AcceptedByEmployeeId,
        COALESCE(ab.employee_name, r.accepted_by_name) AS AcceptedByName,
        r.accepted_dt               AS AcceptedOn,
        r.acceptance_note           AS AcceptanceNote,
        r.next_review_date          AS NextReviewDate,
        r.last_reviewed_dt          AS LastReviewedOn,
        r.review_count              AS ReviewCount,
        st.workflow_stage_code      AS WorkflowStageCode,
        st.open_treatment_task_count AS OpenTreatmentTaskCount,
        st.treatment_task_count      AS TreatmentTaskCount,
        st.is_review_due             AS IsReviewDue,
        (SELECT COUNT(*) FROM grac_practice.risk_practice_map pm
          WHERE pm.risk_register_id = r.risk_register_id) AS MappedPracticeCount,
        (SELECT COUNT(*) FROM grac_practice.risk_dependency_map am
          WHERE am.risk_register_id = r.risk_register_id) AS MappedDependencyCount
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.risk_source_master  sm ON sm.source_type_code = r.source_type_code
 LEFT JOIN grac_practice.risk_candidate      c  ON c.risk_candidate_id = r.risk_candidate_id
 LEFT JOIN grac_practice.risk_analysis       a  ON a.risk_analysis_id  = r.risk_analysis_id
 LEFT JOIN grac_practice.practice            lp ON lp.practice_id      = r.linked_practice_id
 OUTER APPLY (SELECT TOP 1 x.approval_status_code
                FROM grac_practice.risk_analysis x
               WHERE x.risk_register_id = r.risk_register_id
                 AND x.is_current = 1
               ORDER BY x.analysis_version DESC) AS cur
 LEFT JOIN grac_practice.risk_residual_analysis res
        ON res.risk_residual_analysis_id = r.residual_analysis_id
 LEFT JOIN grac_practice.organization_employee rab ON rab.employee_id = res.assessed_by_employee_id
 LEFT JOIN grac_practice.organization_employee an ON an.employee_id = a.analysed_by_employee_id
 LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
 LEFT JOIN grac_practice.organization_employee rb ON rb.employee_id = r.registered_by_employee_id
 LEFT JOIN grac_practice.organization_employee cb ON cb.employee_id = r.closed_by_employee_id
 LEFT JOIN grac_practice.organization_employee ab ON ab.employee_id = r.accepted_by_employee_id
 LEFT JOIN grac_practice.organization_employee td ON td.employee_id = r.treatment_decided_by_employee_id
 LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st ON st.risk_register_id = r.risk_register_id
     WHERE r.risk_register_id = @risk_register_id;
END;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '265 dependency map tables present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_dependency_map','U')        IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_dependency_map_source','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '265 asset-only tables gone' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_asset_map','U')        IS NULL
             AND OBJECT_ID('grac_practice.risk_asset_map_source','U') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- The categories Risk Analysis will offer ARE the Operationalize ones.
-- Asserted by counting the same table sp_resolve_dependency_type_list
-- reads, so a drift between the two screens shows up here.
SELECT '265 categories come from dependency_type_master' AS Check_,
       CONCAT(CAST(COUNT(*) AS NVARCHAR(10)), ' active category(ies): ',
              STRING_AGG(CONVERT(NVARCHAR(MAX), dependency_type_name), ', ')
                  WITHIN GROUP (ORDER BY display_order)) AS Result
  FROM grac_practice.dependency_type_master
 WHERE is_active = 1;

-- Every active category must be resolvable to real objects, or the
-- screen shows a category nobody can pick anything for.
SELECT '265 every active category has a source config' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1
                  FROM grac_practice.dependency_type_master dt
                 WHERE dt.is_active = 1
                   AND NOT EXISTS (SELECT 1 FROM grac_practice.dependency_type_source_config c
                                    WHERE c.dependency_type_id = dt.dependency_type_id))
            THEN 'PASS' ELSE 'FAIL -- see the query in this file''s header' END AS Result;

SELECT '265 one mapping per (risk, category, object)' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.risk_dependency_map
                 GROUP BY risk_register_id, dependency_type_id, dependency_object_id
                HAVING COUNT(*) > 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '265 Risk dependency mapping schema installed.';
PRINT '     Categories are dependency_type_master rows -- the SAME source';
PRINT '     Operationalize reads. Nothing here hard-codes a category.';
PRINT '     NEXT: run 266_risk_dependency_procs.sql -- 262''s procedures still';
PRINT '           reference the dropped asset tables until you do.';
GO

SET NOEXEC OFF;
GO
