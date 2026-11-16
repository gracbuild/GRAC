-- =====================================================================
-- 530_evidence_automation_intake_rollback.sql
--
-- Undoes 530: drops the Evidence Automation procedures and functions and
-- removes the menu row and its permissions.
--
-- The three tables are dropped only when NO evidence was ever received
-- (evidence_automation_event is empty). Otherwise they are KEPT, because
-- they are the record of what was received and who accepted it; drop them
-- by hand once that record is no longer needed.
--
-- Evidence Center items created by received evidence are NOT touched:
-- they are ordinary Evidence Center items, and any that were accepted are
-- linked from Operationalize or a task through the unchanged 476 / 482
-- procedures.
--
-- Nothing that existed before 530 is changed by 530, so nothing needs to
-- be restored. Also remove the 'evidence-automation' rows from
-- 274_menu_master_seed.sql (Sections 1 and 2).
-- ASCII-only. Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_notice_mark;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_notice_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_missing_sweep;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_event_reject;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_event_accept;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_event_targets;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_event_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_ingest;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_filedrop_bindings;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_binding_error;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_binding_resolve_token;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_binding_token_set;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_binding_status;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_binding_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_binding_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_binding_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_obligation_evidence;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_obligation_search;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_automation_lookups;
GO
DROP FUNCTION IF EXISTS grac_practice.fn_pm_evidence_automation_due;
DROP FUNCTION IF EXISTS grac_practice.fn_pm_evidence_automation_can_manage;
GO
PRINT '530 rollback: procedures and functions dropped.';
GO

-- Menu
IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
    DELETE p
      FROM grac_practice.organization_role_menu_permission p
      JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
     WHERE m.menu_key = N'evidence-automation';
    PRINT '530 rollback: permission rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
    DELETE FROM grac_practice.menu_master WHERE menu_key = N'evidence-automation';
    PRINT '530 rollback: menu row removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END
GO

-- Tables -- only when nothing was ever received.
IF OBJECT_ID('grac_practice.evidence_automation_event','U') IS NOT NULL
   AND EXISTS (SELECT 1 FROM grac_practice.evidence_automation_event)
BEGIN
    PRINT '530 rollback: evidence was received -- evidence_automation_notice, _event and _binding KEPT. Drop them by hand once that record is no longer needed.';
END
ELSE
BEGIN
    DROP TABLE IF EXISTS grac_practice.evidence_automation_notice;
    DROP TABLE IF EXISTS grac_practice.evidence_automation_event;
    DROP TABLE IF EXISTS grac_practice.evidence_automation_binding;
    PRINT '530 rollback: tables dropped.';
END
GO

PRINT '530 rollback complete.';
GO
