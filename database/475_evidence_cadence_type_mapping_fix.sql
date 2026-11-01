-- =====================================================================
-- 475_evidence_cadence_type_mapping_fix.sql
--
-- WHAT THIS FILE DOES (2026-10-18)
-- --------------------------------
-- 1. vw_pm_instance_evidence_cadence (473) RE-ISSUED with one fix. Its
--    "by type" branch compared organization_obligation_evidence's
--    evidence_type_id (a GRAC_New evidence type) with
--    practice_instance_evidence's (a Practice Management evidence type).
--    Those are two different masters, so the branch matched nothing -- or
--    the wrong type when two ids happened to coincide -- and the cadence
--    fell back to the row's exact source spec. It now maps the type by
--    name, exactly as sp_resolve_evidence_list does. Everything else in
--    the view is unchanged.
--
-- 2. Drops grac_practice.sp_resolve_obligation_implementation_evidence_check
--    if it exists. An earlier draft of this migration (same day, then named
--    475_one_time_evidence_required_for_implemented.sql) added it to make
--    one-time evidence mandatory before an obligation could be marked
--    Implemented. That rule was withdrawn: one-time evidence is attached on
--    Operationalize but is NOT mandatory. The API no longer calls it.
--
-- SAFE TO RE-RUN. Requires 473.
-- Rollback: 475_evidence_cadence_type_mapping_fix_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.vw_pm_instance_evidence_cadence','V') IS NULL
   OR COL_LENGTH('grac_practice.organization_obligation_evidence','evidence_cadence') IS NULL
   OR OBJECT_ID('grac_practice.evidence_type_master','U') IS NULL
BEGIN
    PRINT 'ABORT (475): run 473 first (it needs Control Management 077).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. vw_pm_instance_evidence_cadence -- by-type branch maps types by name
-- =====================================================================
CREATE OR ALTER VIEW grac_practice.vw_pm_instance_evidence_cadence
AS
    -- 473: the cadence of every practice_instance_evidence row.
    -- 475: the by-type branch maps evidence types by name (see below).
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
        -- 475: oe.evidence_type_id is a GRAC_New evidence type and
        -- e.evidence_type_id a Practice Management one -- two masters. Map
        -- by name, the way sp_resolve_evidence_list (306/473) does.
        JOIN   GRAC_New.evidence_type_master get
               ON get.evidence_type_id = oe.evidence_type_id
        JOIN   grac_practice.evidence_type_master pet
               ON pet.evidence_type_name = get.evidence_type_name
              AND pet.is_active = 1
        WHERE  e.source_obligation_id IS NOT NULL
          AND  oe.organization_id  = e.organization_id
          AND  oe.obligation_id    = e.source_obligation_id
          AND  pet.evidence_type_id = e.evidence_type_id
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

-- =====================================================================
-- 2. Withdrawn rule: drop the check procedure if an earlier draft made it
-- =====================================================================
IF OBJECT_ID('grac_practice.sp_resolve_obligation_implementation_evidence_check','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_resolve_obligation_implementation_evidence_check;
GO

PRINT 'OK (475): cadence view maps evidence types by name.';
GO
SET NOEXEC OFF;
GO
