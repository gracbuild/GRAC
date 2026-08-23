-- =====================================================================
-- 205 Risk Register schema ROLLBACK
--
-- Reverses 205_risk_register_schema.sql and returns risk_candidate to
-- its 169 shape.
--
-- ORDER
--   1. Drop 206's procedures (they bind to risk_analysis / risk_register).
--      206's own rollback owns this; guarding here lets 205 run alone.
--   2. Break the candidate -> register FKs and drop the register tables.
--   3. Drop risk_analysis.
--   4. Remove the columns 205 added to risk_candidate.
--   5. Restore the 169 status CHECK and the NOT NULL on custom_gap_id.
--
-- DATA LOSS WARNING — READ BEFORE RUNNING
-- ---------------------------------------
--   * Every registered risk is DROPPED. The Risk Register is the
--     authoritative repository (BRD §9); there is no other copy.
--   * Every risk analysis and every historical version is DROPPED.
--   * Any candidate whose source is NOT a gap CANNOT survive step 5 —
--     restoring custom_gap_id NOT NULL is impossible while such rows
--     exist. The script REFUSES to do step 5 in that case and leaves the
--     column nullable, printing what to clean up. That is deliberate:
--     silently deleting an organisation's risk candidates to satisfy a
--     constraint would be worse than an incomplete rollback.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.risk_candidate','U') IS NULL
BEGIN
    PRINT '205-rollback: risk_candidate missing — nothing to do.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. 206 procedures
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_risk_register_owner_set','P')      IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_register_owner_set;
IF OBJECT_ID('grac_practice.sp_risk_register_status_set','P')     IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_register_status_set;
IF OBJECT_ID('grac_practice.sp_risk_register_get','P')            IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_register_get;
IF OBJECT_ID('grac_practice.sp_risk_register_list','P')           IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_register_list;
IF OBJECT_ID('grac_practice.sp_risk_custom_create','P')           IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_custom_create;
IF OBJECT_ID('grac_practice.sp_risk_candidate_register','P')      IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_register;
IF OBJECT_ID('grac_practice.sp_risk_candidate_close_duplicate','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_close_duplicate;
IF OBJECT_ID('grac_practice.sp_risk_candidate_clarify','P')       IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_clarify;
IF OBJECT_ID('grac_practice.sp_risk_candidate_assign','P')        IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_assign;
IF OBJECT_ID('grac_practice.sp_risk_duplicate_check','P')         IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_duplicate_check;
IF OBJECT_ID('grac_practice.sp_risk_analysis_history','P')        IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_analysis_history;
IF OBJECT_ID('grac_practice.sp_risk_analysis_get','P')            IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_analysis_get;
IF OBJECT_ID('grac_practice.sp_risk_analysis_save','P')           IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_analysis_save;
IF OBJECT_ID('grac_practice.sp_risk_rating_resolve','P')          IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_rating_resolve;
IF OBJECT_ID('grac_practice.sp_risk_scoring_options_get','P')     IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_scoring_options_get;
GO

-- ---------------------------------------------------------------------
-- 2. Break the cycle, drop the register
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_risk_candidate_registered_risk')
    ALTER TABLE grac_practice.risk_candidate DROP CONSTRAINT fk_pm_risk_candidate_registered_risk;
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_risk_candidate_duplicate_risk')
    ALTER TABLE grac_practice.risk_candidate DROP CONSTRAINT fk_pm_risk_candidate_duplicate_risk;
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_risk_analysis_register')
    ALTER TABLE grac_practice.risk_analysis DROP CONSTRAINT fk_pm_risk_analysis_register;
GO

IF OBJECT_ID('grac_practice.risk_register_history','U') IS NOT NULL DROP TABLE grac_practice.risk_register_history;
IF OBJECT_ID('grac_practice.risk_register','U')         IS NOT NULL DROP TABLE grac_practice.risk_register;
GO

-- ---------------------------------------------------------------------
-- 3. risk_analysis
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.risk_analysis','U') IS NOT NULL DROP TABLE grac_practice.risk_analysis;
GO

-- ---------------------------------------------------------------------
-- 4. risk_candidate columns
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_risk_candidate_registered_link')
    ALTER TABLE grac_practice.risk_candidate DROP CONSTRAINT ck_pm_risk_candidate_registered_link;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_risk_candidate_duplicate_link')
    ALTER TABLE grac_practice.risk_candidate DROP CONSTRAINT ck_pm_risk_candidate_duplicate_link;
IF EXISTS (SELECT 1 FROM sys.foreign_keys    WHERE name = 'fk_pm_risk_candidate_source_type')
    ALTER TABLE grac_practice.risk_candidate DROP CONSTRAINT fk_pm_risk_candidate_source_type;
IF EXISTS (SELECT 1 FROM sys.foreign_keys    WHERE name = 'fk_pm_risk_candidate_analyst')
    ALTER TABLE grac_practice.risk_candidate DROP CONSTRAINT fk_pm_risk_candidate_analyst;
GO

IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE name = 'ix_pm_risk_candidate_source'
              AND object_id = OBJECT_ID('grac_practice.risk_candidate'))
    DROP INDEX ix_pm_risk_candidate_source ON grac_practice.risk_candidate;
GO

IF COL_LENGTH('grac_practice.risk_candidate','candidate_number')             IS NOT NULL ALTER TABLE grac_practice.risk_candidate DROP COLUMN candidate_number;
GO
IF COL_LENGTH('grac_practice.risk_candidate','registered_risk_id')           IS NOT NULL ALTER TABLE grac_practice.risk_candidate DROP COLUMN registered_risk_id;
IF COL_LENGTH('grac_practice.risk_candidate','duplicate_of_risk_id')         IS NOT NULL ALTER TABLE grac_practice.risk_candidate DROP COLUMN duplicate_of_risk_id;
IF COL_LENGTH('grac_practice.risk_candidate','clarification_requested_dt')   IS NOT NULL ALTER TABLE grac_practice.risk_candidate DROP COLUMN clarification_requested_dt;
IF COL_LENGTH('grac_practice.risk_candidate','clarification_note')           IS NOT NULL ALTER TABLE grac_practice.risk_candidate DROP COLUMN clarification_note;
IF COL_LENGTH('grac_practice.risk_candidate','assigned_analyst_employee_id') IS NOT NULL ALTER TABLE grac_practice.risk_candidate DROP COLUMN assigned_analyst_employee_id;
IF COL_LENGTH('grac_practice.risk_candidate','business_unit')                IS NOT NULL ALTER TABLE grac_practice.risk_candidate DROP COLUMN business_unit;
IF COL_LENGTH('grac_practice.risk_candidate','identified_dt')                IS NOT NULL ALTER TABLE grac_practice.risk_candidate DROP COLUMN identified_dt;
IF COL_LENGTH('grac_practice.risk_candidate','source_centre_code')           IS NOT NULL ALTER TABLE grac_practice.risk_candidate DROP COLUMN source_centre_code;
IF COL_LENGTH('grac_practice.risk_candidate','source_description')           IS NOT NULL ALTER TABLE grac_practice.risk_candidate DROP COLUMN source_description;
IF COL_LENGTH('grac_practice.risk_candidate','source_reference')             IS NOT NULL ALTER TABLE grac_practice.risk_candidate DROP COLUMN source_reference;
IF COL_LENGTH('grac_practice.risk_candidate','source_record_id')             IS NOT NULL ALTER TABLE grac_practice.risk_candidate DROP COLUMN source_record_id;
GO

IF EXISTS (SELECT 1 FROM sys.default_constraints
            WHERE name = 'df_pm_risk_candidate_source_type'
              AND parent_object_id = OBJECT_ID('grac_practice.risk_candidate'))
    ALTER TABLE grac_practice.risk_candidate DROP CONSTRAINT df_pm_risk_candidate_source_type;
GO

IF COL_LENGTH('grac_practice.risk_candidate','source_type_code')             IS NOT NULL ALTER TABLE grac_practice.risk_candidate DROP COLUMN source_type_code;
GO

-- ---------------------------------------------------------------------
-- 5. Restore 169's shape
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_risk_candidate_status')
    ALTER TABLE grac_practice.risk_candidate DROP CONSTRAINT ck_pm_risk_candidate_status;
GO

-- Rows already sitting in a 205-only status cannot satisfy the 169
-- CHECK. Fold them onto the nearest 169 equivalent rather than fail —
-- the audit trail in risk_candidate_history keeps the real story.
UPDATE grac_practice.risk_candidate
   SET status_code = CASE status_code
                       WHEN N'UnderAnalysis'          THEN N'Pending'
                       WHEN N'ClarificationRequired'  THEN N'Pending'
                       WHEN N'AnalysisCompleted'      THEN N'Pending'
                       WHEN N'Registered'             THEN N'Accepted'
                       WHEN N'ClosedAsDuplicate'      THEN N'Rejected'
                       ELSE status_code END
 WHERE status_code IN (N'UnderAnalysis', N'ClarificationRequired',
                       N'AnalysisCompleted', N'Registered', N'ClosedAsDuplicate');
GO

ALTER TABLE grac_practice.risk_candidate
    ADD CONSTRAINT ck_pm_risk_candidate_status
        CHECK (status_code IN (N'Pending', N'Accepted', N'Rejected', N'Withdrawn'));
GO

IF EXISTS (SELECT 1 FROM grac_practice.risk_candidate WHERE custom_gap_id IS NULL)
BEGIN
    PRINT '205-rollback: custom_gap_id LEFT NULLABLE.';
    PRINT '              Non-gap risk candidates exist and cannot be represented in the 169 shape.';
    PRINT '              Review them with:';
    PRINT '                SELECT risk_candidate_id, candidate_title FROM grac_practice.risk_candidate WHERE custom_gap_id IS NULL;';
    PRINT '              Delete or re-home them, then run:';
    PRINT '                ALTER TABLE grac_practice.risk_candidate ALTER COLUMN custom_gap_id BIGINT NOT NULL;';
END
ELSE
BEGIN
    -- Same index dance as the forward migration — error 5074 applies in
    -- both directions.
    IF EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_candidate_gap'
                  AND object_id = OBJECT_ID('grac_practice.risk_candidate'))
        DROP INDEX ix_pm_risk_candidate_gap ON grac_practice.risk_candidate;

    IF EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_candidate_org_status'
                  AND object_id = OBJECT_ID('grac_practice.risk_candidate'))
        DROP INDEX ix_pm_risk_candidate_org_status ON grac_practice.risk_candidate;

    ALTER TABLE grac_practice.risk_candidate ALTER COLUMN custom_gap_id BIGINT NOT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_candidate_gap'
                  AND object_id = OBJECT_ID('grac_practice.risk_candidate'))
    CREATE INDEX ix_pm_risk_candidate_gap
        ON grac_practice.risk_candidate(custom_gap_id, status_code);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_risk_candidate_org_status'
                  AND object_id = OBJECT_ID('grac_practice.risk_candidate'))
    CREATE INDEX ix_pm_risk_candidate_org_status
        ON grac_practice.risk_candidate(organization_id, status_code, requested_dt DESC)
        INCLUDE(custom_gap_id, candidate_title, severity_code);
GO

PRINT '205 Risk Register schema rolled back.';
GO

SET NOEXEC OFF;
GO
