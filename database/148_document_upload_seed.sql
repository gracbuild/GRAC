-- =====================================================================
-- 148 Document Upload -- lookup seed
--
-- Seeds the lookup rows the module needs to be usable. Values mirror
-- the current GRAC Plus catalog (Draft/Reviewed/Published stages;
-- Active/Retired status; Policy/SOP types; Uploaded/Policy-Driven
-- sources; Organization/Departments/Users distribution).
--
-- SEED IS IDEMPOTENT
-- ------------------
-- Every INSERT is guarded by NOT EXISTS on the natural key (the *_code
-- column). Rerunning the script skips rows that already exist. This
-- lets 148 run:
--   * fresh, after 146+147, on a new database;
--   * again, when 148 itself is extended in a later revision;
--   * during "reset seed then reload" runs on a shared dev DB.
--
-- WHY CODES, NOT IDS
-- ------------------
-- Callers reference lookup rows by CODE (stage_code, status_code,
-- distribution_code). The identity id itself is not meaningful across
-- environments -- 147's procs resolve id from code every time. This
-- also lets seed re-runs assign different ids on a rebuilt catalog
-- without breaking anything.
--
-- ORGANIZATION_DEPARTMENT
-- -----------------------
-- Not seeded here. Departments are per-organization data and are
-- created by the Organization Administration UI. This script does not
-- assume any organization exists.
--
-- DEPENDS ON: 146, 147. Rollback: 148_document_upload_seed_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

-- Resolve the "Active" and "Inactive" record_status ids once ---------
DECLARE @active_rs_id   INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
DECLARE @inactive_rs_id INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Inactive');

IF @active_rs_id IS NULL OR @inactive_rs_id IS NULL
BEGIN
    RAISERROR('148: record_status_master needs Active and Inactive rows. Run 001/002 first.', 16, 1);
    SET NOEXEC ON;
END

-- =====================================================================
-- document_type_master
-- =====================================================================
IF NOT EXISTS(SELECT 1 FROM grac_practice.document_type_master WHERE type_code = N'POLICY')
    INSERT INTO grac_practice.document_type_master
        (type_code, document_type, description, sort_order, status, record_status_id, entered_by)
    VALUES
        (N'POLICY', N'Policy', N'Governing statement of intent adopted by the organization.',
         10, N'Active', @active_rs_id, N'seed');

IF NOT EXISTS(SELECT 1 FROM grac_practice.document_type_master WHERE type_code = N'SOP')
    INSERT INTO grac_practice.document_type_master
        (type_code, document_type, description, sort_order, status, record_status_id, entered_by)
    VALUES
        (N'SOP', N'SOP', N'Standard Operating Procedure -- step-by-step operational instructions.',
         20, N'Active', @active_rs_id, N'seed');

-- =====================================================================
-- document_stage_master
--
-- Ordered progression: Draft -> Reviewed -> Published. A rejection at
-- either transition sends the document back to Draft (147 encodes this
-- rule); a hard "in-review" holding stage is not modelled -- reviewers
-- pick up Drafts directly.
-- =====================================================================
IF NOT EXISTS(SELECT 1 FROM grac_practice.document_stage_master WHERE stage_code = N'Draft')
    INSERT INTO grac_practice.document_stage_master
        (stage_code, document_stage, description, sort_order, status, record_status_id, entered_by)
    VALUES
        (N'Draft', N'Draft', N'Document has been created/edited and is awaiting review.',
         10, N'Active', @active_rs_id, N'seed');

IF NOT EXISTS(SELECT 1 FROM grac_practice.document_stage_master WHERE stage_code = N'Reviewed')
    INSERT INTO grac_practice.document_stage_master
        (stage_code, document_stage, description, sort_order, status, record_status_id, entered_by)
    VALUES
        (N'Reviewed', N'Reviewed', N'Reviewer has signed off; awaiting approver action.',
         20, N'Active', @active_rs_id, N'seed');

IF NOT EXISTS(SELECT 1 FROM grac_practice.document_stage_master WHERE stage_code = N'Published')
    INSERT INTO grac_practice.document_stage_master
        (stage_code, document_stage, description, sort_order, status, record_status_id, entered_by)
    VALUES
        (N'Published', N'Published', N'Approver has signed off; document is in force.',
         30, N'Active', @active_rs_id, N'seed');

-- =====================================================================
-- document_status_master
--
-- Independent of stage: a Published document that is superseded moves
-- from Active to Retired via sp_document_upload_save @mode='StatusToggle'.
-- =====================================================================
IF NOT EXISTS(SELECT 1 FROM grac_practice.document_status_master WHERE status_code = N'Active')
    INSERT INTO grac_practice.document_status_master
        (status_code, document_status, description, sort_order, status, record_status_id, entered_by)
    VALUES
        (N'Active', N'Active', N'Document is in force and visible to distribution.',
         10, N'Active', @active_rs_id, N'seed');

IF NOT EXISTS(SELECT 1 FROM grac_practice.document_status_master WHERE status_code = N'Retired')
    INSERT INTO grac_practice.document_status_master
        (status_code, document_status, description, sort_order, status, record_status_id, entered_by)
    VALUES
        (N'Retired', N'Retired', N'Document is archived; no longer visible to distribution.',
         20, N'Active', @active_rs_id, N'seed');

-- =====================================================================
-- document_source_type_master
--
-- "Policy Driven" is seeded but marked Inactive because the legacy
-- catalog carried it with status_id=2 (not shown in dropdowns). Flip
-- the record_status to Active later if it becomes selectable again.
-- =====================================================================
IF NOT EXISTS(SELECT 1 FROM grac_practice.document_source_type_master WHERE source_code = N'UPLOADED')
    INSERT INTO grac_practice.document_source_type_master
        (source_code, source_type, description, sort_order, status, record_status_id, entered_by)
    VALUES
        (N'UPLOADED', N'Uploaded', N'Document was uploaded directly by the organization.',
         10, N'Active', @active_rs_id, N'seed');

IF NOT EXISTS(SELECT 1 FROM grac_practice.document_source_type_master WHERE source_code = N'POLICY_DRIVEN')
    INSERT INTO grac_practice.document_source_type_master
        (source_code, source_type, description, sort_order, status, record_status_id, entered_by)
    VALUES
        (N'POLICY_DRIVEN', N'Policy Driven', N'Document generated from a policy template. Legacy carried status_id=2 (hidden).',
         20, N'Inactive', @inactive_rs_id, N'seed');

-- =====================================================================
-- document_distribution_type_master
--
-- 1: Organization -> whole org, no per-department or per-employee row
-- 2: Departments  -> distribution_ids treated as department ids
-- 3: Users        -> distribution_ids treated as employee ids
-- =====================================================================
IF NOT EXISTS(SELECT 1 FROM grac_practice.document_distribution_type_master WHERE distribution_code = N'Organization')
    INSERT INTO grac_practice.document_distribution_type_master
        (distribution_code, distribution_type, description, sort_order, status, record_status_id, entered_by)
    VALUES
        (N'Organization', N'Organization', N'Whole organization -- no distribution rows needed.',
         10, N'Active', @active_rs_id, N'seed');

IF NOT EXISTS(SELECT 1 FROM grac_practice.document_distribution_type_master WHERE distribution_code = N'Departments')
    INSERT INTO grac_practice.document_distribution_type_master
        (distribution_code, distribution_type, description, sort_order, status, record_status_id, entered_by)
    VALUES
        (N'Departments', N'Departments', N'One or more departments in the organization.',
         20, N'Active', @active_rs_id, N'seed');

IF NOT EXISTS(SELECT 1 FROM grac_practice.document_distribution_type_master WHERE distribution_code = N'Users')
    INSERT INTO grac_practice.document_distribution_type_master
        (distribution_code, distribution_type, description, sort_order, status, record_status_id, entered_by)
    VALUES
        (N'Users', N'Users', N'A hand-picked list of individual employees.',
         30, N'Active', @active_rs_id, N'seed');

GO

-- End 148 =============================================================
