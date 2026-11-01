-- =====================================================================
-- 475_evidence_cadence_type_mapping_fix_rollback.sql
-- Reverses 475: re-issues vw_pm_instance_evidence_cadence verbatim as 473
-- left it. (The check procedure an earlier draft added is not restored --
-- that rule was withdrawn; the DROP below is a no-op when it is absent.)
-- ASCII-only. Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
IF OBJECT_ID('grac_practice.sp_resolve_obligation_implementation_evidence_check','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_resolve_obligation_implementation_evidence_check;
GO
CREATE OR ALTER VIEW grac_practice.vw_pm_instance_evidence_cadence
AS
    -- 473: the cadence of every practice_instance_evidence row.
    --   Published = read from the organisation's copy of the specs of
    --               this obligation + evidence type (any Recurring spec
    --               makes the row Recurring), or, failing that, of the
    --               exact spec the row was created from;
    --   Default   = nothing published (organisation-defined evidence)
    --               -> Recurring, the 077 default.
    -- A copied spec with no cadence (a copy still waiting for approval of
    -- the 077 change) reads as Recurring, the same as 077's backfill.
    SELECT e.evidence_id,
           e.organization_id,
           e.practice_instance_id,
           c.EvidenceCadence,
           COALESCE(ro.option_label, c.EvidenceCadence) AS EvidenceCadenceLabel,
           c.CadenceSource
    FROM   grac_practice.practice_instance_evidence e
    OUTER  APPLY (
        SELECT COUNT(*) AS spec_count,
               MAX(CASE WHEN ISNULL(ooe.evidence_cadence, N'Recurring') = N'OneTime' THEN 0 ELSE 1 END) AS any_recurring
        FROM   grac_practice.vw_pm_obligation_evidence oe
        JOIN   grac_practice.organization_obligation_evidence ooe
               ON ooe.organization_id = oe.organization_id
              AND ooe.obligation_evidence_id = oe.obligation_evidence_id
        WHERE  e.source_obligation_id IS NOT NULL
          AND  oe.organization_id  = e.organization_id
          AND  oe.obligation_id    = e.source_obligation_id
          AND  oe.evidence_type_id = e.evidence_type_id
    ) bytype
    OUTER  APPLY (
        SELECT TOP 1 ISNULL(ooe2.evidence_cadence, N'Recurring') AS cadence
        FROM   grac_practice.organization_obligation_evidence ooe2
        WHERE  e.source_obligation_evidence_id IS NOT NULL
          AND  ooe2.organization_id = e.organization_id
          AND  ooe2.obligation_evidence_id = e.source_obligation_evidence_id
    ) exact
    CROSS  APPLY (
        SELECT CASE WHEN bytype.spec_count > 0
                    THEN CASE WHEN bytype.any_recurring = 1 THEN N'Recurring' ELSE N'OneTime' END
                    WHEN exact.cadence IS NOT NULL THEN exact.cadence
                    ELSE N'Recurring' END AS EvidenceCadence,
               CASE WHEN bytype.spec_count > 0 OR exact.cadence IS NOT NULL
                    THEN N'Published' ELSE N'Default' END AS CadenceSource
    ) c
    LEFT   JOIN GRAC_New.reference_option ro
           ON ro.option_group = N'evidence-cadence'
          AND ro.option_value = c.EvidenceCadence;
GO
PRINT 'OK (475 rollback): cadence view restored to 473.';
GO
