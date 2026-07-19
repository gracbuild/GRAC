-- =====================================================================
-- 043 sp_practice_instance_get_context
--
-- Read-only helper: returns display fields needed to pre-fill the
-- "Add Implementation Task" modal.
--
-- Output columns:
--   PracticeInstanceId       BIGINT
--   InstanceCode             NVARCHAR
--   InstanceName             NVARCHAR
--   PracticeId               BIGINT
--   PracticeCode             NVARCHAR
--   PracticeName             NVARCHAR
--   OrganizationId           BIGINT
--   OrganizationName         NVARCHAR
--   ImplementationStatusCode NVARCHAR
--   ImplementationStatusName NVARCHAR
--
-- Returns 0 rows when the instance does not exist. Never throws.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 54310, 'schema grac_practice missing', 1;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_practice_instance_get_context
    @practice_instance_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT pi.practice_instance_id            AS PracticeInstanceId,
           pi.instance_code                   AS InstanceCode,
           pi.instance_name                   AS InstanceName,
           p.practice_id                      AS PracticeId,
           p.practice_code                    AS PracticeCode,
           p.practice_name                    AS PracticeName,
           o.organization_id                  AS OrganizationId,
           o.organization_name                AS OrganizationName,
           COALESCE(ims.status_code, pi.implementation_status) AS ImplementationStatusCode,
           COALESCE(ims.status_name, pi.implementation_status) AS ImplementationStatusName
    FROM grac_practice.practice_instance pi
    LEFT JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
    LEFT JOIN grac_practice.organization o ON o.organization_id = pi.organization_id
    LEFT JOIN grac_practice.implementation_status_master ims ON ims.implementation_status_id = pi.implementation_status_id
    WHERE pi.practice_instance_id = @practice_instance_id;
END;
GO

PRINT '043 sp_practice_instance_get_context installed.';
GO

SET NOEXEC OFF;
GO
