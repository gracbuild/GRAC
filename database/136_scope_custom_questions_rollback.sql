-- =====================================================================
-- 136 Scope custom questions -- ROLLBACK
--
-- Drops the three procedures and the ownership columns on checklist.
--
-- The scope-managed CHECKLISTS AND THEIR QUESTIONS ARE KEPT. They are real
-- questions somebody wrote, some of them already answered on raised
-- checklists, and their event_checklist_mapping rows still fire. What is
-- lost is only the ability to find and edit them from the role / category
-- form -- after this they behave like any hand-authored checklist and are
-- maintained on the Checklists screen.
--
-- The report below names them, since after the columns are dropped there is
-- no longer anything marking them as form-managed.
-- =====================================================================
SET NOCOUNT ON;
GO

PRINT '--- Scope-managed checklists that become ordinary checklists ---';
IF COL_LENGTH('grac_practice.checklist','is_scope_managed') IS NOT NULL
    EXEC('SELECT c.organization_id, c.checklist_id, c.checklist_code, c.checklist_name,
                 c.scope_dimension, c.scope_role_id, c.scope_asset_category_id, c.event_type_code,
                 (SELECT COUNT(*) FROM grac_practice.checklist_item ci
                   WHERE ci.checklist_id = c.checklist_id AND ci.status = N''Active'') AS ActiveQuestions
            FROM grac_practice.checklist c
           WHERE c.is_scope_managed = 1
           ORDER BY c.organization_id, c.checklist_id;');
GO

IF OBJECT_ID('grac_practice.sp_org_scope_question_delete','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_scope_question_delete;
GO
IF OBJECT_ID('grac_practice.sp_org_scope_question_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_scope_question_save;
GO
IF OBJECT_ID('grac_practice.sp_org_scope_question_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_scope_question_list;
GO

BEGIN TRAN;

IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'uq_pm_checklist_scope_managed'
             AND object_id = OBJECT_ID('grac_practice.checklist'))
    DROP INDEX uq_pm_checklist_scope_managed ON grac_practice.checklist;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_checklist_scope_managed')
    ALTER TABLE grac_practice.checklist DROP CONSTRAINT ck_pm_checklist_scope_managed;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_checklist_scope')
    ALTER TABLE grac_practice.checklist DROP CONSTRAINT ck_pm_checklist_scope;
GO
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_checklist_scope_asset_cat')
    ALTER TABLE grac_practice.checklist DROP CONSTRAINT fk_pm_checklist_scope_asset_cat;
GO
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_checklist_scope_role')
    ALTER TABLE grac_practice.checklist DROP CONSTRAINT fk_pm_checklist_scope_role;
GO
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'df_pm_checklist_scope_managed')
    ALTER TABLE grac_practice.checklist DROP CONSTRAINT df_pm_checklist_scope_managed;
GO

IF COL_LENGTH('grac_practice.checklist','is_scope_managed') IS NOT NULL
    ALTER TABLE grac_practice.checklist DROP COLUMN is_scope_managed;
GO
IF COL_LENGTH('grac_practice.checklist','event_type_code') IS NOT NULL
    ALTER TABLE grac_practice.checklist DROP COLUMN event_type_code;
GO
IF COL_LENGTH('grac_practice.checklist','event_type_id') IS NOT NULL
    ALTER TABLE grac_practice.checklist DROP COLUMN event_type_id;
GO
IF COL_LENGTH('grac_practice.checklist','scope_asset_category_id') IS NOT NULL
    ALTER TABLE grac_practice.checklist DROP COLUMN scope_asset_category_id;
GO
IF COL_LENGTH('grac_practice.checklist','scope_role_id') IS NOT NULL
    ALTER TABLE grac_practice.checklist DROP COLUMN scope_role_id;
GO
IF COL_LENGTH('grac_practice.checklist','scope_dimension') IS NOT NULL
    ALTER TABLE grac_practice.checklist DROP COLUMN scope_dimension;
GO

COMMIT TRAN;
GO

SELECT 'ownership columns removed' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.checklist','is_scope_managed') IS NULL
             AND COL_LENGTH('grac_practice.checklist','scope_dimension') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'procedures removed',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_scope_question_save','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '136 rolled back. The checklists listed above survive and are now edited on the Checklists screen.';
GO
