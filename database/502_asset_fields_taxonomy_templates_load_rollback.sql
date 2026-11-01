-- =====================================================================
-- 502_asset_fields_taxonomy_templates_load_rollback.sql
--
-- Undoes what 502 INSERTED. Read the limits first -- a data load is not
-- a schema change and this cannot put back data 502 replaced.
--
-- WHAT IT DOES
--   1. Deletes every asset form template, section, field and rule for
--      the organizations in scope (all of them by default).
--   2. Deletes the 318 asset types / 52 subcategories / 11 categories
--      502 added, by code, and only when nothing references them.
--      Anything referenced is left in place as is_active = 0.
--   3. Re-activates the taxonomy 502 deactivated (the 240 seed values).
--   4. Deletes the 270 field definitions 502 inserted and reseeds the
--      identity.
--
-- WHAT IT CANNOT DO
--   * The field dictionary that 502 replaced is NOT restored here.
--     Re-run database/420_asset_form_templates.sql afterwards: its
--     dictionary seed is insert-only on field_key, so it rebuilds the
--     270 definitions 420 shipped.
--   * Form templates that existed before 502 are gone for good -- 502
--     deleted them, as asked, and no copy was kept.
--   * asset_field_value rows are not restored. They are only ever
--     touched when 502 is run with @force_delete_asset_values = 1.
--
-- ONE TRANSACTION. ASCII-only. Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @organization_id BIGINT = NULL;   -- NULL = every organization
DECLARE @actor NVARCHAR(100) = N'rollback-502';
DECLARE @now DATETIME2 = SYSUTCDATETIME();

IF OBJECT_ID('grac_practice.asset_form_template','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_field_definition','U') IS NULL
BEGIN
    RAISERROR('ABORT (502 rollback): the 420 tables are not present.', 16, 1);
    RETURN;
END

-- The asset type codes 502 loaded are exactly those entered or updated
-- by load-502; nothing else is touched.
BEGIN TRAN;

-- ---- 1. templates --------------------------------------------------
UPDATE grac_practice.asset_form_template
   SET source_template_id = NULL
 WHERE source_template_id IS NOT NULL
   AND (@organization_id IS NULL OR organization_id = @organization_id);

IF OBJECT_ID('grac_practice.asset_form_template_rule_condition','U') IS NOT NULL
    DELETE c FROM grac_practice.asset_form_template_rule_condition c
    JOIN grac_practice.asset_form_template_rule r ON r.rule_id = c.rule_id
    JOIN grac_practice.asset_form_template t ON t.template_id = r.template_id
    WHERE (@organization_id IS NULL OR t.organization_id = @organization_id);

IF OBJECT_ID('grac_practice.asset_form_template_rule','U') IS NOT NULL
    DELETE r FROM grac_practice.asset_form_template_rule r
    JOIN grac_practice.asset_form_template t ON t.template_id = r.template_id
    WHERE (@organization_id IS NULL OR t.organization_id = @organization_id);

DELETE f FROM grac_practice.asset_form_template_field f
JOIN grac_practice.asset_form_template t ON t.template_id = f.template_id
WHERE (@organization_id IS NULL OR t.organization_id = @organization_id);

DELETE s FROM grac_practice.asset_form_template_section s
JOIN grac_practice.asset_form_template t ON t.template_id = s.template_id
WHERE (@organization_id IS NULL OR t.organization_id = @organization_id);

DELETE FROM grac_practice.asset_form_template
WHERE (@organization_id IS NULL OR organization_id = @organization_id);
PRINT CONCAT('502 rollback: templates removed: ', @@ROWCOUNT);

-- ---- 2. the taxonomy 502 added, where nothing points at it ---------
-- Referenced rows are kept, deactivated, rather than failing the whole
-- rollback on a foreign key.
UPDATE grac_practice.dependency_asset_type_master
   SET is_active = 0, updated_by = @actor, updated_dt = @now
 WHERE (entered_by = N'load-502' OR updated_by = N'load-502');

DELETE t FROM grac_practice.dependency_asset_type_master t
WHERE (t.entered_by = N'load-502')
  AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a WHERE a.asset_type_id = t.asset_type_id)
  AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template x WHERE x.asset_type_id = t.asset_type_id);
PRINT CONCAT('502 rollback: asset types deleted: ', @@ROWCOUNT);

DELETE s FROM grac_practice.dependency_asset_subcategory_master s
WHERE (s.entered_by = N'load-502')
  AND NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_type_master t WHERE t.subcategory_id = s.subcategory_id);
PRINT CONCAT('502 rollback: subcategories deleted: ', @@ROWCOUNT);

DELETE c FROM grac_practice.dependency_asset_category_master c
WHERE (c.entered_by = N'load-502')
  AND NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_subcategory_master s WHERE s.asset_category_id = c.asset_category_id);
PRINT CONCAT('502 rollback: categories deleted: ', @@ROWCOUNT);

-- ---- 3. bring the pre-502 taxonomy back into the pickers -----------
UPDATE grac_practice.dependency_asset_category_master
   SET is_active = 1, updated_by = @actor, updated_dt = @now
 WHERE entered_by <> N'load-502' AND is_active = 0;
UPDATE grac_practice.dependency_asset_subcategory_master
   SET is_active = 1, updated_by = @actor, updated_dt = @now
 WHERE entered_by <> N'load-502' AND is_active = 0;
UPDATE grac_practice.dependency_asset_type_master
   SET is_active = 1, updated_by = @actor, updated_dt = @now
 WHERE entered_by <> N'load-502' AND is_active = 0;
PRINT '502 rollback: the pre-502 taxonomy is active again.';

-- ---- 4. the field dictionary 502 inserted --------------------------
DELETE FROM grac_practice.asset_field_definition WHERE entered_by = N'load-502';
PRINT CONCAT('502 rollback: field definitions deleted: ', @@ROWCOUNT);
DBCC CHECKIDENT ('grac_practice.asset_field_definition', RESEED, 0) WITH NO_INFOMSGS;

COMMIT;

PRINT '--- 502 rollback verification ---';
SELECT (SELECT COUNT(*) FROM grac_practice.asset_field_definition WHERE entered_by = N'load-502') AS load_502_field_definitions,
       (SELECT COUNT(*) FROM grac_practice.asset_field_definition)                                AS field_definitions_left,
       (SELECT COUNT(*) FROM grac_practice.asset_form_template)                                   AS templates_left,
       (SELECT COUNT(*) FROM grac_practice.dependency_asset_type_master WHERE entered_by = N'load-502' AND is_active = 1) AS load_502_types_still_active;
-- load_502_* must be 0. If field_definitions_left is 0, re-run
-- database/420_asset_form_templates.sql to rebuild the 420 dictionary.
PRINT '502 rollback: done.';
GO
