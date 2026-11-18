-- 586 rollback  Asset & Contract menu groups
-- Puts the screens back directly under Asset & Contract with their earlier
-- order; sets the five groups Inactive. Grants are untouched.
SET NOCOUNT ON;
GO
DECLARE @root_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-asset-contract');
UPDATE m
   SET parent_menu_id = @root_id, display_order = s.display_order,
       updated_by = 'rollback-586', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master m
  JOIN (VALUES
        (N'asset-register', 349), (N'asset-field-dictionary', 351), (N'asset-form-templates', 352),
        (N'asset-valuation-config', 353), (N'asset-option-lists', 354), (N'asset-taxonomy', 355),
        (N'asset-tech-catalog', 356), (N'asset-attestation', 357), (N'asset-contracts', 358),
        (N'asset-notifications', 359), (N'asset-activities', 360), (N'asset-relationships', 361),
        (N'business-services', 362), (N'asset-discovery', 363), (N'asset-privacy', 364),
        (N'asset-governance', 365), (N'asset-reports', 366)
       ) AS s(menu_key, display_order)
       ON s.menu_key = m.menu_key;
UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = 'rollback-586', updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'nav-asset-inventory', N'nav-asset-contracts', N'nav-asset-operations',
                    N'nav-asset-governance-reporting', N'nav-asset-configuration');
GO
PRINT '586 rolled back: Asset & Contract screens back under Asset & Contract; the five groups Inactive.';
GO
