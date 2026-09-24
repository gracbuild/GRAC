-- =====================================================================
-- 335 Event Assurance -- the four lifecycle events can no longer go missing
--
-- ---------------------------------------------------------------------
-- SYMPTOM
-- ---------------------------------------------------------------------
--     sp_event_instance_raise_scoped: event definition not found for
--     organization.                                    (error 67223)
--
-- on pressing Raise Event.
--
-- ---------------------------------------------------------------------
-- CAUSE
-- ---------------------------------------------------------------------
-- The Raise Event button never sends an event code. Both wrappers --
-- sp_event_raise_people_lifecycle and sp_event_raise_asset_lifecycle --
-- default it to one of four fixed strings:
--
--     ONBOARD      -> PEOPLE_ONBOARDING
--     OFFBOARD     -> PEOPLE_OFFBOARDING
--     COMMISSION   -> ASSET_COMMISSIONING
--     DECOMMISSION -> ASSET_DECOMMISSIONING
--
-- and sp_event_instance_raise_scoped resolves that string against
-- grac_practice.event_definition for the organization, status Active.
-- No row, no raise.
--
-- Those four rows come from migration 126, whose own header calls the
-- codes "a CONTRACT with 124" -- they are not an organizational choice,
-- they are what the wrappers hard-code. Two things empty the table, and
-- neither has anything that puts the rows back:
--
--   1. 126 IS A ONE-SHOT SEED.
--
--          FROM grac_practice.organization o ... WHERE o.status = N'Active'
--
--      over the organizations that existed AT THE MOMENT IT RAN. Nothing
--      re-runs it, so every organization created since has none of the
--      four rows. 126's own header predicted exactly this:
--
--          "Every organization would have to hand-create four rows with
--           exactly the right codes before the module does anything -- an
--           undocumented setup step that will be missed."
--
--      It was missed because it was never anybody's step to take.
--
--   2. 192_practice_data_reset.sql CLEARS event_definition, deliberately.
--      Its header explains why -- the table is organization-scoped and
--      FKs to workflow / workflow_stage, both of which the reset clears,
--      so keeping it would leave orphans and fail the workflow DELETE.
--      That reasoning is sound; what was missing is the other half. Under
--      @Scope = 'CATALOGUE' the organizations survive and their events do
--      not, which leaves every org in the exact state this error reports.
--
--      192 has been amended in the same change as this file: it now calls
--      the ensure below for every surviving active organization, guarded
--      so 192 still runs against a database without 335.
--
-- An event_definition table that is EMPTY for organizations that plainly
-- predate the problem is cause 2. A table with rows for the older
-- organizations and none for the newer is cause 1.
--
-- Run _diag_event_definition_missing.sql first if you want to see which
-- organizations are affected before changing anything.
--
-- ---------------------------------------------------------------------
-- WHAT THIS DOES
-- ---------------------------------------------------------------------
-- 1. sp_event_definition_ensure_baseline -- NEW. Creates 126's two entity
--    types and four event definitions for ONE organization, if they are
--    missing. INSERT-ONLY, no result set, safe to call on every raise.
--
-- 2. sp_event_raise_people_lifecycle / sp_event_raise_asset_lifecycle --
--    re-issued from 128 with three changes each, and nothing else touched:
--
--      a. They call the ensure before raising, so an organization created
--         after 126 provisions itself on first use and this error cannot
--         recur. Only when the caller did NOT pass @event_code -- see
--         "WHY INSERT-ONLY" below.
--
--      b. A definition that is still not resolvable now throws a message
--         that names the organization, the code and the fix, instead of
--         67223's bare sentence. The check sits in the wrapper rather
--         than in sp_event_instance_raise_scoped so that 280-line
--         resolver is not re-issued to change one string.
--
--      c. The subject mutation and the raise are now ONE transaction.
--         Previously the employee was already marked Active/onboarded (or
--         Inactive/offboarded) by the time 67223 fired, because the
--         UPDATE ran outside any transaction and the THROW happened in
--         the callee. The screen said the save failed while the record
--         said it had succeeded. They now agree.
--
-- 3. A one-time gap fill: the ensure runs for every active organization,
--    which is what clears the error for organizations that already exist.
--
-- ---------------------------------------------------------------------
-- WHY INSERT-ONLY, AND WHY NOT WHEN @event_code IS PASSED
-- ---------------------------------------------------------------------
-- 126's MERGE sets status = N'Active' on a matched row. That is right for
-- a seed and wrong for something that runs on every raise: an organization
-- that deliberately deactivated PEOPLE_OFFBOARDING would have it switched
-- back on by the next offboarding, silently. So the ensure only INSERTs
-- what is absent and never touches a row that exists. A deactivated event
-- still refuses to raise -- and now says so in a sentence that explains
-- the deactivation is the reason.
--
-- An explicitly passed @event_code is the organization's own vocabulary,
-- not this contract. Inventing a definition for a code somebody typed
-- would create configuration nobody asked for. That path keeps throwing.
--
-- Checklists and mappings are still NOT seeded, for 126's reason: what
-- belongs on an onboarding checklist is the compliance team's decision.
-- A raise with no mapping succeeds with RaisedCount 0, which the UI
-- already reports as a configuration gap rather than a failure.
--
-- ---------------------------------------------------------------------
-- NESTING IS SAFE
-- ---------------------------------------------------------------------
-- sp_event_instance_raise_scoped (124) and sp_event_obligation_raise
-- (131, re-issued by 331) each open their own BEGIN TRAN / COMMIT TRAN.
-- Neither contains an explicit ROLLBACK anywhere, so the inner COMMITs
-- only decrement @@TRANCOUNT and the outer COMMIT here is the one that
-- writes. With XACT_ABORT ON an error at any depth dooms the whole
-- transaction, which is precisely the behaviour change (c) asks for.
--
-- Depends on 124, 126, 128 (and 131/331 for the obligation path).
-- SAFE TO RE-RUN.
-- NO SCHEMA CHANGE. Two procedures re-issued, one added, rows inserted
-- only where they were missing.
-- Rollback: 335_event_definition_ensure_baseline_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.event_definition','U') IS NULL
   OR OBJECT_ID('grac_practice.entity_type_master','U') IS NULL
   OR OBJECT_ID('grac_practice.organization','U') IS NULL
BEGIN
    PRINT 'ABORT (335): event_definition / entity_type_master / organization missing -- run 066 and 126 first.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_event_instance_raise_scoped','P') IS NULL
BEGIN
    PRINT 'ABORT (335): sp_event_instance_raise_scoped missing -- run 124 first.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_event_raise_people_lifecycle','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_event_raise_asset_lifecycle','P') IS NULL
BEGIN
    PRINT 'ABORT (335): the lifecycle wrappers are missing -- run 124 and 128 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_event_definition_ensure_baseline
--
--    126's rows, for one organization, insert-only. The literals below
--    are 126's text character for character: the code, the name and the
--    description an operator reads on the Events screen must not depend
--    on which migration created the row.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_definition_ensure_baseline
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'ensure-335'
AS
BEGIN
    SET NOCOUNT ON;

    -- RETURN rather than THROW. This runs inside the raise path, and an
    -- organization id that does not resolve is the CALLER's error to
    -- report with its own message, not this helper's.
    IF @organization_id IS NULL RETURN;

    -- ---------------------------------------------------------------
    -- Entity types. Not read by the raise resolver -- event_definition
    -- carries entity_category as a plain string, not an FK -- but a
    -- half-provisioned organization shows an empty Entity Types screen,
    -- so 126 seeded both and so does this.
    -- ---------------------------------------------------------------
    INSERT grac_practice.entity_type_master
        (organization_id, entity_type_code, entity_type_name, description,
         entity_category, status, entered_by, entered_dt)
    SELECT @organization_id, v.entity_type_code, v.entity_type_name,
           v.description, v.entity_category, N'Active', @actor, SYSUTCDATETIME()
    FROM  (VALUES
        (N'PEOPLE', N'People',
         N'Employees, contractors and interns. Subject of onboarding and offboarding assurance.', N'People'),
        (N'ASSET',  N'Asset',
         N'IT and non-IT assets. Subject of commissioning and decommissioning assurance.',        N'Assets')
          ) AS v(entity_type_code, entity_type_name, description, entity_category)
    WHERE NOT EXISTS (
        SELECT 1 FROM grac_practice.entity_type_master x
        WHERE  x.organization_id  = @organization_id
          AND  x.entity_type_code = v.entity_type_code);

    -- ---------------------------------------------------------------
    -- The four lifecycle events. These codes ARE the contract with the
    -- wrappers -- renaming one here stops Raise Event resolving.
    -- ---------------------------------------------------------------
    INSERT grac_practice.event_definition
        (organization_id, event_code, event_name, description,
         entity_category, trigger_source, status, entered_by, entered_dt)
    SELECT @organization_id, v.event_code, v.event_name, v.description,
           v.entity_category, v.trigger_source, N'Active', @actor, SYSUTCDATETIME()
    FROM  (VALUES
        (N'PEOPLE_ONBOARDING',      N'Person Onboarding',
         N'A person joins the organization in a role. Raises the onboarding checklists mapped to that role.',
         N'People', N'Manual'),
        (N'PEOPLE_OFFBOARDING',     N'Person Offboarding',
         N'A person leaves the organization. Raises the offboarding checklists mapped to the roles they held.',
         N'People', N'Manual'),
        (N'ASSET_COMMISSIONING',    N'Asset Commissioning',
         N'An asset is put into service. Raises the commissioning checklists mapped to its category.',
         N'Assets', N'Manual'),
        (N'ASSET_DECOMMISSIONING',  N'Asset Decommissioning',
         N'An asset is retired from service. Raises the decommissioning checklists mapped to its category.',
         N'Assets', N'Manual')
          ) AS v(event_code, event_name, description, entity_category, trigger_source)
    -- No status test. A row that exists and is Inactive must stay
    -- Inactive: somebody turned it off on purpose, and the raise is
    -- supposed to refuse. See "WHY INSERT-ONLY" in the header.
    WHERE NOT EXISTS (
        SELECT 1 FROM grac_practice.event_definition x
        WHERE  x.organization_id = @organization_id
          AND  x.event_code      = v.event_code);
END;
GO

-- =====================================================================
-- 2. sp_event_raise_people_lifecycle
--
--    128's body. The three additions are marked "335"; every other line,
--    including the THROW numbers and the obligation-path guard, is the
--    128 text unchanged.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_raise_people_lifecycle
    @organization_id   BIGINT,
    @employee_id       BIGINT,
    @lifecycle_action  NVARCHAR(20),
    @effective_date    DATE          = NULL,
    @event_code        NVARCHAR(60)  = NULL,
    @trigger_source    NVARCHAR(60)  = N'Manual',
    @actor_employee_id BIGINT        = NULL,
    @out_raised_count  INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @lifecycle_action NOT IN (N'ONBOARD', N'OFFBOARD')
        THROW 67230, 'sp_event_raise_people_lifecycle: lifecycle_action must be ONBOARD or OFFBOARD.', 1;

    SET @effective_date = ISNULL(@effective_date, CAST(SYSUTCDATETIME() AS DATE));
    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                    WHERE employee_id = @employee_id AND organization_id = @organization_id)
        THROW 67231, 'sp_event_raise_people_lifecycle: employee not found in this organization.', 1;

    -- 335. Whether the code was supplied decides whether this
    -- organization may be provisioned for it. Captured before the
    -- default is applied, because after it @event_code is never NULL.
    DECLARE @code_was_supplied BIT = CASE WHEN @event_code IS NULL THEN 0 ELSE 1 END;

    IF @event_code IS NULL
        SET @event_code = CASE @lifecycle_action
                               WHEN N'ONBOARD' THEN N'PEOPLE_ONBOARDING'
                               ELSE N'PEOPLE_OFFBOARDING' END;

    -- 335 (a). An organization created after migration 126 ran has none
    -- of the four contract rows. Create them now rather than fail.
    IF @code_was_supplied = 0
        EXEC grac_practice.sp_event_definition_ensure_baseline
             @organization_id = @organization_id, @actor = @actor;

    -- 335 (b). Still unresolvable? Say which organization, which code,
    -- and which of the two reasons it is -- before anything is written.
    IF NOT EXISTS (SELECT 1 FROM grac_practice.event_definition
                    WHERE organization_id = @organization_id
                      AND event_code      = @event_code
                      AND status          = N'Active')
    BEGIN
        DECLARE @exists_inactive BIT =
            CASE WHEN EXISTS (SELECT 1 FROM grac_practice.event_definition
                               WHERE organization_id = @organization_id
                                 AND event_code      = @event_code)
                 THEN 1 ELSE 0 END;
        DECLARE @msg NVARCHAR(2048) =
            N'Cannot raise this event. The event "' + @event_code
            + N'" is ' + CASE WHEN @exists_inactive = 1 THEN N'inactive' ELSE N'not defined' END
            + N' for organization ' + CAST(@organization_id AS NVARCHAR(20)) + N'. '
            + CASE WHEN @exists_inactive = 1
                   THEN N'Reactivate it on the Events screen, or stop raising this action.'
                   ELSE N'Define it on the Events screen. Nothing has been changed.' END;
        THROW 67232, @msg, 1;
    END

    DECLARE @checklist_count INT = 0, @obligation_count INT = 0;

    -- 335 (c). The status change and the raise stand or fall together.
    BEGIN TRAN;

    IF @lifecycle_action = N'ONBOARD'
        UPDATE grac_practice.organization_employee
           SET onboarded_dt = ISNULL(onboarded_dt, @effective_date),
               status = N'Active', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE employee_id = @employee_id AND organization_id = @organization_id;
    ELSE
        UPDATE grac_practice.organization_employee
           SET offboarded_dt = @effective_date,
               status = N'Inactive', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE employee_id = @employee_id AND organization_id = @organization_id;

    EXEC grac_practice.sp_event_instance_raise_scoped
         @organization_id = @organization_id, @event_code = @event_code,
         @subject_entity = N'EMPLOYEE', @subject_record_id = @employee_id,
         @effective_date = @effective_date, @trigger_source = @trigger_source,
         @actor_employee_id = @actor_employee_id,
         @out_raised_count = @checklist_count OUTPUT;

    -- The obligation event type code mirrors the 066 event code, so the same
    -- string resolves in both taxonomies. If GRAC-ADMIN uses a different
    -- code, pass @event_code explicitly.
    IF EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                WHERE event_code = @event_code AND status = N'Active')
        EXEC grac_practice.sp_event_obligation_raise
             @organization_id = @organization_id, @event_type_code = @event_code,
             @subject_entity = N'EMPLOYEE', @subject_record_id = @employee_id,
             @effective_date = @effective_date, @trigger_source = @trigger_source,
             @actor_employee_id = @actor_employee_id,
             @out_raised_count = @obligation_count OUTPUT;

    COMMIT TRAN;

    SET @out_raised_count = ISNULL(@checklist_count, 0) + ISNULL(@obligation_count, 0);
END;
GO

-- =====================================================================
-- 3. sp_event_raise_asset_lifecycle
--
--    128's body, with the same three additions. The already-commissioned
--    and already-decommissioned guards keep their own THROW numbers and
--    stay ahead of everything, as they were.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_raise_asset_lifecycle
    @organization_id   BIGINT,
    @asset_id          BIGINT,
    @lifecycle_action  NVARCHAR(20),
    @effective_date    DATE          = NULL,
    @event_code        NVARCHAR(60)  = NULL,
    @trigger_source    NVARCHAR(60)  = N'Manual',
    @actor_employee_id BIGINT        = NULL,
    @out_raised_count  INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @lifecycle_action NOT IN (N'COMMISSION', N'DECOMMISSION')
        THROW 67240, 'sp_event_raise_asset_lifecycle: lifecycle_action must be COMMISSION or DECOMMISSION.', 1;

    SET @effective_date = ISNULL(@effective_date, CAST(SYSUTCDATETIME() AS DATE));
    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    DECLARE @current NVARCHAR(30);
    SELECT @current = lifecycle_status
    FROM   grac_practice.organization_dependency_asset
    WHERE  asset_id = @asset_id AND organization_id = @organization_id;
    IF @@ROWCOUNT = 0
        THROW 67241, 'sp_event_raise_asset_lifecycle: asset not found in this organization.', 1;
    IF @lifecycle_action = N'DECOMMISSION' AND @current = N'Decommissioned'
        THROW 67242, 'sp_event_raise_asset_lifecycle: asset is already decommissioned.', 1;
    IF @lifecycle_action = N'COMMISSION' AND @current = N'Commissioned'
        THROW 67243, 'sp_event_raise_asset_lifecycle: asset is already commissioned.', 1;

    -- 335. See the people wrapper for why this is captured before the
    -- default is applied.
    DECLARE @code_was_supplied BIT = CASE WHEN @event_code IS NULL THEN 0 ELSE 1 END;

    IF @event_code IS NULL
        SET @event_code = CASE @lifecycle_action
                               WHEN N'COMMISSION' THEN N'ASSET_COMMISSIONING'
                               ELSE N'ASSET_DECOMMISSIONING' END;

    -- 335 (a).
    IF @code_was_supplied = 0
        EXEC grac_practice.sp_event_definition_ensure_baseline
             @organization_id = @organization_id, @actor = @actor;

    -- 335 (b).
    IF NOT EXISTS (SELECT 1 FROM grac_practice.event_definition
                    WHERE organization_id = @organization_id
                      AND event_code      = @event_code
                      AND status          = N'Active')
    BEGIN
        DECLARE @exists_inactive BIT =
            CASE WHEN EXISTS (SELECT 1 FROM grac_practice.event_definition
                               WHERE organization_id = @organization_id
                                 AND event_code      = @event_code)
                 THEN 1 ELSE 0 END;
        DECLARE @msg NVARCHAR(2048) =
            N'Cannot raise this event. The event "' + @event_code
            + N'" is ' + CASE WHEN @exists_inactive = 1 THEN N'inactive' ELSE N'not defined' END
            + N' for organization ' + CAST(@organization_id AS NVARCHAR(20)) + N'. '
            + CASE WHEN @exists_inactive = 1
                   THEN N'Reactivate it on the Events screen, or stop raising this action.'
                   ELSE N'Define it on the Events screen. Nothing has been changed.' END;
        THROW 67244, @msg, 1;
    END

    DECLARE @checklist_count INT = 0, @obligation_count INT = 0;

    -- 335 (c).
    BEGIN TRAN;

    IF @lifecycle_action = N'COMMISSION'
        UPDATE grac_practice.organization_dependency_asset
           SET lifecycle_status = N'Commissioned', commissioned_dt = @effective_date,
               decommissioned_dt = NULL, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE asset_id = @asset_id AND organization_id = @organization_id;
    ELSE
        UPDATE grac_practice.organization_dependency_asset
           SET lifecycle_status = N'Decommissioned', decommissioned_dt = @effective_date,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE asset_id = @asset_id AND organization_id = @organization_id;

    EXEC grac_practice.sp_event_instance_raise_scoped
         @organization_id = @organization_id, @event_code = @event_code,
         @subject_entity = N'ASSET', @subject_record_id = @asset_id,
         @effective_date = @effective_date, @trigger_source = @trigger_source,
         @actor_employee_id = @actor_employee_id,
         @out_raised_count = @checklist_count OUTPUT;

    IF EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                WHERE event_code = @event_code AND status = N'Active')
        EXEC grac_practice.sp_event_obligation_raise
             @organization_id = @organization_id, @event_type_code = @event_code,
             @subject_entity = N'ASSET', @subject_record_id = @asset_id,
             @effective_date = @effective_date, @trigger_source = @trigger_source,
             @actor_employee_id = @actor_employee_id,
             @out_raised_count = @obligation_count OUTPUT;

    COMMIT TRAN;

    SET @out_raised_count = ISNULL(@checklist_count, 0) + ISNULL(@obligation_count, 0);
END;
GO

-- =====================================================================
-- 4. One-time gap fill.
--
--    The ensure above only runs when somebody raises. This closes the
--    gap for every organization that already exists, so the four events
--    are visible on the Events screen before anyone tries.
--
--    Cursor rather than a set-based insert because the rule lives in the
--    procedure now, and having it in two places is how 126 and the
--    wrappers drifted apart in the first place.
-- =====================================================================
DECLARE @org_id BIGINT;
DECLARE @filled INT = 0;

DECLARE org_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT organization_id FROM grac_practice.organization
    WHERE status = N'Active' ORDER BY organization_id;

OPEN org_cur;
FETCH NEXT FROM org_cur INTO @org_id;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC grac_practice.sp_event_definition_ensure_baseline
         @organization_id = @org_id, @actor = N'seed-335';
    SET @filled = @filled + 1;
    FETCH NEXT FROM org_cur INTO @org_id;
END
CLOSE org_cur;
DEALLOCATE org_cur;

PRINT '335: baseline events ensured for ' + CAST(@filled AS VARCHAR(20)) + ' active organization(s).';
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'sp_event_definition_ensure_baseline' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_event_definition_ensure_baseline','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'people wrapper calls the ensure',
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_event_raise_people_lifecycle')
                            AND definition LIKE N'%sp_event_definition_ensure_baseline%')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'asset wrapper calls the ensure',
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                          WHERE object_id = OBJECT_ID('grac_practice.sp_event_raise_asset_lifecycle')
                            AND definition LIKE N'%sp_event_definition_ensure_baseline%')
            THEN 'PASS' ELSE 'FAIL' END;
GO

-- Every active organization should now show 4. An organization showing
-- fewer has a row that exists but is INACTIVE -- deliberate, and left
-- alone on purpose. _diag_event_definition_missing.sql names it.
SELECT o.organization_id AS OrganizationId,
       o.organization_name AS OrganizationName,
       COUNT(ed.event_definition_id) AS ActiveLifecycleEvents
FROM   grac_practice.organization o
LEFT   JOIN grac_practice.event_definition ed
       ON ed.organization_id = o.organization_id
      AND ed.status = N'Active'
      AND ed.event_code IN (N'PEOPLE_ONBOARDING', N'PEOPLE_OFFBOARDING',
                            N'ASSET_COMMISSIONING', N'ASSET_DECOMMISSIONING')
WHERE  o.status = N'Active'
GROUP  BY o.organization_id, o.organization_name
ORDER  BY o.organization_id;
GO

PRINT '335 done. Raise Event now provisions its own event definitions.';
PRINT 'NEXT: map checklists per role/profile on Scoped Checklist Mapping -- a raise with no mapping succeeds with 0 raised.';
GO

SET NOEXEC OFF;
GO
