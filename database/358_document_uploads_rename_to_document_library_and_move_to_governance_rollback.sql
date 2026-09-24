-- =====================================================================
-- 358 ROLLBACK -- "Document Library" back to "Document Uploads" under
-- Document Management
--
-- Restores menu_master.document-uploads to exactly the state 155 left
-- it in: menu_name 'Document Uploads', parent nav-documents, module_type
-- 'Documents', display_order 10 (first child, matching 155/274). Also
-- restores feature_flag_master's display name.
--
-- menu_key, menu_url, menu_id and every organization_role_menu_permission
-- row are untouched either way -- nothing to roll back there.
--
-- Does NOT revert PracticeScreen.cs -- that is a separate C# code change
-- delivered alongside 358, not part of this SQL file. Revert it by hand
-- (Title back to "Document Uploads", Group back to OversightGroup) if a
-- full rollback of the feature is wanted.
--
-- Re-runnable: yes.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    RAISERROR('358 rollback: grac_practice.menu_master missing.', 16, 1);
    SET NOEXEC ON;
END
GO

DECLARE @docs_parent_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-documents');

IF @docs_parent_id IS NULL
BEGIN
    RAISERROR('358 rollback: nav-documents parent row is missing -- cannot restore prior parent.', 16, 1);
    SET NOEXEC ON;
END
GO

UPDATE grac_practice.menu_master
   SET menu_name      = N'Document Uploads',
       parent_menu_id = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-documents'),
       module_type    = N'Documents',
       display_order  = 10,
       status         = N'Active',
       updated_by     = 'seed-358-rollback',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'document-uploads';

PRINT '358 rollback: document-uploads restored to Document Uploads under Document Management = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

UPDATE grac_practice.feature_flag_master
   SET feature_name = N'Document Uploads',
       updated_by   = 'seed-358-rollback',
       updated_dt   = SYSUTCDATETIME()
 WHERE feature_code = N'screen.document-uploads';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '358 rollback: menu_name restored' AS Check_,
       CASE WHEN (SELECT menu_name FROM grac_practice.menu_master WHERE menu_key = N'document-uploads') = N'Document Uploads'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '358 rollback: parent restored to nav-documents',
       CASE WHEN EXISTS (
                SELECT 1 FROM grac_practice.menu_master m
                JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                WHERE m.menu_key = N'document-uploads' AND p.menu_key = N'nav-documents')
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '358 rollback complete. document-uploads is back under Document Management,';
PRINT '     labelled Document Uploads -- back to pre-358 behaviour.';
GO
SET NOEXEC OFF;
GO
