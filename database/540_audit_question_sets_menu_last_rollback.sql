-- =====================================================================
-- 540 ROLLBACK -- Question Sets back to display_order 445 (between Audit
-- Definition and Audit Configuration). Revert 274 too. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO
UPDATE grac_practice.menu_master
   SET display_order = 445,
       updated_by    = N'rollback-540',
       updated_dt    = SYSUTCDATETIME()
 WHERE menu_key = N'org-assurance-question-sets'
   AND display_order <> 445;
PRINT '540 rollback: Question Sets order restored = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO
