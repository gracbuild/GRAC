-- =====================================================================
-- 147 Document Upload procedures -- ROLLBACK
--
-- Drops every procedure created by 147. Safe to run before rolling
-- 146: dropping procedures does not touch the tables, so document data
-- survives this rollback and can still be inspected via ad-hoc SQL.
--
-- Run BEFORE 146_document_upload_schema_rollback.sql so the drop of
-- document_upload / document_upload_file does not leave orphan procs
-- that reference deleted tables.
-- =====================================================================

IF OBJECT_ID('grac_practice.sp_document_upload_workflow_transition','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_upload_workflow_transition;
GO
IF OBJECT_ID('grac_practice.sp_document_upload_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_upload_save;
GO
IF OBJECT_ID('grac_practice.sp_document_file_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_file_save;
GO
IF OBJECT_ID('grac_practice.sp_document_file_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_file_get;
GO
IF OBJECT_ID('grac_practice.sp_document_distribution_employee_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_distribution_employee_list;
GO
IF OBJECT_ID('grac_practice.sp_document_distribution_department_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_distribution_department_list;
GO
IF OBJECT_ID('grac_practice.sp_document_details_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_details_get;
GO
IF OBJECT_ID('grac_practice.sp_document_register_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_register_list;
GO
IF OBJECT_ID('grac_practice.sp_organization_employee_by_department','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_organization_employee_by_department;
GO
IF OBJECT_ID('grac_practice.sp_organization_department_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_organization_department_list;
GO
IF OBJECT_ID('grac_practice.sp_document_distribution_type_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_distribution_type_list;
GO
IF OBJECT_ID('grac_practice.sp_document_source_type_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_source_type_list;
GO
IF OBJECT_ID('grac_practice.sp_document_status_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_status_list;
GO
IF OBJECT_ID('grac_practice.sp_document_stage_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_stage_list;
GO
IF OBJECT_ID('grac_practice.sp_document_type_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_type_list;
GO

-- End 147 rollback ==================================================
