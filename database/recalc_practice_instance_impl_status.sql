-- =====================================================================
-- recalc_practice_instance_impl_status.sql
--
-- One-time recalculation of every existing Practice Instance's
-- implementation status from its obligations.
--
-- Rule (binary):
--   Implemented      -> every APPLICABLE obligation is Implemented
--   Not Implemented  -> any applicable obligation is anything else
--                       (Not Set / Not Started, Partially Implemented,
--                        Not Implemented)
--
--   * "Applicable" = the instance's ACTIVE obligations that are not N/A.
--   * An instance with NO applicable obligations is LEFT UNCHANGED
--     (never auto-marked Implemented).
--
-- Safe to run any number of times (it only writes rows whose value
-- actually changes). Run it in the target database (the one holding the
-- grac_practice schema). ASCII-only.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @implemented_id INT =
    (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'Implemented');
DECLARE @not_impl_id INT =
    (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'Not Implemented');

IF @implemented_id IS NULL OR @not_impl_id IS NULL
BEGIN
    RAISERROR('implementation_status_master is missing the Implemented / Not Implemented rows. Run migration 043 first.', 16, 1);
END
ELSE
BEGIN
    ;WITH agg AS (
        SELECT pio.practice_instance_id,
               COUNT(*) AS effective_n,
               SUM(CASE WHEN COALESCE(ims.status_code, N'Not Started') = N'Implemented' THEN 1 ELSE 0 END) AS implemented_n
        FROM   grac_practice.practice_instance_obligation pio
        LEFT   JOIN grac_practice.implementation_status_master ims
               ON ims.implementation_status_id = pio.implementation_status_id
        WHERE  pio.status = N'Active'
          AND  COALESCE(ims.status_code, N'Not Started') <> N'N/A'
        GROUP  BY pio.practice_instance_id
    )
    UPDATE pi
       SET implementation_status    = d.derived_code,
           implementation_status_id = d.derived_id,
           updated_by               = N'impl-recalc',
           updated_dt               = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance pi
    JOIN   agg ON agg.practice_instance_id = pi.practice_instance_id
    CROSS  APPLY (SELECT
                     CASE WHEN agg.implemented_n = agg.effective_n THEN N'Implemented' ELSE N'Not Implemented' END AS derived_code,
                     CASE WHEN agg.implemented_n = agg.effective_n THEN @implemented_id ELSE @not_impl_id END       AS derived_id) d
    WHERE  agg.effective_n > 0
      AND (pi.implementation_status <> d.derived_code
           OR ISNULL(pi.implementation_status_id, -1) <> d.derived_id);

    PRINT CONCAT('Practice instances updated: ', @@ROWCOUNT);

    -- Resulting distribution (instances with applicable obligations show
    -- only Implemented / Not Implemented; the rest keep their prior value).
    SELECT COALESCE(pi.implementation_status, N'(null)') AS ImplementationStatus,
           COUNT(*) AS Instances
    FROM   grac_practice.practice_instance pi
    GROUP  BY pi.implementation_status
    ORDER  BY ImplementationStatus;
END
GO
