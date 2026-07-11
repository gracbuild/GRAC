/*  Quick check: is practice_dependency_resolution completely empty,
    or are rows saved with wrong is_active / status? */

-- All rows regardless of is_active
SELECT
    resolution_id,
    organization_id,
    practice_instance_id,
    dependency_type_id,
    resolved_dependency_id,
    resolved_dependency_name,
    resolution_status_id,
    resolution_status,
    is_active,
    record_status_id,
    entered_by,
    entered_dt
FROM grac_practice.practice_dependency_resolution
ORDER BY entered_dt DESC;

-- Row count
SELECT COUNT(*) TotalRows FROM grac_practice.practice_dependency_resolution;
