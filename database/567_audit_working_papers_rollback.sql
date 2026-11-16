-- 567 rollback  Test Working Papers
-- Restores sp_org_assurance_execution_transition (099 body: Submit no
-- longer needs the working papers); drops the working paper procedures and
-- functions; sets the Workpapers menu Inactive and Observations back to 470.
-- Kept: the tables (questions, working papers, activity, masters) and the
-- new execution / observation columns, with their data. The 558 answers
-- were never changed.
SET NOCOUNT ON;
GO

UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = 'rollback-567', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-workpapers';
UPDATE grac_practice.menu_master
   SET display_order = 470, updated_by = 'rollback-567', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-assurance-observations';
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_observation_finding_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_observation_finding_save;
IF OBJECT_ID('grac_practice.sp_org_assurance_observation_finding_get','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_observation_finding_get;
IF OBJECT_ID('grac_practice.sp_org_assurance_wp_raise_finding','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_wp_raise_finding;
IF OBJECT_ID('grac_practice.sp_org_assurance_execution_conclusion_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_execution_conclusion_save;
IF OBJECT_ID('grac_practice.sp_org_assurance_wp_question_conclude','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_wp_question_conclude;
IF OBJECT_ID('grac_practice.sp_org_assurance_working_paper_action','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_working_paper_action;
IF OBJECT_ID('grac_practice.sp_org_assurance_working_paper_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_working_paper_save;
IF OBJECT_ID('grac_practice.sp_org_assurance_wp_question_assign','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_wp_question_assign;
IF OBJECT_ID('grac_practice.sp_org_assurance_wp_activity_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_wp_activity_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_wp_overview','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_wp_overview;
IF OBJECT_ID('grac_practice.sp_org_assurance_wp_execution_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_wp_execution_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_execution_score_refresh','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_execution_score_refresh;
IF OBJECT_ID('grac_practice.sp_org_assurance_wp_question_sync','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_wp_question_sync;
IF OBJECT_ID('grac_practice.sp_org_assurance_wp_log','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_wp_log;
IF OBJECT_ID('grac_practice.sp_org_assurance_observation_origin_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_observation_origin_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_testing_method_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_testing_method_list;
IF OBJECT_ID('grac_practice.fn_org_assurance_wp_question_state') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_wp_question_state;
IF OBJECT_ID('grac_practice.fn_org_assurance_wp_roles') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_wp_roles;
GO

-- sp_org_assurance_execution_transition: 099 body
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_transition
    @organization_id     BIGINT,
    @execution_id        BIGINT,
    @expected_from_codes NVARCHAR(200),  -- comma-separated allowed source codes
    @to_code             NVARCHAR(60),
    @stamp_start         BIT           = 0,
    @stamp_end           BIT           = 0,
    @actor               NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @execution_id IS NULL
        THROW 54009, 'organization_id and execution_id are required.', 1;

    DECLARE @to_id INT, @current_code NVARCHAR(60), @exec_org BIGINT;

    SELECT @to_id = org_assurance_execution_status_id
    FROM grac_practice.org_assurance_execution_status_master
    WHERE status_code = @to_code;
    IF @to_id IS NULL
        THROW 54025, 'Unknown target status_code in execution transition.', 1;

    SELECT @exec_org      = e.organization_id,
           @current_code  = s.status_code
    FROM grac_practice.org_assurance_execution e
    JOIN grac_practice.org_assurance_execution_status_master s
         ON s.org_assurance_execution_status_id = e.execution_status_id
    WHERE e.org_assurance_execution_id = @execution_id
      AND e.is_active = 1;

    IF @exec_org IS NULL      THROW 54010, 'Execution not found or not accessible in this organization.', 1;
    IF @exec_org <> @organization_id
        THROW 54010, 'Execution not found or not accessible in this organization.', 1;

    -- Split expected_from into rows.
    DECLARE @allowed TABLE(code NVARCHAR(60));
    INSERT INTO @allowed(code)
    SELECT LTRIM(RTRIM(value))
    FROM STRING_SPLIT(@expected_from_codes, ',')
    WHERE LTRIM(RTRIM(value)) <> '';

    IF NOT EXISTS (SELECT 1 FROM @allowed WHERE code = @current_code)
        THROW 54026, 'Illegal execution lifecycle transition -- current status does not match the expected source.', 1;

    UPDATE grac_practice.org_assurance_execution
    SET execution_status_id = @to_id,
        actual_start_dt     = CASE
            WHEN @stamp_start = 1 AND actual_start_dt IS NULL
            THEN SYSUTCDATETIME() ELSE actual_start_dt END,
        actual_end_dt       = CASE
            WHEN @stamp_end = 1 AND actual_end_dt IS NULL
            THEN SYSUTCDATETIME() ELSE actual_end_dt END,
        updated_by          = @actor,
        updated_dt          = SYSUTCDATETIME()
    WHERE org_assurance_execution_id = @execution_id;
END
GO

PRINT '567 rolled back: the transition back to 099; working paper procedures and functions dropped; Workpapers menu Inactive, Observations back to 470; tables and columns kept (the working papers stay as data).';
GO
