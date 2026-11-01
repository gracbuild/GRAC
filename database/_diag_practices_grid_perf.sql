-- =====================================================================
-- _diag_practices_grid_perf.sql  (READ-ONLY; not a migration)
--
-- The Practices grid (organization-requirements/query) takes ~1.25 s.
-- Its proc branch does THREE things; this times the two heavy reads
-- separately so we fix the right one. Run in SSMS against the local DB,
-- read the Messages tab (SET STATISTICS TIME elapsed ms per block).
-- Nothing is written (the INSERT is replaced by a COUNT). ASCII only.
-- =====================================================================
SET NOCOUNT ON;
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

DECLARE @org BIGINT = 9;   -- the org you tested
-- The control you opened on the Practices page. If unknown, this picks the
-- control under that org with the most requirements (the worst case):
DECLARE @oc BIGINT =(
    SELECT TOP 1 r.organization_control_id
    FROM grac_practice.organization_requirement r
    WHERE r.organization_id=@org
    GROUP BY r.organization_control_id
    ORDER BY COUNT(*) DESC);
PRINT CONCAT('org=',@org,' control=',@oc);

DECLARE @active_record_status_id INT =
    (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_name='Active');

PRINT '===== A. Materialization candidate CTE (the OR-join source) =====';
;WITH requirement_candidates AS (
  SELECT oc.organization_id, q.requirement_id repository_requirement_id, oc.organization_control_id,
         q.requirement_code,
         ROW_NUMBER() OVER(PARTITION BY oc.organization_id,oc.organization_control_id,q.requirement_code ORDER BY q.requirement_id) row_no
  FROM grac_practice.organization_control oc
  JOIN grac_practice.organization_repository_control repo_control ON repo_control.organization_id=oc.organization_id
    AND (repo_control.control_id=oc.repository_control_id OR repo_control.control_code=oc.control_code) AND repo_control.status='Active'
  JOIN grac_practice.organization_control_requirement_map crm ON crm.organization_id=oc.organization_id
    AND crm.control_id=repo_control.control_id AND crm.status='Active'
  JOIN grac_practice.organization_repository_requirement q ON q.organization_id=oc.organization_id
    AND q.requirement_id=crm.requirement_id AND q.status='Active'
  WHERE ISNULL(oc.origin_type,'Repository') IN ('Repository','Hybrid')
    AND oc.record_status_id=@active_record_status_id
    AND oc.organization_control_id=@oc
)
SELECT COUNT(*) AS candidate_rows FROM requirement_candidates;

PRINT '===== B. Final grid SELECT (OUTER APPLY + per-row instance count) =====';
SELECT q.organization_requirement_id Id, q.requirement_code Code,
   practice.practice_id PracticeId,
   (SELECT COUNT_BIG(1) FROM grac_practice.practice_instance pi_count
      JOIN grac_practice.practice p_count ON p_count.practice_id=pi_count.practice_id
     WHERE p_count.organization_requirement_id=q.organization_requirement_id AND pi_count.status='Active') PracticeInstanceCount,
   COUNT(*) OVER () AS TotalRows
FROM grac_practice.organization_requirement q
OUTER APPLY (
   SELECT TOP (1) p.practice_id, p.practice_owner_id, p.practice_owner
   FROM grac_practice.practice p
   WHERE p.organization_id=q.organization_id AND p.organization_requirement_id=q.organization_requirement_id AND p.status='Active'
   ORDER BY p.practice_id) practice
WHERE q.organization_id=@org
  AND (q.organization_control_id=@oc
       OR EXISTS(SELECT 1 FROM grac_practice.organization_control_requirement m
                  WHERE m.organization_requirement_id=q.organization_requirement_id
                    AND m.organization_control_id=@oc AND m.status='Active'))
ORDER BY q.requirement_code OFFSET 0 ROWS FETCH NEXT 25 ROWS ONLY;

SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
GO
