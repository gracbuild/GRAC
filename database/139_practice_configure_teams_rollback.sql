-- =====================================================================
-- 139 Practice Configure -- ROLLBACK
--
-- Drops the three procedures. NOTHING ELSE.
--
-- Practice instances, their Team dependencies and their resolutions are
-- ordinary rows created through the normal tables; they are left exactly
-- where they are. Dropping them here would destroy real operational data
-- (evidence, assurance activities and tasks hang off an instance) on what
-- is meant to be a code rollback.
--
-- To find what Configure created, if you do need to unwind it by hand:
--
--     SELECT pi.practice_instance_id, pi.instance_code, pi.instance_name,
--            r.resolved_dependency_name AS TeamName, pi.entered_by, pi.entered_dt
--     FROM   grac_practice.practice_instance pi
--     JOIN   grac_practice.practice_dependency_resolution r
--            ON r.practice_instance_id = pi.practice_instance_id
--     JOIN   grac_practice.dependency_type_master dt
--            ON dt.dependency_type_id = r.dependency_type_id
--     WHERE  dt.dependency_type_name = N'Team'
--       AND  pi.instance_code LIKE N'PR[_]%'
--     ORDER  BY pi.entered_dt DESC;
--
-- Retire rather than delete: set pi.status = N'Retired'.
--
-- Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_practice_instance_configure','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_practice_instance_configure;
GO

IF OBJECT_ID('grac_practice.sp_practice_team_option_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_practice_team_option_list;
GO

IF OBJECT_ID('grac_practice.sp_practice_detail_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_practice_detail_get;
GO

SELECT 'procedures dropped' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_instance_configure','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_practice_team_option_list','P')   IS NULL
             AND OBJECT_ID('grac_practice.sp_practice_detail_get','P')         IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- What Configure has created so far, left untouched by this rollback.
SELECT COUNT(*) AS ConfiguredInstancesRemaining
FROM   grac_practice.practice_instance
WHERE  instance_code LIKE N'PR[_]%';

PRINT '139 rolled back: procedures dropped, instance data left intact.';
GO
