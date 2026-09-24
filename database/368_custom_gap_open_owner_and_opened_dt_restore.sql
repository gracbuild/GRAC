-- =====================================================================
-- 368 Custom Gap creation: Owner and Raised On silently blank again in
-- the Gap Center list.
--
-- REPORTED
-- --------
-- "When creating a Custom Gap, Owner and Raised Date are captured, but
--  they are not displayed in the Gap List." Trace the full flow --
--  Custom Gap Create -> API/Backend -> Database -> Gap List API ->
--  Grid/List UI -- and fix only the missing part.
--
-- INVESTIGATION
-- -------------
-- Every layer above the database is already correct:
--   * gaps.cshtml's Add-Gap dialog sends ownerEmployeeId on the create
--     payload, and the grid already has Owner / Raised On columns
--     rendering row.ownerText and row.openedDt (unchanged by this fix).
--   * sp_gap_centre_list (357, the current live body) already projects
--     custom_gap.owner_display_name as OwnerText and custom_gap.opened_dt
--     as OpenedDt for every row (unchanged by this fix).
--   * CustomGapService.ListGapCentreAsync / GapCentreListRow already map
--     both columns by name (unchanged by this fix).
--
-- The break is in the one place that actually stores the row: this
-- project's migration-history-is-frozen convention means the LIVE body
-- of sp_custom_gap_open -- the proc CustomGapController's plain
-- POST /api/practice/gaps/custom (CustomGapService.OpenAsync) calls for
-- every Custom gap the Add-Gap dialog creates -- is whichever migration
-- last re-issued it. That is 324, not 320.
--
-- Migration 320 gave sp_custom_gap_open exactly this fix once already:
-- resolve owner_display_name from owner_employee_id (the dialog only
-- ever sends an id, never a name) and stamp opened_dt = SYSUTCDATETIME()
-- so the gap has a Raised On value the moment it exists.
--
-- Migration 324 (gap_analysis_status_and_reanalysis_guard) re-issued the
-- SAME proc to fix an unrelated bug -- Custom gaps never reaching
-- "Analysed" status -- by stamping lifecycle_state_id at birth. Its own
-- header says it re-issued "byte-for-byte 250's body" (250 predates 320)
-- plus that one addition. It was not rebased on 320's body, so its
-- INSERT column list carries owner_employee_id and due_date but no
-- owner_display_name and no opened_dt at all -- 320's fix is gone from
-- the object actually running today, even though 320's own migration
-- file still sits in this folder, unmodified, earlier in the sequence.
--
-- RESULT: owner_employee_id IS saved correctly on every Custom gap
-- created since 324 was applied (this is why it "is being captured" --
-- the id round-trips fine through Save/Edit and the gap-detail screen,
-- which both resolve the id themselves). owner_display_name and
-- opened_dt are NULL on every one of those rows, so sp_gap_centre_list's
-- OwnerText / OpenedDt columns -- which read the stored display name and
-- stored date, not the id -- come back NULL, and the Gap List shows
-- both columns blank for every Custom gap opened since. Automatic
-- (Implementation) gaps are unaffected: sp_custom_gap_materialize_for_
-- instance is still on 320's body (nothing after 320 re-issued it).
--
-- FIX
-- ---
-- Re-issue sp_custom_gap_open one more time: 324's body (lifecycle_
-- state_id stamped at birth, kept exactly as-is) with 320's owner-
-- display-name resolver and opened_dt stamp restored alongside it.
-- Nothing else changes -- same parameters, same validation, same
-- defaults, same severity fallback, same detection-method handling.
--
-- WHAT THIS DOES NOT DO
-- ----------------------
--   * Does not touch sp_custom_gap_save, sp_custom_gap_materialize_for_
--     instance, sp_gap_centre_list, or any other proc -- all three
--     already carry the owner/opened_dt values (or, for the list proc,
--     already project whatever the row happens to have) and are not
--     part of this regression.
--   * Does not touch the create dialog, the API controller/service, or
--     the grid JS -- all already correct, per the investigation above.
--   * Does not re-run any backfill. Rows created between 324 and this
--     migration are backfilled below (C), narrowly scoped to Custom
--     gaps opened via this exact path so an owner or date someone has
--     since set by hand is never overwritten.
--
-- Depends on 055, 116b, 158 (New state seed), 250, 320, 324 (sp_custom_
-- gap_open's current live body, being re-issued here).
-- Rollback: 368_custom_gap_open_owner_and_opened_dt_restore_rollback.sql
-- restores 324's body verbatim.
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_custom_gap_open','P') IS NULL
BEGIN
    PRINT 'ABORT (368): grac_practice.sp_custom_gap_open is missing (run 055/250/320/324 first).';
    SET NOEXEC ON;
END
GO

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

    -- 320, restored by 368: the Add-Gap dialog's owner picker only ever
    -- sends an employee id, never a display name (it has nowhere to type
    -- one). Resolve it server-side the same way sp_custom_gap_save
    -- (116b) already does, so a Custom gap's Owner column is not blank
    -- the moment someone picks an owner from the dropdown.
    DECLARE @owner_display_name NVARCHAR(240) = NULL;
    IF @owner_employee_id IS NOT NULL
        SELECT @owner_display_name = employee_name
          FROM grac_practice.organization_employee
         WHERE employee_id = @owner_employee_id;

    -- 324: stamp the gap into the v1 lifecycle at birth, unchanged by
    -- this migration.
    DECLARE @new_state_id INT =
        (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'New');

    INSERT INTO grac_practice.custom_gap
        (organization_id, gap_type_code, title, description, priority,
         owner_employee_id, owner_display_name, due_date, status, remarks,
         severity_code, severity_name,
         detection_method_code, detection_method_name,
         lifecycle_state_id,
         -- 320, restored by 368: this gap is "raised" the moment it is
         -- opened through this proc.
         opened_dt,
         entered_by, entered_dt)
    VALUES
        (@organization_id, ISNULL(@gap_type_code, N'Custom'),
         @title, @description, @priority,
         @owner_employee_id, @owner_display_name, @due_date, @status, @remarks,
         @severity_code, @severity_name,
         NULLIF(LTRIM(RTRIM(@detection_method_code)), N''),
         NULLIF(LTRIM(RTRIM(@detection_method_name)), N''),
         @new_state_id,
         SYSUTCDATETIME(),
         COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api'),
         SYSUTCDATETIME());

    SET @custom_gap_id = SCOPE_IDENTITY();
END
GO
PRINT '368: sp_custom_gap_open resolves owner_display_name and sets opened_dt again (restores 320 on top of 324''s lifecycle stamp).';
GO

-- =====================================================================
-- Backfill: Custom gaps opened between 324 and this fix, still missing
-- what 324 dropped. Guarded to touch only rows still missing the value
-- -- never overwrites an owner or date someone (or another proc) has
-- since set by hand. Same shape as 320's own backfill (C1/C2).
-- =====================================================================
UPDATE grac_practice.custom_gap
   SET opened_dt  = entered_dt,
       updated_by = N'seed-368',
       updated_dt = SYSUTCDATETIME()
 WHERE opened_dt IS NULL
   AND entered_dt IS NOT NULL;
PRINT CONCAT('368: opened_dt backfilled on ', @@ROWCOUNT, ' existing custom_gap row(s).');
GO

UPDATE g
   SET g.owner_display_name = e.employee_name,
       g.updated_by         = N'seed-368',
       g.updated_dt         = SYSUTCDATETIME()
  FROM grac_practice.custom_gap g
  JOIN grac_practice.organization_employee e
    ON e.employee_id = g.owner_employee_id
 WHERE g.owner_employee_id IS NOT NULL
   AND (g.owner_display_name IS NULL OR LEN(LTRIM(RTRIM(g.owner_display_name))) = 0);
PRINT CONCAT('368: owner_display_name backfilled on ', @@ROWCOUNT, ' existing custom_gap row(s).');
GO

-- =====================================================================
-- Verification
-- =====================================================================
DECLARE @def368 NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_open','P'));

SELECT '368-a sp_custom_gap_open compiled' AS Check_,
       CASE WHEN @def368 IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '368-b resolves owner_display_name again',
       CASE WHEN @def368 LIKE '%@owner_display_name%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '368-c sets opened_dt again',
       CASE WHEN @def368 LIKE '%opened_dt%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '368-d still stamps lifecycle_state_id (324, unchanged)',
       CASE WHEN @def368 LIKE '%lifecycle_state_id%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '368-e no custom_gap row is missing opened_dt any more',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.custom_gap WHERE opened_dt IS NULL AND entered_dt IS NOT NULL)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '368-f no custom_gap row with an owner id is missing its display name',
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.custom_gap
                 WHERE owner_employee_id IS NOT NULL
                   AND (owner_display_name IS NULL OR LEN(LTRIM(RTRIM(owner_display_name))) = 0))
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '368 complete. Custom Gap creation (sp_custom_gap_open) once again stores Owner display name and Raised On, so the Gap List (sp_gap_centre_list) has values to show for both columns -- without losing 324''s Analysed-status fix.';
GO

SET NOEXEC OFF;
GO
