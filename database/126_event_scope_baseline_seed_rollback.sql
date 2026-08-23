-- =====================================================================
-- 126 Baseline entity types + lifecycle events -- ROLLBACK
--
-- Only removes rows this seed created (entered_by = 'seed-126') AND only
-- where nothing references them. An organization that has since mapped a
-- checklist to one of these events, or raised an instance against it, has
-- real data hanging off the row -- deleting it would orphan that history,
-- so those rows are reported and left in place.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

-- ---------------------------------------------------------------------
-- Event definitions
-- ---------------------------------------------------------------------
DECLARE @in_use TABLE (event_definition_id BIGINT PRIMARY KEY, event_code NVARCHAR(60), reason NVARCHAR(60));

INSERT INTO @in_use
SELECT ed.event_definition_id, ed.event_code, N'has mappings'
FROM   grac_practice.event_definition ed
WHERE  ed.entered_by = 'seed-126'
  AND  EXISTS (SELECT 1 FROM grac_practice.event_checklist_mapping m
                WHERE m.event_definition_id = ed.event_definition_id);

INSERT INTO @in_use
SELECT ed.event_definition_id, ed.event_code, N'has instances'
FROM   grac_practice.event_definition ed
WHERE  ed.entered_by = 'seed-126'
  AND  NOT EXISTS (SELECT 1 FROM @in_use u WHERE u.event_definition_id = ed.event_definition_id)
  AND  EXISTS (SELECT 1 FROM grac_practice.event_instance ei
                WHERE ei.event_definition_id = ed.event_definition_id);

DELETE FROM grac_practice.event_definition
 WHERE entered_by = 'seed-126'
   AND event_code IN (N'PEOPLE_ONBOARDING', N'PEOPLE_OFFBOARDING',
                      N'ASSET_COMMISSIONING', N'ASSET_DECOMMISSIONING')
   AND event_definition_id NOT IN (SELECT event_definition_id FROM @in_use);
GO

-- ---------------------------------------------------------------------
-- Entity types
-- ---------------------------------------------------------------------
DELETE FROM grac_practice.entity_type_master
 WHERE entered_by = 'seed-126'
   AND entity_type_code IN (N'PEOPLE', N'ASSET')
   AND NOT EXISTS (SELECT 1 FROM grac_practice.event_checklist_mapping m
                    WHERE m.entity_type_id = entity_type_master.entity_type_id)
   AND NOT EXISTS (SELECT 1 FROM grac_practice.event_instance ei
                    WHERE ei.entity_type_id = entity_type_master.entity_type_id);
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Report
-- =====================================================================
SELECT 'seed-126 event definitions remaining' AS Check_,
       COUNT(*) AS RowCount_,
       CASE WHEN COUNT(*) = 0 THEN 'CLEAN' ELSE 'RETAINED (in use)' END AS Result
FROM   grac_practice.event_definition
WHERE  entered_by = 'seed-126';

SELECT ed.organization_id, ed.event_code, ed.event_name
FROM   grac_practice.event_definition ed
WHERE  ed.entered_by = 'seed-126'
ORDER BY ed.organization_id, ed.event_code;

PRINT '126 Baseline seed rolled back. Rows still listed above are referenced by mappings or instances and were kept.';
GO
