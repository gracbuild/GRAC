-- =====================================================================
-- 272 Consolidated master data seed -- ROLLBACK
--
-- Removes ONLY the rows 272 inserted, identified by
-- entered_by = 'seed-272'. A master row that was already present when
-- 272 ran carries its owning migration's entered_by ('system', 'seed-035',
-- 'seed-158', 'seed-240', ...) and is left untouched, so rolling 272 back
-- on a database that had already run the migration chain is a no-op.
--
-- WHAT CANNOT BE ROLLED BACK
--   The one UPDATE in 272 -- deactivating the nine gap-lifecycle
--   transitions that 174 retired (PlanResolution, SendBackToValidation,
--   SendBackToAnalysis, StartExecution, SendBackToPlanning,
--   SubmitForVerification, SendBackToExecution, Approve, Reopen). That is
--   the current product behaviour, not a 272 invention, and the pre-272
--   record_status_id of those rows is not recorded anywhere. To undo it
--   deliberately, run 174_gap_lifecycle_collapse_rollback.sql.
--
-- FK ORDER
--   Children are deleted before parents: asset types before subcategories
--   before categories, gap transitions before gap states,
--   dependency_type_source_config before dependency_type_master, and
--   record_status_master last because eight masters carry a
--   record_status_id FK to it.
--
-- A DELETE that hits a foreign key means a real row now depends on a
-- seeded master (for example an organisation_dependency_asset pointing at
-- a seeded asset category). That is intentional: the delete fails loudly
-- rather than orphaning live data. Repoint or remove the dependent row
-- first, then re-run.
--
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (272 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

PRINT '272 rollback: removing rows entered_by = seed-272.';
GO

DECLARE @order TABLE(seq INT IDENTITY(1,1) PRIMARY KEY, schema_name SYSNAME, table_name SYSNAME);
INSERT @order(schema_name, table_name) VALUES
    -- deepest children first
    (N'grac_practice', N'dependency_asset_type_master'),
    (N'grac_practice', N'dependency_asset_subcategory_master'),
    (N'grac_practice', N'dependency_type_source_config'),
    (N'grac_practice', N'gap_lifecycle_transition_master'),
    (N'grac_practice', N'gap_lifecycle_state_master'),
    -- flat masters
    (N'grac_practice', N'dependency_asset_category_master'),
    (N'grac_practice', N'dependency_type_master'),
    (N'grac_practice', N'dependency_hosting_type_master'),
    (N'grac_practice', N'dependency_license_type_master'),
    (N'grac_practice', N'dependency_service_category_master'),
    (N'grac_practice', N'dependency_resolution_status_master'),
    (N'grac_practice', N'location_type_master'),
    (N'grac_practice', N'criticality_master'),
    (N'grac_practice', N'frequency_master'),
    (N'grac_practice', N'collection_method_master'),
    (N'grac_practice', N'assurance_type_master'),
    (N'grac_practice', N'evidence_alignment_status_master'),
    (N'grac_practice', N'assurance_activity_status_master'),
    (N'grac_practice', N'assurance_result_status_master'),
    (N'grac_practice', N'schedule_override_type_master'),
    (N'grac_practice', N'entity_status_master'),
    (N'grac_practice', N'task_type_master'),
    (N'grac_practice', N'origin_type_master'),
    (N'grac_practice', N'related_entity_type_master'),
    (N'grac_practice', N'feature_flag_master'),
    (N'grac_practice', N'org_assurance_status_master'),
    (N'grac_practice', N'org_assurance_scope_dimension_master'),
    (N'grac_practice', N'org_assurance_plan_status_master'),
    (N'grac_practice', N'org_assurance_execution_status_master'),
    (N'grac_practice', N'org_assurance_observation_severity_master'),
    (N'grac_practice', N'org_assurance_observation_status_master'),
    (N'grac_practice', N'org_assurance_gap_status_master'),
    (N'grac_practice', N'document_type_master'),
    (N'grac_practice', N'document_stage_master'),
    (N'grac_practice', N'document_status_master'),
    (N'grac_practice', N'document_source_type_master'),
    (N'grac_practice', N'document_distribution_type_master'),
    (N'grac_practice', N'exception_type_master'),
    (N'grac_practice', N'sla_process_type_master'),
    (N'grac_practice', N'risk_source_master'),
    (N'grac_practice', N'threat_master'),
    (N'grac_practice', N'vulnerability_master'),
    (N'grac_practice', N'connection_type_master'),
    (N'grac_practice', N'organization_metadata_definition'),
    (N'grac_practice', N'reference_option'),
    (N'GRAC_New',      N'evidence_type_master'),
    -- status masters other tables point at
    (N'grac_practice', N'operationalization_status_master'),
    (N'grac_practice', N'implementation_status_master'),
    (N'grac_practice', N'subscription_status_master'),
    (N'grac_practice', N'applicability_status_master'),
    (N'grac_practice', N'record_status_master');

DECLARE @seq INT = 1, @max_seq INT = (SELECT MAX(seq) FROM @order);
DECLARE @sch SYSNAME, @tbl SYSNAME, @sql NVARCHAR(MAX), @removed INT;

WHILE @seq <= @max_seq
BEGIN
    SELECT @sch = schema_name, @tbl = table_name FROM @order WHERE seq = @seq;

    IF OBJECT_ID(QUOTENAME(@sch) + N'.' + QUOTENAME(@tbl), 'U') IS NOT NULL
    BEGIN
        SET @sql = N'DELETE FROM ' + QUOTENAME(@sch) + N'.' + QUOTENAME(@tbl)
                 + N' WHERE entered_by = N''seed-272''; SET @out = @@ROWCOUNT;';
        EXEC sys.sp_executesql @sql, N'@out INT OUTPUT', @out = @removed OUTPUT;
        IF @removed > 0
            PRINT '272 rollback: ' + @sch + '.' + @tbl + ' rows removed = ' + CAST(@removed AS NVARCHAR(20));
    END

    SET @seq = @seq + 1;
END
GO

SELECT 'Rows still carrying entered_by = seed-272' AS Check_,
       SUM(row_count_) AS Count_,
       CASE WHEN SUM(row_count_) = 0 THEN 'PASS' ELSE 'REVIEW' END AS Result_
FROM (
    SELECT CASE WHEN OBJECT_ID('grac_practice.record_status_master','U') IS NULL THEN 0
                ELSE (SELECT COUNT_BIG(1) FROM grac_practice.record_status_master WHERE entered_by = N'seed-272') END AS row_count_
    UNION ALL
    SELECT CASE WHEN OBJECT_ID('grac_practice.entity_status_master','U') IS NULL THEN 0
                ELSE (SELECT COUNT_BIG(1) FROM grac_practice.entity_status_master WHERE entered_by = N'seed-272') END
    UNION ALL
    SELECT CASE WHEN OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL THEN 0
                ELSE (SELECT COUNT_BIG(1) FROM grac_practice.feature_flag_master WHERE entered_by = N'seed-272') END
) probe;

PRINT '272 rollback complete.';
GO

SET NOEXEC OFF;
GO
