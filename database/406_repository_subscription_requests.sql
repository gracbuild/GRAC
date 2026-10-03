-- =====================================================================
-- 406 Repository subscription requests
--
-- Add Release gets a second option, "Subscribe from Repository": an
-- organization lists the central Repository releases, sees whether it is
-- Subscribed / Request Pending / Rejected, and requests the ones it does
-- not have. Control Management reviews each request (Subscription
-- Requests, ControlManagement migration 068) and approves or rejects it.
--
--   Organization -> Request -> Pending -> Control Management -> Approve / Reject
--
-- WHY A REQUEST TABLE (and not a Pending row in repository_subscription)
--   repository_subscription is the subscription itself: one row per
--   organization + release, re-activated in place by Organization Setup,
--   and read by every governance screen. It has no requester, no decision,
--   no reason and no history. A request can be rejected and asked again,
--   and the history must stay (spec 8), so requests get their own rows.
--   The status vocabulary Pending / Approved / Rejected is the one the
--   existing approval table organization_repository_change (395) uses;
--   subscription_status_master (Active / Disabled / Superseded / Pending
--   Review) describes a subscription, not a request, and is not reused.
--
-- WHAT THIS FILE ADDS
--   Table      repository_subscription_request
--   Procedures sp_repository_subscription_request_get     gateway shim (query)
--              sp_repository_subscription_request_manage  gateway shim (SAVE = submit)
--              sp_repository_subscription_request_list    Control Management list
--              sp_repository_subscription_request_decide  Approve / Reject
--
-- REUSED, NOT REIMPLEMENTED
--   * Eligible releases = the exact rule Organization Setup's subscription
--     tree uses (pm_get_practice_repository 'repository-subscription-tree'):
--     authority Active, artifact Active, release Draft or Active.
--   * Approval subscribes through dbo.pm_manage_practice_repository
--     'repository-subscriptions' SAVE -- the existing single-subscription
--     path: insert or re-activate the subscription, copy the release
--     (sp_repository_subscription_copy), create the organization controls.
--     An already active subscription is linked, never duplicated.
--
-- WHO MAY DO WHAT
--   Submit  : the gateway maps this entity to organization-controls, so it
--             needs organization-controls:ADD (the Add Release permission);
--             the API checks organization access and refuses employee
--             scope, exactly as for a custom release.
--   Decide  : Control Management only (subscription-requests:APPROVE /
--             REJECT, checked by the ControlManagement API before it calls
--             sp_repository_subscription_request_decide).
--
-- ASCII-only. Re-runnable. DEPENDS ON: 404 (monolith bodies), 391-393.
-- Rollback: 406_repository_subscription_requests_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

SET NOEXEC OFF;
GO

IF OBJECT_ID('dbo.pm_manage_practice_repository','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_repository_subscription_copy','P') IS NULL
   OR OBJECT_ID('grac_practice.repository_subscription','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_audit_trace','U') IS NULL
   OR OBJECT_ID('grac_new.release','U') IS NULL
BEGIN
    PRINT 'ABORT (406): run 391-393 and 404 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Table
-- =====================================================================
IF OBJECT_ID('grac_practice.repository_subscription_request','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.repository_subscription_request(
        request_id               BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_repo_sub_request PRIMARY KEY,
        organization_id          BIGINT NOT NULL
            CONSTRAINT fk_pm_repo_sub_request_org
                REFERENCES grac_practice.organization(organization_id),
        authority_id             BIGINT NOT NULL,
        artifact_id              BIGINT NOT NULL,
        release_id               BIGINT NOT NULL,
        request_status           NVARCHAR(20) NOT NULL
            CONSTRAINT df_pm_repo_sub_request_status DEFAULT N'Pending',
        requested_by             NVARCHAR(100) NOT NULL,   -- login (session subject)
        requested_by_employee_id BIGINT NULL,              -- when the login maps to an employee of the org
        requested_dt             DATETIME2 NOT NULL
            CONSTRAINT df_pm_repo_sub_request_requested DEFAULT SYSUTCDATETIME(),
        decided_by               NVARCHAR(100) NULL,       -- Control Management login
        decided_dt               DATETIME2 NULL,
        decision_remark          NVARCHAR(1000) NULL,
        subscription_id          BIGINT NULL,              -- set on approval
        entered_by               NVARCHAR(100) NOT NULL,
        entered_dt               DATETIME2 NOT NULL
            CONSTRAINT df_pm_repo_sub_request_entered DEFAULT SYSUTCDATETIME(),
        updated_by               NVARCHAR(100) NULL,
        updated_dt               DATETIME2 NULL,
        CONSTRAINT ck_pm_repo_sub_request_status
            CHECK (request_status IN (N'Pending', N'Approved', N'Rejected'))
    );
END
GO

-- One open request per organization + release, enforced by the database
-- so two clicks (or two users) cannot both get through.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ux_pm_repo_sub_request_pending'
                 AND object_id = OBJECT_ID('grac_practice.repository_subscription_request'))
    CREATE UNIQUE INDEX ux_pm_repo_sub_request_pending
        ON grac_practice.repository_subscription_request(organization_id, release_id)
        WHERE request_status = N'Pending';
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_repo_sub_request_status'
                 AND object_id = OBJECT_ID('grac_practice.repository_subscription_request'))
    CREATE INDEX ix_pm_repo_sub_request_status
        ON grac_practice.repository_subscription_request(request_status, requested_dt);
GO

-- =====================================================================
-- 2. Organization side -- Add Release > Subscribe from Repository list
--    Gateway shim (same 7 parameters as every shim). One row per eligible
--    repository release with the organization's state for it:
--      Subscribed               active subscription
--      Request Pending          open request
--      Rejected                 latest request rejected (may ask again)
--      Request for Subscription none of the above
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_repository_subscription_request_get
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30)  = '',
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30)  = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;

    SET @p_payload = ISNULL(NULLIF(@p_payload, ''), '{}');
    SET @p_search  = NULLIF(LTRIM(RTRIM(ISNULL(@p_search, ''))), '');

    DECLARE @organization_id BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload, '$.organizationId'), ''));
    IF @organization_id IS NULL
        THROW 51401, 'Please select an organization first.', 1;

    ;WITH releases AS (
        -- Same availability rule as Organization Setup's subscription tree
        -- (pm_get_practice_repository 'repository-subscription-tree').
        SELECT au.authority_id, au.authority_code, au.authority_name,
               a.artifact_id, a.artifact_code, a.artifact_name,
               r.release_id, r.version_no, r.status AS release_status,
               r.effective_dt, r.end_dt
        FROM grac_new.authority au
        JOIN grac_new.artifact a ON a.authority_id = au.authority_id AND a.status = 'Active'
        JOIN grac_new.release  r ON r.artifact_id  = a.artifact_id  AND r.status IN ('Draft', 'Active')
        WHERE au.status = 'Active'
    ),
    subscribed AS (
        SELECT s.release_id, MAX(s.subscription_id) AS subscription_id
        FROM grac_practice.repository_subscription s
        WHERE s.organization_id = @organization_id
          AND s.status = 'Active'
          AND ISNULL(s.subscription_status, 'Active') = 'Active'
          AND s.release_id IS NOT NULL
        GROUP BY s.release_id
    ),
    latest_request AS (
        SELECT q.*, ROW_NUMBER() OVER (PARTITION BY q.release_id ORDER BY q.request_id DESC) AS rn
        FROM grac_practice.repository_subscription_request q
        WHERE q.organization_id = @organization_id
    )
    SELECT rl.authority_id   AS AuthorityId,
           rl.authority_code AS AuthorityCode,
           rl.authority_name AS AuthorityName,
           rl.artifact_id    AS ArtifactId,
           rl.artifact_code  AS ArtifactCode,
           rl.artifact_name  AS ArtifactName,
           rl.release_id     AS ReleaseId,
           rl.version_no     AS ReleaseVersion,
           rl.release_status AS ReleaseStatus,
           rl.effective_dt   AS EffectiveDate,
           rl.end_dt         AS EndDate,
           sb.subscription_id AS SubscriptionId,
           CASE WHEN sb.subscription_id IS NOT NULL THEN N'Subscribed'
                WHEN lr.request_status = N'Pending'  THEN N'Request Pending'
                WHEN lr.request_status = N'Rejected' THEN N'Rejected'
                ELSE N'Request for Subscription' END AS SubscriptionState,
           CAST(CASE WHEN sb.subscription_id IS NULL AND ISNULL(lr.request_status, N'') <> N'Pending'
                     THEN 1 ELSE 0 END AS BIT) AS CanRequest,
           lr.request_id      AS RequestId,
           lr.request_status  AS RequestStatus,
           COALESCE(e.employee_name, lr.requested_by) AS RequestedBy,
           lr.requested_dt    AS RequestedDate,
           lr.decided_dt      AS DecisionDate,
           lr.decision_remark AS DecisionRemark
    FROM releases rl
    LEFT JOIN subscribed sb ON sb.release_id = rl.release_id
    LEFT JOIN latest_request lr ON lr.release_id = rl.release_id AND lr.rn = 1
    LEFT JOIN grac_practice.organization_employee e ON e.employee_id = lr.requested_by_employee_id
    WHERE @p_search IS NULL
       OR rl.authority_code LIKE N'%' + @p_search + N'%'
       OR rl.authority_name LIKE N'%' + @p_search + N'%'
       OR rl.artifact_code  LIKE N'%' + @p_search + N'%'
       OR rl.artifact_name  LIKE N'%' + @p_search + N'%'
       OR rl.version_no     LIKE N'%' + @p_search + N'%'
    ORDER BY rl.authority_code, rl.artifact_code, rl.version_no;
END
GO

-- =====================================================================
-- 3. Organization side -- submit a request (gateway shim, SAVE only)
--    payload: organizationId, releaseId (+ _security from the API)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_repository_subscription_request_manage
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30),
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30)  = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @p_action  = UPPER(ISNULL(@p_action, ''));
    SET @p_payload = ISNULL(NULLIF(@p_payload, ''), '{}');
    SET @p_usr_id  = ISNULL(NULLIF(@p_usr_id, ''), 'system');

    -- Submitting is the only write an organization has: a request is never
    -- edited or retired from this side; Control Management decides it.
    IF @p_action NOT IN (N'SAVE', N'')
        THROW 51402, 'Only a new subscription request can be submitted.', 1;
    IF ISNULL(@p_id, 0) <> 0
        THROW 51403, 'A submitted subscription request cannot be changed.', 1;

    DECLARE @organization_id BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload, '$.organizationId'), ''));
    DECLARE @release_id      BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload, '$.releaseId'), ''));
    DECLARE @caller_employee BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload, '$._security.employeeId'), ''));

    IF @organization_id IS NULL
        THROW 51401, 'Please select an organization first.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization
                   WHERE organization_id = @organization_id AND status = 'Active')
        THROW 51404, 'The selected organization is not active.', 1;
    IF @release_id IS NULL
        THROW 51405, 'Please select a repository release.', 1;

    DECLARE @authority_id BIGINT, @artifact_id BIGINT;
    SELECT @authority_id = au.authority_id, @artifact_id = a.artifact_id
    FROM grac_new.release r
    JOIN grac_new.artifact  a  ON a.artifact_id   = r.artifact_id  AND a.status  = 'Active'
    JOIN grac_new.authority au ON au.authority_id = a.authority_id AND au.status = 'Active'
    WHERE r.release_id = @release_id
      AND r.status IN ('Draft', 'Active');
    IF @artifact_id IS NULL
        THROW 51406, 'This release is not available for subscription in the Repository.', 1;

    -- The requester is recorded as an employee only when the login belongs
    -- to this organization; otherwise the login alone is kept.
    IF @caller_employee IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                       WHERE employee_id = @caller_employee AND organization_id = @organization_id)
        SET @caller_employee = NULL;

    BEGIN TRAN;

    IF EXISTS (SELECT 1 FROM grac_practice.repository_subscription WITH (UPDLOCK, HOLDLOCK)
               WHERE organization_id = @organization_id AND release_id = @release_id
                 AND status = 'Active' AND ISNULL(subscription_status, 'Active') = 'Active')
        THROW 51407, 'This organization is already subscribed to this release.', 1;

    IF EXISTS (SELECT 1 FROM grac_practice.repository_subscription_request WITH (UPDLOCK, HOLDLOCK)
               WHERE organization_id = @organization_id AND release_id = @release_id
                 AND request_status = N'Pending')
        THROW 51408, 'A subscription request for this release is already pending.', 1;

    INSERT grac_practice.repository_subscription_request
        (organization_id, authority_id, artifact_id, release_id, request_status,
         requested_by, requested_by_employee_id, entered_by)
    VALUES (@organization_id, @authority_id, @artifact_id, @release_id, N'Pending',
            @p_usr_id, @caller_employee, @p_usr_id);

    DECLARE @new_id BIGINT = SCOPE_IDENTITY();

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, after_json, status, entered_by)
    VALUES (N'repository-subscription-requests', @new_id, N'REQUEST',
            (SELECT @organization_id AS organizationId, @release_id AS releaseId, N'Pending' AS requestStatus
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            'Active', @p_usr_id);

    COMMIT;

    SELECT CAST(1 AS BIT) Success, N'Subscription request submitted for approval.' Message, @new_id Id;
END
GO

-- =====================================================================
-- 4. Control Management side -- list (all organizations)
--    @status: '' = all, else Pending / Approved / Rejected
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_repository_subscription_request_list
    @request_id BIGINT        = 0,
    @status     NVARCHAR(20)  = N'',
    @search     NVARCHAR(250) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET @status = NULLIF(LTRIM(RTRIM(ISNULL(@status, N''))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(ISNULL(@search, N''))), N'');

    SELECT q.request_id                         AS Id,
           q.organization_id                    AS OrganizationId,
           o.organization_code                  AS OrganizationCode,
           o.organization_name                  AS OrganizationName,
           q.authority_id                       AS AuthorityId,
           au.authority_code                    AS AuthorityCode,
           au.authority_name                    AS AuthorityName,
           q.artifact_id                        AS ArtifactId,
           a.artifact_code                      AS ArtifactCode,
           a.artifact_name                      AS ArtifactName,
           q.release_id                         AS ReleaseId,
           r.version_no                         AS ReleaseVersion,
           r.status                             AS ReleaseStatus,
           q.request_status                     AS Status,
           q.requested_by                       AS RequestedByLogin,
           COALESCE(e.employee_name, q.requested_by) AS RequestedBy,
           q.requested_dt                       AS RequestedDate,
           q.decided_by                         AS DecidedByLogin,
           q.decided_dt                         AS DecisionDate,
           q.decision_remark                    AS DecisionRemark,
           q.subscription_id                    AS SubscriptionId
    FROM grac_practice.repository_subscription_request q
    JOIN grac_practice.organization o ON o.organization_id = q.organization_id
    LEFT JOIN grac_new.release   r  ON r.release_id    = q.release_id
    LEFT JOIN grac_new.artifact  a  ON a.artifact_id   = q.artifact_id
    LEFT JOIN grac_new.authority au ON au.authority_id = q.authority_id
    LEFT JOIN grac_practice.organization_employee e ON e.employee_id = q.requested_by_employee_id
    WHERE (ISNULL(@request_id, 0) = 0 OR q.request_id = @request_id)
      AND (@status IS NULL OR q.request_status = @status)
      AND (@search IS NULL
           OR o.organization_name LIKE N'%' + @search + N'%'
           OR o.organization_code LIKE N'%' + @search + N'%'
           OR a.artifact_code     LIKE N'%' + @search + N'%'
           OR a.artifact_name     LIKE N'%' + @search + N'%'
           OR r.version_no        LIKE N'%' + @search + N'%'
           OR q.requested_by      LIKE N'%' + @search + N'%'
           OR e.employee_name     LIKE N'%' + @search + N'%')
    ORDER BY CASE WHEN q.request_status = N'Pending' THEN 0 ELSE 1 END,
             q.requested_dt DESC, q.request_id DESC;
END
GO

-- =====================================================================
-- 5. Control Management side -- Approve / Reject one request
--    @decision : Approve | Reject     @remark : mandatory on Reject
--    @actor    : the Control Management login (from its API token)
--
--    Approve subscribes through the existing 'repository-subscriptions'
--    SAVE of dbo.pm_manage_practice_repository (insert, or re-activate the
--    organization's most recent row for the release), which copies the
--    release and creates the organization controls. _security.isSystemAdmin
--    is set here, server-side: Control Management is not an organization
--    user, and the caller's right to approve was already checked by the
--    ControlManagement API (subscription-requests:APPROVE). That call
--    returns its own one-row result (Success / Message / Id) before this
--    procedure's final row; callers read the LAST result set.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_repository_subscription_request_decide
    @request_id BIGINT,
    @decision   NVARCHAR(20),
    @remark     NVARCHAR(1000) = NULL,
    @actor      NVARCHAR(100)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @decision = UPPER(LTRIM(RTRIM(ISNULL(@decision, N''))));
    IF @decision = N'APPROVED' SET @decision = N'APPROVE';
    IF @decision = N'REJECTED' SET @decision = N'REJECT';
    SET @remark = NULLIF(LTRIM(RTRIM(ISNULL(@remark, N''))), N'');
    SET @actor  = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'system');

    IF @decision NOT IN (N'APPROVE', N'REJECT')
        THROW 51411, 'Decision must be Approve or Reject.', 1;
    IF @decision = N'REJECT' AND @remark IS NULL
        THROW 51412, 'A reason is required to reject a subscription request.', 1;

    BEGIN TRAN;

    DECLARE @organization_id BIGINT, @release_id BIGINT, @current_status NVARCHAR(20);
    SELECT @organization_id = organization_id,
           @release_id      = release_id,
           @current_status  = request_status
    FROM grac_practice.repository_subscription_request WITH (UPDLOCK, HOLDLOCK)
    WHERE request_id = @request_id;

    IF @organization_id IS NULL
        THROW 51413, 'Subscription request was not found.', 1;
    IF @current_status <> N'Pending'
        THROW 51414, 'This subscription request has already been decided.', 1;

    IF @decision = N'REJECT'
    BEGIN
        UPDATE grac_practice.repository_subscription_request
           SET request_status  = N'Rejected',
               decided_by      = @actor,
               decided_dt      = SYSUTCDATETIME(),
               decision_remark = @remark,
               updated_by      = @actor,
               updated_dt      = SYSUTCDATETIME()
         WHERE request_id = @request_id;

        INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, after_json, status, entered_by)
        VALUES (N'repository-subscription-requests', @request_id, N'REJECT',
                (SELECT @organization_id AS organizationId, @release_id AS releaseId,
                        N'Rejected' AS requestStatus, @remark AS decisionRemark
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                'Active', @actor);

        COMMIT;
        SELECT CAST(1 AS BIT) Success, N'Subscription request rejected.' Message,
               @request_id Id, CAST(NULL AS BIGINT) SubscriptionId;
        RETURN;
    END

    -- ---- APPROVE: re-check everything the request was accepted on ----
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization
                   WHERE organization_id = @organization_id AND status = 'Active')
        THROW 51415, 'The requesting organization is no longer active.', 1;

    DECLARE @authority_id BIGINT, @artifact_id BIGINT;
    SELECT @authority_id = au.authority_id, @artifact_id = a.artifact_id
    FROM grac_new.release r
    JOIN grac_new.artifact  a  ON a.artifact_id   = r.artifact_id  AND a.status  = 'Active'
    JOIN grac_new.authority au ON au.authority_id = a.authority_id AND au.status = 'Active'
    WHERE r.release_id = @release_id
      AND r.status IN ('Draft', 'Active');
    IF @artifact_id IS NULL
        THROW 51416, 'This release is no longer available for subscription in the Repository.', 1;

    DECLARE @subscription_id BIGINT =
        (SELECT TOP (1) s.subscription_id
         FROM grac_practice.repository_subscription s
         WHERE s.organization_id = @organization_id AND s.release_id = @release_id
           AND s.status = 'Active' AND ISNULL(s.subscription_status, 'Active') = 'Active'
         ORDER BY s.subscription_id DESC);

    IF @subscription_id IS NULL
    BEGIN
        -- Re-activate the organization's latest row for this release when
        -- one exists (Organization Setup does the same), else insert.
        DECLARE @existing_subscription_id BIGINT =
            (SELECT TOP (1) s.subscription_id
             FROM grac_practice.repository_subscription s
             WHERE s.organization_id = @organization_id AND s.release_id = @release_id
             ORDER BY s.subscription_id DESC);
        -- 0 = insert. Never NULL: the monolith tests @p_id = 0, and NULL
        -- would fall into its UPDATE branch and change nothing.
        DECLARE @save_subscription_id BIGINT = ISNULL(@existing_subscription_id, 0);

        DECLARE @subscribe_payload NVARCHAR(MAX) =
            (SELECT @organization_id AS organizationId,
                    @authority_id    AS authorityId,
                    @artifact_id     AS artifactId,
                    @release_id      AS releaseId,
                    -- Type only on a new row: a re-activated row keeps its own.
                    CASE WHEN @existing_subscription_id IS NULL THEN N'Repository' END AS subscriptionType,
                    N'Active' AS subscriptionStatus,
                    N'Active' AS status,
                    CONVERT(NVARCHAR(10), CONVERT(DATE, SYSUTCDATETIME()), 23) AS effectiveDate,
                    JSON_QUERY(N'{"isSystemAdmin":true}') AS [_security]
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.pm_manage_practice_repository
             @p_entity_type = N'repository-subscriptions',
             @p_action      = N'SAVE',
             @p_id          = @save_subscription_id,
             @p_payload     = @subscribe_payload,
             @p_usr_id      = @actor;

        SELECT TOP (1) @subscription_id = s.subscription_id
        FROM grac_practice.repository_subscription s
        WHERE s.organization_id = @organization_id AND s.release_id = @release_id
          AND s.status = 'Active' AND ISNULL(s.subscription_status, 'Active') = 'Active'
        ORDER BY s.subscription_id DESC;

        IF @subscription_id IS NULL
            THROW 51417, 'The organization subscription could not be activated.', 1;
    END

    UPDATE grac_practice.repository_subscription_request
       SET request_status  = N'Approved',
           decided_by      = @actor,
           decided_dt      = SYSUTCDATETIME(),
           decision_remark = @remark,
           subscription_id = @subscription_id,
           updated_by      = @actor,
           updated_dt      = SYSUTCDATETIME()
     WHERE request_id = @request_id;

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, after_json, status, entered_by)
    VALUES (N'repository-subscription-requests', @request_id, N'APPROVE',
            (SELECT @organization_id AS organizationId, @release_id AS releaseId,
                    N'Approved' AS requestStatus, @subscription_id AS subscriptionId,
                    @remark AS decisionRemark
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            'Active', @actor);

    COMMIT;

    SELECT CAST(1 AS BIT) Success, N'Subscription request approved. The organization is now subscribed.' Message,
           @request_id Id, @subscription_id SubscriptionId;
END
GO

-- =====================================================================
-- 6. Verification
-- =====================================================================
SELECT CASE WHEN OBJECT_ID('grac_practice.repository_subscription_request','U') IS NOT NULL THEN 1 ELSE 0 END AS HasTable,
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_repo_sub_request_pending') THEN 1 ELSE 0 END AS HasPendingGuard,
       CASE WHEN OBJECT_ID('grac_practice.sp_repository_subscription_request_get','P')    IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_repository_subscription_request_manage','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_repository_subscription_request_list','P')   IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_repository_subscription_request_decide','P') IS NOT NULL
            THEN 1 ELSE 0 END AS HasProcedures;

-- Release list for the first active organization (read-only).
DECLARE @verify_org BIGINT = (SELECT TOP (1) organization_id FROM grac_practice.organization WHERE status = 'Active' ORDER BY organization_id);
DECLARE @verify_payload NVARCHAR(200) = CONCAT(N'{"organizationId":', @verify_org, N'}');
IF @verify_org IS NOT NULL
    EXEC grac_practice.sp_repository_subscription_request_get
         @p_entity_type = N'repository-subscription-requests', @p_payload = @verify_payload;
GO

SET NOEXEC OFF;
GO

PRINT '406 complete.';
GO
