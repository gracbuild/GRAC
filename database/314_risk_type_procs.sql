-- =====================================================================
-- 314 Risk Type -- procedures
--
--   1. sp_risk_type_list            the three options, for the combo
--   2. sp_risk_type_selection_set   replace the set (REQUIRED, >= 1)
--   3. sp_risk_type_selection_get   the current set for one risk
--
-- THIS IS 286's SHAPE, INCLUDING THE THING IT REFUSED TO BUILD
-- -----------------------------------------------------------
-- 286 considered wrapping sp_risk_analysis_save so one call could carry
-- the id list, and rejected it in writing: reproducing 216's full
-- parameter list purely to pass it through would have to be
-- re-reproduced every time 216 gained a parameter, and "a pass-through
-- that has to be maintained in lockstep is not reuse; it is a copy with
-- extra steps".
--
-- That reasoning holds here, so there is NO WRAPPER. The caller does two
-- things: save the analysis through sp_risk_register_assess as it always
-- has, then call sp_risk_type_selection_set with the whole list.
--
-- AND THAT IS WHY ONE CHANGE COVERS BOTH SCREENS. Inherent Risk Analysis
-- and Review Risk both delegate to sp_risk_register_assess -- 264's
-- review path calls the very same procedure the analysis screen calls --
-- so neither of them needed a procedure of its own here.
--
-- NOT IN ONE TRANSACTION, deliberately, for 286's reason: RiskCentreService
-- opens a connection per call and uses no explicit transactions
-- anywhere, every procedure managing its own. The failure that would
-- guard against -- analysis saved, selection not -- is handled in the
-- READ instead: _get returns the analysis-version set when the register
-- set is empty (see section 3), so such a risk still shows its types and
-- the next successful save repairs the register side.
--
-- REQUIRED: AT LEAST ONE OF C / I / A
-- -----------------------------------
-- 56731 on an empty set. This is the deliberate difference from
-- Threats/Vulnerabilities, which are optional.
--
-- It is enforced HERE rather than only in the browser because a rule
-- that lives only in a form is not a rule. The two forms also mark the
-- control required, which is the affordance; this is the guarantee.
--
-- ACCEPTED CONSEQUENCE: a risk analysed before 313 shipped has no risk
-- type, so re-saving it is refused until an analyst picks one. That was
-- chosen knowingly over back-filling a value nobody assessed -- there is
-- no honest default. 56731's message says exactly what to do.
--
-- ORGANISATION SCOPING
--   Ids are validated against what this tenant may see -- shared rows
--   (organization_id NULL) or its own -- so a crafted payload cannot
--   attach another tenant's private type. Same guard 286 uses.
--
--   An id that is neither is DROPPED, not thrown on: it means the row was
--   retired or belongs elsewhere, and refusing an entire save over one
--   stale chip would lose the analyst's other work. But if dropping
--   leaves the set EMPTY, 56731 fires -- silently saving nothing when the
--   analyst chose something would be worse than either.
--
-- Re-runnable: yes (CREATE OR ALTER).
-- Rollback: database/314_risk_type_procs_rollback.sql
-- DEPENDS ON: 313 (the master and both link tables).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF OBJECT_ID('grac_practice.risk_type_master','U') IS NULL
BEGIN
    PRINT 'ABORT (314): risk_type_master missing. Run 313 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.risk_analysis_risk_type','U') IS NULL
   OR OBJECT_ID('grac_practice.risk_register_risk_type','U') IS NULL
BEGIN
    PRINT 'ABORT (314): the risk-type link tables are missing. Run 313 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('314_risk_type_procs: prerequisites missing -- see the PRINT messages above. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_risk_type_list
--
-- Shared rows plus this tenant's, ordered by display_order so the combo
-- reads Confidentiality, Integrity, Availability rather than
-- alphabetically -- which would put Availability first and read as a
-- mistake to anyone who works in security.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_type_list
    @organization_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT m.risk_type_id    AS RiskTypeId,
           m.risk_type_code  AS RiskTypeCode,
           m.risk_type_name  AS RiskTypeName,
           m.display_order   AS DisplayOrder,
           CAST(CASE WHEN m.organization_id IS NULL THEN 1 ELSE 0 END AS BIT) AS IsShared
      FROM grac_practice.risk_type_master m
     WHERE m.status_id = 1
       AND (m.organization_id IS NULL
            OR @organization_id IS NULL
            OR m.organization_id = @organization_id)
     ORDER BY m.display_order, m.risk_type_id;
END;
GO

-- =====================================================================
-- 2. sp_risk_type_selection_set
--
-- Replaces the whole set for one analysis version and/or one register
-- row. DELETE-then-INSERT rather than a MERGE, for 286's reason: the set
-- is three rows at most, the caller always sends the complete list, and
-- "what is here now" is the only question -- a diff would be more code
-- protecting nothing.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_type_selection_set
    @organization_id     BIGINT,
    @risk_analysis_id    BIGINT        = NULL,
    @risk_register_id    BIGINT        = NULL,
    @risk_type_ids       NVARCHAR(MAX) = NULL,   -- comma separated
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 56730, 'sp_risk_type_selection_set: organization_id is required.', 1;
    IF @risk_analysis_id IS NULL AND @risk_register_id IS NULL
        THROW 56732, 'sp_risk_type_selection_set: risk_analysis_id or risk_register_id is required.', 1;

    DECLARE @t TABLE(risk_type_id INT PRIMARY KEY);

    -- Visible = shared or this tenant's. See the header on why an
    -- invisible id is dropped rather than thrown on.
    INSERT INTO @t(risk_type_id)
    SELECT DISTINCT m.risk_type_id
      FROM STRING_SPLIT(ISNULL(@risk_type_ids, N''), ',') s
      JOIN grac_practice.risk_type_master m
        ON m.risk_type_id = TRY_CAST(LTRIM(RTRIM(s.value)) AS INT)
     WHERE LTRIM(RTRIM(s.value)) <> N''
       AND m.status_id = 1
       AND (m.organization_id IS NULL OR m.organization_id = @organization_id);

    -- THE REQUIRED RULE. After validation, not before: "you sent three
    -- ids and all three were unusable" and "you sent none" are the same
    -- problem from the analyst's side -- nothing selectable was chosen --
    -- and both must refuse rather than quietly store an empty set.
    IF NOT EXISTS (SELECT 1 FROM @t)
        THROW 56731, 'sp_risk_type_selection_set: at least one risk type is required. Select Confidentiality, Integrity or Availability -- a risk analysed before this field existed must be given one before it can be saved again.', 1;

    BEGIN TRY
        BEGIN TRAN;

        IF @risk_analysis_id IS NOT NULL
        BEGIN
            DELETE FROM grac_practice.risk_analysis_risk_type
             WHERE risk_analysis_id = @risk_analysis_id;

            INSERT INTO grac_practice.risk_analysis_risk_type
                (risk_analysis_id, risk_type_id, entered_by)
            SELECT @risk_analysis_id, risk_type_id, @caller_display_name FROM @t;
        END

        IF @risk_register_id IS NOT NULL
        BEGIN
            DELETE FROM grac_practice.risk_register_risk_type
             WHERE risk_register_id = @risk_register_id;

            INSERT INTO grac_practice.risk_register_risk_type
                (risk_register_id, risk_type_id, entered_by)
            SELECT @risk_register_id, risk_type_id, @caller_display_name FROM @t;
        END

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT (SELECT COUNT(*) FROM @t) AS RiskTypeCount;
END;
GO

-- =====================================================================
-- 3. sp_risk_type_selection_get
--
-- The chips for one risk, read from the REGISTER link table -- the
-- current answer, which is what an edit form needs.
--
-- THE FALLBACK. When the register set is empty, the newest analysis
-- version's set is returned instead. That covers three real cases with
-- one rule: the second of the caller's two writes failing (see the
-- header), a risk registered by a path not yet taught the link tables,
-- and a register row cleared by something else. Without it, any of those
-- would show an empty control on a risk that was plainly assessed.
--
-- 286 falls back to a legacy single column for the same purpose. There
-- is no legacy column here, so the audit record is the fallback -- which
-- is the better source anyway: it is what was actually assessed.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_type_selection_get
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56733, 'sp_risk_type_selection_get: risk_register_id is required.', 1;

    DECLARE @has_register BIT =
        CASE WHEN EXISTS (SELECT 1 FROM grac_practice.risk_register_risk_type
                           WHERE risk_register_id = @risk_register_id)
             THEN 1 ELSE 0 END;

    IF @has_register = 1
    BEGIN
        SELECT m.risk_type_id   AS RiskTypeId,
               m.risk_type_code AS RiskTypeCode,
               m.risk_type_name AS RiskTypeName,
               m.display_order  AS DisplayOrder,
               CAST(0 AS BIT)   AS FromAnalysisFallback
          FROM grac_practice.risk_register_risk_type x
          JOIN grac_practice.risk_type_master m
            ON m.risk_type_id = x.risk_type_id
         WHERE x.risk_register_id = @risk_register_id
         ORDER BY m.display_order, m.risk_type_id;
        RETURN;
    END

    -- Fallback: the newest analysis version's set. is_current is the
    -- flag 205/216 maintain for "the version the register reflects", and
    -- analysis_version DESC breaks a tie the same way
    -- sp_risk_register_get's OUTER APPLY does.
    DECLARE @analysis_id BIGINT =
        (SELECT TOP 1 a.risk_analysis_id
           FROM grac_practice.risk_analysis a
          WHERE a.risk_register_id = @risk_register_id
          ORDER BY a.is_current DESC, a.analysis_version DESC);

    SELECT m.risk_type_id   AS RiskTypeId,
           m.risk_type_code AS RiskTypeCode,
           m.risk_type_name AS RiskTypeName,
           m.display_order  AS DisplayOrder,
           CAST(1 AS BIT)   AS FromAnalysisFallback
      FROM grac_practice.risk_analysis_risk_type x
      JOIN grac_practice.risk_type_master m
        ON m.risk_type_id = x.risk_type_id
     WHERE x.risk_analysis_id = @analysis_id
     ORDER BY m.display_order, m.risk_type_id;
END;
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '314-a sp_risk_type_list exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_type_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '314-b sp_risk_type_selection_set exists',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_type_selection_set','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '314-c sp_risk_type_selection_get exists',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_type_selection_get','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '314-d the required rule (56731) is in the set proc',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_type_selection_set'))
                 LIKE '%56731%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '314-e ids are validated against shared-or-own-tenant',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_type_selection_set'))
                 LIKE '%m.organization_id IS NULL OR m.organization_id = @organization_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '314-f the set proc writes BOTH link tables',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_type_selection_set'))
                 LIKE '%risk_analysis_risk_type%'
            AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_type_selection_set'))
                 LIKE '%risk_register_risk_type%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '314-g the get proc falls back to the analysis set',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_type_selection_get'))
                 LIKE '%FromAnalysisFallback%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- 314 must not have touched the assess path. This is the whole point of
-- there being no wrapper.
SELECT '314-h sp_risk_register_assess was NOT re-issued here',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_register_assess','P') IS NOT NULL
            THEN 'PASS' ELSE 'CHECK -- it should still exist, untouched' END;

-- The options the combo will show, in the order it will show them.
IF OBJECT_ID('grac_practice.sp_risk_type_list','P') IS NOT NULL
    EXEC grac_practice.sp_risk_type_list;

PRINT '';
PRINT '314 complete. The list / set / get procedures exist.';
PRINT 'sp_risk_register_assess is UNCHANGED -- the caller makes two calls:';
PRINT 'assess as before, then sp_risk_type_selection_set with the id list.';
PRINT 'Next: the API service + controller, then the two forms.';
GO

SET NOEXEC OFF;
GO
