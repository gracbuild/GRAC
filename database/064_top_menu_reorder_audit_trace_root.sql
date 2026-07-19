-- =====================================================================
-- 064 Top-level sidebar reorder + promote Audit Traceability to root
--
-- Target top-level order after this migration:
--     Dashboard             (10)
--     Governance            (100)  [nav-governance]
--     Oversight             (150)  [nav-oversight]      -- moved up
--     Assurance             (200)  [nav-assurance]      -- moved up
--     Organization          (250)  [nav-organization]   -- moved down
--     Audit Traceability    (300)  [audit-trace]        -- promoted from
--                                                         nav-administration
--                                                         child + reactivated
--     Administration        (500)  [nav-administration] -- unchanged
--
-- Any migration that was hiding Governance / Oversight / Assurance /
-- Organization parents is untouched -- only their display_order (and, for
-- audit-trace, parent_menu_id + status) is updated.
--
-- audit-trace changes:
--   * status         Active
--   * parent_menu_id NULL           (was nav-administration per 052)
--   * display_order  300            (was 520)
--   * module_type    'Governance'   (top-level tile, no longer nested
--                                    inside the Administration group)
--   * menu_url / menu_key           unchanged (page keeps working)
--
-- ASCII-only. Idempotent -- safe to re-run.
-- Rollback: database/064_top_menu_reorder_audit_trace_root_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    RAISERROR('064: prerequisites missing (schema grac_practice or menu_master).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- ---------------------------------------------------------------------------
-- Step 1 -- Reorder the four synthetic navigation parents that already
--           exist as top-level tiles. menu_name, icon, module_type and
--           parent_menu_id (NULL) are left as they are.
-- ---------------------------------------------------------------------------
UPDATE grac_practice.menu_master
   SET display_order = 100,
       updated_by    = 'seed-064',
       updated_dt    = SYSUTCDATETIME()
 WHERE menu_key = N'nav-governance';

UPDATE grac_practice.menu_master
   SET display_order = 150,
       updated_by    = 'seed-064',
       updated_dt    = SYSUTCDATETIME()
 WHERE menu_key = N'nav-oversight';

UPDATE grac_practice.menu_master
   SET display_order = 200,
       updated_by    = 'seed-064',
       updated_dt    = SYSUTCDATETIME()
 WHERE menu_key = N'nav-assurance';

UPDATE grac_practice.menu_master
   SET display_order = 250,
       updated_by    = 'seed-064',
       updated_dt    = SYSUTCDATETIME()
 WHERE menu_key = N'nav-organization';

-- ---------------------------------------------------------------------------
-- Step 2 -- Promote audit-trace to a top-level tile.
--           Reactivate it, drop the nav-administration parent (052 had
--           tucked it under Administration), and slot it at display_order
--           300 so it lands right after Organization.
-- ---------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'audit-trace')
BEGIN
    UPDATE grac_practice.menu_master
       SET menu_name      = N'Audit Traceability',
           menu_url       = N'Practice/Index/audit-trace',
           parent_menu_id = NULL,
           display_order  = 300,
           icon_class     = N'timeline',
           module_type    = N'Governance',
           status         = N'Active',
           updated_by     = 'seed-064',
           updated_dt     = SYSUTCDATETIME()
     WHERE menu_key = N'audit-trace';
END
ELSE
BEGIN
    INSERT INTO grac_practice.menu_master
        (menu_key, menu_name, menu_url, parent_menu_id, display_order,
         icon_class, module_type, status, entered_by)
    VALUES
        (N'audit-trace',
         N'Audit Traceability',
         N'Practice/Index/audit-trace',
         NULL,
         300,
         N'timeline',
         N'Governance',
         N'Active',
         'seed-064');
END

-- ---------------------------------------------------------------------------
-- Step 3 -- Grant every Admin role can_view on audit-trace so it renders
--           in the sidebar just like the other top-level entries. Mirrors
--           the pattern migrations 052 / 063 use for their new rows.
-- ---------------------------------------------------------------------------
IF OBJECT_ID('grac_practice.organization_role','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
BEGIN
    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id
    );
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    MERGE grac_practice.organization_role_menu_permission AS target
    USING (
        SELECT r.role_id, m.menu_id,
               CAST(1 AS BIT) AS can_view,
               CAST(0 AS BIT) AS can_add,
               CAST(0 AS BIT) AS can_edit,
               CAST(0 AS BIT) AS can_delete,
               CAST(0 AS BIT) AS can_approve,
               @active_record_status_id AS record_status_id
        FROM grac_practice.organization_role r
        CROSS JOIN grac_practice.menu_master m
        WHERE r.role_name = N'Admin'
          AND r.status    = N'Active'
          AND m.menu_key  = N'audit-trace'
    ) AS source
    ON target.role_id = source.role_id AND target.menu_id = source.menu_id
    WHEN MATCHED THEN UPDATE SET
        can_view    = source.can_view,
        status      = N'Active',
        updated_by  = 'seed-064',
        updated_dt  = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
         status, record_status_id, entered_by)
    VALUES
        (source.role_id, source.menu_id, source.can_view, source.can_add,
         source.can_edit, source.can_delete, source.can_approve,
         N'Active', source.record_status_id, 'seed-064');
END

COMMIT TRAN;

-- ---------------------------------------------------------------------------
-- Sanity report -- every currently Active top-level row (parent_menu_id NULL)
-- ---------------------------------------------------------------------------
SELECT menu_key, menu_name, menu_url, display_order, module_type, status
FROM grac_practice.menu_master
WHERE parent_menu_id IS NULL
  AND status = N'Active'
ORDER BY display_order, menu_key;

PRINT '064 Top-level sidebar reorder complete.';
PRINT '  Order: Dashboard, Governance, Oversight, Assurance, Organization,';
PRINT '         Audit Traceability, Administration.';
GO

SET NOEXEC OFF;
GO
