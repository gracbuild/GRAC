-- =====================================================================
-- _diag_267_dependency_mappable_flag  (read-only)
--
-- Risk Analysis's Impact Details section shows "No dependency
-- categories are configured for this organisation" while the same
-- dependencies show fine under Operationalize, for the same org.
--
-- This is NOT organization-scoped on either side -- dependency_type_master
-- has no organization_id column and neither query filters by one -- so
-- the message text is misleading, but the real question is simpler:
-- does ANY row in dependency_type_master currently have
-- is_dependency_mappable = 1? Migration 267 seeded that flag to 1 for
-- exactly five categories (Asset, Vendor, Person, Team, Committee),
-- matched by name OR code, defaulting every row to 0 first. If this
-- environment's actual category names/codes do not literally match
-- that seed list, the seed UPDATE matched nothing and every row is
-- still 0 -- which is exactly the symptom described.
--
-- Section 1: every row in dependency_type_master, as it stands today.
-- Section 2: which of the five 267 expected to turn on actually got
--            turned on.
-- Section 3: exactly what sp_risk_mapping_get's category result set
--            returns right now, for comparison against what the
--            generic lookups endpoint (Operationalize) returns.
-- =====================================================================
SET NOCOUNT ON;

SELECT '1. dependency_type_master -- full current state' AS Step_,
       dependency_type_id, dependency_type_code, dependency_type_name,
       display_order, is_active, is_dependency_mappable
FROM   grac_practice.dependency_type_master
ORDER BY display_order, dependency_type_name;

SELECT '2. Did 267''s seed match this environment''s naming?' AS Step_,
       expected.ExpectedName,
       m.dependency_type_id, m.dependency_type_name, m.dependency_type_code,
       m.is_dependency_mappable,
       CASE WHEN m.dependency_type_id IS NULL THEN 'NOT FOUND BY NAME/CODE'
            WHEN m.is_dependency_mappable = 1 THEN 'OK -- mappable'
            ELSE 'FOUND BUT NOT MARKED MAPPABLE' END AS Verdict
FROM   (VALUES ('Asset'),('Vendor'),('Person'),('Team'),('Committee')) AS expected(ExpectedName)
LEFT JOIN grac_practice.dependency_type_master m
       ON m.dependency_type_name = expected.ExpectedName
       OR m.dependency_type_code IN (expected.ExpectedName, UPPER(expected.ExpectedName));

-- ---------------------------------------------------------------------
-- Section 3: what each screen's own query returns right now.
-- ---------------------------------------------------------------------
SELECT '3a. What Operationalize (generic lookups) returns for dependency-types' AS Step_,
       dependency_type_id, dependency_type_name
FROM   grac_practice.dependency_type_master
WHERE  is_active = 1
ORDER BY dependency_type_name;

SELECT '3b. What sp_risk_mapping_get''s category result set would return' AS Step_,
       dt.dependency_type_id, dt.dependency_type_code, dt.dependency_type_name, dt.display_order
FROM   grac_practice.dependency_type_master dt
WHERE  dt.is_active = 1
  AND  dt.is_dependency_mappable = 1
ORDER BY dt.display_order, dt.dependency_type_name;
