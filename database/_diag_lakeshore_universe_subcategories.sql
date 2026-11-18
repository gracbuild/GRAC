-- =====================================================================
-- Diagnostic (read-only): where did the Audit Universe subcategories go?
-- Shows, per organization that has Universe masters, its categories and
-- how many subcategories each has, so the organization chosen on the
-- Audit Universe screen can be compared with the one the load used.
-- Changes nothing.
-- =====================================================================
SET NOCOUNT ON;

-- 1. Organizations named like Lakeshore.
SELECT organization_id, organization_name
  FROM grac_practice.organization
 WHERE organization_name LIKE N'%Lakeshore%';

-- 2. Categories and their subcategories, per organization.
SELECT c.organization_id, o.organization_name, c.universe_master_id AS category_id, c.code AS category_code,
       c.name AS category_name, c.is_active AS category_active,
       COUNT(s.universe_master_id) AS subcategories,
       SUM(CASE WHEN s.is_active = 1 THEN 1 ELSE 0 END) AS active_subcategories
  FROM grac_practice.org_assurance_universe_master c
  JOIN grac_practice.organization o ON o.organization_id = c.organization_id
  LEFT JOIN grac_practice.org_assurance_universe_master s
    ON s.parent_master_id = c.universe_master_id AND s.master_group = N'SUBCATEGORY'
 WHERE c.master_group = N'CATEGORY'
 GROUP BY c.organization_id, o.organization_name, c.universe_master_id, c.code, c.name, c.is_active, c.display_order
 ORDER BY c.organization_id, c.display_order;

-- 3. Subcategories whose parent is not a CATEGORY of the same organization
--    (should be none).
SELECT s.organization_id, s.universe_master_id, s.code, s.name, s.parent_master_id,
       p.organization_id AS parent_org, p.master_group AS parent_group
  FROM grac_practice.org_assurance_universe_master s
  LEFT JOIN grac_practice.org_assurance_universe_master p ON p.universe_master_id = s.parent_master_id
 WHERE s.master_group = N'SUBCATEGORY'
   AND (p.universe_master_id IS NULL OR p.master_group <> N'CATEGORY' OR p.organization_id <> s.organization_id);
