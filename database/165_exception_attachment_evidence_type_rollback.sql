SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.sp_evidence_type_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_evidence_type_list;
GO
IF EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_exception_attachment_evidence_type')
    ALTER TABLE grac_practice.exception_request_attachment DROP CONSTRAINT fk_pm_exception_attachment_evidence_type;
GO
IF COL_LENGTH('grac_practice.exception_request_attachment','evidence_type_id') IS NOT NULL
    ALTER TABLE grac_practice.exception_request_attachment DROP COLUMN evidence_type_id;
GO
PRINT '165 rollback complete. save/get/list procs still expect the new signature -- rerun 164 to restore pre-165 shape.';
GO
