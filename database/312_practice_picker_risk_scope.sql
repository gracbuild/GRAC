-- =====================================================================
-- 312 Practice Picker -- exclude by ORGANISATION **and** RISK, in SQL
--
-- THE COMPLAINT
--   "Map Practice shows 1 already selected for a practice I never used
--    against this risk. The check should be by organization id and risk
--    id -- is it?"
--
-- WHAT IT WAS
--   Half in SQL, half in the browser, and the SQL half did not know
--   about risks at all:
--
--     sp_practice_picker_practices  filtered by @organization_id, and
--                                   excluded only the id LIST a caller
--                                   handed it in @exclude_practice_ids
--     the browser                   built that list from
--                                   GET /register/{id}/mapping
--
--   Both halves were per-risk in effect, but NOTHING in the database
--   ever compared a practice against a risk -- so the question "is the
--   exclusion scoped to this risk?" could only be answered by reading
--   JavaScript, and the answer changed with whatever the page happened
--   to have in memory. A stale exclusion list, a picker instance reused
--   across two risks, a mount whose /mapping had not returned yet: each
--   of those produces a wrong exclusion that no query would show.
--
--   Worse, the API's @exclude_practice_ids parameter was never actually
--   sent by the picker (the URL it builds has no such argument), so the
--   only enforcement was a client-side .filter().
--
-- WHAT IT IS NOW
--   The procedure takes @risk_register_id and does the exclusion itself:
--
--     NOT EXISTS (SELECT 1 FROM risk_practice_map pm
--                  WHERE pm.organization_id  = @organization_id
--                    AND pm.risk_register_id = @risk_register_id
--                    AND pm.practice_id      = p.practice_id)
--
--   Organisation AND risk, both named, in one place, verifiable with a
--   query. @exclude_practice_ids still works and still applies on top --
--   other callers pass it and the Risk Centre still sends its list as a
--   belt-and-braces second filter.
--
--   @risk_register_id NULL means "no risk in play" and excludes nothing,
--   which is every non-Risk-Centre caller's behaviour today, unchanged.
--
-- AND IT NOW SAYS WHY, PER ROW
--   AlreadyMappedToRisk (BIT) comes back on every row: 1 when this risk
--   already has that practice. @include_already_mapped = 1 returns those
--   rows instead of dropping them, so the UI can show the practice
--   greyed out with the reason rather than an empty dropdown reading
--   "1 already used" -- which is the message that caused this report.
--
--   The default is 0, so any existing caller sees exactly what it saw.
--
-- WHY THE PRACTICE WAS PROBABLY THERE
--   sp_risk_mapping_sync_primary (262/266) derives a Primary
--   risk_practice_map row from risk_register.linked_practice_id on the
--   first /mapping read. A risk raised FROM a practice therefore owns
--   that practice in its scope without anyone mapping it by hand -- so
--   "a practice I never used against this risk" can genuinely be on the
--   risk. With AlreadyMappedToRisk the UI can now say so instead of
--   leaving the reader to guess.
--
-- ADDITIVE: two new parameters with defaults, one new output column.
-- No table, no data, no other procedure.
--
-- ASCII-only on purpose (sqlcmd codepage safety).
-- Re-runnable: yes (CREATE OR ALTER).
-- DEPENDS ON: 282 (this procedure), 261 (risk_practice_map).
-- Rollback:   database/312_practice_picker_risk_scope_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF OBJECT_ID('grac_practice.sp_practice_picker_practices','P') IS NULL
BEGIN
    PRINT 'ABORT (312): sp_practice_picker_practices missing. Run 282 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.risk_practice_map','U') IS NULL
BEGIN
    PRINT 'ABORT (312): risk_practice_map missing. Run 261 first.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.risk_practice_map','organization_id') IS NULL
   OR COL_LENGTH('grac_practice.risk_practice_map','risk_register_id') IS NULL
   OR COL_LENGTH('grac_practice.risk_practice_map','practice_id') IS NULL
BEGIN
    PRINT 'ABORT (312): risk_practice_map is missing one of the three columns';
    PRINT '             this exclusion is keyed on. Run 261 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('312_practice_picker_risk_scope: prerequisites missing -- see the PRINT messages above. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_practice_picker_practices
    @organization_id         BIGINT,
    @organization_control_id BIGINT,
    @search                  NVARCHAR(200) = NULL,
    @exclude_practice_ids    NVARCHAR(MAX) = NULL,
    -- NEW in 312. The risk whose scope decides what is already taken.
    -- NULL = no risk in play; nothing is excluded on that basis, which
    -- is every pre-312 caller's behaviour.
    @risk_register_id        BIGINT        = NULL,
    -- NEW in 312. 0 (the default, and the pre-312 behaviour) drops the
    -- practices this risk already has. 1 returns them with
    -- AlreadyMappedToRisk = 1 so the UI can show them disabled and say
    -- why, instead of presenting an empty list.
    @include_already_mapped  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @organization_control_id IS NULL
        THROW 57004, 'sp_practice_picker_practices: organization_id and organization_control_id are required.', 1;

    DECLARE @excluded TABLE(practice_id BIGINT PRIMARY KEY);
    IF @exclude_practice_ids IS NOT NULL AND LEN(LTRIM(RTRIM(@exclude_practice_ids))) > 0
        INSERT INTO @excluded(practice_id)
        SELECT DISTINCT TRY_CONVERT(BIGINT, LTRIM(RTRIM(value)))
        FROM   STRING_SPLIT(@exclude_practice_ids, ',')
        WHERE  TRY_CONVERT(BIGINT, LTRIM(RTRIM(value))) IS NOT NULL;

    SELECT p.practice_id                        AS PracticeId,
           p.practice_code                      AS PracticeCode,
           p.practice_name                      AS PracticeName,
           p.applicability_status               AS ApplicabilityStatus,
           q.organization_requirement_id        AS OrganizationRequirementId,
           oc.organization_control_id           AS OrganizationControlId,
           oc.control_code                      AS ControlCode,
           -- ORGANISATION **AND** RISK. Both named, in one expression,
           -- so "what is this scoped to" is answerable by reading it.
           -- risk_practice_map is UNIQUE(risk_register_id, practice_id),
           -- so this can match at most one row.
           CAST(CASE WHEN @risk_register_id IS NOT NULL
                      AND EXISTS (SELECT 1
                                    FROM grac_practice.risk_practice_map pm
                                   WHERE pm.organization_id  = @organization_id
                                     AND pm.risk_register_id = @risk_register_id
                                     AND pm.practice_id      = p.practice_id)
                     THEN 1 ELSE 0 END AS BIT) AS AlreadyMappedToRisk,
           -- Which is it: mapped by a person, or derived from the risk's
           -- own linked_practice_id by sp_risk_mapping_sync_primary? The
           -- second is the case that reads as a phantom exclusion, so
           -- the UI is given the means to say so.
           (SELECT TOP 1 pm2.map_source_code
              FROM grac_practice.risk_practice_map pm2
             WHERE pm2.organization_id  = @organization_id
               AND pm2.risk_register_id = @risk_register_id
               AND pm2.practice_id      = p.practice_id) AS MapSourceCode
    FROM   grac_practice.organization_control_requirement ocr
    JOIN   grac_practice.organization_control oc
           ON oc.organization_control_id = ocr.organization_control_id
          AND oc.organization_id = @organization_id
          AND oc.status = N'Active'
    JOIN   grac_practice.organization_requirement q
           ON q.organization_requirement_id = ocr.organization_requirement_id
          AND q.status = N'Active'
    JOIN   grac_practice.practice p
           ON p.organization_requirement_id = q.organization_requirement_id
          AND p.organization_id = @organization_id
          AND p.status = N'Active'
    WHERE  ocr.organization_control_id = @organization_control_id
      AND  ocr.status = N'Active'
      AND  NOT EXISTS (SELECT 1 FROM @excluded x WHERE x.practice_id = p.practice_id)
      -- The risk-scoped exclusion. Skipped entirely when no risk was
      -- named, and skipped when the caller asked for the already-mapped
      -- rows so it can render them disabled.
      AND  (@risk_register_id IS NULL
            OR @include_already_mapped = 1
            OR NOT EXISTS (SELECT 1
                             FROM grac_practice.risk_practice_map pm
                            WHERE pm.organization_id  = @organization_id
                              AND pm.risk_register_id = @risk_register_id
                              AND pm.practice_id      = p.practice_id))
      AND  (@search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
            OR p.practice_name LIKE N'%' + @search + N'%'
            OR p.practice_code LIKE N'%' + @search + N'%')
    ORDER BY p.practice_code, p.practice_name;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '312-a takes @risk_register_id' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_practice_picker_practices')
                            AND name = '@risk_register_id')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '312-b takes @include_already_mapped',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_practice_picker_practices')
                            AND name = '@include_already_mapped')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '312-c the exclusion names organization_id AND risk_register_id',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))
                 LIKE '%pm.organization_id  = @organization_id%'
            AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))
                 LIKE '%pm.risk_register_id = @risk_register_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '312-d returns AlreadyMappedToRisk',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))
                 LIKE '%AS AlreadyMappedToRisk%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '312-e @exclude_practice_ids still honoured (282 behaviour)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))
                 LIKE '%FROM @excluded x WHERE x.practice_id = p.practice_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '312-f still a read-only procedure',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))
                 NOT LIKE '%UPDATE grac_practice%'
            AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))
                 NOT LIKE '%INSERT INTO grac_practice%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '312 complete. The picker exclusion is now decided in SQL on';
PRINT 'organization_id AND risk_register_id, and every row says whether';
PRINT 'THIS risk already has it. Next: rebuild the API and Web tiers.';
GO

SET NOEXEC OFF;
GO
