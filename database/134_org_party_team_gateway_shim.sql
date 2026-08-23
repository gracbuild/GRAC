-- =====================================================================
-- 134 Gateway shims for users / teams -- monolith-compatible contract
--
-- WHAT 133 LEFT OPEN
-- ------------------
-- 133 created sp_org_user_save / sp_org_team_save with clean signatures.
-- The gateway cannot call them as they are: PracticeRepositoryService
-- invokes one procedure name with a fixed seven-parameter contract
--     @p_entity_type, @p_action, @p_id, @p_search, @p_status,
--     @p_payload, @p_usr_id
-- and performs the organization-access and release-scope enforcement
-- itself, before the call. Reaching a differently-shaped procedure would
-- mean threading a second code path through that method.
--
-- WHAT I UNDERSTATED WHEN RECOMMENDING THE SPLIT
-- ----------------------------------------------
-- The users and teams SAVE logic is entity-specific, but three things
-- around it are shared by all forty-odd entity types:
--     * @p_action = 'RETIRE' is handled once, generically, at the top of
--       dbo.pm_manage_practice_repository -- including for users and teams;
--     * every save appends to grac_practice.practice_audit_trace;
--     * every save returns SELECT Success, Message, Id.
-- Reproducing all of that per entity would defeat the point of splitting.
--
-- SO THE SHIM ONLY INTERCEPTS SAVE
-- --------------------------------
-- Anything that is not a save -- RETIRE today, and whatever generic action
-- is added tomorrow -- is passed straight back to the monolith, unchanged.
-- That keeps exactly one implementation of the shared behaviour and leaves
-- the shim responsible for one thing: the entity save.
--
-- Nested transactions are safe here: the monolith opens and commits its
-- own, which under an outer transaction only decrements @@TRANCOUNT.
--
-- Objects:
--   * sp_org_user_repository_manage  NEW  (monolith contract)
--   * sp_org_team_repository_manage  NEW  (monolith contract)
--   * sp_org_user_repository_get     NEW  (monolith contract)
--   * sp_org_team_repository_get     NEW  (monolith contract)
--
-- Depends on 133.
-- Rollback: 134_org_party_team_gateway_shim_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_org_user_save','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_team_save','P') IS NULL
BEGIN
    RAISERROR('134: run 133 first.', 16, 1);
    RETURN;
END
GO


-- =====================================================================
-- sp_org_user_repository_manage
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_user_repository_manage
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30),
    @p_id          BIGINT = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30) = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @p_action  = ISNULL(@p_action, '');
    SET @p_payload = ISNULL(NULLIF(@p_payload, ''), '{}');
    SET @p_usr_id  = ISNULL(NULLIF(@p_usr_id, ''), 'system');

    -- Not a save: the monolith owns it. Passing @p_entity_type through
    -- unchanged means RETIRE keeps its generic organization-access check.
    IF @p_action <> N'SAVE' AND @p_action <> N''
    BEGIN
        EXEC dbo.pm_manage_practice_repository
             @p_entity_type = @p_entity_type, @p_action = @p_action, @p_id = @p_id,
             @p_search = @p_search, @p_status = @p_status,
             @p_payload = @p_payload, @p_usr_id = @p_usr_id;
        RETURN;
    END

    BEGIN TRAN;

    DECLARE @new_id BIGINT = @p_id;
    EXEC grac_practice.sp_org_user_save
         @p_payload = @p_payload, @p_id = @p_id, @p_usr_id = @p_usr_id,
         @out_id = @new_id OUTPUT;

    -- Same audit row the monolith writes, so the trace stays continuous
    -- across the boundary and nothing downstream has to know a save was
    -- handled by a different procedure.
    INSERT grac_practice.practice_audit_trace
        (entity_type, entity_id, action_type, after_json, status, entered_by)
    VALUES (@p_entity_type, @new_id, N'SAVE', @p_payload, 'Active', @p_usr_id);

    COMMIT;

    SELECT CAST(1 AS BIT) Success, N'Saved successfully.' Message, @new_id Id;
END;
GO


-- =====================================================================
-- sp_org_team_repository_manage
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_team_repository_manage
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30),
    @p_id          BIGINT = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30) = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @p_action  = ISNULL(@p_action, '');
    SET @p_payload = ISNULL(NULLIF(@p_payload, ''), '{}');
    SET @p_usr_id  = ISNULL(NULLIF(@p_usr_id, ''), 'system');

    IF @p_action <> N'SAVE' AND @p_action <> N''
    BEGIN
        EXEC dbo.pm_manage_practice_repository
             @p_entity_type = @p_entity_type, @p_action = @p_action, @p_id = @p_id,
             @p_search = @p_search, @p_status = @p_status,
             @p_payload = @p_payload, @p_usr_id = @p_usr_id;
        RETURN;
    END

    BEGIN TRAN;

    DECLARE @new_id BIGINT = @p_id;
    EXEC grac_practice.sp_org_team_save
         @p_payload = @p_payload, @p_id = @p_id, @p_usr_id = @p_usr_id,
         @out_id = @new_id OUTPUT;

    INSERT grac_practice.practice_audit_trace
        (entity_type, entity_id, action_type, after_json, status, entered_by)
    VALUES (@p_entity_type, @new_id, N'SAVE', @p_payload, 'Active', @p_usr_id);

    COMMIT;

    SELECT CAST(1 AS BIT) Success, N'Saved successfully.' Message, @new_id Id;
END;
GO


-- =====================================================================
-- Read shims.
--
-- organizationId, pageNumber and pageSize all arrive inside @p_payload,
-- exactly as the monolith reads them. Defaulting @organization_id to NULL
-- instead of unpacking it would return EVERY organization's users to
-- whoever asked -- a tenant leak, not a paging bug. It is unpacked here
-- for that reason.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_user_repository_get
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30) = 'QUERY',
    @p_id          BIGINT = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30) = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SET @p_payload = ISNULL(NULLIF(@p_payload, ''), '{}');

    DECLARE @organization_id BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
    DECLARE @page_number INT = ISNULL(NULLIF(TRY_CONVERT(INT, JSON_VALUE(@p_payload,'$.pageNumber')),0),1);
    DECLARE @page_size   INT = ISNULL(NULLIF(TRY_CONVERT(INT, JSON_VALUE(@p_payload,'$.pageSize')),0),25);

    EXEC grac_practice.sp_org_user_list
         @p_id            = @p_id,
         @organization_id = @organization_id,
         @p_status        = @p_status,
         @p_search        = @p_search,
         @p_page_number   = @page_number,
         @p_page_size     = @page_size;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_team_repository_get
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30) = 'QUERY',
    @p_id          BIGINT = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30) = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SET @p_payload = ISNULL(NULLIF(@p_payload, ''), '{}');

    DECLARE @organization_id BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.organizationId'),''));
    DECLARE @page_number INT = ISNULL(NULLIF(TRY_CONVERT(INT, JSON_VALUE(@p_payload,'$.pageNumber')),0),1);
    DECLARE @page_size   INT = ISNULL(NULLIF(TRY_CONVERT(INT, JSON_VALUE(@p_payload,'$.pageSize')),0),25);

    EXEC grac_practice.sp_org_team_list
         @p_id            = @p_id,
         @organization_id = @organization_id,
         @p_status        = @p_status,
         @p_search        = @p_search,
         @p_page_number   = @page_number,
         @p_page_size     = @page_size;
END;
GO


-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'sp_org_user_repository_manage' AS Check_, CASE WHEN OBJECT_ID('grac_practice.sp_org_user_repository_manage','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'sp_org_team_repository_manage', CASE WHEN OBJECT_ID('grac_practice.sp_org_team_repository_manage','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_org_user_repository_get',    CASE WHEN OBJECT_ID('grac_practice.sp_org_user_repository_get','P')    IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_org_team_repository_get',    CASE WHEN OBJECT_ID('grac_practice.sp_org_team_repository_get','P')    IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

-- All four must accept the monolith's seven parameters, or the gateway's
-- generic call will fail at run time with a parameter mismatch.
SELECT p.name AS ProcedureName, COUNT(*) AS ParameterCount,
       CASE WHEN COUNT(*) = 7 THEN 'PASS' ELSE 'FAIL -- must be 7' END AS Result
FROM   sys.procedures p
JOIN   sys.parameters pa ON pa.object_id = p.object_id
WHERE  p.name IN ('sp_org_user_repository_manage','sp_org_team_repository_manage',
                  'sp_org_user_repository_get','sp_org_team_repository_get')
GROUP BY p.name
ORDER BY p.name;

PRINT '134 Gateway shims deployed.';
PRINT 'NEXT: map users / teams to these procedure names in PracticeRepositoryService,';
PRINT '      then add the fields to wwwroot/js/practice.js.';
GO
