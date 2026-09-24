-- =====================================================================
-- 342_functional_owners_lookup.sql
--
-- WHY THIS EXISTS
-- ---------------
-- Owner dropdowns must offer only Functional Users (341). Owner pickers
-- in the Organization-Setup forms are fed by the generic /lookups
-- payload's `users-id` (numeric employee_id) and `users` (employee_name)
-- lists -- but those SAME lists also feed NON-owner pickers (Location
-- Head, Department Head, Team Manager, Chairperson, Reporting Officer,
-- Task Assigned To), which must keep every user. So the users lists
-- cannot be filtered in place.
--
-- Following the project's shim pattern (241 asset-taxonomy, 244
-- connection-types, 248 implementation-status-id) -- which deliberately
-- avoids editing the monolith pm_get_practice_repository -- this adds a
-- dedicated `owners` lookup entity returning only functional users. The
-- UI intersects it with the already-org-scoped users/users-id lists to
-- build functional-only `owners`/`owners-id` pickers, leaving the shared
-- lists untouched.
--
-- Same 7-parameter signature as the other lookup shims so the generic
-- query path (ResolveProcedureAsync) routes to it via the same mapping.
-- Read-only master-ish data; the id list is returned across every
-- organization (the UI intersects with the org-scoped users list, so no
-- scoping is duplicated here).
--
-- SAFE TO RE-RUN. Requires 341 (is_functional_user) and 009
-- (organization_employee). ASCII-only.
-- Rollback: database/342_functional_owners_lookup_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF COL_LENGTH('grac_practice.organization_employee','is_functional_user') IS NULL
BEGIN
    PRINT 'ABORT (342): organization_employee.is_functional_user missing. Run 341 first.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_get_owners_lookup
    -- 7-parameter signature mirrors the other lookup shims so
    -- ResolveProcedureAsync can invoke it with its standard argument
    -- list. Parameters are read and ignored -- the UI does the org
    -- scoping by intersecting with the users list.
    @p_entity_type   NVARCHAR(100) = N'',
    @p_action        NVARCHAR(40)  = N'',
    @p_id            BIGINT        = 0,
    @p_search        NVARCHAR(250) = N'',
    @p_status        NVARCHAR(30)  = N'',
    @p_payload       NVARCHAR(MAX) = N'{}',
    @p_usr_id        NVARCHAR(200) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    SELECT N'owners'                                   AS EntityType,
           CAST(e.employee_id AS NVARCHAR(40))         AS Value,   -- matches users-id.value
           e.employee_name                             AS Label,   -- matches users.value (name)
           e.organization_id                           AS OrganizationId,
           e.employee_name                             AS EmployeeName
    FROM   grac_practice.organization_employee e
    WHERE  e.is_functional_user = 1
      AND  e.status = N'Active'
    ORDER  BY e.organization_id, e.employee_name;
END
GO
PRINT '342: sp_get_owners_lookup ready.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 342 verification ===';
SELECT '342 shim proc present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_get_owners_lookup','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO

SET NOEXEC OFF;
GO
