-- =====================================================================
-- 375 Risk Category -- many-to-many selection on a risk (schema)
--
-- REQUEST
-- -------
-- In the Risk Analysis form, Risk Category currently allows selecting
-- only ONE category. Change it to a multi-select, so a risk that is
-- genuinely both Operational and Compliance is recorded as both, not
-- forced into one. Multiple categories must be:
--   1. captured in the UI (multi-select, reusing the existing GRAC
--      pattern),
--   2. sent through the API and saved via a proper mapping/relationship
--      table -- not a comma-separated string baked into one column,
--   3. loaded again when editing/viewing the analysis, and
--   4. shown comma-separated in the Risk List/Grid's Category column.
--
-- THIS IS 285's / 313's PATTERN, NOT A NEW ONE
-- ---------------------------------------------------------------------
-- 285 built exactly this shape for Threats and Vulnerabilities, and 313
-- built it again for Risk Type: an organisation-aware master plus link
-- tables at BOTH analysis version level and register level. Every
-- decision below is one of those two decisions, for the same reason:
--
--   * LINK TABLES ON BOTH ANALYSIS AND REGISTER. The analysis row is
--     the versioned audit record of what was assessed (BRD 20); the
--     register row is the current answer the grid reads without a join
--     to the newest version. 205 freezes risk_category_name on both for
--     the same reason 205 freezes likelihood_name.
--
--   * LEGACY COLUMNS STAY, AND STAY REQUIRED. risk_analysis.risk_
--     category_code / risk_category_name and their register twins are
--     NOT dropped, and sp_risk_register_assess's @risk_category_code
--     parameter is NOT made optional (or touched at all -- see 376's
--     header for why there is no wrapper). risk_category_master has no
--     "Others" free-text escape hatch (unlike threat/vulnerability), so
--     there is nothing to convert on next save; the legacy scalar is
--     simply kept in step as "the first selected category", written by
--     the SAME sp_risk_register_assess call the form has always made
--     (285/313's own convention: 313 comments this as "the affordance
--     only", meaning the real guarantee is the new required-selection
--     guard in the SET procedure -- 376's 56741).
--
-- WHERE THIS DELIBERATELY DIVERGES FROM 285
-- ---------------------------------------------------------------------
-- risk_category_master (204) is ALREADY organisation-owned --
-- organization_id BIGINT NOT NULL, no NULL-means-shared row, no
-- "Others" id-0 escape hatch, and a plain IDENTITY BIGINT primary key
-- (not an externally-mirrored id needing a reserved allocation band
-- the way threat_id / risk_type_id do). So this migration:
--   * does NOT add organization_id to risk_category_master (already
--     there, already NOT NULL),
--   * does NOT need a reserved-id-band allocation scheme,
--   * DOES still need a backfill, because risk_category_code is an
--     EXISTING column with real data (313 was a brand-new field with
--     nothing to backfill; 285 is the template for the backfill shape).
--
-- THE BACKFILL
-- ---------------------------------------------------------------------
-- Every risk_analysis / risk_register row whose risk_category_code
-- matches a row in THIS ORGANISATION's risk_category_master gets that
-- one category copied into the new link table, so a risk analysed
-- before this ships opens with its existing category already shown as
-- a ticked option, not an empty control. NOT EXISTS-gated, so re-running
-- this file is safe and never overwrites a selection an analyst has
-- since changed. Unlike 285, there is no "Others" id to skip -- every
-- non-null risk_category_code either matches a master row or it does
-- not (an org that has since renamed or retired that category code
-- leaves that one historical row without a backfilled selection, which is
-- correct: there is nothing left in the master to point the chip at).
--
-- Re-runnable: yes -- every object is guarded, the backfill is
--              NOT EXISTS-gated.
-- Rollback: database/375_risk_category_multi_schema_rollback.sql
-- DEPENDS ON: 204 (risk_category_master), 205 (risk_analysis,
--             risk_register).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- ---- Preflight -------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (375): schema grac_practice missing. Run base scripts first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.risk_category_master','U') IS NULL
BEGIN
    PRINT 'ABORT (375): risk_category_master missing. Run 204 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.risk_analysis','U') IS NULL
   OR OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN
    PRINT 'ABORT (375): risk_analysis / risk_register missing. Run 205 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('375_risk_category_multi_schema: prerequisites missing -- see the PRINT messages above. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. risk_analysis_risk_category -- the VERSIONED audit set
--
-- One row per (analysis version, category). ON DELETE CASCADE from the
-- analysis: if an analysis version is ever removed, its selection has
-- no meaning without it. The master side is NOT cascaded -- retiring a
-- category (status = 'Inactive') must not silently rewrite what an
-- audit record says was assessed.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_analysis_risk_category','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.risk_analysis_risk_category(
        risk_analysis_id BIGINT NOT NULL
            CONSTRAINT fk_pm_ra_category_analysis
                REFERENCES grac_practice.risk_analysis(risk_analysis_id)
                ON DELETE CASCADE,
        risk_category_id BIGINT NOT NULL
            CONSTRAINT fk_pm_ra_category_master
                REFERENCES grac_practice.risk_category_master(risk_category_id),
        entered_by       NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_ra_category_by DEFAULT N'system',
        entered_dt       DATETIME2 NOT NULL
            CONSTRAINT df_pm_ra_category_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT pk_pm_ra_category PRIMARY KEY (risk_analysis_id, risk_category_id)
    );
    PRINT '375: risk_analysis_risk_category created.';
END
ELSE
    PRINT '375: risk_analysis_risk_category already present -- left alone.';
GO

-- =====================================================================
-- 2. risk_register_risk_category -- the CURRENT set
--
-- What the register grid and every read screen show without joining to
-- the newest analysis version.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_register_risk_category','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.risk_register_risk_category(
        risk_register_id BIGINT NOT NULL
            CONSTRAINT fk_pm_rr_category_register
                REFERENCES grac_practice.risk_register(risk_register_id)
                ON DELETE CASCADE,
        risk_category_id BIGINT NOT NULL
            CONSTRAINT fk_pm_rr_category_master
                REFERENCES grac_practice.risk_category_master(risk_category_id),
        entered_by       NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_rr_category_by DEFAULT N'system',
        entered_dt       DATETIME2 NOT NULL
            CONSTRAINT df_pm_rr_category_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT pk_pm_rr_category PRIMARY KEY (risk_register_id, risk_category_id)
    );
    PRINT '375: risk_register_risk_category created.';
END
ELSE
    PRINT '375: risk_register_risk_category already present -- left alone.';
GO

-- The reverse lookup: "which risks carry Compliance Risk?" -- the same
-- shape 313's ix_pm_risk_register_risk_type_type index gives Risk Type,
-- and the STRING_AGG the grid does (376) needs the forward direction
-- indexed too, which the primary key already covers (risk_register_id
-- leads it).
IF OBJECT_ID('grac_practice.risk_register_risk_category','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'ix_pm_rr_category_type'
                      AND object_id = OBJECT_ID('grac_practice.risk_register_risk_category'))
    CREATE INDEX ix_pm_rr_category_type
        ON grac_practice.risk_register_risk_category(risk_category_id)
        INCLUDE(risk_register_id);
GO

-- =====================================================================
-- 3. Backfill the existing single values
--
-- risk_category_code matched against THIS ORGANISATION's master (the
-- code is only unique per (organization_id, category_code) -- 204's
-- uq_pm_risk_category_org_code -- so the join must include organization
-- to avoid attaching a different tenant's same-named category).
--
-- NOT EXISTS-gated rather than TRUNCATE-and-reload: re-running must not
-- rewrite entered_by/entered_dt on rows a user has since curated, and
-- must not resurrect a chip an analyst deliberately unticked.
-- =====================================================================
INSERT INTO grac_practice.risk_analysis_risk_category(risk_analysis_id, risk_category_id, entered_by)
SELECT a.risk_analysis_id, m.risk_category_id, N'backfill-375'
  FROM grac_practice.risk_analysis a
  JOIN grac_practice.risk_category_master m
    ON m.organization_id = a.organization_id
   AND m.category_code   = a.risk_category_code
 WHERE a.risk_category_code IS NOT NULL
   AND LEN(LTRIM(RTRIM(a.risk_category_code))) > 0
   AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_analysis_risk_category x
                    WHERE x.risk_analysis_id = a.risk_analysis_id AND x.risk_category_id = m.risk_category_id);
GO

INSERT INTO grac_practice.risk_register_risk_category(risk_register_id, risk_category_id, entered_by)
SELECT r.risk_register_id, m.risk_category_id, N'backfill-375'
  FROM grac_practice.risk_register r
  JOIN grac_practice.risk_category_master m
    ON m.organization_id = r.organization_id
   AND m.category_code   = r.risk_category_code
 WHERE r.risk_category_code IS NOT NULL
   AND LEN(LTRIM(RTRIM(r.risk_category_code))) > 0
   AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_register_risk_category x
                    WHERE x.risk_register_id = r.risk_register_id AND x.risk_category_id = m.risk_category_id);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '375-a both link tables exist' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_analysis_risk_category','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_register_risk_category','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '375-b both link tables key on (parent, category)',
       CASE WHEN EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'pk_pm_ra_category')
             AND EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'pk_pm_rr_category')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '375-c the reverse-lookup index exists',
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_rr_category_type')
            THEN 'PASS' ELSE 'FAIL' END;

-- The backfill must have moved every matchable reference. A miss here
-- means a risk will open with an empty control where it used to show a
-- category.
SELECT '375-d register category backfill complete for every matchable row' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.risk_register r
                 WHERE r.risk_category_code IS NOT NULL
                   AND LEN(LTRIM(RTRIM(r.risk_category_code))) > 0
                   AND EXISTS (SELECT 1 FROM grac_practice.risk_category_master m
                                WHERE m.organization_id = r.organization_id
                                  AND m.category_code   = r.risk_category_code)
                   AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_register_risk_category x
                                    WHERE x.risk_register_id = r.risk_register_id))
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '375-e rows with no matching master row (expected -- code renamed/retired since)' AS Check_,
       CAST((SELECT COUNT(*) FROM grac_practice.risk_register r
              WHERE r.risk_category_code IS NOT NULL
                AND LEN(LTRIM(RTRIM(r.risk_category_code))) > 0
                AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_category_master m
                                 WHERE m.organization_id = r.organization_id
                                   AND m.category_code   = r.risk_category_code)) AS NVARCHAR(20))
       + ' register rows left with no backfilled chip' AS Result;

PRINT '';
PRINT '375 complete. Both link tables exist and are backfilled from the';
PRINT 'existing single risk_category_code values. Nothing reads or writes';
PRINT 'them yet -- that is 376 (procedures), then the API, then the form.';
GO

SET NOEXEC OFF;
GO
