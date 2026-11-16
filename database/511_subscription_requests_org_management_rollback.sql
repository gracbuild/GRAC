-- =====================================================================
-- 511 ROLLBACK -- removes the 'subscription-requests' menu row and every
-- grant on it. The requests themselves (repository_subscription_request)
-- are untouched; Control Management's screen keeps working as before.
-- Also remove the row from 274_menu_master_seed.sql, or its next run puts
-- the row back. SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @menu_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'subscription-requests');
IF @menu_id IS NOT NULL
BEGIN
    BEGIN TRAN;
    DELETE FROM grac_practice.organization_role_menu_permission WHERE menu_id = @menu_id;
    PRINT CONCAT('511 rollback: grants removed: ', @@ROWCOUNT);
    DELETE FROM grac_practice.menu_master WHERE menu_id = @menu_id;
    PRINT CONCAT('511 rollback: menu row removed: ', @@ROWCOUNT);
    COMMIT;
END
ELSE
    PRINT '511 rollback: nothing to remove.';
GO

SELECT '511 rollback: menu row gone' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'subscription-requests')
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
GO
