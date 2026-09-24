-- =====================================================================
-- 354 Risk register resolves its own linked practice
--
-- BUG: A Risk auto-created from a Practice Instance's "Not Implemented"
--      obligation -- Gap -> business_risk_present='Y' -> candidate ->
--      "Register as Risk" -- used to show the originating practice in
--      Risk Analysis's "Existing Practice Map" panel. It no longer
--      does, for risks registered since.
--
-- CAUSE, and it is 261's, exactly as 261's own header already admitted:
--
--     "risk_register.linked_practice_id has existed since 205 and has
--      never been written: the Risk Centre UI does not send it, and no
--      procedure derives it."
--
--   261 only ran a ONE-TIME backfill for rows that existed on 2-Sep.
--   It explicitly deferred a live mechanism ("the picker"), which was
--   never built for Risk. Every risk registered after 261 ran -- i.e.
--   every gap-driven risk from that day to this one -- carries a NULL
--   linked_practice_id, so sp_risk_mapping_sync_primary (266) takes its
--   "@practice_id IS NULL" branch on every /mapping read and the panel
--   renders no practice at all.
--
--   Exception Centre hit the identical bug and got the full fix in
--   258: backfill + create-time derivation + read-time fallback. Risk
--   never got the second or third part. This migration gives Risk the
--   same three-part treatment, reusing 261's own two-route join --
--   already proven correct against this data -- rather than inventing
--   a new one.
--
-- THE FIX
--   1. Backfill: 261's two-route join, re-run, catching every risk
--      registered between 261 and today that is still NULL. Guarded by
--      "linked_practice_id IS NULL", so nothing set by hand, by 261, or
--      by a later analysis is ever touched.
--
--   2. sp_risk_register_insert derives at CREATE time when the caller
--      does not supply @linked_practice_id and the risk's own source
--      is a Gap: source_record_id (the custom_gap_id, whichever route
--      supplied it -- see below) -> custom_gap.source_reference_id
--      (a practice_instance, when source_reference_type says so) ->
--      practice_instance.practice_id.
--
--      This is centralised in sp_risk_register_insert rather than in
--      sp_risk_candidate_register (which is what was floated when this
--      fix was proposed). sp_risk_register_insert is the true single
--      funnel every registration passes through -- sp_risk_candidate_
--      register (Route A, via a candidate) already forwards the
--      candidate's own source_record_id into it unchanged, and any
--      future direct/custom caller that names a Gap source on the
--      register itself (Route B, 206) would land here too. One place,
--      both routes, matching 258's "one place" reasoning even more
--      completely than 258's own proc choice did.
--
--   3. sp_risk_mapping_sync_primary derives-AND-PERSISTS at READ time
--      when the stored column is still NULL: it re-derives from the
--      risk's own source_type_code/source_record_id (261's Route B
--      join, since by this point there is no candidate to go through),
--      and if that resolves a practice, UPDATEs risk_register.
--      linked_practice_id before continuing -- so the very next /mapping
--      read, and every screen that displays "Linked practice", stops
--      needing to re-derive at all. This is what makes the fix retro-
--      active for the specific risk already reported broken: simply
--      opening its Existing Practice Map panel triggers the self-heal,
--      no fresh migration run required.
--
-- WHAT THIS DOES NOT DO
--   A Custom risk, or a Gap risk whose gap traces to something other
--   than a PracticeInstance (an OrgAssuranceGap, say), has no practice
--   instance behind it and stays NULL -- on all three parts. The panel
--   reports that honestly, exactly as 258 chose to for Exception
--   Centre, rather than guessing or widening to "any practice in the
--   organisation".
--
--   Nothing here changes risk_practice_map, sp_risk_practice_map, or
--   any Additional-mapping behaviour -- only how the Primary row's
--   source practice id (linked_practice_id) gets populated.
--
-- Re-runnable: yes (backfill is WHERE-guarded; both procedures are
--              CREATE OR ALTER).
-- Rollback:   database/354_risk_linked_practice_derivation_rollback.sql
--             (restores both procedures to their 216/266 bodies; does
--             not undo the backfill or any self-heal UPDATE already
--             persisted by part 3 -- see that file's header).
-- DEPENDS ON: 205 (linked_practice_id column), 207 (candidate source
--             wiring), 216 (sp_risk_register_insert, sp_risk_candidate_
--             register), 261 (the join this reuses), 266 (sp_risk_
--             mapping_sync_primary).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (354): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.risk_register','U') IS NULL
BEGIN PRINT 'ABORT (354): risk_register missing (run 205 first).'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.risk_register','linked_practice_id') IS NULL
BEGIN PRINT 'ABORT (354): risk_register.linked_practice_id missing (run 205 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_risk_register_insert','P') IS NULL
BEGIN PRINT 'ABORT (354): sp_risk_register_insert missing (run 216 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_risk_mapping_sync_primary','P') IS NULL
BEGIN PRINT 'ABORT (354): sp_risk_mapping_sync_primary missing (run 266 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
BEGIN PRINT 'ABORT (354): custom_gap missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_instance','U') IS NULL
BEGIN PRINT 'ABORT (354): practice_instance missing.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('354_risk_linked_practice_derivation: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Backfill -- 261's own two-route join, re-run defensively.
--
-- Only touches rows still NULL. Anything 261 already set, anything set
-- by hand, and anything a later analysis set is left exactly as it is.
-- =====================================================================

-- Route A: register -> candidate -> gap -> instance -> practice.
UPDATE r
   SET linked_practice_id = pi.practice_id,
       updated_by         = COALESCE(r.updated_by, N'migration-354'),
       updated_dt         = SYSUTCDATETIME()
  FROM grac_practice.risk_register r
  JOIN grac_practice.risk_candidate c ON c.risk_candidate_id = r.risk_candidate_id
  JOIN grac_practice.custom_gap g ON g.custom_gap_id = c.source_record_id
  JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = g.source_reference_id
 WHERE r.linked_practice_id IS NULL
   AND c.source_type_code       = N'Gap'
   AND g.source_reference_type  = N'PracticeInstance'
   AND g.source_reference_id    IS NOT NULL
   AND pi.practice_id           IS NOT NULL
   AND pi.organization_id       = r.organization_id;

PRINT CONCAT('354: backfilled linked_practice_id via candidate route on ', @@ROWCOUNT, ' risk(s).');

-- Route B: the register's own source columns (206), for risks that
-- never went through a candidate.
UPDATE r
   SET linked_practice_id = pi.practice_id,
       updated_by         = COALESCE(r.updated_by, N'migration-354'),
       updated_dt         = SYSUTCDATETIME()
  FROM grac_practice.risk_register r
  JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.source_record_id
  JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = g.source_reference_id
 WHERE r.linked_practice_id IS NULL
   AND r.source_type_code      = N'Gap'
   AND g.source_reference_type = N'PracticeInstance'
   AND g.source_reference_id   IS NOT NULL
   AND pi.practice_id          IS NOT NULL
   AND pi.organization_id      = r.organization_id;

PRINT CONCAT('354: backfilled linked_practice_id via direct-source route on ', @@ROWCOUNT, ' risk(s).');
GO

-- =====================================================================
-- 2. sp_risk_register_insert -- derive at CREATE time
--
-- 216's body, verbatim, with one added step immediately after the
-- assessment row is read (so @org_id and @source_record_id are both
-- already in hand) and before the mandatory-field gate. Everything
-- else -- every THROW, every column, the history row -- is unchanged.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_register_insert
    @risk_analysis_id     BIGINT,
    @risk_title           NVARCHAR(300),
    @source_type_code     NVARCHAR(40),
    @source_record_id     BIGINT        = NULL,
    @source_reference     NVARCHAR(200) = NULL,
    @source_description   NVARCHAR(MAX) = NULL,
    @source_centre_code   NVARCHAR(60)  = NULL,
    @risk_candidate_id    BIGINT        = NULL,
    @linked_asset_id      BIGINT        = NULL,
    @linked_vendor_id     BIGINT        = NULL,
    @linked_practice_id   BIGINT        = NULL,
    @linked_obligation_id BIGINT        = NULL,
    @linked_control_id    BIGINT        = NULL,
    @registered_by_employee_id BIGINT   = NULL,
    @caller_display_name  NVARCHAR(100) = N'system',
    @risk_register_id     BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @risk_register_id = NULL;

    IF @risk_analysis_id IS NULL
        THROW 56110, 'sp_risk_register_insert: risk_analysis_id is required — a risk cannot be registered without its assessment (BRD 24.1).', 1;
    IF @risk_title IS NULL OR LEN(LTRIM(RTRIM(@risk_title))) = 0
        THROW 56111, 'sp_risk_register_insert: risk_title is required.', 1;
    IF @source_type_code IS NULL OR LEN(LTRIM(RTRIM(@source_type_code))) = 0
        THROW 56112, 'sp_risk_register_insert: source_type_code is required — every registered risk shall have a defined source (BRD 24.7).', 1;

    DECLARE
        @org_id BIGINT, @scope NVARCHAR(20),
        @statement NVARCHAR(1000), @cat_code NVARCHAR(60), @cat_name NVARCHAR(200),
        @description NVARCHAR(MAX), @cause NVARCHAR(MAX),
        @consequence NVARCHAR(MAX), @controls NVARCHAR(MAX),
        @lk_code NVARCHAR(60), @lk_name NVARCHAR(200), @lk_value INT,
        @im_code NVARCHAR(60), @im_name NVARCHAR(200), @im_value INT,
        @rt_code NVARCHAR(30), @rt_name NVARCHAR(120), @rt_score INT,
        @owner_id BIGINT, @bu NVARCHAR(200), @proc_name NVARCHAR(200),
        @threat_id INT, @threat_name NVARCHAR(400), @threat_desc NVARCHAR(MAX),
        @vuln_id INT, @vuln_name NVARCHAR(400), @vuln_desc NVARCHAR(MAX),
        @bf_id BIGINT, @bf_name NVARCHAR(200),
        @already_registered BIGINT;

    SELECT @org_id      = organization_id,
           @scope       = analysis_scope_code,
           @statement   = risk_statement,
           @cat_code    = risk_category_code,
           @cat_name    = risk_category_name,
           @description = risk_description,
           @cause       = risk_cause,
           @consequence = potential_consequence,
           @controls    = existing_controls,
           @lk_code     = likelihood_code,
           @lk_name     = likelihood_name,
           @lk_value    = likelihood_value,
           @im_code     = impact_code,
           @im_name     = impact_name,
           @im_value    = impact_value,
           @rt_code     = inherent_rating_code,
           @rt_name     = inherent_rating_name,
           @rt_score    = inherent_rating_score,
           @owner_id    = risk_owner_employee_id,
           @bu          = business_unit,
           @proc_name   = process_name,
           @threat_id   = threat_id,
           @threat_name = threat_name,
           @threat_desc = threat_description,
           @vuln_id     = vulnerability_id,
           @vuln_name   = vulnerability_name,
           @vuln_desc   = vulnerability_description,
           @bf_id       = business_function_id,
           @bf_name     = business_function_name,
           @already_registered = risk_register_id
      FROM grac_practice.risk_analysis
     WHERE risk_analysis_id = @risk_analysis_id;

    IF @org_id IS NULL
        THROW 56113, 'sp_risk_register_insert: assessment not found.', 1;
    IF @already_registered IS NOT NULL
        THROW 56114, 'sp_risk_register_insert: this assessment has already been registered.', 1;

    -- 354: derive linked_practice_id when the caller did not name one
    -- and this risk's source is a Gap. source_record_id is the
    -- custom_gap_id whichever route supplied it -- sp_risk_candidate_
    -- register forwards the candidate's own source_record_id here
    -- unchanged (Route A), and a direct/custom caller that names a Gap
    -- source on the register itself lands here too (Route B, 206) --
    -- so one check covers both of 261's routes at once. Org-scoped,
    -- same as 261's backfill, so a gap and instance that happen to
    -- share an id under a different organisation can never match.
    IF @linked_practice_id IS NULL
       AND @source_type_code = N'Gap'
       AND @source_record_id IS NOT NULL
        SELECT @linked_practice_id = pi.practice_id
          FROM grac_practice.custom_gap g
          JOIN grac_practice.practice_instance pi
               ON pi.practice_instance_id = g.source_reference_id
         WHERE g.custom_gap_id        = @source_record_id
           AND g.source_reference_type = N'PracticeInstance'
           AND pi.organization_id      = @org_id;

    -- ---- The mandatory-field gate (the five stage-1 fields) ---------
    -- 56116 (category), 56117 (likelihood), 56118 (impact) and 56119
    -- (rating) are RETIRED by 216: those belong to stage 2 now. The
    -- numbers are not reused, so an old log line still means what it
    -- said.
    IF @statement IS NULL OR LEN(LTRIM(RTRIM(@statement))) = 0
        THROW 56115, 'sp_risk_register_insert: assessment is incomplete — risk statement is required.', 1;
    IF @threat_id IS NULL
        THROW 56410, 'sp_risk_register_insert: assessment is incomplete — a threat is required.', 1;
    IF @vuln_id IS NULL
        THROW 56411, 'sp_risk_register_insert: assessment is incomplete — a vulnerability is required.', 1;
    IF @owner_id IS NULL
        THROW 56120, 'sp_risk_register_insert: assessment is incomplete — risk owner is required.', 1;

    IF @source_type_code = N'Custom' AND @risk_candidate_id IS NOT NULL
        THROW 56121, 'sp_risk_register_insert: a Custom risk cannot carry a candidate (BRD 24.8).', 1;
    IF @source_type_code <> N'Custom' AND @scope = N'Custom'
        THROW 56122, 'sp_risk_register_insert: a custom-scoped assessment must register with source type Custom (BRD 24.8).', 1;

    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    INSERT INTO grac_practice.risk_register
        (organization_id,
         risk_title, risk_statement, risk_description,
         risk_category_code, risk_category_name,
         source_type_code, source_record_id, source_reference,
         source_description, source_centre_code,
         risk_candidate_id, risk_analysis_id,
         risk_owner_employee_id, business_unit, process_name,
         risk_cause, potential_consequence, existing_controls,
         likelihood_code, likelihood_name, likelihood_value,
         impact_code, impact_name, impact_value,
         inherent_rating_code, inherent_rating_name, inherent_rating_score,
         threat_id, threat_name, threat_description,
         vulnerability_id, vulnerability_name, vulnerability_description,
         business_function_id, business_function_name, analysis_pending,
         linked_asset_id, linked_vendor_id, linked_practice_id,
         linked_obligation_id, linked_control_id,
         status_code, registered_dt, registered_by_employee_id,
         record_status_id, entered_by, entered_dt)
    VALUES
        (@org_id,
         @risk_title, @statement, @description,
         @cat_code, @cat_name,
         @source_type_code, @source_record_id, @source_reference,
         @source_description, @source_centre_code,
         @risk_candidate_id, @risk_analysis_id,
         @owner_id, @bu, @proc_name,
         @cause, @consequence, @controls,
         @lk_code, @lk_name, @lk_value,
         @im_code, @im_name, @im_value,
         @rt_code, @rt_name, @rt_score,
         @threat_id, @threat_name, @threat_desc,
         @vuln_id, @vuln_name, @vuln_desc,
         @bf_id, @bf_name,
         CASE WHEN @rt_code IS NULL THEN 1 ELSE 0 END,
         @linked_asset_id, @linked_vendor_id, @linked_practice_id,
         @linked_obligation_id, @linked_control_id,
         N'Active', SYSUTCDATETIME(), @registered_by_employee_id,
         @active_rs, @caller_display_name, SYSUTCDATETIME());

    SET @risk_register_id = SCOPE_IDENTITY();

    UPDATE grac_practice.risk_analysis
       SET risk_register_id = @risk_register_id,
           decision_code    = N'Register',
           decision_dt      = COALESCE(decision_dt, SYSUTCDATETIME()),
           decision_by_employee_id = COALESCE(decision_by_employee_id, @registered_by_employee_id),
           updated_by       = @caller_display_name,
           updated_dt       = SYSUTCDATETIME()
     WHERE risk_analysis_id = @risk_analysis_id;

    INSERT INTO grac_practice.risk_register_history
        (risk_register_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@risk_register_id, N'Register', NULL, N'Active',
         CONCAT(N'Registered from ', @source_type_code,
                CASE WHEN @source_reference IS NULL THEN N''
                     ELSE CONCAT(N' ', @source_reference) END,
                N'; assessment #', CAST(@risk_analysis_id AS NVARCHAR(20)),
                CASE WHEN @rt_code IS NULL
                     THEN N'; rating pending analysis'
                     ELSE CONCAT(N'; inherent rating ', @rt_code) END),
         @registered_by_employee_id, @caller_display_name,
         @caller_display_name, SYSUTCDATETIME());
END;
GO
PRINT '354: sp_risk_register_insert derives linked_practice_id for Gap-sourced risks.';
GO

-- =====================================================================
-- 3. sp_risk_mapping_sync_primary -- derive AND PERSIST at READ time
--
-- 266's body, verbatim, with one added step: when the stored column is
-- still NULL, try to derive it from the risk's own source columns
-- (261's Route B join -- by the time a risk is this old there is no
-- longer a live candidate row to go through, so the register's own
-- source_type_code/source_record_id is what is left), and if that
-- resolves a practice, UPDATE risk_register before carrying on with
-- the normal flow below. A screen that depends on a denormalised
-- column should not go blank the moment that column is missing --
-- and self-healing here means the very next /mapping call for a
-- given risk is the last one that will ever need to re-derive it.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_mapping_sync_primary
    @risk_register_id    BIGINT,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56660, 'sp_risk_mapping_sync_primary: risk_register_id is required.', 1;

    DECLARE @org_id BIGINT, @practice_id BIGINT,
            @src_type NVARCHAR(40), @src_id BIGINT;
    SELECT @org_id      = organization_id,
           @practice_id = linked_practice_id,
           @src_type    = source_type_code,
           @src_id      = source_record_id
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56661, 'sp_risk_mapping_sync_primary: risk not found.', 1;

    -- 354: the column is still NULL -- try to derive it, same join as
    -- the create-time step, and persist it so this is the last time
    -- this particular risk needs to take this branch.
    IF @practice_id IS NULL
       AND @src_type = N'Gap'
       AND @src_id IS NOT NULL
    BEGIN
        SELECT @practice_id = pi.practice_id
          FROM grac_practice.custom_gap g
          JOIN grac_practice.practice_instance pi
               ON pi.practice_instance_id = g.source_reference_id
         WHERE g.custom_gap_id        = @src_id
           AND g.source_reference_type = N'PracticeInstance'
           AND pi.organization_id      = @org_id;

        IF @practice_id IS NOT NULL
            UPDATE grac_practice.risk_register
               SET linked_practice_id = @practice_id,
                   updated_by         = @caller_display_name,
                   updated_dt         = SYSUTCDATETIME()
             WHERE risk_register_id = @risk_register_id
               AND linked_practice_id IS NULL;
    END

    IF @practice_id IS NULL
    BEGIN
        SELECT CAST(0 AS BIT) AS Created, CAST(NULL AS BIGINT) AS PracticeId;
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM grac_practice.risk_practice_map
                WHERE risk_register_id = @risk_register_id
                  AND practice_id      = @practice_id
                  AND map_source_code  = N'Primary')
    BEGIN
        SELECT CAST(0 AS BIT) AS Created, @practice_id AS PracticeId;
        RETURN;
    END

    UPDATE grac_practice.risk_practice_map
       SET map_source_code = N'Additional',
           updated_by      = @caller_display_name,
           updated_dt      = SYSUTCDATETIME()
     WHERE risk_register_id = @risk_register_id
       AND map_source_code  = N'Primary'
       AND practice_id     <> @practice_id;

    IF EXISTS (SELECT 1 FROM grac_practice.risk_practice_map
                WHERE risk_register_id = @risk_register_id
                  AND practice_id      = @practice_id)
    BEGIN
        UPDATE grac_practice.risk_practice_map
           SET map_source_code = N'Primary',
               updated_by      = @caller_display_name,
               updated_dt      = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id
           AND practice_id      = @practice_id;

        SELECT CAST(0 AS BIT) AS Created, @practice_id AS PracticeId;
        RETURN;
    END

    EXEC grac_practice.sp_risk_practice_map
         @risk_register_id    = @risk_register_id,
         @practice_id         = @practice_id,
         @map_source_code     = N'Primary',
         @actor_employee_id   = @actor_employee_id,
         @caller_display_name = @caller_display_name;
END;
GO
PRINT '354: sp_risk_mapping_sync_primary self-heals linked_practice_id on read.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 354 verification ===';

DECLARE @ri NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_insert','P'));
DECLARE @mp NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_mapping_sync_primary','P'));

SELECT '354-a sp_risk_register_insert derives from a Gap source' AS Check_,
       CASE WHEN @ri LIKE '%source_reference_type = N''PracticeInstance''%'
             AND @ri LIKE '%@source_type_code = N''Gap''%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '354-b sp_risk_register_insert still gates the five stage-1 fields',
       CASE WHEN @ri LIKE '%56115%' AND @ri LIKE '%56410%' AND @ri LIKE '%56411%' AND @ri LIKE '%56120%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '354-c sp_risk_mapping_sync_primary derives and persists on read',
       CASE WHEN @mp LIKE '%@practice_id IS NULL%@src_type = N''Gap''%'
             AND @mp LIKE '%UPDATE grac_practice.risk_register%SET linked_practice_id = @practice_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '354-d sp_risk_mapping_sync_primary still creates the Primary map row',
       CASE WHEN @mp LIKE '%EXEC grac_practice.sp_risk_practice_map%' THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- How many Gap-sourced risks can now name a practice? ---';

SELECT
    COUNT_BIG(*)                                                    AS TotalGapSourcedRisks,
    SUM(CASE WHEN linked_practice_id IS NOT NULL THEN 1 ELSE 0 END) AS WithPractice,
    SUM(CASE WHEN linked_practice_id IS NULL     THEN 1 ELSE 0 END) AS WithoutPractice
  FROM grac_practice.risk_register
 WHERE source_type_code = N'Gap';

PRINT '';
PRINT 'Rows still without a practice are normally sourced from something';
PRINT 'other than a PracticeInstance gap (e.g. an OrgAssuranceGap) -- there';
PRINT 'is no practice instance behind them to derive one from, same as 258';
PRINT 'chose for Exception Centre:';

SELECT g.source_reference_type AS GapSourceReferenceType,
       COUNT_BIG(*)            AS RisksWithoutPractice
  FROM grac_practice.risk_register r
  LEFT JOIN grac_practice.custom_gap g ON g.custom_gap_id = r.source_record_id
 WHERE r.source_type_code = N'Gap'
   AND r.linked_practice_id IS NULL
 GROUP BY g.source_reference_type;

PRINT '';
PRINT '354 complete. A Gap-sourced risk''s Existing Practice Map panel now';
PRINT 'resolves the originating practice on the very next read even if the';
PRINT 'backfill above missed it for some reason, and every future Register';
PRINT 'as Risk from a practice-instance gap carries it from the moment it';
PRINT 'is created. No C#/JS change and no rebuild are required -- this is';
PRINT 'entirely inside sp_risk_register_insert and sp_risk_mapping_sync_';
PRINT 'primary, both of which are already called on every registration and';
PRINT 'every /mapping read respectively.';
GO

SET NOEXEC OFF;
GO
