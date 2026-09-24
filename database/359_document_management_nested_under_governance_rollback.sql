-- =====================================================================
-- 359 ROLLBACK -- Document Management back to a root menu; Document
-- Library back to a direct Governance child (358's end state)
--
-- Restores exactly what 358 left in place:
--   * nav-documents: parent_menu_id -> NULL (root again), module_type
--     -> 'Documents', display_order -> 400.
--   * document-uploads: parent_menu_id -> nav-governance (direct
--     child), module_type -> 'Governance', display_order -> 130.
--     menu_name stays 'Document Library' -- that rename is 358's, not
--     359's, and is not undone by this file.
--
-- document-acknowledgements / my-acknowledgements are untouched (as
-- 359 never touched them either) -- they remain under nav-documents,
-- which simply moves back to being a root menu.
--
-- Re-runnable: yes.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    RAISERROR('359 rollback: grac_practice.menu_master missing.', 16, 1);
    SET NOEXEC ON;
END
GO

UPDATE grac_practice.menu_master
   SET parent_menu_id = NULL,
       module_type    = N'Documents',
       display_order  = 400,
       status         = N'Active',
       updated_by     = 'seed-359-rollback',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'nav-documents';

PRINT '359 rollback: Document Management restored to a root menu = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

DECLARE @gov_parent_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-governance');

UPDATE grac_practice.menu_master
   SET parent_menu_id = @gov_parent_id,
       module_type    = N'Governance',
       display_order  = 130,
       status         = N'Active',
       updated_by     = 'seed-359-rollback',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'document-uploads';

PRINT '359 rollback: Document Library restored as a direct Governance child = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '359 rollback: Document Management is a root menu again' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-documents' AND parent_menu_id IS NULL)
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '359 rollback: Document Library is a direct child of Governance again',
       CASE WHEN EXISTS (
                SELECT 1 FROM grac_practice.menu_master m
                JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                WHERE m.menu_key = N'document-uploads' AND p.menu_key = N'nav-governance')
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '359 rollback complete. Back to 358''s end state: Document Management';
PRINT '     a root menu, Document Library a direct child of Governance.';
GO
SET NOEXEC OFF;
GO
