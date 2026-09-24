-- =====================================================================
-- 225 Typed obligation detail -- project the whole detail row
--
-- SYMPTOM
-- -------
-- With 224 applied, an Assurance obligation on Operationalize showed
-- only Scope and Remarks. The admin module captures more than that --
-- verification method, assurance party, trigger mode, and then either
-- event details (trigger mode = event driven) or an assurance frequency
-- (scheduled).
--
-- CAUSE
-- -----
-- vw_pm_obligation_typed_detail listed columns by name, because it was
-- lifted from migration 122, which listed them by name. That list was
-- correct when 122 was written. GRAC_New.obligation_assurance_spec has
-- since gained columns -- trigger mode and the event-driven fields --
-- and a projection that names columns cannot show a column that did not
-- exist when it was named.
--
-- Practice Management does not own those tables. Control Management
-- does, and adds to them on its own schedule. Every such addition needed
-- a PM migration to become visible, and until someone wrote it the
-- screen quietly showed a subset -- which is worse than showing nothing,
-- because it looks complete.
--
-- FIX
-- ---
-- Stop naming the columns. Each per-type sub-query now selects the whole
-- detail row, so a column Control Management adds appears on the next
-- page load with no PM change at all.
--
-- The label lookups stay explicit -- a frequency id is not a frequency
-- name, and only the join knows the difference -- so each sub-query is
-- "the row, plus the labels its foreign keys resolve to".
--
-- THE BROWSER DECIDES WHAT TO SHOW
-- --------------------------------
-- resolve-workspace.cshtml renders every key it finds and hides the ones
-- that are empty, with a deny-list for housekeeping columns (status,
-- entered_by, record_status_id, ...) and for raw *_id keys that have a
-- resolved label beside them. So:
--
--   * trigger mode = Scheduled  -> the event columns are NULL and do not
--                                  render; the frequency does.
--   * trigger mode = EventDriven-> the reverse.
--
-- That conditional display falls out of "show what is populated" and
-- needs no rule encoded on either side.
--
-- WHY SELECT * IS RIGHT HERE AND NOT IN GENERAL
-- ---------------------------------------------
-- SELECT * is normally a liability: the shape of a result set changes
-- under callers who did not ask for it. Here the caller is a JSON
-- serialiser feeding a renderer that was written to be shape-agnostic,
-- and the table belongs to another module. The alternative -- a name
-- list PM has to keep in step with CM by hand -- is the thing that
-- produced this defect.
--
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
--
-- Idempotent: CREATE OR ALTER; no data is written.
--
-- DEPENDS ON: 224 (the view this replaces).
-- Rollback:   database/225_obligation_typed_detail_full_row_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

DECLARE @prereqs_ok BIT = 1;

IF OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail','V') IS NULL
BEGIN
    PRINT 'ABORT (225): vw_pm_obligation_typed_detail missing. Run 224_resolve_obligation_typed_detail.sql first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('225_obligation_typed_detail_full_row: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- vw_pm_obligation_typed_detail -- re-issued
--
-- Same seven columns, same names, same consumers. Only the column list
-- inside each per-type sub-query has gone from a hand-written list to
-- the whole row.
--
-- Alias discipline: each sub-query is `<alias>.*` plus label columns
-- named so they cannot collide with a real column. If Control Management
-- ever adds a column called ExecutionFrequency to the execution spec,
-- FOR JSON emits both and the browser shows the last one -- rename the
-- alias here if that happens.
-- =====================================================================
CREATE OR ALTER VIEW grac_practice.vw_pm_obligation_typed_detail
AS
    SELECT
        o.obligation_id AS ObligationId,

        COALESCE((
            SELECT s.*
            FROM GRAC_New.obligation_state_rule s
            WHERE s.obligation_id = o.obligation_id AND s.status = N'Active'
            FOR JSON PATH
        ), N'[]') AS StateRulesJson,

        COALESCE((
            SELECT es.*,
                   ef.option_label AS ExecutionFrequency
            FROM GRAC_New.obligation_execution_spec es
            LEFT JOIN GRAC_New.reference_option ef ON ef.reference_option_id = es.execution_frequency_id
            WHERE es.obligation_id = o.obligation_id AND es.status = N'Active'
            FOR JSON PATH
        ), N'[]') AS ExecutionSpecsJson,

        COALESCE((
            SELECT [as].*,
                   af.option_label AS AssuranceFrequency
            FROM GRAC_New.obligation_assurance_spec [as]
            LEFT JOIN GRAC_New.reference_option af ON af.reference_option_id = [as].assurance_frequency_id
            WHERE [as].obligation_id = o.obligation_id AND [as].status = N'Active'
            FOR JSON PATH
        ), N'[]') AS AssuranceSpecsJson,

        COALESCE((
            SELECT er.*
            FROM GRAC_New.obligation_event_response er
            WHERE er.obligation_id = o.obligation_id AND er.status = N'Active'
            FOR JSON PATH
        ), N'[]') AS EventResponsesJson,

        COALESCE((
            SELECT cr.*
            FROM GRAC_New.obligation_constraint_rule cr
            WHERE cr.obligation_id = o.obligation_id AND cr.status = N'Active'
            FOR JSON PATH
        ), N'[]') AS ConstraintRulesJson,

        COALESCE((
            SELECT rs.*
            FROM GRAC_New.obligation_retention_spec rs
            WHERE rs.obligation_id = o.obligation_id AND rs.status = N'Active'
            FOR JSON PATH
        ), N'[]') AS RetentionSpecsJson,

        -- Evidence stays an explicit list. It is not one table's rows: it
        -- is a UNION of the legacy 1:M rows and the six per-type link
        -- tables, so the columns have to be stated to line the two halves
        -- up. A column added to requirement_obligation_evidence does need
        -- a change here -- but that table is the taxonomy's oldest and
        -- least likely to move.
        COALESCE((
            SELECT * FROM (
                SELECT
                    N'Direct' AS Source,
                    NULL AS LinkTypeCode,
                    roe.obligation_evidence_id AS ObligationEvidenceId,
                    roe.evidence_type_id AS EvidenceTypeId,
                    et.evidence_type_name AS EvidenceType,
                    roe.frequency_id AS FrequencyId,
                    freq.option_label AS Frequency,
                    roe.retention_requirement AS RetentionRequirement,
                    roe.remarks AS Remarks,
                    et.display_order AS DisplayOrder
                FROM GRAC_New.requirement_obligation_evidence roe
                LEFT JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id = roe.evidence_type_id
                LEFT JOIN GRAC_New.reference_option freq ON freq.reference_option_id = roe.frequency_id
                WHERE roe.obligation_id = o.obligation_id
                  AND roe.status = N'Active'
                UNION ALL
                SELECT N'Link', l.TypeCode,
                       roe2.obligation_evidence_id, roe2.evidence_type_id,
                       et2.evidence_type_name,
                       roe2.frequency_id, freq2.option_label,
                       roe2.retention_requirement, roe2.remarks,
                       et2.display_order
                FROM (
                    SELECT N'State' AS TypeCode, obligation_id, obligation_evidence_id, status
                    FROM GRAC_New.obligation_state_evidence_link
                    UNION ALL SELECT N'Execution', obligation_id, obligation_evidence_id, status
                    FROM GRAC_New.obligation_execution_evidence_link
                    UNION ALL SELECT N'Assurance', obligation_id, obligation_evidence_id, status
                    FROM GRAC_New.obligation_assurance_evidence_link
                    UNION ALL SELECT N'EventResponse', obligation_id, obligation_evidence_id, status
                    FROM GRAC_New.obligation_event_response_evidence_link
                    UNION ALL SELECT N'Constraint', obligation_id, obligation_evidence_id, status
                    FROM GRAC_New.obligation_constraint_evidence_link
                    UNION ALL SELECT N'Retention', obligation_id, obligation_evidence_id, status
                    FROM GRAC_New.obligation_retention_evidence_link
                ) l
                JOIN GRAC_New.requirement_obligation_evidence roe2 ON roe2.obligation_evidence_id = l.obligation_evidence_id
                LEFT JOIN GRAC_New.evidence_type_master et2 ON et2.evidence_type_id = roe2.evidence_type_id
                LEFT JOIN GRAC_New.reference_option freq2 ON freq2.reference_option_id = roe2.frequency_id
                WHERE l.obligation_id = o.obligation_id
                  AND l.status = N'Active'
            ) combined
            ORDER BY combined.Source, ISNULL(combined.DisplayOrder, 999), combined.EvidenceType
            FOR JSON PATH
        ), N'[]') AS EvidenceJson

    FROM GRAC_New.requirement_obligation o;
GO

-- =====================================================================
-- Verification
--
-- The point of this migration is that PM no longer has an opinion about
-- which columns exist, so the check is simply: what DOES the assurance
-- spec carry, and does a sample obligation's JSON now contain it?
-- =====================================================================
PRINT '=== 225 verification ===';

SELECT 'view no longer names detail columns' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail','V'))
                 LIKE '%verification_method%'
            THEN 'FAIL -- still a hand-written column list' ELSE 'PASS' END AS Result;

PRINT '=== Columns Control Management actually keeps on each detail table ===';
SELECT t.name AS TableName, c.column_id, c.name AS ColumnName, ty.name AS DataType
FROM   sys.tables t
JOIN   sys.schemas sc ON sc.schema_id = t.schema_id
JOIN   sys.columns c  ON c.object_id = t.object_id
JOIN   sys.types  ty  ON ty.user_type_id = c.user_type_id
WHERE  sc.name = 'GRAC_New'
  AND  t.name IN ('obligation_state_rule', 'obligation_execution_spec',
                  'obligation_assurance_spec', 'obligation_event_response',
                  'obligation_constraint_rule', 'obligation_retention_spec')
ORDER  BY t.name, c.column_id;

PRINT '=== A sample of what the view now emits per type ===';
SELECT TOP (5)
       o.obligation_id AS ObligationId,
       t.type_code     AS TypeCode,
       LEFT(d.AssuranceSpecsJson, 900) AS AssuranceSpecsJson_First900
FROM   GRAC_New.requirement_obligation o
JOIN   grac_practice.vw_pm_obligation_typed_detail d ON d.ObligationId = o.obligation_id
LEFT   JOIN GRAC_New.obligation_type_master t ON t.obligation_type_id = o.obligation_type_id
WHERE  o.status = N'Active'
  AND  d.AssuranceSpecsJson <> N'[]'
ORDER  BY o.obligation_id;

PRINT '';
PRINT '225 complete. Ship PracticeManagement.Web with it -- the card renders';
PRINT 'whatever keys arrive, so no Api change is needed.';
GO

SET NOEXEC OFF;
GO
