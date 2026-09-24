-- =====================================================================
-- 320 Gap Center -- Owner and Raised On (opened_dt) were silently
-- blank on both gap-creation paths.
--
-- REPORTED
-- --------
-- "context and duedate remove cheyyanam" (handled in gaps.cshtml, no
-- SQL change needed) "-- PINNE RAISED ON NNU PARANJA COLUMN AND OWNER
-- lu ipo data varunnilla. automtic anenkil practice owner ku
-- automatic assign cheyyanam. custom lu owner selection undu. pakshe
-- list lu date kanikunnilla. raised on Also" -- i.e. Owner and Raised
-- On show no data; for automatic (Implementation) gaps the owner
-- should auto-assign from the practice; Custom gaps do have an owner
-- picker, but the list still shows no date for them either.
--
-- ROOT CAUSE -- two different procs, two different gaps
-- -------------------------------------------------------
-- 1) sp_custom_gap_materialize_for_instance (160) -- creates the
--    custom_gap row behind an AUTOMATIC (Implementation) gap the
--    first time it enters the lifecycle. Its INSERT has never set
--    owner_employee_id, owner_display_name, or opened_dt -- all three
--    are NULL on every one of these rows, full stop.
--
-- 2) sp_custom_gap_open (latest live body: 250) -- this is what the
--    Gap Center "Add Gap" dialog actually calls for a CUSTOM gap
--    (CustomGapController's plain POST / -> CustomGapService.OpenAsync
--    -> sp_custom_gap_open; NOT sp_custom_gap_save/POST .../save,
--    which is the *edit*/unified-upsert path used elsewhere). 250's
--    INSERT takes @owner_employee_id from the dialog's owner picker
--    but never resolves owner_display_name from it, and never sets
--    opened_dt at all -- so every Custom gap opened through the
--    dialog was born with Owner blank and Raised On blank, even
--    though an owner was selected. (sp_custom_gap_save, re-issued in
--    116b, gets both of these right -- but it is not on the create
--    path the dialog uses, which is why reading that proc alone did
--    not explain the report.)
--
-- FIX
-- ---
-- A) 160: pull the practice instance's owner (primary_owner_id /
--    primary_owner, the same pair 287/290 already resolve against
--    organization_employee for Resolve) alongside the title/
--    description lookup already there, and add owner_employee_id,
--    owner_display_name, opened_dt to the INSERT. This is the
--    "practice owner auto-assign" the user asked for on automatic
--    gaps.
-- B) 250: add the same owner-display-name hybrid resolver
--    sp_custom_gap_save already has (organization_employee lookup
--    when an employee id is supplied but no display name), and add
--    opened_dt to the INSERT.
-- C) One-time, idempotent backfill for rows already sitting on the
--    table with the gap wide open:
--      - opened_dt = entered_dt where opened_dt IS NULL (mirrors
--        109's own backfill, which only ever covered rows that
--        existed when 109 ran -- these are the ones created after,
--        by a proc that didn't set it).
--      - owner_display_name resolved from organization_employee where
--        owner_employee_id is set but the display name is not.
--      - for automatic gaps specifically (gap_source_module_code =
--        'Implementation' AND source_reference_type =
--        'PracticeInstance'), owner_employee_id / owner_display_name
--        pulled from the linked practice_instance where still NULL.
--    Every backfill is guarded to only touch rows that are still
--    missing the value -- never overwrites an owner or date someone
--    (or a proc) already set.
--
-- 160.sql and 250.sql are left exactly as they were, per this
-- project's append-only-migration-history convention -- this
-- migration re-issues both procs with CREATE OR ALTER instead.
--
-- ERROR CODE RANGE: reuses 160's 55170-55179 and 250's -- no new
-- THROWs added here.
--
-- Depends on 054, 109, 116b, 139 (practice_instance.primary_owner_id),
-- 156/158 (gap_lifecycle_state_master), 160, 250, 287 (established the
-- organization_employee owner-resolution join pattern this reuses).
-- Rollback: 320_gap_owner_and_opened_dt_autopopulate_rollback.sql.
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (320): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_instance','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee','U') IS NULL
BEGIN
    PRINT 'ABORT (320): custom_gap / practice_instance / organization_employee missing.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- A. sp_custom_gap_materialize_for_instance -- 160's body, re-emitted,
--    now carrying the practice instance's owner and an opened_dt onto
--    the materialized row.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_materialize_for_instance
    @practice_instance_id BIGINT,
    @organization_id      BIGINT,
    @caller_employee_id   BIGINT        = NULL,
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 55170, 'sp_custom_gap_materialize_for_instance: practice_instance_id is required.', 1;
    IF @organization_id IS NULL
        THROW 55171, 'sp_custom_gap_materialize_for_instance: organization_id is required.', 1;

    -- Idempotent lookup first. Match on the source-reference pair the
    -- 109 extension added -- that pair is the canonical "who raised
    -- this gap" pointer, independent of gap_source_module_code casing.
    DECLARE @existing_id BIGINT =
        (SELECT TOP 1 custom_gap_id
           FROM grac_practice.custom_gap
          WHERE source_reference_type = N'PracticeInstance'
            AND source_reference_id   = @practice_instance_id
            AND organization_id       = @organization_id
          ORDER BY custom_gap_id DESC);

    IF @existing_id IS NOT NULL
    BEGIN
        SELECT @existing_id AS CustomGapId, CAST(0 AS BIT) AS Created;
        RETURN;
    END

    -- Pull a sensible title and severity hint from the instance itself,
    -- plus -- 320 -- its owner. Same LEFT JOIN organization_employee
    -- pattern 287/290 already use to resolve a practice instance's
    -- owner display name (primary_owner_id first, primary_owner text
    -- snapshot as fallback for an instance whose owner has no
    -- organization_employee row).
    DECLARE @title NVARCHAR(250), @desc NVARCHAR(MAX), @impl_status NVARCHAR(60),
            @owner_employee_id BIGINT, @owner_display_name NVARCHAR(240);
    SELECT @title = LEFT(COALESCE(pi.instance_name, pi.instance_code, CONCAT(N'Practice Instance #', @practice_instance_id)), 250),
           @desc  = CONCAT(
                        N'Implementation gap materialized from Practice Instance ',
                        COALESCE(pi.instance_code, CAST(@practice_instance_id AS NVARCHAR(20))),
                        CASE WHEN pi.instance_name IS NOT NULL THEN N' -- ' + pi.instance_name ELSE N'' END,
                        N'.'),
           @impl_status        = pi.implementation_status,
           @owner_employee_id  = pi.primary_owner_id,
           @owner_display_name = COALESCE(owner_emp.employee_name, pi.primary_owner)
      FROM grac_practice.practice_instance pi
      LEFT JOIN grac_practice.organization_employee owner_emp
             ON owner_emp.employee_id = pi.primary_owner_id
     WHERE pi.practice_instance_id = @practice_instance_id
       AND pi.organization_id      = @organization_id;

    IF @title IS NULL
        THROW 55172, 'sp_custom_gap_materialize_for_instance: practice instance not found in this organization.', 1;

    DECLARE @new_state_id INT =
        (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'New');
    IF @new_state_id IS NULL
        THROW 55173, 'sp_custom_gap_materialize_for_instance: state master missing the New state (run 158 seed).', 1;

    DECLARE @active_rs_id INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    -- gap_source_module_code must be one of the values enforced by
    -- ck_pm_custom_gap_source_module (Implementation / Assurance /
    -- Custom / Exception / Risk / Audit). For a practice-instance
    -- derived gap the correct code is Implementation.
    DECLARE @new_id BIGINT = NULL;

    BEGIN TRY
        BEGIN TRAN;

        -- 320: owner_employee_id / owner_display_name (auto-assigned
        -- from the practice instance's owner) and opened_dt (this gap
        -- is "raised" the moment it is materialized) added to the
        -- column list. Every other column is unchanged from 160.
        INSERT INTO grac_practice.custom_gap
            (organization_id, gap_type_code, title, description,
             priority, status,
             owner_employee_id, owner_display_name,
             gap_source_module_code, source_reference_type, source_reference_id,
             lifecycle_state_id,
             opened_dt,
             entered_by, entered_dt)
        VALUES
            (@organization_id, N'Implementation', @title, @desc,
             N'Medium', N'Open',
             @owner_employee_id, @owner_display_name,
             N'Implementation', N'PracticeInstance', @practice_instance_id,
             @new_state_id,
             SYSUTCDATETIME(),
             @caller_display_name, SYSUTCDATETIME());

        SET @new_id = SCOPE_IDENTITY();

        -- History only if the parent insert succeeded (SCOPE_IDENTITY
        -- would be NULL otherwise -- and history.custom_gap_id is NOT NULL).
        IF @new_id IS NOT NULL AND OBJECT_ID('grac_practice.custom_gap_history','U') IS NOT NULL
        BEGIN
            INSERT INTO grac_practice.custom_gap_history
                (custom_gap_id, organization_id, action_code,
                 from_status_code, to_status_code, reason_text,
                 actor_display_name, entered_by, entered_dt)
            VALUES
                (@new_id, @organization_id, N'Materialize',
                 NULL, N'New',
                 CONCAT(N'Materialized from PracticeInstance #', @practice_instance_id,
                        CASE WHEN @impl_status IS NOT NULL THEN N' (impl_status=' + @impl_status + N')' ELSE N'' END),
                 @caller_display_name, @caller_display_name, SYSUTCDATETIME());
        END

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        -- Surface the underlying error to the caller so the UI can
        -- show what actually broke (CHECK constraint, missing column,
        -- FK violation, ...). No history row gets left behind.
        THROW;
    END CATCH

    SELECT @new_id AS CustomGapId, CAST(1 AS BIT) AS Created;
END
GO
PRINT '320: sp_custom_gap_materialize_for_instance auto-assigns owner and sets opened_dt.';
GO

-- =====================================================================
-- B. sp_custom_gap_open -- 250's body, re-emitted, now resolving
--    owner_display_name (same hybrid resolver 116b's sp_custom_gap_save
--    already has) and setting opened_dt. Every other parameter and
--    piece of logic (severity fallback, detection method, status
--    validation) is unchanged from 250.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_open
    @organization_id        BIGINT,
    @title                  NVARCHAR(250),
    @description            NVARCHAR(MAX) = NULL,
    @priority               NVARCHAR(30)  = N'Medium',
    @owner_employee_id      BIGINT        = NULL,
    @due_date               DATE          = NULL,
    @status                 NVARCHAR(30)  = N'Open',
    @remarks                NVARCHAR(1000) = NULL,
    @gap_type_code          NVARCHAR(60)  = N'Custom',
    @actor_employee_id      BIGINT        = NULL,
    -- Migration 250: captured at Add-Gap time. Optional; NULL means
    -- "no opinion" (existing behaviour: severity later gets derived).
    @severity_code          NVARCHAR(30)  = NULL,
    @severity_name          NVARCHAR(120) = NULL,
    @detection_method_code  NVARCHAR(60)  = NULL,
    @detection_method_name  NVARCHAR(200) = NULL,
    @custom_gap_id          BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @title IS NULL OR LTRIM(RTRIM(@title)) = N''
        THROW 54010, 'sp_custom_gap_open: organization_id and title are required.', 1;

    IF @priority NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @priority = N'Medium';

    IF @status NOT IN (N'Open', N'InProgress', N'Closed', N'Cancelled')
        SET @status = N'Open';

    -- Severity validated against the same four values every other
    -- write path uses. Blank / unknown falls back to priority so the
    -- gap still lands with some rank -- the same fallback 189's
    -- sp_custom_gap_apply_sla was using.
    IF @severity_code IS NOT NULL AND @severity_code NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @severity_code = NULL;
    IF @severity_code IS NULL
        SET @severity_code = @priority;
    IF @severity_name IS NULL
        SET @severity_name = @severity_code;

    -- 320: the Add-Gap dialog's owner picker only ever sends an
    -- employee id, never a display name (it has nowhere to type one).
    -- Resolve it server-side the same way sp_custom_gap_save (116b)
    -- already does, so a Custom gap's Owner column is not blank the
    -- moment someone picks an owner from the dropdown.
    DECLARE @owner_display_name NVARCHAR(240) = NULL;
    IF @owner_employee_id IS NOT NULL
        SELECT @owner_display_name = employee_name
          FROM grac_practice.organization_employee
         WHERE employee_id = @owner_employee_id;

    INSERT INTO grac_practice.custom_gap
        (organization_id, gap_type_code, title, description, priority,
         owner_employee_id, owner_display_name, due_date, status, remarks,
         severity_code, severity_name,
         detection_method_code, detection_method_name,
         opened_dt,
         entered_by, entered_dt)
    VALUES
        (@organization_id, ISNULL(@gap_type_code, N'Custom'),
         @title, @description, @priority,
         @owner_employee_id, @owner_display_name, @due_date, @status, @remarks,
         @severity_code, @severity_name,
         NULLIF(LTRIM(RTRIM(@detection_method_code)), N''),
         NULLIF(LTRIM(RTRIM(@detection_method_name)), N''),
         SYSUTCDATETIME(),
         COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api'),
         SYSUTCDATETIME());

    SET @custom_gap_id = SCOPE_IDENTITY();
END
GO
PRINT '320: sp_custom_gap_open resolves owner_display_name and sets opened_dt.';
GO

-- =====================================================================
-- C. One-time backfill for rows created before this fix.
-- =====================================================================

-- C1. opened_dt: mirrors 109's own backfill (opened_dt = entered_dt),
-- but 109 only ever covered rows that existed when IT ran. Everything
-- created afterward by sp_custom_gap_open (250, and whatever it was
-- before) or sp_custom_gap_materialize_for_instance (160) went in with
-- opened_dt left NULL until this fix. Guarded to touch only rows still
-- missing it.
UPDATE grac_practice.custom_gap
   SET opened_dt  = entered_dt,
       updated_by = N'seed-320',
       updated_dt = SYSUTCDATETIME()
 WHERE opened_dt IS NULL
   AND entered_dt IS NOT NULL;
PRINT CONCAT('320: opened_dt backfilled on ', @@ROWCOUNT, ' existing custom_gap row(s).');
GO

-- C2. owner_display_name for any gap that already has an owner id but
-- no display name yet (Custom gaps opened before this fix, where the
-- picker sent only the id).
UPDATE g
   SET g.owner_display_name = e.employee_name,
       g.updated_by         = N'seed-320',
       g.updated_dt         = SYSUTCDATETIME()
  FROM grac_practice.custom_gap g
  JOIN grac_practice.organization_employee e
    ON e.employee_id = g.owner_employee_id
 WHERE g.owner_employee_id IS NOT NULL
   AND (g.owner_display_name IS NULL OR LEN(LTRIM(RTRIM(g.owner_display_name))) = 0);
PRINT CONCAT('320: owner_display_name backfilled on ', @@ROWCOUNT, ' existing custom_gap row(s).');
GO

-- C3. Owner auto-assign for existing AUTOMATIC (Implementation) gaps
-- that materialized before this fix and so never got an owner at all.
-- Only fills owner_employee_id/owner_display_name where still NULL --
-- never overwrites an owner someone has since set by hand on the gap.
UPDATE g
   SET g.owner_employee_id  = pi.primary_owner_id,
       g.owner_display_name = COALESCE(e.employee_name, pi.primary_owner),
       g.updated_by          = N'seed-320',
       g.updated_dt          = SYSUTCDATETIME()
  FROM grac_practice.custom_gap g
  JOIN grac_practice.practice_instance pi
    ON pi.practice_instance_id = g.source_reference_id
   AND g.source_reference_type = N'PracticeInstance'
  LEFT JOIN grac_practice.organization_employee e
    ON e.employee_id = pi.primary_owner_id
 WHERE g.gap_source_module_code = N'Implementation'
   AND g.owner_employee_id IS NULL
   AND pi.primary_owner_id IS NOT NULL;
PRINT CONCAT('320: owner auto-assigned on ', @@ROWCOUNT, ' existing automatic (Implementation) custom_gap row(s).');
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 320 verification ===';

SELECT '320-a materialize proc sets opened_dt' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_materialize_for_instance','P')) LIKE '%opened_dt%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '320-b materialize proc assigns owner_employee_id from practice_instance',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_materialize_for_instance','P')) LIKE '%pi.primary_owner_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '320-c open proc resolves owner_display_name',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_open','P')) LIKE '%@owner_display_name%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '320-d open proc sets opened_dt',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_open','P')) LIKE '%opened_dt%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '320-e no custom_gap row is missing opened_dt any more',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.custom_gap WHERE opened_dt IS NULL AND entered_dt IS NOT NULL)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '320-f regression: open proc still validates status',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_open','P')) LIKE '%@status NOT IN%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- 320 diagnostic: automatic gaps still without an owner (no primary_owner_id on their instance) ---';
SELECT g.custom_gap_id, g.title, pi.instance_code, pi.primary_owner_id, pi.primary_owner
  FROM grac_practice.custom_gap g
  JOIN grac_practice.practice_instance pi
    ON pi.practice_instance_id = g.source_reference_id
   AND g.source_reference_type = N'PracticeInstance'
 WHERE g.gap_source_module_code = N'Implementation'
   AND g.owner_employee_id IS NULL;

PRINT '';
PRINT '320 complete. Gap Center Owner and Raised On now populate on both creation paths, and existing rows are backfilled.';
GO

SET NOEXEC OFF;
GO
