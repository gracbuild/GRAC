-- =====================================================================
-- 148 Document Upload seed -- ROLLBACK
--
-- Deletes only the rows this seed inserted, identified by the entered_by
-- marker N'seed'. Any lookup row an operator added by hand (entered_by
-- <> 'seed') is preserved.
--
-- READ BEFORE RUNNING
-- -------------------
-- Deleting a stage / status / type / source / distribution_type row
-- that a document currently points at will fail on the FK. If the
-- rollback errors on FK, either:
--   1. Roll 147 procs and 146 tables first (removes the FKs), or
--   2. Reassign the affected documents to a different lookup row and
--      rerun this rollback.
-- =====================================================================
SET NOCOUNT ON;
GO

DELETE FROM grac_practice.document_distribution_type_master
 WHERE entered_by = N'seed'
   AND distribution_code IN (N'Organization', N'Departments', N'Users');

DELETE FROM grac_practice.document_source_type_master
 WHERE entered_by = N'seed'
   AND source_code IN (N'UPLOADED', N'POLICY_DRIVEN');

DELETE FROM grac_practice.document_status_master
 WHERE entered_by = N'seed'
   AND status_code IN (N'Active', N'Retired');

DELETE FROM grac_practice.document_stage_master
 WHERE entered_by = N'seed'
   AND stage_code IN (N'Draft', N'Reviewed', N'Published');

DELETE FROM grac_practice.document_type_master
 WHERE entered_by = N'seed'
   AND type_code IN (N'POLICY', N'SOP');

GO

-- End 148 rollback ==================================================
