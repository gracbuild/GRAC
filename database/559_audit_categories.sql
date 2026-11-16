-- =====================================================================
-- 559  Audit Categories -- the category list replaced
--
-- REQUEST (2026-11-15, sir): remove the current audit categories and
--   use this list, in this order:
--     Internal Audit, Information Systems Audit, Cybersecurity Audit,
--     Compliance Audit, Operational Audit, Process Audit, Regulatory
--     Inspection, Third-Party Audit, Self Assessment, Management Review,
--     Special Investigation.
--
-- WHERE THE LIST LIVES
--   grac_new.assurance_category (the Admin master). It feeds the "Audit
--   Category" dropdown on Audit Definitions through
--   grac_practice.sp_org_assurance_admin_category_list (072).
--
-- WHAT THIS DOES
--   1. The 11 categories, matched on category_code:
--        * a code that already exists keeps its row (and id), and gets the
--          new name, display order, Published / Active;
--        * the 5 new ones are inserted.
--      Kept rows: INT_AUDIT, IS_AUDIT, PROC_AUDIT, REG_INSPECTION,
--      SELF_ASSESS, MGMT_REVIEW. New rows: CYBER_AUDIT, COMP_AUDIT,
--      OPS_AUDIT, THIRD_PARTY_AUDIT, SPECIAL_INVESTIGATION.
--   2. Every other category is removed:
--        * DELETED when nothing uses it;
--        * made INACTIVE (is_active = 0, status 'Inactive') when a foreign
--          key points at it (e.g. grac_new.assurance_starter_template) or an
--          audit definition version carries its id. A delete would fail on
--          the foreign key, and an inactive row keeps old audits readable.
--      It no longer appears in the dropdown either way.
--   3. sp_org_assurance_admin_category_list re-issued (072 body):
--        * lists a row only when it is active on BOTH is_active and status
--          (072 picked one of the two columns, not reliably the same one);
--        * sorts by display_order, then name (072 sorted by name only), so
--          the dropdown follows the order above.
--
-- AUDIT DEFINITIONS ALREADY SAVED
--   A definition keeps the category name it was saved with (soft copy on
--   org_assurance_definition_version), so the list still shows it. When
--   such a definition is edited, its retired category is not in the
--   dropdown; pick one of the new categories before saving.
--
-- Rollback: 559_audit_categories_rollback.sql (restores the 15 categories
--   as they were on 2026-11-15 and the 072 procedure).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_new.assurance_category','U') IS NULL
   OR COL_LENGTH('grac_new.assurance_category','category_code')    IS NULL
   OR COL_LENGTH('grac_new.assurance_category','category_name')    IS NULL
   OR COL_LENGTH('grac_new.assurance_category','display_order')    IS NULL
   OR COL_LENGTH('grac_new.assurance_category','is_active')        IS NULL
   OR COL_LENGTH('grac_new.assurance_category','status')           IS NULL
   OR COL_LENGTH('grac_new.assurance_category','lifecycle_status') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_definition_version','assurance_category_id') IS NULL
BEGIN
    PRINT 'ABORT (559): grac_new.assurance_category (or its columns) not found. Nothing was changed.';
    RAISERROR('559_audit_categories: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1 + 2. The category rows
-- ---------------------------------------------------------------------
BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @now DATETIME2 = SYSUTCDATETIME();

    IF OBJECT_ID('tempdb..#cat559') IS NOT NULL DROP TABLE #cat559;
    CREATE TABLE #cat559 (
        category_code NVARCHAR(80)  NOT NULL PRIMARY KEY,
        category_name NVARCHAR(200) NOT NULL,
        description   NVARCHAR(400) NOT NULL,
        display_order INT           NOT NULL
    );
    INSERT #cat559 (category_code, category_name, description, display_order) VALUES
        (N'INT_AUDIT',             N'Internal Audit',            N'Standard internal audit engagements.', 1),
        (N'IS_AUDIT',              N'Information Systems Audit', N'Assurance over IT systems, applications and controls.', 2),
        (N'CYBER_AUDIT',           N'Cybersecurity Audit',       N'Assurance over cybersecurity controls and posture.', 3),
        (N'COMP_AUDIT',            N'Compliance Audit',          N'Assurance over regulatory and internal compliance.', 4),
        (N'OPS_AUDIT',             N'Operational Audit',         N'Audits of operations for effectiveness and efficiency.', 5),
        (N'PROC_AUDIT',            N'Process Audit',             N'Process audits with a defined scope.', 6),
        (N'REG_INSPECTION',        N'Regulatory Inspection',     N'Inspections triggered by a regulator or supervisor.', 7),
        (N'THIRD_PARTY_AUDIT',     N'Third-Party Audit',         N'Audits of vendors, suppliers and other third parties.', 8),
        (N'SELF_ASSESS',           N'Self Assessment',           N'Control and process self assessments.', 9),
        (N'MGMT_REVIEW',           N'Management Review',         N'Reviews commissioned by management for governance and performance.', 10),
        (N'SPECIAL_INVESTIGATION', N'Special Investigation',     N'Investigations into a specific incident, allegation or concern.', 11);

    -- 1a. Existing codes: keep the row, set name / order / active.
    UPDATE c
       SET c.category_name    = n.category_name,
           c.display_order    = n.display_order,
           c.is_active        = 1,
           c.status           = N'Active',
           c.lifecycle_status = N'Published',
           c.updated_by       = N'559_audit_categories',
           c.updated_dt       = @now
      FROM grac_new.assurance_category c
      JOIN #cat559 n ON n.category_code = c.category_code;

    -- 1b. New codes.
    INSERT grac_new.assurance_category
        (category_code, category_name, description, lifecycle_status,
         is_active, status, display_order, entered_by, entered_dt)
    SELECT n.category_code, n.category_name, n.description, N'Published',
           1, N'Active', n.display_order, N'559_audit_categories', @now
      FROM #cat559 n
     WHERE NOT EXISTS (SELECT 1 FROM grac_new.assurance_category c
                        WHERE c.category_code = n.category_code);

    -- 2. Every category not in the list: in use -> inactive, else delete.
    IF OBJECT_ID('tempdb..#old559') IS NOT NULL DROP TABLE #old559;
    CREATE TABLE #old559 (assurance_category_id BIGINT NOT NULL PRIMARY KEY, in_use BIT NOT NULL DEFAULT 0);

    INSERT #old559 (assurance_category_id)
    SELECT c.assurance_category_id
      FROM grac_new.assurance_category c
     WHERE NOT EXISTS (SELECT 1 FROM #cat559 n WHERE n.category_code = c.category_code);

    -- used by an audit definition version (soft reference)
    UPDATE o SET in_use = 1
      FROM #old559 o
     WHERE EXISTS (SELECT 1 FROM grac_practice.org_assurance_definition_version v
                    WHERE v.assurance_category_id = o.assurance_category_id);

    -- used through any foreign key (e.g. grac_new.assurance_starter_template)
    DECLARE @fk NVARCHAR(MAX) = N'';
    SELECT @fk = @fk + N'UPDATE o SET in_use = 1 FROM #old559 o WHERE EXISTS (SELECT 1 FROM '
               + QUOTENAME(OBJECT_SCHEMA_NAME(fkc.parent_object_id)) + N'.'
               + QUOTENAME(OBJECT_NAME(fkc.parent_object_id))
               + N' t WHERE t.' + QUOTENAME(COL_NAME(fkc.parent_object_id, fkc.parent_column_id))
               + N' = o.assurance_category_id);' + CHAR(10)
      FROM sys.foreign_key_columns fkc
     WHERE fkc.referenced_object_id = OBJECT_ID('grac_new.assurance_category');
    IF @fk <> N'' EXEC sp_executesql @fk;

    DECLARE @inactive INT, @deleted INT;

    UPDATE c
       SET c.is_active  = 0,
           c.status     = N'Inactive',
           c.updated_by = N'559_audit_categories',
           c.updated_dt = @now
      FROM grac_new.assurance_category c
      JOIN #old559 o ON o.assurance_category_id = c.assurance_category_id
     WHERE o.in_use = 1;
    SET @inactive = @@ROWCOUNT;

    DELETE c
      FROM grac_new.assurance_category c
      JOIN #old559 o ON o.assurance_category_id = c.assurance_category_id
     WHERE o.in_use = 0;
    SET @deleted = @@ROWCOUNT;

    COMMIT TRANSACTION;

    PRINT '559: 11 audit categories in place; ' + CAST(@deleted AS VARCHAR(10))
        + ' old categories deleted, ' + CAST(@inactive AS VARCHAR(10))
        + ' made inactive (still in use).';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'ABORT (559): ' + ERROR_MESSAGE() + ' Nothing was changed.';
    THROW;
END CATCH
GO

-- ---------------------------------------------------------------------
-- 3. Category list for the dropdown (072 body; active on both columns,
--    ordered by display_order)
-- ---------------------------------------------------------------------
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
            @name_col NVARCHAR(128), @desc_col NVARCHAR(128);

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
        FROM grac_new.assurance_category
        WHERE 1 = 1';

    -- 559: active on every active column the table has (072 used only one).
    IF COL_LENGTH('grac_new.assurance_category','status') IS NOT NULL
        SET @sql = @sql + N' AND [status] = N''Active''';
    IF COL_LENGTH('grac_new.assurance_category','is_active') IS NOT NULL
        SET @sql = @sql + N' AND [is_active] = 1';
    IF COL_LENGTH('grac_new.assurance_category','active_flag') IS NOT NULL
        SET @sql = @sql + N' AND [active_flag] = 1';

    -- 559: the order set in display_order, then the name.
    IF COL_LENGTH('grac_new.assurance_category','display_order') IS NOT NULL
        SET @sql = @sql + N' ORDER BY [display_order], ' + QUOTENAME(@name_col) + N';';
    ELSE
        SET @sql = @sql + N' ORDER BY ' + QUOTENAME(@name_col) + N';';

    EXEC sp_executesql @sql;
END
GO

PRINT '559 sp_org_assurance_admin_category_list re-issued (active on both columns, display order).';
GO
SET NOEXEC OFF;
GO
