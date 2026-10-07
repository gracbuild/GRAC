-- =====================================================================
-- 444 ROLLBACK  Asset merge
-- =====================================================================
-- Restores the 429 body of sp_asset_register_list and drops the merge
-- objects. Recover executed merges first (Merges -> Recover): merged
-- assets stay archived with their pointer cleared, moved objects stay with
-- the survivor. Merge rules (role ASSET_MERGE) are deactivated, not
-- deleted (the transition log refers to them by code).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_register_list
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @asset_type_id   INT           = NULL,
    @status_code     NVARCHAR(60)  = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25,
    @pending_only    BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) NOT BETWEEN 1 AND 200 THEN 25 ELSE @page_size END;
    SET @pending_only = ISNULL(@pending_only, 0);

    ;WITH rows_ AS (
        SELECT a.asset_id, a.asset_name, a.asset_type_id, a.template_id, a.owner_id, a.location_id, a.criticality_id,
               a.asset_category_id, a.asset_subcategory_id, a.updated_dt, a.entered_dt,
               COALESCE(cs.status_code, ls.status_code) AS status_code
          FROM grac_practice.organization_dependency_asset a
          LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
          LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
         WHERE a.organization_id = @organization_id
           AND (@asset_type_id IS NULL OR a.asset_type_id = @asset_type_id)
           AND (@search IS NULL OR a.asset_name LIKE N'%' + @search + N'%' OR CAST(a.asset_id AS NVARCHAR(30)) = @search)
    )
    SELECT r.asset_id AS AssetId, r.asset_name AS AssetName,
           c.asset_category_name AS CategoryName, s.subcategory_name AS SubcategoryName,
           r.asset_type_id AS AssetTypeId, t.asset_type_name AS AssetTypeName,
           r.status_code AS StatusCode, sm.status_name AS StatusName, ph.phase_name AS PhaseName,
           r.template_id AS TemplateId, tpl.version_no AS TemplateVersion,
           e.employee_name AS OwnerName, l.location_name AS LocationName, cr.criticality_name AS CriticalityName,
           ISNULL(r.updated_dt, r.entered_dt) AS LastChanged,
           pc.change_id AS PendingChangeId, pcs.status_name AS PendingToStatusName,
           COUNT(*) OVER () AS TotalRows
      FROM rows_ r
      LEFT JOIN grac_practice.dependency_asset_category_master c ON c.asset_category_id = r.asset_category_id
      LEFT JOIN grac_practice.dependency_asset_subcategory_master s ON s.subcategory_id = r.asset_subcategory_id
      LEFT JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = r.asset_type_id
      LEFT JOIN grac_practice.entity_status_master sm ON sm.entity_type = N'Asset' AND sm.status_code = r.status_code
      LEFT JOIN grac_practice.asset_lifecycle_status_phase ph ON ph.status_code = r.status_code
      LEFT JOIN grac_practice.asset_form_template tpl ON tpl.template_id = r.template_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = r.owner_id
      LEFT JOIN grac_practice.organization_location l ON l.location_id = r.location_id
      LEFT JOIN grac_practice.criticality_master cr ON cr.criticality_id = r.criticality_id
      LEFT JOIN grac_practice.asset_lifecycle_change pc ON pc.asset_id = r.asset_id AND pc.change_status = N'PENDING_APPROVAL'
      LEFT JOIN grac_practice.entity_status_master pcs ON pcs.entity_type = N'Asset' AND pcs.status_code = pc.to_status_code
     WHERE (@status_code IS NULL OR r.status_code = @status_code)
       AND (@pending_only = 0 OR pc.change_id IS NOT NULL)
     ORDER BY ISNULL(r.updated_dt, r.entered_dt) DESC, r.asset_id DESC
     OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '444 rollback: sp_asset_register_list restored (429).';
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_asset_merge_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_merge_events;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_merge_action;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_merge_recover;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_merge_execute_one;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_merge_save;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_merge_critical;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_merge_impact;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_merge_fields;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_merge_plan;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_merge_blockers;
GO
UPDATE grac_practice.entity_state_transition_rule
   SET is_active = 0, updated_by = N'rollback-444', updated_dt = SYSUTCDATETIME()
 WHERE entity_type = N'Asset' AND actor_role_code = N'ASSET_MERGE' AND is_active = 1;
PRINT CONCAT('444 rollback: merge rules deactivated: ', @@ROWCOUNT);
GO
DROP TABLE IF EXISTS grac_practice.asset_alias;
DROP TABLE IF EXISTS grac_practice.asset_merge_split_object;
DROP TABLE IF EXISTS grac_practice.asset_merge_split_approval;
DROP TABLE IF EXISTS grac_practice.asset_merge_split_member;
DROP TABLE IF EXISTS grac_practice.asset_merge_split_event;
GO
IF COL_LENGTH('grac_practice.organization_dependency_asset','merged_into_asset_id') IS NOT NULL
BEGIN
    ALTER TABLE grac_practice.organization_dependency_asset DROP CONSTRAINT fk_pm_org_dep_asset_merged;
    ALTER TABLE grac_practice.organization_dependency_asset DROP COLUMN merged_into_asset_id;
    PRINT '444 rollback: merged_into_asset_id dropped.';
END
GO

SELECT '444 rollback' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_merge_split_event','U') IS NULL
             AND OBJECT_ID('grac_practice.asset_alias','U') IS NULL
             AND COL_LENGTH('grac_practice.organization_dependency_asset','merged_into_asset_id') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_register_list')) NOT LIKE '%asset_alias%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
