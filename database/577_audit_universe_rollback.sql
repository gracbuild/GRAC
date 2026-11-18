-- 577 rollback  Audit Intelligence -- Audit Universe
-- Drops the Audit Universe procedures and functions; sets the Audit
-- Intelligence, Audit Universe and Universe Configuration menus Inactive;
-- sets the HEAD_INTERNAL_AUDIT responsibility inactive. Kept: the tables
-- (masters, subjects, registry links, exclusions, relationships, history)
-- with their data, and the roles' responsibility rows.
SET NOCOUNT ON;
GO
UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = 'rollback-577', updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'nav-audit-intelligence', N'org-audit-universe', N'org-audit-universe-config');
GO
UPDATE grac_practice.role_responsibility_master
   SET is_active = 0
 WHERE responsibility_code = N'HEAD_INTERNAL_AUDIT';
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_history_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_history_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_relationship_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_relationship_save;
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_action','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_action;
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_save;
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_get','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_get;
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_lookups','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_lookups;
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_discover_apply','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_discover_apply;
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_discover','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_discover;
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_master_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_master_save;
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_master_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_master_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_universe_master_seed','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_universe_master_seed;
IF OBJECT_ID('grac_practice.fn_org_assurance_universe_kind_label') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_universe_kind_label;
IF OBJECT_ID('grac_practice.fn_org_assurance_universe_registry_records') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_universe_registry_records;
GO
PRINT '577 rolled back: Audit Universe procedures dropped; menus Inactive; HEAD_INTERNAL_AUDIT inactive; tables kept.';
GO
