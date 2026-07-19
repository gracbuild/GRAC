-- ============================================================================
-- ISO Controls Import to GRAC v1.0
-- Phase 1 -- Cleanup existing ISO repository data for the target release
-- ============================================================================
-- Fill in the two parameters below before running.
-- @release_id : the grac_new.release row that represents the ISO release
--               these controls belong to. Get it from grac_new.release +
--               artifact + authority.
-- ============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @release_id       BIGINT = /* <FILL_IN> */ NULL;
DECLARE @artifact_id      BIGINT = (SELECT artifact_id FROM grac_new.release WHERE release_id = @release_id);
DECLARE @actor            NVARCHAR(100) = 'iso-import-v1.0';

IF @release_id IS NULL OR @artifact_id IS NULL
BEGIN
    RAISERROR('Set @release_id before running this script.', 16, 1);
    RETURN;
END
GO

-- Rebuild variable inside the batch (variables don't cross GO boundaries).
DECLARE @release_id BIGINT = /* <FILL_IN> */ NULL;
IF @release_id IS NULL BEGIN RAISERROR('Set @release_id.', 16, 1); RETURN; END;

-- Capture the control_ids and requirement_ids that belong ONLY to this release
-- so we do not orphan controls that are shared across other releases.
DECLARE @target_controls TABLE (control_id BIGINT PRIMARY KEY);
DECLARE @target_reqs     TABLE (requirement_id BIGINT PRIMARY KEY);

INSERT @target_controls (control_id)
SELECT DISTINCT scm.control_id
FROM grac_new.source_control_map scm
JOIN grac_new.source_structure_node n
     ON n.structure_node_id = scm.structure_node_id
    AND n.release_id = @release_id
WHERE scm.status = 'Active';

INSERT @target_reqs (requirement_id)
SELECT DISTINCT crm.requirement_id
FROM grac_new.control_requirement_map crm
JOIN @target_controls tc ON tc.control_id = crm.control_id
WHERE crm.status = 'Active';

BEGIN TRAN;

-- 1a. Detach source_control_map rows for this release.
DELETE scm
FROM grac_new.source_control_map scm
JOIN grac_new.source_structure_node n
     ON n.structure_node_id = scm.structure_node_id
    AND n.release_id = @release_id;

-- 1b. Detach control<->requirement mappings for the affected controls.
DELETE crm
FROM grac_new.control_requirement_map crm
JOIN @target_controls tc ON tc.control_id = crm.control_id;

-- 1c. Delete requirements that are no longer mapped to any control.
DELETE q
FROM grac_new.requirement q
JOIN @target_reqs tr ON tr.requirement_id = q.requirement_id
WHERE NOT EXISTS (
    SELECT 1 FROM grac_new.control_requirement_map crm
    WHERE crm.requirement_id = q.requirement_id
);

-- 1d. Delete controls that are no longer mapped to any release.
DELETE c
FROM grac_new.control c
JOIN @target_controls tc ON tc.control_id = c.control_id
WHERE NOT EXISTS (
    SELECT 1 FROM grac_new.source_control_map scm
    WHERE scm.control_id = c.control_id
);

COMMIT;

SELECT 'Phase 1 cleanup complete' AS Result,
       (SELECT COUNT(*) FROM @target_controls) AS ControlsTouched,
       (SELECT COUNT(*) FROM @target_reqs)     AS RequirementsTouched;
GO
