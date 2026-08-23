-- =====================================================================
-- 153 Document Acknowledgement user-side procedures -- ROLLBACK
-- =====================================================================
SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.sp_document_ack_user_ack','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_ack_user_ack;
GO
IF OBJECT_ID('grac_practice.sp_document_ack_user_documents','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_ack_user_documents;
GO
IF OBJECT_ID('grac_practice.sp_document_ack_user_batches','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_ack_user_batches;
GO
PRINT '153 rollback complete.';
GO
