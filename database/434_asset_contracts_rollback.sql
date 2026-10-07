-- =====================================================================
-- 434 rollback -- Contracts, contract versions and vendor contacts
--
--   * removes the Contracts menu row and its grants;
--   * drops the contract procedures and functions;
--   * drops asset_contract_version_contact, asset_contract_contact,
--     asset_contract_contact_role, asset_contract_document,
--     asset_contract_version and asset_contract (every contract, version,
--     document reference and contact mapping is lost);
--   * removes the ContractVersion transition rules. The ContractVersion
--     statuses stay because the immutable transition log references them.
-- The 433 option-group fix is not rolled back (it is a correction).
-- practice_audit_trace rows stay as history. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DELETE p FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'asset-contracts';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'asset-contracts';
PRINT '434 rollback: menu row removed.';
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_lookups;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_version_compare;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_version_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_document_remove;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_document_add;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_contact_action;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_contact_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_version_action;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_version_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_version_create;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_version_check;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_sync;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_contract_version_move;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_contract_readiness;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_contract_version_contacts;
PRINT '434 rollback: procedures and functions dropped.';
GO

DROP TABLE IF EXISTS grac_practice.asset_contract_version_contact;
DROP TABLE IF EXISTS grac_practice.asset_contract_contact;
DROP TABLE IF EXISTS grac_practice.asset_contract_contact_role;
DROP TABLE IF EXISTS grac_practice.asset_contract_document;
DROP TABLE IF EXISTS grac_practice.asset_contract_version;
DROP TABLE IF EXISTS grac_practice.asset_contract;
DELETE FROM grac_practice.entity_state_transition_rule
 WHERE entity_type = N'ContractVersion' AND entered_by = N'seed-434';
PRINT '434 rollback: tables and rules removed.';
GO

SELECT '434 rollback: contract objects gone' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_contract','U') IS NULL
             AND OBJECT_ID('grac_practice.sp_asset_contract_sync','P') IS NULL
             AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'asset-contracts')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
