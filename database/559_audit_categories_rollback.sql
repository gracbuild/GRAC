-- =====================================================================
-- 559 ROLLBACK  Audit Categories
--
-- Puts back the 15 categories as they were on 2026-11-15 (ids, codes,
-- names, descriptions, display order, all Published / Active) and the 072
-- body of sp_org_assurance_admin_category_list.
--   * A category 559 deleted is re-inserted with its original id.
--   * A category 559 made inactive is made active again.
--   * The 5 categories 559 added are deleted when nothing uses them, or
--     made inactive when something does.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_new.assurance_category','U') IS NULL
BEGIN
    PRINT 'ABORT (559 rollback): grac_new.assurance_category not found. Nothing was changed.';
    RAISERROR('559_audit_categories_rollback: table missing.', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @now DATETIME2 = SYSUTCDATETIME();

    IF OBJECT_ID('tempdb..#orig559') IS NOT NULL DROP TABLE #orig559;
    CREATE TABLE #orig559 (
        assurance_category_id BIGINT        NOT NULL PRIMARY KEY,
        category_code         NVARCHAR(80)  NOT NULL,
        category_name         NVARCHAR(200) NOT NULL,
        description           NVARCHAR(400) NOT NULL,
        display_order         INT           NOT NULL
    );
    INSERT #orig559 VALUES
        ( 1, N'COMP_REVIEW',        N'Compliance Review',          N'Assurance over regulatory and internal compliance.', 4),
        ( 2, N'CONT_ASSURANCE',     N'Continuous Assurance',       N'Continuous or automated assurance monitoring.', 10),
        ( 3, N'CUSTOM',             N'Custom Assurance',           N'Custom assurance engagements not covered by other categories.', 15),
        ( 4, N'EVENT_DRIVEN',       N'Event Driven Assurance',     N'Assurance triggered by an event or trigger.', 11),
        ( 5, N'INT_AUDIT',          N'Internal Audit',             N'Standard internal audit engagements.', 1),
        ( 6, N'IS_AUDIT',           N'Information Systems Audit',  N'Assurance over IT systems, applications and controls.', 2),
        ( 7, N'MGMT_REVIEW',        N'Management Review',          N'Reviews commissioned by management for governance and performance.', 5),
        ( 8, N'OPS_REVIEW',         N'Operational Review',         N'Operational and process reviews.', 12),
        ( 9, N'PROC_AUDIT',         N'Process Audit',              N'Process audits with a defined scope.', 13),
        (10, N'RBIA',               N'Risk Based Internal Audit',  N'Risk based internal audit programs.', 3),
        (11, N'REG_INSPECTION',     N'Regulatory Inspection',      N'Inspections triggered by a regulator or supervisor.', 9),
        (12, N'SELF_ASSESS',        N'Self Assessment',            N'Control and process self assessments.', 6),
        (13, N'TECH_AUDIT',         N'Technology Audit',           N'Technology or infrastructure audits.', 14),
        (14, N'THIRD_PARTY_ASSESS', N'Third Party Assessment',     N'Broader third party risk and compliance assessments.', 8),
        (15, N'VENDOR_ASSESS',      N'Vendor Assessment',          N'Vendor and supplier assurance engagements.', 7);

    -- Rows still present: back to their original values, active.
    UPDATE c
       SET c.category_name    = o.category_name,
           c.description      = o.description,
           c.display_order    = o.display_order,
           c.is_active        = 1,
           c.status           = N'Active',
           c.lifecycle_status = N'Published',
           c.updated_by       = N'559_audit_categories_rollback',
           c.updated_dt       = @now
      FROM grac_new.assurance_category c
      JOIN #orig559 o ON o.category_code = c.category_code;

    -- Rows 559 deleted: back with their original ids.
    SET IDENTITY_INSERT grac_new.assurance_category ON;
    INSERT grac_new.assurance_category
        (assurance_category_id, category_code, category_name, description,
         lifecycle_status, is_active, status, display_order, entered_by, entered_dt)
    SELECT o.assurance_category_id, o.category_code, o.category_name, o.description,
           N'Published', 1, N'Active', o.display_order, N'system', @now
      FROM #orig559 o
     WHERE NOT EXISTS (SELECT 1 FROM grac_new.assurance_category c
                        WHERE c.category_code = o.category_code)
       AND NOT EXISTS (SELECT 1 FROM grac_new.assurance_category c
                        WHERE c.assurance_category_id = o.assurance_category_id);
    SET IDENTITY_INSERT grac_new.assurance_category OFF;

    -- The 5 categories 559 added: delete, or inactive when in use.
    IF OBJECT_ID('tempdb..#new559') IS NOT NULL DROP TABLE #new559;
    CREATE TABLE #new559 (assurance_category_id BIGINT NOT NULL PRIMARY KEY, in_use BIT NOT NULL DEFAULT 0);
    INSERT #new559 (assurance_category_id)
    SELECT c.assurance_category_id
      FROM grac_new.assurance_category c
     WHERE c.category_code IN (N'CYBER_AUDIT', N'COMP_AUDIT', N'OPS_AUDIT',
                               N'THIRD_PARTY_AUDIT', N'SPECIAL_INVESTIGATION');

    IF COL_LENGTH('grac_practice.org_assurance_definition_version','assurance_category_id') IS NOT NULL
        UPDATE n SET in_use = 1
          FROM #new559 n
         WHERE EXISTS (SELECT 1 FROM grac_practice.org_assurance_definition_version v
                        WHERE v.assurance_category_id = n.assurance_category_id);

    DECLARE @fk NVARCHAR(MAX) = N'';
    SELECT @fk = @fk + N'UPDATE n SET in_use = 1 FROM #new559 n WHERE EXISTS (SELECT 1 FROM '
               + QUOTENAME(OBJECT_SCHEMA_NAME(fkc.parent_object_id)) + N'.'
               + QUOTENAME(OBJECT_NAME(fkc.parent_object_id))
               + N' t WHERE t.' + QUOTENAME(COL_NAME(fkc.parent_object_id, fkc.parent_column_id))
               + N' = n.assurance_category_id);' + CHAR(10)
      FROM sys.foreign_key_columns fkc
     WHERE fkc.referenced_object_id = OBJECT_ID('grac_new.assurance_category');
    IF @fk <> N'' EXEC sp_executesql @fk;

    UPDATE c
       SET c.is_active = 0, c.status = N'Inactive',
           c.updated_by = N'559_audit_categories_rollback', c.updated_dt = @now
      FROM grac_new.assurance_category c
      JOIN #new559 n ON n.assurance_category_id = c.assurance_category_id
     WHERE n.in_use = 1;

    DELETE c
      FROM grac_new.assurance_category c
      JOIN #new559 n ON n.assurance_category_id = c.assurance_category_id
     WHERE n.in_use = 0;

    COMMIT TRANSACTION;
    PRINT '559 rollback: the 15 original categories are back.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    BEGIN TRY SET IDENTITY_INSERT grac_new.assurance_category OFF; END TRY BEGIN CATCH END CATCH;
    PRINT 'ABORT (559 rollback): ' + ERROR_MESSAGE() + ' Nothing was changed.';
    THROW;
END CATCH
GO

-- 072 body of the category list, as it was before 559.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_admin_category_list
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('grac_new.assurance_category','U') IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT)     AS Id,
               CAST(NULL AS NVARCHAR(120)) AS Code,
               CAST(NULL AS NVARCHAR(200)) AS Name,
               CAST(NULL AS NVARCHAR(1000)) AS Description
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @tbl_id INT = OBJECT_ID('grac_new.assurance_category');
    DECLARE @id_col NVARCHAR(128), @code_col NVARCHAR(128),
            @name_col NVARCHAR(128), @desc_col NVARCHAR(128),
            @status_col NVARCHAR(128);

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @id_col = name FROM candidates
    WHERE name IN (N'assurance_category_id', N'category_id', N'id')
    ORDER BY CASE name
        WHEN N'assurance_category_id' THEN 1
        WHEN N'category_id'           THEN 2
        WHEN N'id'                    THEN 3
        ELSE 99 END;

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @code_col = name FROM candidates
    WHERE name IN (N'assurance_category_code', N'category_code', N'code')
    ORDER BY CASE name
        WHEN N'assurance_category_code' THEN 1
        WHEN N'category_code'           THEN 2
        WHEN N'code'                    THEN 3
        ELSE 99 END;

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @name_col = name FROM candidates
    WHERE name IN (N'assurance_category_name', N'category_name', N'name',
                   N'label', N'display_name')
    ORDER BY CASE name
        WHEN N'assurance_category_name' THEN 1
        WHEN N'category_name'           THEN 2
        WHEN N'name'                    THEN 3
        WHEN N'label'                   THEN 4
        WHEN N'display_name'            THEN 5
        ELSE 99 END;

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @desc_col = name FROM candidates
    WHERE name IN (N'description', N'notes', N'remarks');

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @status_col = name FROM candidates
    WHERE name IN (N'status', N'is_active', N'active_flag');

    IF @id_col IS NULL OR @name_col IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT)     AS Id,
               CAST(NULL AS NVARCHAR(120)) AS Code,
               CAST(NULL AS NVARCHAR(200)) AS Name,
               CAST(NULL AS NVARCHAR(1000)) AS Description
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @sql NVARCHAR(MAX) = N'
        SELECT ' + QUOTENAME(@id_col) + N' AS Id,
               ' + COALESCE(QUOTENAME(@code_col), N'CAST(NULL AS NVARCHAR(120))') + N' AS Code,
               ' + QUOTENAME(@name_col) + N' AS Name,
               ' + COALESCE(QUOTENAME(@desc_col), N'CAST(NULL AS NVARCHAR(1000))') + N' AS Description
        FROM grac_new.assurance_category';

    IF @status_col = N'status'
        SET @sql = @sql + N' WHERE ' + QUOTENAME(@status_col) + N' = N''Active''';
    ELSE IF @status_col IN (N'is_active', N'active_flag')
        SET @sql = @sql + N' WHERE ' + QUOTENAME(@status_col) + N' = 1';

    SET @sql = @sql + N' ORDER BY ' + QUOTENAME(@name_col) + N';';

    EXEC sp_executesql @sql;
END
GO

PRINT '559 rollback: sp_org_assurance_admin_category_list back to 072.';
GO
SET NOEXEC OFF;
GO
