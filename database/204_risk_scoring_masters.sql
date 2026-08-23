-- =====================================================================
-- 204 Risk Centre — scoring + classification masters
--     (Risk Candidate Analysis and Risk Register BRD, §7, §12, §13)
--
-- WHY THIS FILE EXISTS
-- --------------------
-- BRD §7 says the initial analysis captures Likelihood, Impact and an
-- Inherent Risk Rating, and that "the actual scoring methodology shall be
-- configurable based on the organisation's risk framework". BRD §12 then
-- says the Custom Risk route must reuse the SAME categories, scales and
-- matrix as the stream route — "the only difference shall be the entry
-- route".
--
-- Both sentences point at one thing: the scale must be DATA, owned per
-- organisation, and there must be exactly one copy of it. A hardcoded
-- 5x5 in a proc, or a second copy for custom risks, breaks §12 the day
-- an organisation changes its framework.
--
-- So this migration adds five masters and nothing else. No candidate, no
-- register, no analysis — those are 205. Keeping the scale in its own
-- migration means an organisation can be re-configured (206's procs read
-- these tables live) without touching transactional schema.
--
-- WHAT THIS MIGRATION ADDS
-- ------------------------
--   grac_practice.risk_source_master        BRD §13 source classification
--   grac_practice.risk_category_master      BRD §7.1 Risk Category
--   grac_practice.risk_likelihood_master    BRD §7.1 Likelihood scale
--   grac_practice.risk_impact_master        BRD §7.1 Impact scale
--   grac_practice.risk_matrix_cell          BRD §7.1 Inherent Risk Rating
--   sp_risk_scoring_seed_default            idempotent per-org 5x5 seed
--
-- SOURCE MASTER IS GLOBAL, THE REST ARE ORG-SCOPED
-- ------------------------------------------------
-- BRD §13 requires the source model to be "extensible so that additional
-- GRAC Centres can contribute risk candidates without redesigning the
-- Risk Centre". A source is a GRAC structural fact (there IS a Gap
-- Centre), not an organisational preference, so risk_source_master is a
-- global list with an is_system flag: system rows are the Centres that
-- exist, non-system rows are an organisation's own extensions under
-- 'Other'. Categories and scales ARE organisational preference, so they
-- carry organization_id.
--
-- NOTE ON 'Custom'
-- ----------------
-- BRD §24 rule 8: "Custom risks shall have source type Custom." That row
-- is seeded here and is the only source_type_code a Route B risk may
-- carry; 206 enforces it.
--
-- ADDITIVE ONLY. Idempotent — safe to re-run.
-- ERROR CODE RANGE: 56000-56019
-- Rollback: database/204_risk_scoring_masters_rollback.sql
-- Next:     205_risk_register_schema.sql
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (204): schema grac_practice is missing.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.organization','U') IS NULL
BEGIN PRINT 'ABORT (204): organization missing — run 001 first.'; SET @ok = 0; END

IF OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN PRINT 'ABORT (204): record_status_master missing — run 008 first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('204_risk_scoring_masters: prerequisites missing — see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. risk_source_master  (BRD §13)
--
-- source_type_code is the vocabulary every downstream table stores. It
-- deliberately overlaps task_candidate.source_type_code (197) where the
-- concepts coincide — Gap, Exception, Risk-adjacent Centres read the
-- same words across GRAC — but Risk has more sources than Task Centre
-- does, so it keeps its own list rather than widening 197's CHECK.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_source_master','U') IS NULL
CREATE TABLE grac_practice.risk_source_master(
    risk_source_id       INT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_source_master PRIMARY KEY,
    source_type_code     NVARCHAR(40)  NOT NULL
        CONSTRAINT uq_pm_risk_source_code UNIQUE,
    source_name          NVARCHAR(120) NOT NULL,
    description          NVARCHAR(500) NULL,

    -- The GRAC Centre that owns the originating record, for the §10
    -- "navigate back to source" link. NULL for Custom and Other.
    source_centre_code   NVARCHAR(60)  NULL,

    -- System rows are the Centres GRAC ships with and must not be
    -- deleted; an organisation extending §13 adds non-system rows.
    is_system            BIT NOT NULL
        CONSTRAINT df_pm_risk_source_is_system DEFAULT 0,
    display_order        INT NOT NULL
        CONSTRAINT df_pm_risk_source_order DEFAULT 100,
    status               NVARCHAR(20) NOT NULL
        CONSTRAINT df_pm_risk_source_status DEFAULT N'Active',
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_source_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_source_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,

    CONSTRAINT ck_pm_risk_source_status CHECK (status IN (N'Active', N'Inactive'))
);
GO

-- BRD §13's exact table, in its order.
MERGE grac_practice.risk_source_master AS t
USING (VALUES
    (N'Practice',   N'Practice',   N'Risk identified through practice/control evaluation', N'Practice',        10),
    (N'Assurance',  N'Assurance',  N'Risk identified through assurance activity',           N'Assurance',       20),
    (N'Gap',        N'Gap',        N'Risk originating from an identified gap',              N'GapCentre',       30),
    (N'Exception',  N'Exception',  N'Risk arising from an accepted/unresolved exception',   N'ExceptionCentre', 40),
    (N'Obligation', N'Obligation', N'Risk associated with an obligation or regulatory requirement', N'Obligation', 50),
    (N'Asset',      N'Asset',      N'Risk associated with an asset',                        N'Asset',           60),
    (N'Vendor',     N'Vendor',     N'Risk associated with a vendor/service',                N'Vendor',          70),
    (N'Event',      N'Event',      N'Risk triggered by a defined event',                    N'EventAssurance',  80),
    (N'Custom',     N'Custom',     N'Risk directly identified by an authorised user',       NULL,               90),
    (N'Other',      N'Other',      N'Configurable future source',                           NULL,              100)
) AS s(source_type_code, source_name, description, source_centre_code, display_order)
ON t.source_type_code = s.source_type_code
WHEN MATCHED THEN UPDATE SET
    source_name        = s.source_name,
    description        = s.description,
    source_centre_code = s.source_centre_code,
    display_order      = s.display_order,
    is_system          = 1,
    status             = N'Active',
    updated_by         = 'seed-204',
    updated_dt         = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (source_type_code, source_name, description, source_centre_code,
     is_system, display_order, status, entered_by)
VALUES
    (s.source_type_code, s.source_name, s.description, s.source_centre_code,
     1, s.display_order, N'Active', 'seed-204');
GO

-- =====================================================================
-- 2. risk_category_master  (BRD §7.1 "Risk Category", §12 "same
--    categories for both routes")
--
-- Org-scoped: a bank's category list is not a hospital's. Seeded with a
-- neutral default set by sp_risk_scoring_seed_default so an organisation
-- can analyse a risk on day one and refine the list later.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_category_master','U') IS NULL
CREATE TABLE grac_practice.risk_category_master(
    risk_category_id     BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_category_master PRIMARY KEY,
    organization_id      BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_category_organization
            REFERENCES grac_practice.organization(organization_id),
    category_code        NVARCHAR(60)  NOT NULL,
    category_name        NVARCHAR(200) NOT NULL,
    description          NVARCHAR(500) NULL,
    display_order        INT NOT NULL
        CONSTRAINT df_pm_risk_category_order DEFAULT 100,
    status               NVARCHAR(20) NOT NULL
        CONSTRAINT df_pm_risk_category_status DEFAULT N'Active',
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_category_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_category_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,

    CONSTRAINT uq_pm_risk_category_org_code UNIQUE (organization_id, category_code),
    CONSTRAINT ck_pm_risk_category_status CHECK (status IN (N'Active', N'Inactive'))
);
GO

-- =====================================================================
-- 3. risk_likelihood_master  (BRD §7.1 "Likelihood")
--
-- level_value is the number the matrix is keyed on. Keeping it separate
-- from display_order means an organisation can reorder the picklist
-- without silently rescoring every existing risk.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_likelihood_master','U') IS NULL
CREATE TABLE grac_practice.risk_likelihood_master(
    risk_likelihood_id   BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_likelihood_master PRIMARY KEY,
    organization_id      BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_likelihood_organization
            REFERENCES grac_practice.organization(organization_id),
    likelihood_code      NVARCHAR(60)  NOT NULL,
    likelihood_name      NVARCHAR(200) NOT NULL,
    level_value          INT NOT NULL,            -- 1..N, feeds the matrix
    descriptor           NVARCHAR(500) NULL,      -- e.g. "Expected once a year"
    status               NVARCHAR(20) NOT NULL
        CONSTRAINT df_pm_risk_likelihood_status DEFAULT N'Active',
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_likelihood_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_likelihood_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,

    CONSTRAINT uq_pm_risk_likelihood_org_code  UNIQUE (organization_id, likelihood_code),
    CONSTRAINT uq_pm_risk_likelihood_org_level UNIQUE (organization_id, level_value),
    CONSTRAINT ck_pm_risk_likelihood_level  CHECK (level_value BETWEEN 1 AND 10),
    CONSTRAINT ck_pm_risk_likelihood_status CHECK (status IN (N'Active', N'Inactive'))
);
GO

-- =====================================================================
-- 4. risk_impact_master  (BRD §7.1 "Impact")
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_impact_master','U') IS NULL
CREATE TABLE grac_practice.risk_impact_master(
    risk_impact_id       BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_impact_master PRIMARY KEY,
    organization_id      BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_impact_organization
            REFERENCES grac_practice.organization(organization_id),
    impact_code          NVARCHAR(60)  NOT NULL,
    impact_name          NVARCHAR(200) NOT NULL,
    level_value          INT NOT NULL,
    descriptor           NVARCHAR(500) NULL,
    status               NVARCHAR(20) NOT NULL
        CONSTRAINT df_pm_risk_impact_status DEFAULT N'Active',
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_impact_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_impact_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,

    CONSTRAINT uq_pm_risk_impact_org_code  UNIQUE (organization_id, impact_code),
    CONSTRAINT uq_pm_risk_impact_org_level UNIQUE (organization_id, level_value),
    CONSTRAINT ck_pm_risk_impact_level  CHECK (level_value BETWEEN 1 AND 10),
    CONSTRAINT ck_pm_risk_impact_status CHECK (status IN (N'Active', N'Inactive'))
);
GO

-- =====================================================================
-- 5. risk_matrix_cell  (BRD §7.1 "Inherent Risk Rating", §12 "risk
--    matrix")
--
-- One row per (likelihood, impact) pair. Storing the whole matrix rather
-- than a formula is deliberate: real GRC matrices are not symmetric and
-- are rarely a simple product — an organisation routinely promotes
-- (Low likelihood x Catastrophic impact) to High. A formula cannot
-- express that; a grid can.
--
-- rating_code is free text on purpose. Some frameworks use
-- Low/Medium/High/Critical, others use 1-4 or colour bands, and §7 says
-- the methodology is the organisation's. 206 never interprets the code —
-- it copies it onto the analysis and the register entry.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_matrix_cell','U') IS NULL
CREATE TABLE grac_practice.risk_matrix_cell(
    risk_matrix_cell_id  BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_matrix_cell PRIMARY KEY,
    organization_id      BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_matrix_organization
            REFERENCES grac_practice.organization(organization_id),
    likelihood_value     INT NOT NULL,
    impact_value         INT NOT NULL,
    rating_code          NVARCHAR(30)  NOT NULL,
    rating_name          NVARCHAR(120) NOT NULL,
    rating_score         INT NULL,                -- optional numeric score
    colour_hex           NVARCHAR(10) NULL,       -- heat-map colour for the UI
    entered_by NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_risk_matrix_entered_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL
        CONSTRAINT df_pm_risk_matrix_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,

    CONSTRAINT uq_pm_risk_matrix_cell UNIQUE (organization_id, likelihood_value, impact_value),
    CONSTRAINT ck_pm_risk_matrix_likelihood CHECK (likelihood_value BETWEEN 1 AND 10),
    CONSTRAINT ck_pm_risk_matrix_impact     CHECK (impact_value     BETWEEN 1 AND 10)
);
GO

-- =====================================================================
-- 6. sp_risk_scoring_seed_default
--
-- Gives one organisation a working 5x5 framework: 5 likelihood levels,
-- 5 impact levels, 25 matrix cells and a neutral category list.
--
-- IDEMPOTENT AND NON-DESTRUCTIVE. Every statement is a MERGE guarded on
-- the natural key, and the matrix MERGE only INSERTs — an organisation
-- that has re-graded a cell keeps its grading if this is re-run. That
-- matters because 205 and any future migration may call this proc for
-- newly created organisations.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_scoring_seed_default
    @organization_id     BIGINT,
    @caller_display_name NVARCHAR(100) = N'seed-204'
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 56000, 'sp_risk_scoring_seed_default: organization_id is required.', 1;
    IF NOT EXISTS(SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 56001, 'sp_risk_scoring_seed_default: organization not found.', 1;

    -- ---- Likelihood scale (1 = rarest) -------------------------------
    MERGE grac_practice.risk_likelihood_master AS t
    USING (VALUES
        (N'Rare',           N'Rare',           1, N'May occur only in exceptional circumstances (< once in 5 years)'),
        (N'Unlikely',       N'Unlikely',       2, N'Could occur at some time (once in 2-5 years)'),
        (N'Possible',       N'Possible',       3, N'Might occur at some time (about once a year)'),
        (N'Likely',         N'Likely',         4, N'Will probably occur in most circumstances (several times a year)'),
        (N'AlmostCertain',  N'Almost Certain', 5, N'Expected to occur in most circumstances (monthly or more often)')
    ) AS s(likelihood_code, likelihood_name, level_value, descriptor)
    ON t.organization_id = @organization_id AND t.likelihood_code = s.likelihood_code
    WHEN NOT MATCHED THEN INSERT
        (organization_id, likelihood_code, likelihood_name, level_value, descriptor, status, entered_by)
    VALUES
        (@organization_id, s.likelihood_code, s.likelihood_name, s.level_value, s.descriptor,
         N'Active', @caller_display_name);

    -- ---- Impact scale (1 = mildest) ----------------------------------
    MERGE grac_practice.risk_impact_master AS t
    USING (VALUES
        (N'Insignificant', N'Insignificant', 1, N'No material effect; absorbed by normal operations'),
        (N'Minor',         N'Minor',         2, N'Limited effect; resolved within the business unit'),
        (N'Moderate',      N'Moderate',      3, N'Noticeable effect; management attention required'),
        (N'Major',         N'Major',         4, N'Significant effect on objectives, finances or reputation'),
        (N'Severe',        N'Severe',        5, N'Threatens the organisation''s objectives, licence or viability')
    ) AS s(impact_code, impact_name, level_value, descriptor)
    ON t.organization_id = @organization_id AND t.impact_code = s.impact_code
    WHEN NOT MATCHED THEN INSERT
        (organization_id, impact_code, impact_name, level_value, descriptor, status, entered_by)
    VALUES
        (@organization_id, s.impact_code, s.impact_name, s.level_value, s.descriptor,
         N'Active', @caller_display_name);

    -- ---- 5x5 matrix ---------------------------------------------------
    -- Banding: score = likelihood x impact, with the two conventional
    -- overrides GRC practitioners expect — a Severe impact is never Low
    -- however rare, and an Almost Certain likelihood is never Low however
    -- mild. Those two rows are exactly why this is a grid and not a
    -- formula (see the table header note).
    ;WITH lv AS (SELECT v FROM (VALUES (1),(2),(3),(4),(5)) x(v)),
         iv AS (SELECT v FROM (VALUES (1),(2),(3),(4),(5)) y(v)),
         grid AS (
            SELECT lv.v AS likelihood_value,
                   iv.v AS impact_value,
                   lv.v * iv.v AS raw_score
              FROM lv CROSS JOIN iv
         ),
         graded AS (
            SELECT likelihood_value, impact_value, raw_score,
                   CASE
                     WHEN raw_score >= 15                              THEN N'Critical'
                     WHEN raw_score >= 10                              THEN N'High'
                     WHEN impact_value = 5                             THEN N'High'      -- severe impact floor
                     WHEN raw_score >= 5                               THEN N'Medium'
                     WHEN likelihood_value = 5                         THEN N'Medium'    -- near-certain floor
                     ELSE N'Low'
                   END AS rating_code
              FROM grid
         )
    MERGE grac_practice.risk_matrix_cell AS t
    USING (
        SELECT likelihood_value, impact_value, raw_score, rating_code,
               CASE rating_code WHEN N'Critical' THEN N'Critical'
                                WHEN N'High'     THEN N'High'
                                WHEN N'Medium'   THEN N'Medium'
                                ELSE N'Low' END AS rating_name,
               CASE rating_code WHEN N'Critical' THEN N'#742A2A'
                                WHEN N'High'     THEN N'#E53E3E'
                                WHEN N'Medium'   THEN N'#D69E2E'
                                ELSE N'#38A169' END AS colour_hex
          FROM graded
    ) AS s
    ON t.organization_id  = @organization_id
   AND t.likelihood_value = s.likelihood_value
   AND t.impact_value     = s.impact_value
    WHEN NOT MATCHED THEN INSERT
        (organization_id, likelihood_value, impact_value,
         rating_code, rating_name, rating_score, colour_hex, entered_by)
    VALUES
        (@organization_id, s.likelihood_value, s.impact_value,
         s.rating_code, s.rating_name, s.raw_score, s.colour_hex, @caller_display_name);

    -- ---- Category list ------------------------------------------------
    MERGE grac_practice.risk_category_master AS t
    USING (VALUES
        (N'Strategic',     N'Strategic',              N'Risks to business objectives, market position or strategy', 10),
        (N'Operational',   N'Operational',            N'Risks in day-to-day processes, people and systems',         20),
        (N'Compliance',    N'Compliance / Regulatory',N'Risks of breaching law, regulation or obligation',          30),
        (N'Financial',     N'Financial',              N'Risks to financial reporting, liquidity or cost',           40),
        (N'Technology',    N'Technology',             N'Risks in applications, infrastructure and change',          50),
        (N'InfoSec',       N'Information Security',   N'Risks to confidentiality, integrity or availability',       60),
        (N'ThirdParty',    N'Third Party / Vendor',   N'Risks arising from suppliers, vendors and outsourcing',     70),
        (N'Reputational',  N'Reputational',           N'Risks to brand, trust and stakeholder confidence',          80),
        (N'People',        N'People / HR',            N'Risks in resourcing, capability, conduct and safety',        90),
        (N'Other',         N'Other',                  N'Uncategorised — refine as the framework matures',          100)
    ) AS s(category_code, category_name, description, display_order)
    ON t.organization_id = @organization_id AND t.category_code = s.category_code
    WHEN NOT MATCHED THEN INSERT
        (organization_id, category_code, category_name, description, display_order, status, entered_by)
    VALUES
        (@organization_id, s.category_code, s.category_name, s.description,
         s.display_order, N'Active', @caller_display_name);
END;
GO

-- =====================================================================
-- 7. Seed every currently active organisation
-- =====================================================================
DECLARE @org_id BIGINT;
DECLARE org_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT organization_id FROM grac_practice.organization WHERE status = N'Active';
OPEN org_cur;
FETCH NEXT FROM org_cur INTO @org_id;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC grac_practice.sp_risk_scoring_seed_default
         @organization_id = @org_id, @caller_display_name = N'seed-204';
    FETCH NEXT FROM org_cur INTO @org_id;
END
CLOSE org_cur;
DEALLOCATE org_cur;
GO

-- =====================================================================
-- 8. Indexes
-- =====================================================================
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_category_org'
                  AND object_id = OBJECT_ID('grac_practice.risk_category_master'))
    CREATE INDEX ix_pm_risk_category_org
        ON grac_practice.risk_category_master(organization_id, status, display_order);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_likelihood_org'
                  AND object_id = OBJECT_ID('grac_practice.risk_likelihood_master'))
    CREATE INDEX ix_pm_risk_likelihood_org
        ON grac_practice.risk_likelihood_master(organization_id, status, level_value);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_impact_org'
                  AND object_id = OBJECT_ID('grac_practice.risk_impact_master'))
    CREATE INDEX ix_pm_risk_impact_org
        ON grac_practice.risk_impact_master(organization_id, status, level_value);
GO

-- =====================================================================
-- 9. Sanity
-- =====================================================================
SELECT '204 masters present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_source_master','U')     IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_category_master','U')   IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_likelihood_master','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_impact_master','U')     IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_matrix_cell','U')       IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'BRD 13 sources seeded (10 expected)' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.risk_source_master WHERE is_system = 1) >= 10
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'every active org has a full 5x5 matrix' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.organization o
                 WHERE o.status = N'Active'
                   AND (SELECT COUNT(*) FROM grac_practice.risk_matrix_cell m
                         WHERE m.organization_id = o.organization_id) < 25)
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '204 Risk scoring masters installed. Next: 205_risk_register_schema.sql';
GO

SET NOEXEC OFF;
GO
