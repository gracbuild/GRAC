-- =====================================================================
-- 508_documents_dashboard_rollback.sql
--
-- Reverses 508: drops sp_dashboard_documents; removes the Policies &
-- Documents 'documents-dashboard' menu row and its permission rows.
-- Nothing else in the module is touched.
--
-- Deploy the previous Web build first (the Dashboard screen and the Home
-- card call the procedure this drops; without it they show "not set up").
-- Also remove the 508 rows from 274_menu_master_seed.sql.
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_dashboard_documents;
GO

DELETE p
  FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'documents-dashboard';
PRINT CONCAT('508 rollback: permission rows removed: ', @@ROWCOUNT);
DELETE FROM grac_practice.menu_master WHERE menu_key = N'documents-dashboard';
PRINT CONCAT('508 rollback: menu rows removed: ', @@ROWCOUNT);
GO

PRINT '508 rollback complete.';
GO
