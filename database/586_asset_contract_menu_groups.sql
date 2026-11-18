-- =====================================================================
-- 586  Asset & Contract menu grouped by area (2026-11-18, sir)
--
-- REQUEST: group the Asset & Contract menus as was done for Audit
--   Assurance (578). Sir chose (2026-11-18):
--   Dashboard (stays first, the module's entry point)
--   1. Asset Inventory        -- Asset Register, Asset Discovery, Asset
--                                Relationships, Business Services, Asset
--                                Attestation
--   2. Contracts              -- Contracts
--   3. Asset Operations       -- Asset Activities, Asset Notifications
--   4. Governance & Reporting -- Asset Governance, Asset Privacy, Asset
--                                Reports
--   5. Asset Configuration    -- Asset Taxonomy, Technology Catalogue,
--                                Field Dictionary, Asset Form Templates,
--                                Option Lists, Asset Valuation
--
-- WHAT THIS DOES (menu only -- no screen, grant or url changes)
--   1. NEW group rows (no url) under 'nav-asset-contract', after the
--      Dashboard (348): nav-asset-inventory 371, nav-asset-contracts 372,
--      nav-asset-operations 373, nav-asset-governance-reporting 374,
--      nav-asset-configuration 375.
--   2. The screens move under them (order within the group 10, 20, ...);
--      names unchanged.
--   3. Written back into 274.
-- A group needs no permission row: the sidebar keeps a group while the
-- signed-in role may open one of its screens (PracticeController
-- .PermittedMenu). Every screen keeps its menu_id and so every role's
-- permission.
-- NOTE: 420-452 re-parent their row to 'nav-asset-contract' when re-run;
-- run 586 again after re-running any of them (274 is updated, so a 274
-- run keeps the groups).
-- DEPENDS ON: 420 (nav-asset-contract) and the Asset & Contract screens.
-- Rollback: 586_asset_contract_menu_groups_rollback.sql.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-asset-contract')
BEGIN
    PRINT 'ABORT (586): menu nav-asset-contract not found (run 420 first). Nothing was changed.';
    RAISERROR('586_asset_contract_menu_groups: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. The groups
-- =====================================================================
DECLARE @root_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-asset-contract');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'nav-asset-inventory',            N'Asset Inventory',        371, N'boxes-stacked'),
    (N'nav-asset-contracts',            N'Contracts',              372, N'file-contract'),
    (N'nav-asset-operations',           N'Asset Operations',       373, N'calendar-check'),
    (N'nav-asset-governance-reporting', N'Governance & Reporting', 374, N'gauge-high'),
    (N'nav-asset-configuration',        N'Asset Configuration',    375, N'sliders')
) AS src(menu_key, menu_name, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = NULL,
    parent_menu_id = @root_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Asset & Contract',
    status = N'Active', updated_by = 'seed-586', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, NULL, @root_id, src.display_order,
     src.icon_class, N'Asset & Contract', N'Active', 'seed-586');
PRINT '586.1: Asset & Contract group rows upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 2. The screens under their groups
-- =====================================================================
UPDATE m
   SET parent_menu_id = g.menu_id,
       display_order  = s.display_order,
       updated_by     = 'seed-586', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master m
  JOIN (VALUES
        (N'asset-register',         N'nav-asset-inventory',            10),
        (N'asset-discovery',        N'nav-asset-inventory',            20),
        (N'asset-relationships',    N'nav-asset-inventory',            30),
        (N'business-services',      N'nav-asset-inventory',            40),
        (N'asset-attestation',      N'nav-asset-inventory',            50),
        (N'asset-contracts',        N'nav-asset-contracts',            10),
        (N'asset-activities',       N'nav-asset-operations',           10),
        (N'asset-notifications',    N'nav-asset-operations',           20),
        (N'asset-governance',       N'nav-asset-governance-reporting', 10),
        (N'asset-privacy',          N'nav-asset-governance-reporting', 20),
        (N'asset-reports',          N'nav-asset-governance-reporting', 30),
        (N'asset-taxonomy',         N'nav-asset-configuration',        10),
        (N'asset-tech-catalog',     N'nav-asset-configuration',        20),
        (N'asset-field-dictionary', N'nav-asset-configuration',        30),
        (N'asset-form-templates',   N'nav-asset-configuration',        40),
        (N'asset-option-lists',     N'nav-asset-configuration',        50),
        (N'asset-valuation-config', N'nav-asset-configuration',        60)
       ) AS s(menu_key, group_key, display_order)
       ON s.menu_key = m.menu_key
  JOIN grac_practice.menu_master g ON g.menu_key = s.group_key;
PRINT '586.2: screens moved under their groups = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 3. Verification: the tree under Asset & Contract
-- =====================================================================
SELECT ISNULL(g.menu_name, N'(Asset & Contract)') AS GroupName, m.menu_key AS MenuKey, m.menu_name AS MenuName,
       m.display_order AS DisplayOrder, m.status AS Status
  FROM grac_practice.menu_master m
  JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
  LEFT JOIN grac_practice.menu_master g ON g.menu_id = m.parent_menu_id AND g.menu_key <> N'nav-asset-contract'
 WHERE m.status = N'Active'
   AND (p.menu_key = N'nav-asset-contract' OR p.parent_menu_id = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-asset-contract'))
 ORDER BY ISNULL(g.display_order, m.display_order), CASE WHEN g.menu_id IS NULL THEN 0 ELSE 1 END, m.display_order;
PRINT '586 done: Asset & Contract menus grouped (Inventory, Contracts, Operations, Governance & Reporting, Configuration).';
GO
