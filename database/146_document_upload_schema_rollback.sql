-- =====================================================================
-- 146 Document Upload schema -- ROLLBACK
--
-- Drops everything migration 146 added. Order matters: history and
-- distribution children first, then the file table, then the main
-- register, then the lookups, then organization_department.
--
-- READ BEFORE RUNNING
-- -------------------
-- document_upload / document_upload_file hold real organization content:
-- policy PDFs, review remarks, workflow decisions. Dropping the tables
-- destroys them; there is no other copy in this database. Capture them
-- first if the module is live:
--
--     SELECT * FROM grac_practice.document_upload;
--     SELECT document_file_id, document_id, version_number, file_name,
--            file_size_bytes, uploaded_dt
--       FROM grac_practice.document_upload_file;
--     SELECT * FROM grac_practice.document_upload_history;
--
-- organization_department is dropped too. If anything outside 146 has
-- started referencing departments (a later migration might), promote
-- the table out of this rollback and rerun the promoted version.
--
-- The stored procedures added by 147 and the seed added by 148 depend
-- on the tables 146 creates. Rolling 146 back without also rolling 147
-- and 148 will leave orphan procedures that fail on first call. Roll
-- migrations back in reverse order (148 -> 147 -> 146).
-- =====================================================================

-- Children of document_upload first ----------------------------------
IF OBJECT_ID('grac_practice.document_upload_history','U') IS NOT NULL
    DROP TABLE grac_practice.document_upload_history;
GO

IF OBJECT_ID('grac_practice.document_upload_distribution_employee','U') IS NOT NULL
    DROP TABLE grac_practice.document_upload_distribution_employee;
GO

IF OBJECT_ID('grac_practice.document_upload_distribution_department','U') IS NOT NULL
    DROP TABLE grac_practice.document_upload_distribution_department;
GO

IF OBJECT_ID('grac_practice.document_upload_file','U') IS NOT NULL
    DROP TABLE grac_practice.document_upload_file;
GO

-- Main register ------------------------------------------------------
IF OBJECT_ID('grac_practice.document_upload','U') IS NOT NULL
    DROP TABLE grac_practice.document_upload;
GO

-- Lookups (no dependants after the tables above are gone) ------------
IF OBJECT_ID('grac_practice.document_distribution_type_master','U') IS NOT NULL
    DROP TABLE grac_practice.document_distribution_type_master;
GO

IF OBJECT_ID('grac_practice.document_source_type_master','U') IS NOT NULL
    DROP TABLE grac_practice.document_source_type_master;
GO

IF OBJECT_ID('grac_practice.document_status_master','U') IS NOT NULL
    DROP TABLE grac_practice.document_status_master;
GO

IF OBJECT_ID('grac_practice.document_stage_master','U') IS NOT NULL
    DROP TABLE grac_practice.document_stage_master;
GO

IF OBJECT_ID('grac_practice.document_type_master','U') IS NOT NULL
    DROP TABLE grac_practice.document_type_master;
GO

-- Foundational ------------------------------------------------------
IF OBJECT_ID('grac_practice.organization_department','U') IS NOT NULL
    DROP TABLE grac_practice.organization_department;
GO

-- End 146 rollback ==================================================
