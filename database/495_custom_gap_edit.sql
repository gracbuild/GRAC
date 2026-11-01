-- =====================================================================
-- 495 Custom gap: Edit
--
-- Change request 2026-10-27: a Custom gap added on the Add Custom Gap
-- page (491) can be edited -- the same fields, on the same page.
--
-- WHAT THIS SCRIPT DOES
--   grac_practice.sp_custom_gap_edit (NEW). Writes exactly the fields the
--   Add Custom Gap page captures -- Title, Description, Current State /
--   As-Is, Gap Identified / Finding, Comments / Management Response
--   (remarks), Severity (priority kept equal to it, as on Add), Owner,
--   Due Date, Detection Method -- and re-sets the mapped practice
--   instances. Status is NOT edited here: it moves through the lifecycle
--   actions (Close Gap, Start, Verify, ...), as before.
--
--   Why a new procedure and not sp_custom_gap_save's edit branch: that
--   branch overwrites every column it knows (reviewer, target resolution
--   date, remediation plan, owner role, ...) from its parameters, so a
--   page that does not show those would blank them. It also has no
--   narrative fields (491) and no practice-instance mapping.
--
-- RULES (the same ones sp_custom_gap_save's edit branch applies, plus the
-- ones only this page needs)
--   55001  organization required          (as 112/324)
--   55002  title required                 (as 112/324)
--   55004  gap not found                  (as 112/324)
--   55005  gap of another organization    (as 112/324)
--   55006  status not Open / InProgress / Reopened (as 324)
--   55060  not a Custom gap -- gaps of the other sources are owned by
--          their own module (same scope as Close Gap on the menu)
--   55061  lifecycle stage is terminal (Analysed / Closed / Invalid /
--          Duplicate): once analysed, the analysis owns severity and
--          the downstream tasks / exceptions / risks own the gap. A gap
--          with no lifecycle stage yet counts as New.
--   55062  at least one practice instance of this organization (the
--          Add page requires one too; 382/388)
--
-- PRACTICE INSTANCES
--   The chosen set replaces the current one: a mapping no longer chosen
--   is set Inactive (record_status_master; every reader of
--   custom_gap_practice_map filters on Active -- 388, 389, 411), one
--   chosen again is set Active, and a new one is added by the existing
--   sp_custom_gap_practice_instance_set (388). A practice-level row with
--   no instance (gaps mapped before 388) is retired once instances are
--   chosen. Nothing is deleted.
--
-- Every edit writes one custom_gap_history row (EDIT, "Gap edited.").
--
-- Requires 250, 382, 388, 491. SAFE TO RE-RUN. ASCII-only.
-- Rollback: 495_custom_gap_edit_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('grac_practice.custom_gap','current_state') IS NULL
   OR COL_LENGTH('grac_practice.custom_gap','detection_method_code') IS NULL
   OR COL_LENGTH('grac_practice.custom_gap_practice_map','practice_instance_id') IS NULL
   OR OBJECT_ID('grac_practice.sp_custom_gap_practice_instance_set','P') IS NULL
   OR OBJECT_ID('grac_practice.gap_lifecycle_state_master','U') IS NULL
BEGIN
    PRINT 'ABORT (495): run 250, 382, 388 and 491 first.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_edit
    @organization_id             BIGINT,
    @custom_gap_id               BIGINT,
    @title                       NVARCHAR(250),
    @description                 NVARCHAR(MAX)  = NULL,
    @current_state               NVARCHAR(MAX)  = NULL,
    @gap_finding                 NVARCHAR(MAX)  = NULL,
    @remarks                     NVARCHAR(1000) = NULL,
    @severity_code               NVARCHAR(30)   = NULL,
    @owner_employee_id           BIGINT         = NULL,
    @due_date                    DATE           = NULL,
    @detection_method_code       NVARCHAR(60)   = NULL,
    @detection_method_name       NVARCHAR(200)  = NULL,
    -- JSON array of practice instance ids, e.g. '[41,57]'.
    @practice_instance_ids_json  NVARCHAR(MAX),
    @actor_employee_id           BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 55001, 'organization_id is required.', 1;
    IF @title IS NULL OR LEN(LTRIM(RTRIM(@title))) = 0
        THROW 55002, 'Title is required.', 1;

    DECLARE @gap_org BIGINT, @status NVARCHAR(60), @source NVARCHAR(30),
            @state_code NVARCHAR(40), @is_terminal BIT, @old_owner BIGINT;
    SELECT @gap_org     = g.organization_id,
           @status      = g.status,
           @source      = g.gap_source_module_code,
           @state_code  = ISNULL(s.state_code, N'New'),
           @is_terminal = ISNULL(s.is_terminal, 0),
           @old_owner   = g.owner_employee_id
      FROM grac_practice.custom_gap g
      LEFT JOIN grac_practice.gap_lifecycle_state_master s
             ON s.lifecycle_state_id = g.lifecycle_state_id
     WHERE g.custom_gap_id = @custom_gap_id;

    IF @gap_org IS NULL
        THROW 55004, 'Gap not found.', 1;
    IF @gap_org <> @organization_id
        THROW 55005, 'Gap belongs to a different organization.', 1;
    IF ISNULL(@source, N'Custom') <> N'Custom'
        THROW 55060, 'Only a Custom gap can be edited here.', 1;
    IF @status NOT IN (N'Open', N'InProgress', N'Reopened')
        THROW 55006, 'Gap cannot be edited in its current status.', 1;
    IF @is_terminal = 1
        THROW 55061, 'Gap cannot be edited once it has been analysed, closed or marked invalid / duplicate.', 1;

    -- The chosen instances: this organization's only (same rule as 388).
    DECLARE @inst TABLE (practice_instance_id BIGINT PRIMARY KEY);
    IF @practice_instance_ids_json IS NOT NULL AND ISJSON(@practice_instance_ids_json) = 1
        INSERT @inst (practice_instance_id)
        SELECT DISTINCT pi.practice_instance_id
          FROM OPENJSON(@practice_instance_ids_json) WITH (practice_instance_id BIGINT N'$') j
          JOIN grac_practice.practice_instance pi
            ON pi.practice_instance_id = j.practice_instance_id
           AND pi.organization_id      = @organization_id;
    IF NOT EXISTS (SELECT 1 FROM @inst)
        THROW 55062, 'Map at least one Practice Instance.', 1;

    -- Severity: the four codes Add offers; anything else keeps Medium.
    -- priority = severity, as the Add page sends it (491).
    IF @severity_code IS NULL OR @severity_code NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @severity_code = N'Medium';

    DECLARE @owner_name NVARCHAR(240) = NULL;
    IF @owner_employee_id IS NOT NULL
        SELECT @owner_name = employee_name
          FROM grac_practice.organization_employee
         WHERE employee_id = @owner_employee_id
           AND organization_id = @organization_id;
    IF @owner_employee_id IS NOT NULL AND @owner_name IS NULL
        SET @owner_employee_id = NULL;   -- not an employee of this organization

    DECLARE @actor NVARCHAR(100) =
        COALESCE(N'employee:' + CAST(@actor_employee_id AS NVARCHAR(20)), N'api');
    DECLARE @actor_name NVARCHAR(240) =
        COALESCE((SELECT employee_name FROM grac_practice.organization_employee
                   WHERE employee_id = @actor_employee_id), @actor);
    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
    DECLARE @inactive_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Inactive');

    BEGIN TRAN;

    UPDATE grac_practice.custom_gap
       SET title                 = LTRIM(RTRIM(@title)),
           description           = NULLIF(LTRIM(RTRIM(@description)), N''),
           current_state         = NULLIF(LTRIM(RTRIM(@current_state)), N''),
           gap_finding           = NULLIF(LTRIM(RTRIM(@gap_finding)), N''),
           remarks               = NULLIF(LTRIM(RTRIM(@remarks)), N''),
           severity_code         = @severity_code,
           severity_name         = @severity_code,
           priority              = @severity_code,
           owner_employee_id     = @owner_employee_id,
           owner_display_name    = @owner_name,
           -- A changed owner drops the role the old one was picked by
           -- (the Add page never sets a role; a role-picked owner is the
           -- 116b path, which this page does not offer).
           owner_role_id         = CASE WHEN ISNULL(@old_owner, -1) = ISNULL(@owner_employee_id, -1)
                                        THEN owner_role_id ELSE NULL END,
           owner_role_name       = CASE WHEN ISNULL(@old_owner, -1) = ISNULL(@owner_employee_id, -1)
                                        THEN owner_role_name ELSE NULL END,
           due_date              = @due_date,
           detection_method_code = NULLIF(LTRIM(RTRIM(@detection_method_code)), N''),
           detection_method_name = NULLIF(LTRIM(RTRIM(@detection_method_name)), N''),
           updated_by            = @actor,
           updated_dt            = SYSUTCDATETIME()
     WHERE custom_gap_id = @custom_gap_id;

    -- Practice instances: retire what is no longer chosen (including a
    -- pre-388 practice-level row with no instance) ...
    UPDATE m
       SET record_status_id = @inactive_rs
      FROM grac_practice.custom_gap_practice_map m
     WHERE m.custom_gap_id = @custom_gap_id
       AND m.record_status_id = @active_rs
       AND (m.practice_instance_id IS NULL
            OR NOT EXISTS (SELECT 1 FROM @inst i WHERE i.practice_instance_id = m.practice_instance_id));

    -- ... add the new ones (388's procedure, unchanged) ...
    DECLARE @json NVARCHAR(MAX) =
        N'[' + (SELECT STRING_AGG(CAST(practice_instance_id AS NVARCHAR(20)), N',') FROM @inst) + N']';
    EXEC grac_practice.sp_custom_gap_practice_instance_set
         @custom_gap_id              = @custom_gap_id,
         @practice_instance_ids_json = @json,
         @actor_employee_id          = @actor_employee_id;

    -- ... and make every chosen one Active: one chosen again after it was
    -- removed, and one 388's procedure placed on a retired practice-level
    -- row it claimed.
    UPDATE m
       SET record_status_id = @active_rs,
           mapped_dt        = CASE WHEN m.record_status_id = @active_rs THEN m.mapped_dt ELSE SYSUTCDATETIME() END,
           mapped_by_employee_id = CASE WHEN m.record_status_id = @active_rs THEN m.mapped_by_employee_id
                                        ELSE @actor_employee_id END
      FROM grac_practice.custom_gap_practice_map m
      JOIN @inst i ON i.practice_instance_id = m.practice_instance_id
     WHERE m.custom_gap_id = @custom_gap_id;

    INSERT INTO grac_practice.custom_gap_history(
        custom_gap_id, organization_id, action_code,
        from_status_code, to_status_code,
        reason_text, actor_display_name, entered_by)
    VALUES(
        @custom_gap_id, @organization_id, N'EDIT',
        @status, @status, N'Gap edited.', @actor_name, @actor);

    COMMIT;

    SELECT @custom_gap_id AS CustomGapId;
END
GO

SELECT '495 sp_custom_gap_edit exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_custom_gap_edit','P') IS NOT NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_edit')) LIKE '%sp_custom_gap_practice_instance_set%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
PRINT '495 complete. Deploy API + Web next.';
GO

SET NOEXEC OFF;
GO
