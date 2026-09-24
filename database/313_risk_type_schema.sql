-- =====================================================================
-- 313 Risk Type (Confidentiality / Integrity / Availability) -- schema
--     and seed
--
-- WHAT THIS IS FOR
--   Inherent Risk Analysis and Review Risk capture WHICH security
--   properties a risk threatens. The CIA triad, MULTI-SELECT: a risk
--   that leaks data and corrupts it is Confidentiality AND Integrity,
--   and being made to pick one would be a false record.
--
-- THIS IS 285's PATTERN, NOT A NEW ONE
--   285 built exactly this shape for Threats and Vulnerabilities:
--   an organisation-aware master plus link tables at BOTH analysis
--   version level and register level. Every decision below is that
--   decision, for the same reason:
--
--     * ORGANISATION-AWARE MASTER. organization_id NULL = the seeded,
--       shared rows every tenant sees. A value = created by that tenant,
--       private to it. The three rows this file seeds are NULL, so every
--       organisation sees them and no tenant can edit them away.
--
--     * PLAIN INT PK, NOT IDENTITY, and organisation rows allocated from
--       a reserved band starting at 1,000,000. 285's header explains the
--       original reason (216 mirrors external ids); the reason to keep it
--       here is that these two masters sit side by side and read by the
--       same code, and one being IDENTITY while its sibling is not is a
--       trap for whoever writes the next one.
--
--     * LINK TABLES ON BOTH ANALYSIS AND REGISTER. The analysis row is
--       the versioned audit record of what was assessed (BRD 20); the
--       register row is the current answer the grid reads without a join
--       to the newest version. 205 freezes likelihood_name for the same
--       reason.
--
-- WHERE IT DELIBERATELY DIVERGES FROM 285, AND WHY
--   Risk Type is NEW. There is no pre-existing single risk_type_id
--   column on risk_analysis or risk_register, no "Others" free-text
--   escape hatch, and no legacy data. So this migration has:
--     * NO lead-id column to keep a foreign key satisfied,
--     * NO backfill -- there is nothing to backfill from,
--     * NO free-text conversion path.
--   285 needed all three because it was replacing something. This is not.
--
-- DISPLAY ORDER IS DATA, NOT A SORT
--   Ordered C, I, A -- the order the triad is always given in. Sorting by
--   name would put Availability first, which reads as a mistake to
--   anybody who works in security. display_order carries it so the UI
--   does not have to special-case three strings.
--
-- REQUIRED AT SAVE TIME, AND THAT RULE LIVES IN 314
--   At least one risk type must be selected. The schema does NOT enforce
--   it -- a CHECK cannot span a link table, and a trigger to do it would
--   be a second place for the rule to live. 314's
--   sp_risk_type_selection_set throws 56731 on an empty set, and the two
--   forms mark the control required. Consequence, accepted deliberately:
--   a risk analysed before this ships has no risk type and cannot be
--   re-saved until an analyst picks one.
--
-- Re-runnable: yes -- every object is guarded, the seed is insert-only.
-- Rollback: database/313_risk_type_schema_rollback.sql
-- DEPENDS ON: 205 (risk_analysis, risk_register), 001 (organization).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- ---- Preflight -------------------------------------------------------
-- The link tables carry real foreign keys. Creating them against absent
-- parents would leave un-FK-able rubble behind.
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (313): schema grac_practice missing. Run base scripts first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.organization','U') IS NULL
BEGIN
    PRINT 'ABORT (313): organization missing. Run 001 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.risk_analysis','U') IS NULL
   OR OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN
    PRINT 'ABORT (313): risk_analysis / risk_register missing. Run 205 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('313_risk_type_schema: prerequisites missing -- see the PRINT messages above. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. risk_type_master
--
-- status_id INT DEFAULT 1 mirrors threat_master / vulnerability_master
-- (216) rather than introducing an NVARCHAR status beside them. Two
-- masters read by the same screen should not disagree about how they say
-- "active".
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_type_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.risk_type_master(
        risk_type_id    INT NOT NULL
            CONSTRAINT pk_pm_risk_type_master PRIMARY KEY,
        -- NULL = shared with every tenant. A value = private to that one.
        organization_id BIGINT NULL
            CONSTRAINT fk_pm_risk_type_master_org
                REFERENCES grac_practice.organization(organization_id),
        risk_type_code  NVARCHAR(30)  NOT NULL,
        risk_type_name  NVARCHAR(120) NOT NULL,
        -- C, I, A -- see the header. Lower sorts first.
        display_order   INT NOT NULL
            CONSTRAINT df_pm_risk_type_master_order DEFAULT 100,
        status_id       INT NOT NULL
            CONSTRAINT df_pm_risk_type_master_status DEFAULT 1,
        entered_by      NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_risk_type_master_entered_by DEFAULT N'system',
        entered_dt      DATETIME2 NOT NULL
            CONSTRAINT df_pm_risk_type_master_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by      NVARCHAR(100) NULL,
        updated_dt      DATETIME2 NULL,

        -- One row per code per owner. SQL Server treats NULLs as equal in
        -- a UNIQUE constraint, so this also permits exactly ONE shared
        -- row per code -- which is what stops a second global
        -- "Confidentiality" appearing.
        CONSTRAINT uq_pm_risk_type_master_code UNIQUE(organization_id, risk_type_code)
    );
    PRINT '313: risk_type_master created.';
END
ELSE
    PRINT '313: risk_type_master already present -- left alone.';
GO

-- =====================================================================
-- 2. The seed -- three shared rows, INSERT-ONLY
--
-- Explicit ids 1/2/3 because the PK is not an IDENTITY, and low ids
-- leave the 1,000,000+ band free for organisation-created types.
--
-- INSERT-ONLY on purpose: NOT EXISTS per row, no MERGE and no UPDATE. An
-- organisation that has renamed its own copy, or a deployment that has
-- retired one, must not have that undone by re-running this file. The
-- same rule 272 applies to every global master seed.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_type_master','U') IS NOT NULL
BEGIN
    INSERT INTO grac_practice.risk_type_master
        (risk_type_id, organization_id, risk_type_code, risk_type_name, display_order, status_id, entered_by)
    SELECT v.risk_type_id, NULL, v.risk_type_code, v.risk_type_name, v.display_order, 1, N'seed-313'
      FROM (VALUES
              (1, N'CONF', N'Confidentiality', 1),
              (2, N'INTG', N'Integrity',       2),
              (3, N'AVAL', N'Availability',    3)
           ) AS v(risk_type_id, risk_type_code, risk_type_name, display_order)
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.risk_type_master m
                        WHERE m.risk_type_id = v.risk_type_id)
       AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_type_master m2
                        WHERE m2.organization_id IS NULL
                          AND m2.risk_type_code = v.risk_type_code);

    PRINT '313: risk type seed applied (insert-only).';
END
GO

-- =====================================================================
-- 3. risk_analysis_risk_type -- the VERSIONED audit set
--
-- One row per (analysis version, risk type). ON DELETE CASCADE from the
-- analysis: if an analysis version is ever removed, its selection has no
-- meaning without it. The master side is NOT cascaded -- retiring a risk
-- type must not silently rewrite what an audit record says was assessed.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_analysis_risk_type','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.risk_analysis_risk_type(
        risk_analysis_id BIGINT NOT NULL
            CONSTRAINT fk_pm_risk_analysis_risk_type_analysis
                REFERENCES grac_practice.risk_analysis(risk_analysis_id)
                ON DELETE CASCADE,
        risk_type_id     INT NOT NULL
            CONSTRAINT fk_pm_risk_analysis_risk_type_type
                REFERENCES grac_practice.risk_type_master(risk_type_id),
        entered_by       NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_risk_analysis_risk_type_entered_by DEFAULT N'system',
        entered_dt       DATETIME2 NOT NULL
            CONSTRAINT df_pm_risk_analysis_risk_type_entered_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT pk_pm_risk_analysis_risk_type
            PRIMARY KEY(risk_analysis_id, risk_type_id)
    );
    PRINT '313: risk_analysis_risk_type created.';
END
ELSE
    PRINT '313: risk_analysis_risk_type already present -- left alone.';
GO

-- =====================================================================
-- 4. risk_register_risk_type -- the CURRENT set
--
-- What the register grid and every read screen show without joining to
-- the newest analysis version.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_register_risk_type','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.risk_register_risk_type(
        risk_register_id BIGINT NOT NULL
            CONSTRAINT fk_pm_risk_register_risk_type_risk
                REFERENCES grac_practice.risk_register(risk_register_id)
                ON DELETE CASCADE,
        risk_type_id     INT NOT NULL
            CONSTRAINT fk_pm_risk_register_risk_type_type
                REFERENCES grac_practice.risk_type_master(risk_type_id),
        entered_by       NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_risk_register_risk_type_entered_by DEFAULT N'system',
        entered_dt       DATETIME2 NOT NULL
            CONSTRAINT df_pm_risk_register_risk_type_entered_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT pk_pm_risk_register_risk_type
            PRIMARY KEY(risk_register_id, risk_type_id)
    );
    PRINT '313: risk_register_risk_type created.';
END
ELSE
    PRINT '313: risk_register_risk_type already present -- left alone.';
GO

-- The reverse lookup: "which risks threaten Confidentiality?" -- the
-- question a security owner asks, and the one that makes the set worth
-- storing rather than deriving.
IF OBJECT_ID('grac_practice.risk_register_risk_type','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'ix_pm_risk_register_risk_type_type'
                      AND object_id = OBJECT_ID('grac_practice.risk_register_risk_type'))
    CREATE INDEX ix_pm_risk_register_risk_type_type
        ON grac_practice.risk_register_risk_type(risk_type_id)
        INCLUDE(risk_register_id);
GO

-- =====================================================================
-- Verification -- PASS/FAIL, so a green run is provable rather than
-- assumed. This matters more than usual: this file was written without
-- the static SQL sweeps this project normally runs, so these SELECTs are
-- the check.
--
-- STRUCTURAL CHECKS ARE STATIC, CONTENT CHECKS ARE DYNAMIC, and the
-- split is not cosmetic. A SELECT has no deferred name resolution:
-- naming risk_type_master in a static statement fails at COMPILE time if
-- the table is absent, which takes the whole batch with it EVEN UNDER
-- SET NOEXEC ON. So on a database where the preflight above aborted,
-- a static content check would replace one clear "prerequisites missing"
-- error with a confusing "Invalid object name". Everything that reads a
-- 313 table therefore goes through sp_executesql, guarded by OBJECT_ID.
-- 264 uses the same device around CREATE VIEW, for the same reason.
-- =====================================================================
SELECT '313-a risk_type_master exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_type_master','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '313-d risk_analysis_risk_type exists',
       CASE WHEN OBJECT_ID('grac_practice.risk_analysis_risk_type','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '313-e risk_register_risk_type exists',
       CASE WHEN OBJECT_ID('grac_practice.risk_register_risk_type','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '313-f both link tables key on (parent, type)',
       CASE WHEN EXISTS (SELECT 1 FROM sys.key_constraints
                          WHERE name = 'pk_pm_risk_analysis_risk_type')
             AND EXISTS (SELECT 1 FROM sys.key_constraints
                          WHERE name = 'pk_pm_risk_register_risk_type')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '313-g one shared row per code is enforced',
       CASE WHEN EXISTS (SELECT 1 FROM sys.key_constraints
                          WHERE name = 'uq_pm_risk_type_master_code')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '313-i the reverse-lookup index exists',
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                          WHERE name = 'ix_pm_risk_register_risk_type_type')
            THEN 'PASS' ELSE 'FAIL' END;

IF OBJECT_ID('grac_practice.risk_type_master','U') IS NOT NULL
BEGIN
    EXEC sp_executesql N'
        SELECT ''313-b the three shared rows are seeded'' AS Check_,
               CASE WHEN (SELECT COUNT(*) FROM grac_practice.risk_type_master
                           WHERE organization_id IS NULL
                             AND risk_type_code IN (N''CONF'', N''INTG'', N''AVAL'')) = 3
                    THEN ''PASS'' ELSE ''FAIL'' END AS Result
        UNION ALL
        SELECT ''313-c they order C, I, A'',
               CASE WHEN (SELECT STRING_AGG(risk_type_code, '','')
                                 WITHIN GROUP (ORDER BY display_order)
                            FROM grac_practice.risk_type_master
                           WHERE organization_id IS NULL) = N''CONF,INTG,AVAL''
                    THEN ''PASS'' ELSE ''FAIL'' END
        UNION ALL
        -- The seed must not have consumed the organisation band.
        SELECT ''313-h the 1,000,000+ band is untouched'',
               CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.risk_type_master
                                      WHERE risk_type_id >= 1000000)
                    THEN ''PASS'' ELSE ''FAIL'' END;

        SELECT risk_type_id    AS RiskTypeId,
               risk_type_code  AS Code,
               risk_type_name  AS Name,
               display_order   AS DisplayOrder,
               organization_id AS OrganizationId,
               status_id       AS StatusId
          FROM grac_practice.risk_type_master
         ORDER BY display_order, risk_type_id;';
END
ELSE
    PRINT '313: risk_type_master absent -- content checks skipped.';

PRINT '';
PRINT '313 complete. The master and both link tables exist and are seeded.';
PRINT 'Nothing reads or writes them yet -- that is 314 (procedures), then';
PRINT 'the API, then the Analysis and Review forms.';
GO

SET NOEXEC OFF;
GO
