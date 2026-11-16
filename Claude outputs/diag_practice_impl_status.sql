-- =====================================================================
-- Diagnostic (read-only): why does a practice show Implemented while one
-- of its instances shows Not Updated?
--
-- Set @org and @practice_code (the code shown in Practice View), run,
-- and send back both result sets. Nothing is changed.
-- =====================================================================
DECLARE @org           BIGINT        = 1;           -- organization id
DECLARE @practice_code NVARCHAR(100) = N'PUT-CODE';  -- practice / requirement code

-- 1. Every instance of the practice, as Practice View lists it (text
--    column) next to what the roll-up counts (status id -> master) and
--    whether the roll-up includes it at all (pi.status = Active).
SELECT q.organization_requirement_id,
       q.requirement_code,
       p.practice_id,
       p.status                         AS practice_row_status,
       pi.practice_instance_id,
       pi.instance_code,
       pi.status                        AS instance_status,          -- roll-up counts only 'Active'
       pi.implementation_status         AS shown_in_practice_view,   -- the text Practice View prints
       pi.implementation_status_id,
       ism.status_code                  AS counted_by_rollup_as,     -- what the roll-up tests
       pi.updated_by, pi.updated_dt
FROM grac_practice.organization_requirement q
JOIN grac_practice.practice p            ON p.organization_requirement_id = q.organization_requirement_id
LEFT JOIN grac_practice.practice_instance pi ON pi.practice_id = p.practice_id
LEFT JOIN grac_practice.implementation_status_master ism ON ism.implementation_status_id = pi.implementation_status_id
WHERE q.organization_id = @org
  AND (q.requirement_code = @practice_code OR p.practice_code = @practice_code)
ORDER BY p.practice_id, pi.practice_instance_id;

-- 2. The roll-up exactly as the Practices grid / Practice View compute it.
SELECT q.organization_requirement_id,
       COUNT_BIG(pi.practice_instance_id)                                   AS InstanceCount,
       COUNT_BIG(CASE WHEN ism.status_code = N'Implemented' THEN 1 END)     AS ImplementedInstanceCount
FROM grac_practice.organization_requirement q
JOIN grac_practice.practice pp           ON pp.organization_requirement_id = q.organization_requirement_id
JOIN grac_practice.practice_instance pi  ON pi.practice_id = pp.practice_id
                                        AND pi.organization_id = q.organization_id
                                        AND pi.status = N'Active'
LEFT JOIN grac_practice.implementation_status_master ism ON ism.implementation_status_id = pi.implementation_status_id
WHERE q.organization_id = @org
  AND q.requirement_code = @practice_code
GROUP BY q.organization_requirement_id;
