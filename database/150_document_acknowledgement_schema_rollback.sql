-- =====================================================================
-- 150 Document Acknowledgement schema -- ROLLBACK
--
-- Drop order: user rows -> document rows -> batch master -> pending
-- (pending's FK to master forces master to survive until pending goes
-- or the FK is dropped). Data loss is total -- capture first if the
-- ack module is live:
--
--     SELECT * FROM grac_practice.document_acknowledgement_user;
--     SELECT * FROM grac_practice.document_acknowledgement_document;
--     SELECT * FROM grac_practice.document_acknowledgement;
--     SELECT * FROM grac_practice.document_acknowledgement_pending;
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.document_acknowledgement_user','U') IS NOT NULL
    DROP TABLE grac_practice.document_acknowledgement_user;
GO

IF OBJECT_ID('grac_practice.document_acknowledgement_document','U') IS NOT NULL
    DROP TABLE grac_practice.document_acknowledgement_document;
GO

-- Drop the pending -> master FK before dropping master.
IF EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_doc_ack_pending_batch')
    ALTER TABLE grac_practice.document_acknowledgement_pending
        DROP CONSTRAINT fk_pm_doc_ack_pending_batch;
GO

IF OBJECT_ID('grac_practice.document_acknowledgement','U') IS NOT NULL
    DROP TABLE grac_practice.document_acknowledgement;
GO

IF OBJECT_ID('grac_practice.document_acknowledgement_pending','U') IS NOT NULL
    DROP TABLE grac_practice.document_acknowledgement_pending;
GO

-- End 150 rollback ==================================================
