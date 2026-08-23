-- =====================================================================
-- 166 rollback -- drop the 8 new columns + type master + expiry proc.
-- Restore CHECK constraint to (Pending/Approved/Rejected/Withdrawn) only.
-- Any Expired rows will fail the new constraint -- caller must flip
-- them back to Approved first if they exist.
-- =====================================================================
SET NOCOUNT ON;
GO

IF EXISTS (SELECT 1 FROM grac_practice.exception_request WHERE status_code = N'Expired')
    PRINT '166 rollback WARNING: rows exist with status Expired. Reset them to Approved or Rejected before rerunning this rollback.';
GO

IF OBJECT_ID('grac_practice.sp_exception_request_expire_due','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_exception_request_expire_due;
GO
IF OBJECT_ID('grac_practice.sp_exception_type_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_exception_type_list;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'ck_pm_exception_request_status')
    ALTER TABLE grac_practice.exception_request DROP CONSTRAINT ck_pm_exception_request_status;
GO
ALTER TABLE grac_practice.exception_request
    ADD CONSTRAINT ck_pm_exception_request_status
        CHECK (status_code IN (N'Pending', N'Approved', N'Rejected', N'Withdrawn'));
GO

IF EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_exception_request_type')
    ALTER TABLE grac_practice.exception_request DROP CONSTRAINT fk_pm_exception_request_type;
GO
IF COL_LENGTH('grac_practice.exception_request','exception_type_id') IS NOT NULL
    ALTER TABLE grac_practice.exception_request DROP COLUMN exception_type_id;
GO
IF COL_LENGTH('grac_practice.exception_request','justification') IS NOT NULL
    ALTER TABLE grac_practice.exception_request DROP COLUMN justification;
GO
IF COL_LENGTH('grac_practice.exception_request','risk_impact') IS NOT NULL
    ALTER TABLE grac_practice.exception_request DROP COLUMN risk_impact;
GO
IF EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_exception_request_owner')
    ALTER TABLE grac_practice.exception_request DROP CONSTRAINT fk_pm_exception_request_owner;
GO
IF COL_LENGTH('grac_practice.exception_request','owner_employee_id') IS NOT NULL
    ALTER TABLE grac_practice.exception_request DROP COLUMN owner_employee_id;
GO
IF COL_LENGTH('grac_practice.exception_request','effective_from') IS NOT NULL
    ALTER TABLE grac_practice.exception_request DROP COLUMN effective_from;
GO
IF COL_LENGTH('grac_practice.exception_request','compensating_control') IS NOT NULL
    ALTER TABLE grac_practice.exception_request DROP COLUMN compensating_control;
GO
IF EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_exception_request_freq')
    ALTER TABLE grac_practice.exception_request DROP CONSTRAINT fk_pm_exception_request_freq;
GO
IF COL_LENGTH('grac_practice.exception_request','review_frequency_id') IS NOT NULL
    ALTER TABLE grac_practice.exception_request DROP COLUMN review_frequency_id;
GO
IF COL_LENGTH('grac_practice.exception_request','linked_practice_id') IS NOT NULL
    ALTER TABLE grac_practice.exception_request DROP COLUMN linked_practice_id;
GO
IF COL_LENGTH('grac_practice.exception_request','linked_requirement_ref') IS NOT NULL
    ALTER TABLE grac_practice.exception_request DROP COLUMN linked_requirement_ref;
GO

IF OBJECT_ID('grac_practice.exception_type_master','U') IS NOT NULL
    DROP TABLE grac_practice.exception_type_master;
GO

PRINT '166 rollback complete. Rerun 162 to restore prior sp_exception_request_create/approve signatures.';
GO
