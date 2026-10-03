-- =====================================================================
-- 406 rollback: removes repository subscription requests.
--   * the four sp_repository_subscription_request_* procedures
--   * grac_practice.repository_subscription_request (request history is lost)
-- Subscriptions that approvals created stay: they are ordinary
-- repository_subscription rows, the same ones Organization Setup creates.
-- Run ControlManagement 068 rollback FIRST (its procedures call these).
-- ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_repository_subscription_request_decide;
DROP PROCEDURE IF EXISTS grac_practice.sp_repository_subscription_request_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_repository_subscription_request_manage;
DROP PROCEDURE IF EXISTS grac_practice.sp_repository_subscription_request_get;
GO

DROP TABLE IF EXISTS grac_practice.repository_subscription_request;
GO

PRINT '406 rolled back.';
GO
