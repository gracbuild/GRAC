-- =====================================================================
-- 428 rollback -- Asset Register core
--
--   * removes the Asset Register menu row and its grants;
--   * restores the 421 body of sp_asset_form_template_evaluate (copied
--     verbatim below) and drops the register procedures and the
--     functions fn_asset_form_evaluate, fn_asset_master_lookup and
--     fn_asset_stored_values;
--   * drops asset_field_value (every VALUE-stored field value is lost),
--     asset_field_validation_rule, asset_legacy_status_map and
--     asset_lifecycle_status_phase;
--   * drops the template_id / current_status_id / record_version columns
--     of organization_dependency_asset (assets, their COLUMN values and
--     the legacy lifecycle_status stay);
--   * removes the Asset creation rule. Asset statuses stay because the
--     immutable transition log references them (BACKFILL_428 rows).
-- practice_audit_trace rows are immutable and stay as history.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DELETE p FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'asset-register';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'asset-register';
PRINT '428 rollback: menu row removed.';
GO

-- 421 body, verbatim
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_evaluate
    @organization_id BIGINT,
    @template_id     BIGINT,
    @values_json     NVARCHAR(MAX) = N'{}'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template
                    WHERE template_id = @template_id AND organization_id = @organization_id)
        THROW 54202, 'Asset form template not found for this organization.', 1;
    IF ISJSON(ISNULL(@values_json, N'')) <> 1 SET @values_json = N'{}';

    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @raw TABLE (field_key NVARCHAR(100) NOT NULL, val NVARCHAR(MAX) NULL, val_type INT NOT NULL);
    INSERT @raw (field_key, val, val_type)
    SELECT j.[key], j.[value], j.[type] FROM OPENJSON(@values_json) j;

    DECLARE @elem TABLE (field_key NVARCHAR(100) NOT NULL, elem NVARCHAR(400) NOT NULL);
    INSERT @elem (field_key, elem)
    SELECT r.field_key, LEFT(LTRIM(RTRIM(a.[value])), 400)
      FROM @raw r CROSS APPLY OPENJSON(r.val) a
     WHERE r.val_type = 4 AND a.[value] IS NOT NULL AND LTRIM(RTRIM(a.[value])) <> N'';
    INSERT @elem (field_key, elem)
    SELECT r.field_key, LEFT(LTRIM(RTRIM(s.[value])), 400)
      FROM @raw r CROSS APPLY STRING_SPLIT(ISNULL(r.val, N''), N'|') s
     WHERE r.val_type IN (1, 2, 3) AND LTRIM(RTRIM(s.[value])) <> N'';

    -- One row per condition with its outcome.
    DECLARE @cond TABLE (rule_id BIGINT NOT NULL, group_no INT NOT NULL, ok INT NOT NULL);
    INSERT @cond (rule_id, group_no, ok)
    SELECT c.rule_id, c.group_no,
           CASE c.operator_code
             WHEN N'EQ'        THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e WHERE e.field_key = d.field_key AND e.elem = c.compare_value) THEN 1 ELSE 0 END
             WHEN N'NEQ'       THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e WHERE e.field_key = d.field_key AND e.elem = c.compare_value) THEN 0 ELSE 1 END
             WHEN N'IN'        THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e
                                                       JOIN STRING_SPLIT(ISNULL(c.compare_value, N''), N'|') l ON LTRIM(RTRIM(l.[value])) = e.elem
                                                      WHERE e.field_key = d.field_key) THEN 1 ELSE 0 END
             WHEN N'NOT_IN'    THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e
                                                       JOIN STRING_SPLIT(ISNULL(c.compare_value, N''), N'|') l ON LTRIM(RTRIM(l.[value])) = e.elem
                                                      WHERE e.field_key = d.field_key) THEN 0 ELSE 1 END
             WHEN N'EMPTY'     THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e WHERE e.field_key = d.field_key) THEN 0 ELSE 1 END
             WHEN N'NOT_EMPTY' THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e WHERE e.field_key = d.field_key) THEN 1 ELSE 0 END
             WHEN N'GT'  THEN CASE WHEN nv.num >  TRY_CONVERT(DECIMAL(38, 6), c.compare_value) THEN 1 ELSE 0 END
             WHEN N'GTE' THEN CASE WHEN nv.num >= TRY_CONVERT(DECIMAL(38, 6), c.compare_value) THEN 1 ELSE 0 END
             WHEN N'LT'  THEN CASE WHEN nv.num <  TRY_CONVERT(DECIMAL(38, 6), c.compare_value) THEN 1 ELSE 0 END
             WHEN N'LTE' THEN CASE WHEN nv.num <= TRY_CONVERT(DECIMAL(38, 6), c.compare_value) THEN 1 ELSE 0 END
             WHEN N'DATE_BEFORE_TODAY' THEN CASE WHEN nv.dt < @today THEN 1 ELSE 0 END
             WHEN N'DATE_AFTER_TODAY'  THEN CASE WHEN nv.dt > @today THEN 1 ELSE 0 END
             WHEN N'DATE_WITHIN_DAYS'  THEN CASE WHEN nv.dt >= @today
                                                  AND nv.dt <= DATEADD(DAY, ISNULL(TRY_CONVERT(INT, c.compare_value), 0), @today) THEN 1 ELSE 0 END
             ELSE 0 END
      FROM grac_practice.asset_form_template_rule r
      JOIN grac_practice.asset_form_template_rule_condition c ON c.rule_id = r.rule_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = c.source_field_definition_id
      OUTER APPLY (SELECT TOP (1) TRY_CONVERT(DECIMAL(38, 6), e.elem) AS num, TRY_CONVERT(DATE, e.elem) AS dt
                     FROM @elem e WHERE e.field_key = d.field_key) nv
     WHERE r.template_id = @template_id AND r.is_active = 1;

    -- A group holds when all its conditions hold; a rule when any group does.
    DECLARE @group TABLE (rule_id BIGINT NOT NULL, group_no INT NOT NULL, ok INT NOT NULL);
    INSERT @group (rule_id, group_no, ok)
    SELECT rule_id, group_no, MIN(ok) FROM @cond GROUP BY rule_id, group_no;

    DECLARE @rule TABLE (rule_id BIGINT PRIMARY KEY, ok INT NOT NULL);
    INSERT @rule (rule_id, ok)
    SELECT rule_id, MAX(ok) FROM @group GROUP BY rule_id;

    DECLARE @state TABLE (field_definition_id INT PRIMARY KEY, has_show INT NOT NULL, show_ok INT NOT NULL, require_ok INT NOT NULL,
                          fired NVARCHAR(MAX) NULL);
    INSERT @state (field_definition_id, has_show, show_ok, require_ok, fired)
    SELECT r.target_field_definition_id,
           MAX(CASE WHEN r.action_code IN (N'SHOW', N'SHOW_AND_REQUIRE') THEN 1 ELSE 0 END),
           MAX(CASE WHEN r.action_code IN (N'SHOW', N'SHOW_AND_REQUIRE') THEN x.ok ELSE 0 END),
           MAX(CASE WHEN r.action_code IN (N'REQUIRE', N'SHOW_AND_REQUIRE') THEN x.ok ELSE 0 END),
           STRING_AGG(CASE WHEN x.ok = 1 THEN r.rule_name END, N'; ')
      FROM grac_practice.asset_form_template_rule r
      JOIN @rule x ON x.rule_id = r.rule_id
     WHERE r.template_id = @template_id AND r.is_active = 1
     GROUP BY r.target_field_definition_id;

    SELECT f.field_definition_id AS FieldDefinitionId, d.field_key AS FieldKey, d.display_label AS DisplayLabel,
           f.section_id AS SectionId,
           eff.is_visible AS IsVisible,
           CASE WHEN eff.is_visible = 1 AND (f.is_mandatory = 1 OR ISNULL(s.require_ok, 0) = 1) THEN 1 ELSE 0 END AS IsMandatory,
           CASE WHEN ISNULL(s.has_show, 0) = 1 THEN 1 ELSE 0 END AS VisibilityByRule,
           s.fired AS RulesFired,
           CASE WHEN EXISTS (SELECT 1 FROM @raw v WHERE v.field_key = d.field_key) THEN 1 ELSE 0 END AS ValueSupplied
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.asset_form_template_section x ON x.section_id = f.section_id
      LEFT JOIN @state s ON s.field_definition_id = f.field_definition_id
      CROSS APPLY (SELECT CASE WHEN ISNULL(s.has_show, 0) = 1 THEN s.show_ok ELSE CAST(f.is_visible AS INT) END AS is_visible) eff
     WHERE f.template_id = @template_id
     ORDER BY x.display_order, f.display_order;
END
GO
PRINT '428 rollback: sp_asset_form_template_evaluate restored (421).';
GO

IF OBJECT_ID('grac_practice.sp_asset_register_save','P') IS NOT NULL    DROP PROCEDURE grac_practice.sp_asset_register_save;
IF OBJECT_ID('grac_practice.sp_asset_register_list','P') IS NOT NULL    DROP PROCEDURE grac_practice.sp_asset_register_list;
IF OBJECT_ID('grac_practice.sp_asset_register_get','P') IS NOT NULL     DROP PROCEDURE grac_practice.sp_asset_register_get;
IF OBJECT_ID('grac_practice.sp_asset_register_form','P') IS NOT NULL    DROP PROCEDURE grac_practice.sp_asset_register_form;
IF OBJECT_ID('grac_practice.sp_asset_register_lookups','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_asset_register_lookups;
IF OBJECT_ID('grac_practice.fn_asset_form_evaluate') IS NOT NULL        DROP FUNCTION grac_practice.fn_asset_form_evaluate;
IF OBJECT_ID('grac_practice.fn_asset_master_lookup') IS NOT NULL        DROP FUNCTION grac_practice.fn_asset_master_lookup;
IF OBJECT_ID('grac_practice.fn_asset_stored_values') IS NOT NULL        DROP FUNCTION grac_practice.fn_asset_stored_values;
PRINT '428 rollback: procedures and functions dropped.';
GO

IF OBJECT_ID('grac_practice.asset_field_value','U') IS NOT NULL            DROP TABLE grac_practice.asset_field_value;
IF OBJECT_ID('grac_practice.asset_field_validation_rule','U') IS NOT NULL  DROP TABLE grac_practice.asset_field_validation_rule;
IF OBJECT_ID('grac_practice.asset_legacy_status_map','U') IS NOT NULL      DROP TABLE grac_practice.asset_legacy_status_map;
IF OBJECT_ID('grac_practice.asset_lifecycle_status_phase','U') IS NOT NULL DROP TABLE grac_practice.asset_lifecycle_status_phase;
PRINT '428 rollback: tables dropped.';
GO

IF OBJECT_ID('grac_practice.fk_pm_org_asset_template') IS NOT NULL
    ALTER TABLE grac_practice.organization_dependency_asset DROP CONSTRAINT fk_pm_org_asset_template;
IF OBJECT_ID('grac_practice.fk_pm_org_asset_lifecycle_state') IS NOT NULL
    ALTER TABLE grac_practice.organization_dependency_asset DROP CONSTRAINT fk_pm_org_asset_lifecycle_state;
GO
IF COL_LENGTH('grac_practice.organization_dependency_asset','template_id') IS NOT NULL
    ALTER TABLE grac_practice.organization_dependency_asset DROP COLUMN template_id;
IF COL_LENGTH('grac_practice.organization_dependency_asset','current_status_id') IS NOT NULL
    ALTER TABLE grac_practice.organization_dependency_asset DROP COLUMN current_status_id;
IF COL_LENGTH('grac_practice.organization_dependency_asset','record_version') IS NOT NULL
    ALTER TABLE grac_practice.organization_dependency_asset DROP COLUMN record_version;
PRINT '428 rollback: asset columns dropped.';
GO

DELETE FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'Asset' AND from_status_code IS NULL AND to_status_code = N'DRAFT';
DELETE s FROM grac_practice.entity_status_master s
 WHERE s.entity_type = N'Asset'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_log l
                    WHERE l.from_status_id = s.entity_status_id OR l.to_status_id = s.entity_status_id);
PRINT '428 rollback: lifecycle rows removed where unreferenced.';
GO
