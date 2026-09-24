-- =====================================================================
-- 346_instance_impl_status_derived.sql
--
-- WHY
-- ---
-- Practice Instance implementation status was maintained independently
-- of its obligations -- set on the instance form, by
-- sp_practice_instance_configure, and by the "Update Implementation
-- Status" popup. The business rule is that a Practice Instance is only
-- as implemented as its obligations, with exactly two effective values:
--
--     Implemented      -- every applicable obligation is Implemented
--     Not Implemented  -- any obligation is anything else
--                         (Not Set / Not Started, Partially Implemented,
--                          Not Implemented)
--
-- This migration makes that derivation the source of truth:
--   1. sp_pm_recalc_instance_impl_status -- recomputes one instance
--      (or all) from its obligations, writing practice_instance
--      .implementation_status(+_id). Only writes when the value
--      actually changes.
--   2. tr_pm_pio_impl_status_rollup -- fires on every INSERT / UPDATE /
--      DELETE of practice_instance_obligation and recomputes the
--      affected instance(s), so the status can never drift from the
--      obligations, whatever path changed them (adopt, local save,
--      retire, bulk).
--   3. A one-time backfill so existing instances already reflect the
--      rule.
--
-- N/A obligations are excluded from the calculation (an obligation the
-- organisation marked Not Applicable is not outstanding work), matching
-- vw_pm_instance_effective_impl_status (243).
--
-- NO-OBLIGATION RULE: an instance with zero applicable (non-N/A, active)
-- obligations is LEFT UNTOUCHED -- it is never auto-marked Implemented.
-- This preserves the existing default ('Not Started' from
-- sp_practice_instance_configure) for a fresh instance.
--
-- The instance-form Implementation Status field is made read-only in the
-- Web tier (practice.js) so the value cannot be set by hand; this
-- database layer is the enforcement so the status stays consistent even
-- if a value is written directly.
--
-- SAFE TO RE-RUN. Requires 242 (practice_instance_obligation
-- .implementation_status_id) and 043 (status master values). ASCII-only.
-- Rollback: database/346_instance_impl_status_derived_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF COL_LENGTH('grac_practice.practice_instance_obligation','implementation_status_id') IS NULL
BEGIN
    PRINT 'ABORT (346): practice_instance_obligation.implementation_status_id missing. Run 242 first.';
    SET NOEXEC ON;
END
GO

IF NOT EXISTS (SELECT 1 FROM grac_practice.implementation_status_master WHERE status_code = N'Implemented')
   OR NOT EXISTS (SELECT 1 FROM grac_practice.implementation_status_master WHERE status_code = N'Not Implemented')
BEGIN
    PRINT 'ABORT (346): implementation_status_master missing Implemented / Not Implemented. Run 043 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Recompute procedure (single instance, or all when @p_... IS NULL)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_pm_recalc_instance_impl_status
    @p_practice_instance_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @implemented_id INT =
        (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'Implemented');
    DECLARE @not_impl_id INT =
        (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'Not Implemented');
    IF @implemented_id IS NULL OR @not_impl_id IS NULL RETURN;

    ;WITH agg AS (
        SELECT pio.practice_instance_id,
               COUNT(*) AS effective_n,
               SUM(CASE WHEN COALESCE(ims.status_code, N'Not Started') = N'Implemented' THEN 1 ELSE 0 END) AS implemented_n
        FROM   grac_practice.practice_instance_obligation pio
        LEFT   JOIN grac_practice.implementation_status_master ims
               ON ims.implementation_status_id = pio.implementation_status_id
        WHERE  pio.status = N'Active'
          AND  COALESCE(ims.status_code, N'Not Started') <> N'N/A'
          AND  (@p_practice_instance_id IS NULL OR pio.practice_instance_id = @p_practice_instance_id)
        GROUP  BY pio.practice_instance_id
    )
    UPDATE pi
       SET implementation_status    = d.derived_code,
           implementation_status_id = d.derived_id,
           updated_by               = N'derive-346',
           updated_dt               = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance pi
    JOIN   agg ON agg.practice_instance_id = pi.practice_instance_id
    CROSS  APPLY (SELECT
                     CASE WHEN agg.implemented_n = agg.effective_n THEN N'Implemented' ELSE N'Not Implemented' END AS derived_code,
                     CASE WHEN agg.implemented_n = agg.effective_n THEN @implemented_id ELSE @not_impl_id END       AS derived_id) d
    WHERE  agg.effective_n > 0                       -- no applicable obligations => leave untouched
      AND (pi.implementation_status <> d.derived_code
           OR ISNULL(pi.implementation_status_id, -1) <> d.derived_id);
END
GO
PRINT '346: sp_pm_recalc_instance_impl_status ready.';
GO

-- =====================================================================
-- 2. Rollup trigger on the obligation table
-- =====================================================================
CREATE OR ALTER TRIGGER grac_practice.tr_pm_pio_impl_status_rollup
ON grac_practice.practice_instance_obligation
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    -- Distinct instances touched by this statement (inserted + deleted).
    DECLARE @affected INT =
        (SELECT COUNT(DISTINCT practice_instance_id)
         FROM (SELECT practice_instance_id FROM inserted
               UNION ALL
               SELECT practice_instance_id FROM deleted) z
         WHERE practice_instance_id IS NOT NULL);

    IF @affected = 0 RETURN;

    IF @affected = 1
    BEGIN
        DECLARE @pid BIGINT =
            (SELECT MIN(practice_instance_id)
             FROM (SELECT practice_instance_id FROM inserted
                   UNION ALL
                   SELECT practice_instance_id FROM deleted) z
             WHERE practice_instance_id IS NOT NULL);
        EXEC grac_practice.sp_pm_recalc_instance_impl_status @pid;
    END
    ELSE
    BEGIN
        -- Rare: one statement spanning several instances (e.g. a bulk
        -- admin update). Recompute all -- correctness over micro-tuning.
        EXEC grac_practice.sp_pm_recalc_instance_impl_status NULL;
    END
END
GO
PRINT '346: tr_pm_pio_impl_status_rollup ready.';
GO

-- =====================================================================
-- 3. One-time backfill of existing instances
-- =====================================================================
EXEC grac_practice.sp_pm_recalc_instance_impl_status NULL;
GO
PRINT '346: existing practice instances recalculated.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 346 verification ===';
SELECT '346 objects present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_pm_recalc_instance_impl_status','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.tr_pm_pio_impl_status_rollup','TR') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- Every instance that has at least one applicable obligation must now be
-- exactly Implemented or Not Implemented, and Implemented only when all
-- of its applicable obligations are Implemented.
SELECT 'Derived-status consistency' AS Check_,
       CASE WHEN NOT EXISTS (
           SELECT 1
           FROM (
               SELECT pio.practice_instance_id,
                      COUNT(*) AS eff_n,
                      SUM(CASE WHEN COALESCE(ims.status_code, N'Not Started') = N'Implemented' THEN 1 ELSE 0 END) AS impl_n
               FROM   grac_practice.practice_instance_obligation pio
               LEFT   JOIN grac_practice.implementation_status_master ims
                      ON ims.implementation_status_id = pio.implementation_status_id
               WHERE  pio.status = N'Active'
                 AND  COALESCE(ims.status_code, N'Not Started') <> N'N/A'
               GROUP  BY pio.practice_instance_id
               HAVING COUNT(*) > 0
           ) a
           JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = a.practice_instance_id
           WHERE pi.implementation_status <>
                 CASE WHEN a.impl_n = a.eff_n THEN N'Implemented' ELSE N'Not Implemented' END
       ) THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
