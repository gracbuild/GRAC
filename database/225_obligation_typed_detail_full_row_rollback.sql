-- =====================================================================
-- 225 Typed obligation detail, whole row -- ROLLBACK
--
-- Restores grac_practice.vw_pm_obligation_typed_detail to the 224 body:
-- each per-type sub-query back to a hand-written column list.
--
-- WHAT YOU LOSE BY DOING THIS
-- ---------------------------
-- The card goes back to showing only the columns that existed when
-- migration 122 was written. Any column Control Management has added
-- since -- trigger mode and the event-driven fields on
-- obligation_assurance_spec among them -- disappears from Operationalize
-- again, silently, because a projection that names columns cannot show
-- one it does not name.
--
-- Only roll this back if the whole-row projection is itself causing a
-- problem (a column collision with one of the label aliases, or a column
-- CM added that must not reach this screen). Both cases are better
-- solved forward -- rename the alias, or add the column to the browser's
-- deny-list in resolve-workspace.cshtml.
--
-- The browser-side renderer needs no rollback: it shows whatever keys
-- arrive, so it degrades to the shorter list on its own.
--
-- ASCII-only on purpose (see the forward script header).
-- Idempotent: safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR SCHEMA_ID('GRAC_New') IS NULL
BEGIN
    PRINT 'ABORT (225 rollback): schema grac_practice or GRAC_New missing.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER VIEW grac_practice.vw_pm_obligation_typed_detail
AS
    SELECT
        o.obligation_id AS ObligationId,

        COALESCE((
            SELECT s.state_rule_id AS Id,
                   s.attribute, s.operator, s.[value], s.unit, s.tolerance, s.remarks
            FROM GRAC_New.obligation_state_rule s
            WHERE s.obligation_id = o.obligation_id AND s.status = N'Active'
            FOR JSON PATH
        ), N'[]') AS StateRulesJson,

        COALESCE((
            SELECT es.execution_spec_id AS Id,
                   es.[action],
                   es.execution_frequency_id AS ExecutionFrequencyId,
                   ef.option_label AS ExecutionFrequency,
                   es.trigger_condition, es.responsible_party, es.due_within, es.remarks
            FROM GRAC_New.obligation_execution_spec es
            LEFT JOIN GRAC_New.reference_option ef ON ef.reference_option_id = es.execution_frequency_id
            WHERE es.obligation_id = o.obligation_id AND es.status = N'Active'
            FOR JSON PATH
        ), N'[]') AS ExecutionSpecsJson,

        COALESCE((
            SELECT [as].assurance_spec_id AS Id,
                   [as].verification_method, [as].scope,
                   [as].assurance_frequency_id AS AssuranceFrequencyId,
                   af.option_label AS AssuranceFrequency,
                   [as].assurance_party, [as].remarks
            FROM GRAC_New.obligation_assurance_spec [as]
            LEFT JOIN GRAC_New.reference_option af ON af.reference_option_id = [as].assurance_frequency_id
            WHERE [as].obligation_id = o.obligation_id AND [as].status = N'Active'
            FOR JSON PATH
        ), N'[]') AS AssuranceSpecsJson,

        COALESCE((
            SELECT er.event_response_id AS Id,
                   er.trigger_event, er.response_action,
                   er.sla_value AS SlaValue, er.sla_unit AS SlaUnit,
                   er.escalation_path, er.remarks
            FROM GRAC_New.obligation_event_response er
            WHERE er.obligation_id = o.obligation_id AND er.status = N'Active'
            FOR JSON PATH
        ), N'[]') AS EventResponsesJson,

        COALESCE((
            SELECT cr.constraint_rule_id AS Id,
                   cr.prohibited_condition, cr.scope, cr.exception_policy, cr.remarks
            FROM GRAC_New.obligation_constraint_rule cr
            WHERE cr.obligation_id = o.obligation_id AND cr.status = N'Active'
            FOR JSON PATH
        ), N'[]') AS ConstraintRulesJson,

        COALESCE((
            SELECT rs.retention_spec_id AS Id,
                   rs.retained_object,
                   rs.min_retention_value AS MinRetentionValue, rs.min_retention_unit AS MinRetentionUnit,
                   rs.max_retention_value AS MaxRetentionValue, rs.max_retention_unit AS MaxRetentionUnit,
                   rs.disposal_policy, rs.remarks
            FROM GRAC_New.obligation_retention_spec rs
            WHERE rs.obligation_id = o.obligation_id AND rs.status = N'Active'
            FOR JSON PATH
        ), N'[]') AS RetentionSpecsJson,

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

PRINT '=== 225 rollback verification ===';

SELECT 'view names detail columns again' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail','V'))
                 LIKE '%verification_method%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '';
PRINT '225 rollback complete. Columns Control Management added after';
PRINT 'migration 122 are no longer visible on Operationalize.';
GO

SET NOEXEC OFF;
GO
