-- ============================================================================
-- ISO Controls Import to GRAC v1.0
-- Phase 6 -- Populate grac_new.framework_statement so the Source Statements
--            (RS3) grid actually returns rows for the imported ISO release.
-- ============================================================================
-- Why this is needed:
--   The RS3 Source Statements screen (Level 2 drill-down of Repository
--   Subscriptions) does NOT read from grac_new.control. It reads from
--   grac_new.framework_statement (see PracticeRepositoryService.
--   QueryReleaseStatementsAsync). Phases 2 + 3 populated only the
--   control / requirement side; without Phase 6 the RS3 grid stays empty.
--
-- Semantic mapping we adopt:
--   Excel row              -> grac_new.framework_statement (RS3 row)
--   -----------------------   ------------------------------------------
--   Control (5.1, 5.2, ...)-> ONE framework_statement per Excel control
--                             (93 statements total for ISO 27001:2022)
--   Practice (5.1.1, ...)  -> requirement row (loaded by Phase 3)
--                             + framework_statement_requirement_map row
--                             linking practice <-> parent control-as-statement
--
-- Also inserts framework_statement_control_map so anywhere the schema
-- expects statement<->control linkage (a few reports do), the ISO release
-- looks structurally identical to PCI-DSS / RBI.
--
-- Prereqs: run 02 + 03 first (controls + requirements must exist).
-- ASCII-only. Idempotent (WHERE NOT EXISTS guards). Safe to re-run.
-- ============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @release_id  BIGINT = /* <FILL_IN> */ NULL;
DECLARE @actor       NVARCHAR(100) = 'iso-import-v1.0';

IF @release_id IS NULL BEGIN RAISERROR('Set @release_id.', 16, 1); RETURN; END;

-- Sanity: 93 controls and 1115 requirements should already be present
-- and mapped for this release, otherwise this script cannot derive the
-- statement<->requirement fan-out.
IF NOT EXISTS (
    SELECT 1
    FROM grac_new.source_control_map scm
    JOIN grac_new.source_structure_node n
         ON n.structure_node_id = scm.structure_node_id
        AND n.release_id = @release_id
    WHERE scm.status = 'Active'
)
BEGIN
    RAISERROR('Phase 6: no source_control_map rows found for the release. Run 02_insert_repository_controls.sql first.', 16, 1);
    RETURN;
END

BEGIN TRAN;

-- ---------------------------------------------------------------------------
-- 6a. framework_statement -- one per control mapped to this release.
--     statement_reference = control_code (e.g. '5.1')
--     statement_title     = control_name
--     statement_text      = control description
--     structure_node_id   = the node from Excel (via source_control_map)
--     display_order       = derived from control_code (5.1 -> 501, 5.10 -> 510)
-- ---------------------------------------------------------------------------
;WITH ordered_controls AS (
    SELECT DISTINCT
        c.control_id,
        c.control_code,
        c.control_name,
        c.description  AS control_description,
        scm.structure_node_id,
        -- Derive a sortable numeric display_order from "5.1", "5.10", "6.3" etc.
        -- (major*1000 + minor). Falls back to 0 if the code doesn't parse.
        CASE
          WHEN CHARINDEX('.', c.control_code) > 0 THEN
            ISNULL(TRY_CONVERT(INT, LEFT(c.control_code, CHARINDEX('.', c.control_code)-1)), 0) * 1000
            + ISNULL(TRY_CONVERT(INT, SUBSTRING(c.control_code, CHARINDEX('.', c.control_code)+1, 10)), 0)
          ELSE 0
        END AS derived_display_order
    FROM grac_new.control c
    JOIN grac_new.source_control_map scm
         ON scm.control_id = c.control_id AND scm.status = 'Active'
    JOIN grac_new.source_structure_node n
         ON n.structure_node_id = scm.structure_node_id
        AND n.release_id = @release_id
        AND n.status = 'Active'
    WHERE c.status = 'Active'
)
INSERT INTO grac_new.framework_statement
    (release_id, structure_node_id, statement_reference, statement_title,
     statement_text, display_order, status, entered_by, entered_dt)
SELECT
    @release_id,
    oc.structure_node_id,
    oc.control_code,
    oc.control_name,
    oc.control_description,
    oc.derived_display_order,
    N'Active',
    @actor,
    SYSUTCDATETIME()
FROM ordered_controls oc
WHERE NOT EXISTS (
    SELECT 1 FROM grac_new.framework_statement fs
    WHERE fs.release_id = @release_id
      AND fs.statement_reference = oc.control_code
);

DECLARE @statements_inserted INT = @@ROWCOUNT;

-- ---------------------------------------------------------------------------
-- 6b. framework_statement_control_map -- 1:1 link from each newly-created
--     framework_statement back to its underlying control. Some downstream
--     reports (audit, coverage) look up controls via this map, and every
--     working framework in the system uses it.
-- ---------------------------------------------------------------------------
INSERT INTO grac_new.framework_statement_control_map
    (framework_statement_id, control_id, status, entered_by, entered_dt)
SELECT
    fs.framework_statement_id,
    c.control_id,
    N'Active',
    @actor,
    SYSUTCDATETIME()
FROM grac_new.framework_statement fs
JOIN grac_new.control c
     ON c.control_code = fs.statement_reference AND c.status = 'Active'
WHERE fs.release_id = @release_id
  AND fs.status = 'Active'
  AND NOT EXISTS (
      SELECT 1 FROM grac_new.framework_statement_control_map m
      WHERE m.framework_statement_id = fs.framework_statement_id
        AND m.control_id             = c.control_id
  );

-- ---------------------------------------------------------------------------
-- 6c. framework_statement_requirement_map -- explodes each control-as-statement
--     to its list of practices. Uses the control_requirement_map loaded in
--     Phase 3 as the source of truth for parent->child linkage.
-- ---------------------------------------------------------------------------
INSERT INTO grac_new.framework_statement_requirement_map
    (framework_statement_id, requirement_id, status, entered_by, entered_dt)
SELECT
    fs.framework_statement_id,
    crm.requirement_id,
    N'Active',
    @actor,
    SYSUTCDATETIME()
FROM grac_new.framework_statement       fs
JOIN grac_new.control                   c
     ON c.control_code = fs.statement_reference AND c.status = 'Active'
JOIN grac_new.control_requirement_map   crm
     ON crm.control_id = c.control_id AND crm.status = 'Active'
JOIN grac_new.requirement               r
     ON r.requirement_id = crm.requirement_id AND r.status = 'Active'
WHERE fs.release_id = @release_id
  AND fs.status = 'Active'
  AND NOT EXISTS (
      SELECT 1 FROM grac_new.framework_statement_requirement_map m
      WHERE m.framework_statement_id = fs.framework_statement_id
        AND m.requirement_id         = crm.requirement_id
  );

COMMIT;

-- ---------------------------------------------------------------------------
-- Sanity report
-- ---------------------------------------------------------------------------
SELECT 'Statements active for this release'         AS Check_,
       COUNT(*) AS Rows_
FROM grac_new.framework_statement
WHERE release_id = @release_id AND status = N'Active';

SELECT 'Statements attached to an Active node'      AS Check_,
       COUNT(*) AS Rows_
FROM grac_new.framework_statement fs
JOIN grac_new.source_structure_node n
     ON n.structure_node_id = fs.structure_node_id
    AND n.release_id = @release_id
    AND n.status = 'Active'
WHERE fs.release_id = @release_id AND fs.status = 'Active';

SELECT 'Statement <-> Requirement mappings'         AS Check_,
       COUNT(*) AS Rows_
FROM grac_new.framework_statement fs
JOIN grac_new.framework_statement_requirement_map m
     ON m.framework_statement_id = fs.framework_statement_id AND m.status = 'Active'
WHERE fs.release_id = @release_id AND fs.status = 'Active';

SELECT 'Statement <-> Control mappings'             AS Check_,
       COUNT(*) AS Rows_
FROM grac_new.framework_statement fs
JOIN grac_new.framework_statement_control_map m
     ON m.framework_statement_id = fs.framework_statement_id AND m.status = 'Active'
WHERE fs.release_id = @release_id AND fs.status = 'Active';

PRINT 'Phase 6 framework_statement layer populated.';
GO
