-- =====================================================================
-- Diagnostic script for the empty SLA Master dropdown
--
-- Purpose:
--   The "Adopt SLA" dialog is showing an empty dropdown -- only the
--   placeholder "-- pick an SLA master --". This can mean any of:
--
--     A. Migrations 178 / 179 / 180 have not been deployed yet.
--     B. `grac_new.sla_master` does not exist (Control Management side).
--     C. `grac_new.sla_master` exists but its column names do not
--        match the candidates in sp_ctrl_sla_master_list (179).
--     D. `grac_new.sla_master` exists but has no active rows.
--     E. `grac_new.sla_master` exists but the status column drops
--        every row (e.g. status = 'Draft' when we filter to 'Active').
--
-- Run this script against the same database the API tier uses. Copy
-- ALL result-set outputs back into chat -- I will use them to either
-- (a) confirm you need to run the migrations, or (b) expand
-- sp_ctrl_sla_master_list's defensive column discovery to cover the
-- names your Control Management schema actually uses.
--
-- Read-only. Safe to run any number of times.
-- =====================================================================
SET NOCOUNT ON;
PRINT '===== Section 1 =====';
PRINT 'Are migrations 178 / 179 / 180 deployed?';

SELECT
    CASE WHEN OBJECT_ID('grac_practice.org_sla_config','U')             IS NOT NULL THEN 'YES' ELSE 'NO' END AS SchemaTable_org_sla_config,
    CASE WHEN OBJECT_ID('grac_practice.org_sla_config_notify_role','U') IS NOT NULL THEN 'YES' ELSE 'NO' END AS SchemaTable_notify_role,
    CASE WHEN OBJECT_ID('grac_practice.org_sla_process_binding','U')    IS NOT NULL THEN 'YES' ELSE 'NO' END AS SchemaTable_process_binding,
    CASE WHEN OBJECT_ID('grac_practice.sla_process_type_master','U')    IS NOT NULL THEN 'YES' ELSE 'NO' END AS SchemaTable_process_type_master,
    CASE WHEN OBJECT_ID('grac_practice.sp_ctrl_sla_master_list','P')    IS NOT NULL THEN 'YES' ELSE 'NO' END AS Proc_sp_ctrl_sla_master_list,
    CASE WHEN OBJECT_ID('grac_practice.sp_org_sla_config_upsert','P')   IS NOT NULL THEN 'YES' ELSE 'NO' END AS Proc_sp_org_sla_config_upsert,
    CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-sla-config') THEN 'YES' ELSE 'NO' END AS Menu_org_sla_config,
    CASE WHEN EXISTS (SELECT 1 FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.org-sla-config') THEN 'YES' ELSE 'NO' END AS Feature_flag_master_row;

-- If any of the above is NO, the corresponding migration file is
-- unapplied. Run these against the DB in order (each in its own batch):
--   database/178_org_sla_config_schema.sql
--   database/179_org_sla_config_procs.sql
--   database/180_org_sla_config_menu_seed.sql

PRINT '';
PRINT '===== Section 2 =====';
PRINT 'Does grac_new.sla_master exist? If yes, what columns does it have?';

IF OBJECT_ID('grac_new.sla_master','U') IS NULL
BEGIN
    SELECT 'grac_new.sla_master DOES NOT EXIST' AS Diagnosis,
           'Either the SLA master lives under a different schema/table name, or Control Management has not yet created it in this database.' AS NextStep;
END
ELSE
BEGIN
    SELECT 'grac_new.sla_master EXISTS' AS Diagnosis;

    -- Full column list. Copy back to chat so we can expand the
    -- defensive discovery if needed.
    SELECT
        c.column_id                 AS Ordinal,
        c.name                      AS ColumnName,
        t.name                      AS DataType,
        c.max_length                AS MaxLength,
        c.is_nullable               AS IsNullable
    FROM sys.columns c
    JOIN sys.types   t ON t.user_type_id = c.user_type_id
    WHERE c.object_id = OBJECT_ID('grac_new.sla_master')
    ORDER BY c.column_id;

    -- What our defensive discovery FOUND (mirrors sp_ctrl_sla_master_list).
    DECLARE @tbl_id INT = OBJECT_ID('grac_new.sla_master');
    DECLARE @id_col NVARCHAR(128), @code_col NVARCHAR(128),
            @name_col NVARCHAR(128), @desc_col NVARCHAR(128),
            @days_col NVARCHAR(128), @status_col NVARCHAR(128);

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @id_col = name FROM candidates
    WHERE name IN (N'sla_master_id', N'sla_id', N'id')
    ORDER BY CASE name WHEN N'sla_master_id' THEN 1 WHEN N'sla_id' THEN 2 WHEN N'id' THEN 3 ELSE 99 END;

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @code_col = name FROM candidates
    WHERE name IN (N'sla_master_code', N'sla_code', N'code');

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @name_col = name FROM candidates
    WHERE name IN (N'sla_master_name', N'sla_name', N'name', N'label', N'display_name');

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @desc_col = name FROM candidates
    WHERE name IN (N'description', N'notes', N'remarks');

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @days_col = name FROM candidates
    WHERE name IN (N'total_sla_days', N'sla_days', N'target_days', N'duration_days');

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @status_col = name FROM candidates
    WHERE name IN (N'status', N'is_active', N'active_flag');

    SELECT
        ISNULL(@id_col,     '(NOT FOUND -- discovery fails, dropdown empty)') AS Discovered_IdCol,
        ISNULL(@code_col,   '(not found -- optional)')                        AS Discovered_CodeCol,
        ISNULL(@name_col,   '(NOT FOUND -- discovery fails, dropdown empty)') AS Discovered_NameCol,
        ISNULL(@desc_col,   '(not found -- optional)')                        AS Discovered_DescCol,
        ISNULL(@days_col,   '(not found -- optional)')                        AS Discovered_DaysCol,
        ISNULL(@status_col, '(none -- no filter applied)')                    AS Discovered_StatusCol;

    -- Row counts.
    DECLARE @sql NVARCHAR(MAX) = N'SELECT COUNT(*) AS TotalRows FROM grac_new.sla_master;';
    EXEC sp_executesql @sql;

    IF @status_col IS NOT NULL
    BEGIN
        IF @status_col = N'status'
            SET @sql = N'SELECT COUNT(*) AS ActiveRows_by_status FROM grac_new.sla_master WHERE ' + QUOTENAME(@status_col) + N' = N''Active'';';
        ELSE
            SET @sql = N'SELECT COUNT(*) AS ActiveRows_by_flag   FROM grac_new.sla_master WHERE ' + QUOTENAME(@status_col) + N' = 1;';
        EXEC sp_executesql @sql;
    END
END

PRINT '';
PRINT '===== Section 3 =====';
PRINT 'What does sp_ctrl_sla_master_list actually return?';

IF OBJECT_ID('grac_practice.sp_ctrl_sla_master_list','P') IS NULL
BEGIN
    SELECT 'sp_ctrl_sla_master_list DOES NOT EXIST' AS Diagnosis,
           'Deploy 179_org_sla_config_procs.sql first.' AS NextStep;
END
ELSE
BEGIN
    EXEC grac_practice.sp_ctrl_sla_master_list;
    -- If this comes back empty AND Section 2 shows "NOT FOUND" for
    -- IdCol or NameCol, share the ColumnName list back and I will
    -- expand the candidate list in sp_ctrl_sla_master_list to match.
END

PRINT '';
PRINT '===== Diagnostic complete =====';
