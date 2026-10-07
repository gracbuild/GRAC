-- =====================================================================
-- 429 rollback -- Asset lifecycle transitions
--
--   * restores the 428 body of sp_asset_register_list (copied verbatim
--     below) and drops sp_asset_lifecycle_apply / _transition / _decide /
--     _get / _matrix;
--   * drops asset_lifecycle_change (the reason / reference / evidence and
--     approval record of every lifecycle change is lost; the immutable
--     entity_state_transition_log and practice_audit_trace rows stay);
--   * drops asset_lifecycle_transition_gate and deletes the Asset
--     transition rules seeded by 429 (entered_by = 'seed-429');
--   * clears the APPROVE grant 429 set on Asset Register.
--   Assets keep the status they reached; with the rules gone they can only
--   be changed again after 429 is re-run.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

UPDATE grac_practice.organization_role_menu_permission
   SET can_approve = 0, updated_by = N'rollback-429', updated_dt = SYSUTCDATETIME()
 WHERE updated_by = N'seed-429';
PRINT CONCAT('429 rollback: APPROVE grants cleared: ', @@ROWCOUNT);
GO

-- 428 body, verbatim
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_register_list
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @asset_type_id   INT           = NULL,
    @status_code     NVARCHAR(60)  = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) NOT BETWEEN 1 AND 200 THEN 25 ELSE @page_size END;

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
     WHERE @status_code IS NULL OR r.status_code = @status_code
     ORDER BY ISNULL(r.updated_dt, r.entered_dt) DESC, r.asset_id DESC
     OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '429 rollback: sp_asset_register_list restored (428).';
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_asset_lifecycle_matrix;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_lifecycle_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_lifecycle_decide;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_lifecycle_transition;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_lifecycle_apply;
PRINT '429 rollback: lifecycle procedures dropped.';
GO

DROP TABLE IF EXISTS grac_practice.asset_lifecycle_change;
DROP TABLE IF EXISTS grac_practice.asset_lifecycle_transition_gate;
DELETE FROM grac_practice.entity_state_transition_rule
 WHERE entity_type = N'Asset' AND entered_by = N'seed-429';
PRINT CONCAT('429 rollback: Asset transition rules removed: ', @@ROWCOUNT);
GO

SELECT '429 rollback: lifecycle objects gone, 428 list restored' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_lifecycle_change','U') IS NULL
             AND OBJECT_ID('grac_practice.asset_lifecycle_transition_gate','U') IS NULL
             AND OBJECT_ID('grac_practice.sp_asset_lifecycle_transition','P') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_register_list')) NOT LIKE '%pending_only%'
             AND NOT EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'Asset' AND entered_by = N'seed-429')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
