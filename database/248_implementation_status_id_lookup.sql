-- =====================================================================
-- 248 Implementation-status id-valued lookup shim
--
-- WHY THIS EXISTS
-- ---------------
-- The generic /lookups endpoint (pm_get_practice_repository line ~1891)
-- emits 'implementation-status' with Value = status_code -- 'Not
-- Implemented', 'Partially Implemented', ... That is what the pre-
-- resolve Practice Instance form used, and changing its shape would
-- rewrite the value stored on practice_instance.implementation_status.
--
-- The Resolve workspace, however, writes an INT id
-- (practice_instance_obligation.implementation_status_id, added in
-- 242) and its save path sends the dropdown value straight through
-- as $.implementationStatusId. When the value is a code string, the
-- OPENJSON extraction to INT returns NULL, the MERGE COALESCEs onto
-- the stored NULL, and the row stays without a status -- silently.
-- The sync proc (245) then excludes it from @current and no gap
-- row is opened, which is exactly what the user hit: "Not Implemented
-- save cheythirunnu, but Gap Center lu vannilla."
--
-- The right fix is a lookup whose Value IS the id -- so the dropdown
-- posts a number the schema can accept. Rather than mutate the
-- 'implementation-status' UNION (which the Practice Instance form
-- would then also see and misinterpret), 248 adds a second entity
-- 'implementation-status-id' backed by a dedicated shim.
--
-- Same shape and 7-param signature as sp_get_asset_taxonomy_lookup
-- (241) and sp_get_connection_type_lookup (244), so the generic query
-- path in ResolveProcedureAsync can route to it via the same shim
-- mapping. The UI switches to fetching this entity instead of picking
-- 'implementation-status' from the /lookups bulk payload.
--
-- SAFE TO RE-RUN. Requires migration 002 (implementation_status_master).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (248): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.implementation_status_master','U') IS NULL
BEGIN
    PRINT 'ABORT (248): implementation_status_master missing (run 002 first).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_get_implementation_status_id_lookup
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_get_implementation_status_id_lookup
    -- 7-parameter signature mirrors sp_get_asset_taxonomy_lookup /
    -- sp_get_connection_type_lookup so ResolveProcedureAsync can
    -- invoke the shim with its standard argument list. The lookup
    -- is master data, so parameters are read and ignored.
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

    SELECT N'implementation-status-id'                        AS EntityType,
           CAST(implementation_status_id AS NVARCHAR(40))     AS Value,
           status_name                                        AS Label,
           status_code                                        AS Code,
           display_order                                      AS DisplayOrder
    FROM   grac_practice.implementation_status_master
    WHERE  is_active = 1
    ORDER  BY display_order, implementation_status_id;
END
GO
PRINT '248: sp_get_implementation_status_id_lookup ready.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 248 verification ===';

SELECT '248-a shim proc present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_get_implementation_status_id_lookup','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '248-b master rows still present',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.implementation_status_master
                          WHERE status_code = N'Not Implemented' AND is_active = 1)
             AND EXISTS (SELECT 1 FROM grac_practice.implementation_status_master
                          WHERE status_code = N'Partially Implemented' AND is_active = 1)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Values from the shim must be numeric ids, not codes -- otherwise
-- 248 has not solved the problem it was written for.
SELECT '248-c shim Value column is numeric',
       CASE WHEN NOT EXISTS (
                SELECT 1
                FROM   grac_practice.implementation_status_master
                WHERE  is_active = 1
                  AND  ISNUMERIC(CAST(implementation_status_id AS NVARCHAR(40))) = 0)
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '=== Current active implementation statuses (as the shim will emit) ===';
EXEC grac_practice.sp_get_implementation_status_id_lookup;

PRINT '';
PRINT '248 complete. UI + shim path can now round-trip the id.';
GO

SET NOEXEC OFF;
GO
