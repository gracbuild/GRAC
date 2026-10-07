-- =====================================================================
-- 441  Business services: service register, consumers, supporting assets /
--      services / suppliers / contracts, activation and retirement rules,
--      continuity conflicts and service impact (Asset & Contract
--      Management, Phase 7 increment 2)
--
-- REQUEST
-- -------
--   BRD v1.7 5.5 "Business Service Mapping": a governed business-service
--   hierarchy mapped to the applications, data, infrastructure, facilities,
--   suppliers and contracts it needs. Service fields: ID / name, type
--   (business, customer-facing, technical, shared, supporting), description
--   / purpose, business / service owner, legal entity / units (consumers and
--   accountable organization), criticality / CIA, RTO / RPO / MTPD, service
--   hours / SLA, data / privacy classification, supporting assets /
--   services (effective-dated mappings), supplier / contract dependencies,
--   status Draft, Design, Active, Degraded, Suspended, Retiring, Retired,
--   review date. 5.5.1: a service may depend on several child services and
--   assets, each mapping keeping role, criticality, effective dates and
--   source; service impact shows directly and indirectly affected services,
--   processes, locations, customers, owners and continuity objectives;
--   criticality and RTO / RPO conflicts with supporting assets create
--   validation warnings; no activation without an owner and the minimum
--   supporting relationships; retirement needs dependency migration,
--   consumer review, contract assessment and approval. 5.5.2 acceptance
--   criteria (topology history kept). Plan: docs/asset-contract-management.md
--   (Phase 7.2, D88-D96).
--
-- WHAT THIS DOES
-- --------------
--   1. business_service (per organization) with history and consumers
--      (departments, business functions, locations or named external
--      customers); business_service_setting (minimum supporting
--      relationships for activation, approval of retirement).
--   2. Relationships (440): Supports Service is activated -- assets,
--      applications, processes, vendors, contracts and child services
--      support a service; contracts become relationship endpoints; every
--      relationship gets an optional role ("primary database").
--      Re-issued: fn_asset_ci_catalog (+ services, contracts),
--      sp_asset_relationship_save / _action / _history_add /
--      sp_asset_relationships / _get (+ role), sp_asset_ci_impact (+ the
--      affected services with owners, objectives and consumers).
--   3. Status rules: activation needs a business owner and the minimum
--      supporting relationships; Retiring -> Retired needs no remaining
--      critical dependants, a consumer review and a contract assessment, and
--      another person approval (where configured); a retired service ends
--      its supporting relationships.
--   4. Conflicts (fn_business_service_conflicts): supporting item rated less
--      critical than the service, supporting asset RPO longer than the
--      service RPO, child service with a longer RTO / RPO or lower
--      criticality, supporting item no longer in use, disputed mapping,
--      active service without owner or support, review date passed.
--   5. Business Services screen (menu row, readers / writers).
--
-- NOT DONE HERE: tasks raised from conflicts (warnings only); review-date
--   reminders through the 437 profiles; service dashboards and exports
--   (Phase 8); comparison of the asset recovery tier (an option list)
--   with the service RTO; CIA rating scales other than 1-5.
--
-- ERROR NUMBERS: 54730-54759
--   54730 organization not found         54731 service not found
--   54732 changed by someone else        54733 code / name required
--   54734 code or name already used      54735 service type
--   54736 owner / manager                54737 accountable department
--   54738 criticality                    54739 CIA rating
--   54740 RTO / RPO / MTPD               54741 status change not allowed
--   54742 note required                  54743 activation needs an owner
--   54744 activation needs support       54745 retirement blocked (dependants)
--   54746 retirement review notes        54747 no pending retirement / one pending
--   54748 segregation of duties          54749 consumer
--   54750 setting                        54751 a retired service is history
--
-- ALSO EDITED: API (AssetConfig service / controller / models), Web proxy,
--   PracticeScreen + Manage.cshtml + appsettings, business-services.cshtml /
--   .js (new), asset-relationships.cshtml / .js (role, contract and service
--   kinds), 274 (menu), docs.
-- DEPENDS ON: 434, 440.
-- Rollback: 441_business_services_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_asset_relationship_save','P') IS NULL
   OR OBJECT_ID('grac_practice.asset_relationship','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_relationship_edges') IS NULL
   OR OBJECT_ID('grac_practice.asset_contract','U') IS NULL
   OR COL_LENGTH('grac_practice.asset_contract','current_version_id') IS NULL
   OR COL_LENGTH('grac_practice.asset_contract_version','contract_owner_id') IS NULL
BEGIN
    RAISERROR('ABORT (441): run 434 and 440 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Business services (5.5)
-- =====================================================================
IF OBJECT_ID('grac_practice.business_service','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.business_service (
        service_id                  BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_bsvc PRIMARY KEY,
        organization_id             BIGINT         NOT NULL
            CONSTRAINT fk_pm_bsvc_org REFERENCES grac_practice.organization(organization_id),
        service_code                NVARCHAR(40)   NOT NULL,
        service_name                NVARCHAR(200)  NOT NULL,
        service_type                NVARCHAR(16)   NOT NULL
            CONSTRAINT ck_pm_bsvc_type CHECK (service_type IN (N'BUSINESS', N'CUSTOMER_FACING', N'TECHNICAL', N'SHARED', N'SUPPORTING')),
        description                 NVARCHAR(2000) NULL,
        customer_outcome            NVARCHAR(1000) NULL,
        business_owner_employee_id  BIGINT         NULL
            CONSTRAINT fk_pm_bsvc_owner REFERENCES grac_practice.organization_employee(employee_id),
        service_manager_employee_id BIGINT         NULL
            CONSTRAINT fk_pm_bsvc_manager REFERENCES grac_practice.organization_employee(employee_id),
        accountable_department_id   BIGINT         NULL
            CONSTRAINT fk_pm_bsvc_dept REFERENCES grac_practice.organization_department(department_id),
        criticality_id              INT            NULL
            CONSTRAINT fk_pm_bsvc_crit REFERENCES grac_practice.criticality_master(criticality_id),
        confidentiality_rating      TINYINT        NULL CONSTRAINT ck_pm_bsvc_c CHECK (confidentiality_rating BETWEEN 1 AND 5),
        integrity_rating            TINYINT        NULL CONSTRAINT ck_pm_bsvc_i CHECK (integrity_rating BETWEEN 1 AND 5),
        availability_rating         TINYINT        NULL CONSTRAINT ck_pm_bsvc_a CHECK (availability_rating BETWEEN 1 AND 5),
        rto_hours                   DECIMAL(9, 2)  NULL,
        rpo_hours                   DECIMAL(9, 2)  NULL,
        mtpd_hours                  DECIMAL(9, 2)  NULL,
        service_hours               NVARCHAR(200)  NULL,
        sla_text                    NVARCHAR(1000) NULL,
        data_classification         NVARCHAR(100)  NULL,
        privacy_classification      NVARCHAR(100)  NULL,
        status                      NVARCHAR(10)   NOT NULL
            CONSTRAINT ck_pm_bsvc_status CHECK (status IN (N'DRAFT', N'DESIGN', N'ACTIVE', N'DEGRADED', N'SUSPENDED', N'RETIRING', N'RETIRED')),
        review_date                 DATE           NULL,
        version_no                  INT            NOT NULL CONSTRAINT df_pm_bsvc_vno DEFAULT 1,
        status_note                 NVARCHAR(1000) NULL,
        pending_retirement          BIT            NOT NULL CONSTRAINT df_pm_bsvc_pret DEFAULT 0,
        consumer_review_note        NVARCHAR(1000) NULL,
        contract_assessment_note    NVARCHAR(1000) NULL,
        pending_by                  NVARCHAR(100)  NULL,
        pending_by_employee_id      BIGINT         NULL,
        pending_dt                  DATETIME2      NULL,
        retired_dt                  DATETIME2      NULL,
        entered_by                  NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_bsvc_eby DEFAULT N'system',
        entered_dt                  DATETIME2      NOT NULL CONSTRAINT df_pm_bsvc_edt DEFAULT SYSUTCDATETIME(),
        updated_by                  NVARCHAR(100)  NULL,
        updated_dt                  DATETIME2      NULL,
        record_version              ROWVERSION     NOT NULL,
        CONSTRAINT uq_pm_bsvc_code UNIQUE (organization_id, service_code),
        CONSTRAINT uq_pm_bsvc_name UNIQUE (organization_id, service_name),
        CONSTRAINT ck_pm_bsvc_obj CHECK ((rto_hours IS NULL OR rto_hours >= 0) AND (rpo_hours IS NULL OR rpo_hours >= 0)
                                         AND (mtpd_hours IS NULL OR mtpd_hours >= 0)
                                         AND (rto_hours IS NULL OR mtpd_hours IS NULL OR rto_hours <= mtpd_hours))
    );
    CREATE INDEX ix_pm_bsvc_org ON grac_practice.business_service(organization_id, status);
    PRINT '441: business_service created.';
END
GO

IF OBJECT_ID('grac_practice.business_service_consumer','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.business_service_consumer (
        consumer_id      BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_bsvc_cons PRIMARY KEY,
        service_id       BIGINT        NOT NULL
            CONSTRAINT fk_pm_bsvc_cons_svc REFERENCES grac_practice.business_service(service_id),
        consumer_kind    NVARCHAR(18)  NOT NULL
            CONSTRAINT ck_pm_bsvc_cons_kind CHECK (consumer_kind IN (N'DEPARTMENT', N'BUSINESS_FUNCTION', N'LOCATION', N'EXTERNAL')),
        consumer_ref_id  BIGINT        NULL,          -- department / business function / location id
        consumer_name    NVARCHAR(200) NULL,          -- external customer or partner
        note             NVARCHAR(400) NULL,
        entered_by       NVARCHAR(100) NOT NULL CONSTRAINT df_pm_bsvc_cons_eby DEFAULT N'system',
        entered_dt       DATETIME2     NOT NULL CONSTRAINT df_pm_bsvc_cons_edt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT ck_pm_bsvc_cons_ref CHECK ((consumer_kind = N'EXTERNAL' AND consumer_name IS NOT NULL)
                                              OR (consumer_kind <> N'EXTERNAL' AND consumer_ref_id IS NOT NULL))
    );
    CREATE INDEX ix_pm_bsvc_cons_svc ON grac_practice.business_service_consumer(service_id);
    PRINT '441: business_service_consumer created.';
END
GO

IF OBJECT_ID('grac_practice.business_service_history','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.business_service_history (
        history_id        BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_bsvc_hist PRIMARY KEY,
        service_id        BIGINT         NOT NULL
            CONSTRAINT fk_pm_bsvc_hist_svc REFERENCES grac_practice.business_service(service_id),
        organization_id   BIGINT         NOT NULL,
        version_no        INT            NOT NULL,
        action_code       NVARCHAR(20)   NOT NULL,
        status            NVARCHAR(10)   NOT NULL,
        snapshot_json     NVARCHAR(MAX)  NOT NULL,
        note              NVARCHAR(1000) NULL,
        actor             NVARCHAR(100)  NOT NULL,
        actor_employee_id BIGINT         NULL,
        entered_dt        DATETIME2      NOT NULL CONSTRAINT df_pm_bsvc_hist_edt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_bsvc_hist_svc ON grac_practice.business_service_history(service_id, history_id);
    PRINT '441: business_service_history created.';
END
GO

IF OBJECT_ID('grac_practice.business_service_setting','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.business_service_setting (
        organization_id              BIGINT        NOT NULL CONSTRAINT pk_pm_bsvc_set PRIMARY KEY
            CONSTRAINT fk_pm_bsvc_set_org REFERENCES grac_practice.organization(organization_id),
        min_supporting_relationships INT           NOT NULL
            CONSTRAINT ck_pm_bsvc_set_min CHECK (min_supporting_relationships BETWEEN 0 AND 50),
        retirement_approval_required BIT           NOT NULL,
        updated_by                   NVARCHAR(100) NOT NULL,
        updated_dt                   DATETIME2     NOT NULL CONSTRAINT df_pm_bsvc_set_udt DEFAULT SYSUTCDATETIME()
    );
    PRINT '441: business_service_setting created.';
END
GO

-- =====================================================================
-- 2. Relationships (440): contracts as endpoints, a role per mapping,
--    Supports Service active
-- =====================================================================
IF COL_LENGTH('grac_practice.asset_relationship', 'service_role') IS NULL
    ALTER TABLE grac_practice.asset_relationship ADD service_role NVARCHAR(100) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_asset_rel_skind' AND definition LIKE '%CONTRACT%')
BEGIN
    ALTER TABLE grac_practice.asset_relationship DROP CONSTRAINT ck_pm_asset_rel_skind;
    ALTER TABLE grac_practice.asset_relationship WITH CHECK ADD CONSTRAINT ck_pm_asset_rel_skind
        CHECK (source_kind IN (N'ASSET', N'APPLICATION', N'PROCESS', N'VENDOR', N'LOCATION', N'SERVICE', N'CONTRACT'));
    ALTER TABLE grac_practice.asset_relationship DROP CONSTRAINT ck_pm_asset_rel_tkind;
    ALTER TABLE grac_practice.asset_relationship WITH CHECK ADD CONSTRAINT ck_pm_asset_rel_tkind
        CHECK (target_kind IN (N'ASSET', N'APPLICATION', N'PROCESS', N'VENDOR', N'LOCATION', N'SERVICE', N'CONTRACT'));
    PRINT '441: relationship kinds widened (CONTRACT).';
END
GO

UPDATE grac_practice.asset_relationship_type
   SET is_active = 1, inactive_reason = NULL, source_kinds = N'ASSET,APPLICATION,PROCESS,VENDOR,CONTRACT,SERVICE',
       description = N'Asset, application, process, supplier, contract or child service contributes to a business service.'
 WHERE type_code = N'SUPPORTS_SERVICE' AND (is_active = 0 OR source_kinds <> N'ASSET,APPLICATION,PROCESS,VENDOR,CONTRACT,SERVICE');
PRINT CONCAT('441: Supports Service activated: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 3. Helpers
-- =====================================================================
-- Consumers of a service with their names resolved.
CREATE OR ALTER FUNCTION grac_practice.fn_business_service_consumers (@service_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT c.consumer_id AS ConsumerId, c.consumer_kind AS ConsumerKind, c.consumer_ref_id AS ConsumerRefId,
           CAST(COALESCE(d.department_name, f.function_name, l.location_name, c.consumer_name) AS NVARCHAR(200)) AS ConsumerName,
           c.note AS Note
      FROM grac_practice.business_service_consumer c
      LEFT JOIN grac_practice.organization_department d ON c.consumer_kind = N'DEPARTMENT' AND d.department_id = c.consumer_ref_id
      LEFT JOIN grac_practice.organization_business_function f ON c.consumer_kind = N'BUSINESS_FUNCTION'
                                                              AND f.business_function_id = c.consumer_ref_id
      LEFT JOIN grac_practice.organization_location l ON c.consumer_kind = N'LOCATION' AND l.location_id = c.consumer_ref_id
     WHERE c.service_id = @service_id;
GO

-- "4 hours" -> 4; minutes, hours, days, weeks. Anything else -> NULL.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_duration_hours (@text NVARCHAR(400))
RETURNS DECIMAL(12, 2)
AS
BEGIN
    DECLARE @t NVARCHAR(400) = LTRIM(RTRIM(ISNULL(@text, N'')));
    DECLARE @n DECIMAL(18, 4) = TRY_CONVERT(DECIMAL(18, 4), LEFT(@t, CHARINDEX(N' ', @t + N' ') - 1));
    DECLARE @u NVARCHAR(100) = LOWER(LTRIM(SUBSTRING(@t, CHARINDEX(N' ', @t + N' ') + 1, 100)));
    RETURN CASE WHEN @n IS NULL OR @n < 0 THEN NULL
                WHEN @u LIKE N'min%' THEN CAST(@n / 60 AS DECIMAL(12, 2))
                WHEN @u LIKE N'h%' THEN CAST(@n AS DECIMAL(12, 2))
                WHEN @u LIKE N'day%' THEN CAST(@n * 24 AS DECIMAL(12, 2))
                WHEN @u LIKE N'week%' THEN CAST(@n * 168 AS DECIMAL(12, 2)) END;
END
GO

-- Validation warnings of the services of an organization (5.5.1, D93).
CREATE OR ALTER FUNCTION grac_practice.fn_business_service_conflicts (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    WITH svc AS (
        SELECT b.service_id, b.service_name, b.status, b.rto_hours, b.rpo_hours, b.business_owner_employee_id, b.review_date,
               cm.criticality_code,
               CASE cm.criticality_code WHEN N'Critical' THEN 4 WHEN N'High' THEN 3 WHEN N'Medium' THEN 2 WHEN N'Low' THEN 1 END AS crit_rank
          FROM grac_practice.business_service b
          LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id = b.criticality_id
         WHERE b.organization_id = @organization_id AND b.status <> N'RETIRED'),
    sup AS (
        SELECT r.relationship_id, r.target_id AS service_id, r.source_kind, r.source_id, r.status AS rel_status,
               ci.CiName, ci.IsUsable, scm.criticality_code AS sup_crit,
               CASE scm.criticality_code WHEN N'Critical' THEN 4 WHEN N'High' THEN 3 WHEN N'Medium' THEN 2 WHEN N'Low' THEN 1 END AS sup_rank,
               cs.rto_hours AS child_rto, cs.rpo_hours AS child_rpo, rp.rpo_h AS asset_rpo
          FROM grac_practice.asset_relationship r
          LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) ci ON ci.CiKind = r.source_kind AND ci.CiId = r.source_id
          LEFT JOIN grac_practice.organization_dependency_asset a ON r.source_kind = N'ASSET' AND a.asset_id = r.source_id
          LEFT JOIN grac_practice.organization_dependency_application ap ON r.source_kind = N'APPLICATION' AND ap.application_id = r.source_id
          LEFT JOIN grac_practice.organization_dependency_vendor v ON r.source_kind = N'VENDOR' AND v.vendor_id = r.source_id
          LEFT JOIN grac_practice.business_service cs ON r.source_kind = N'SERVICE' AND cs.service_id = r.source_id
          LEFT JOIN grac_practice.criticality_master scm
                 ON scm.criticality_id = COALESCE(a.criticality_id, ap.criticality_id, v.criticality_id, cs.criticality_id)
         OUTER APPLY (SELECT grac_practice.fn_asset_duration_hours(fv.value_text) AS rpo_h
                        FROM grac_practice.asset_field_value fv
                        JOIN grac_practice.asset_field_definition fd ON fd.field_definition_id = fv.field_definition_id AND fd.field_key = N'rpo'
                       WHERE r.source_kind = N'ASSET' AND fv.asset_id = r.source_id) rp
         WHERE r.organization_id = @organization_id AND r.relationship_type_code = N'SUPPORTS_SERVICE' AND r.target_kind = N'SERVICE'
           AND r.status IN (N'ACTIVE', N'DISPUTED')
           AND r.effective_from <= CAST(SYSUTCDATETIME() AS DATE)
           AND (r.effective_to IS NULL OR r.effective_to >= CAST(SYSUTCDATETIME() AS DATE)))
    SELECT s.service_id AS ServiceId, s.service_name AS ServiceName, N'SUPPORT_CRITICALITY' AS ConflictCode,
           CAST(CONCAT(p.CiName, N' is rated ', p.sup_crit, N'; the service is ', s.criticality_code, N'.') AS NVARCHAR(600)) AS Message,
           p.source_kind AS CiKind, p.source_id AS CiId, p.CiName, p.relationship_id AS RelationshipId
      FROM svc s JOIN sup p ON p.service_id = s.service_id
     WHERE p.rel_status = N'ACTIVE' AND s.crit_rank IS NOT NULL AND p.sup_rank IS NOT NULL AND p.sup_rank < s.crit_rank
    UNION ALL
    SELECT s.service_id, s.service_name, N'SUPPORT_RPO',
           CAST(CONCAT(p.CiName, N' has an RPO of ', p.asset_rpo, N' hour(s); the service RPO is ', s.rpo_hours, N'.') AS NVARCHAR(600)),
           p.source_kind, p.source_id, p.CiName, p.relationship_id
      FROM svc s JOIN sup p ON p.service_id = s.service_id
     WHERE p.rel_status = N'ACTIVE' AND s.rpo_hours IS NOT NULL AND p.asset_rpo IS NOT NULL AND p.asset_rpo > s.rpo_hours
    UNION ALL
    SELECT s.service_id, s.service_name, N'CHILD_OBJECTIVE',
           CAST(CONCAT(N'Supporting service ', p.CiName, N' allows RTO ', ISNULL(CAST(p.child_rto AS NVARCHAR(20)), N'-'), N' h / RPO ',
                       ISNULL(CAST(p.child_rpo AS NVARCHAR(20)), N'-'), N' h; this service needs RTO ',
                       ISNULL(CAST(s.rto_hours AS NVARCHAR(20)), N'-'), N' h / RPO ', ISNULL(CAST(s.rpo_hours AS NVARCHAR(20)), N'-'), N' h.')
                AS NVARCHAR(600)),
           p.source_kind, p.source_id, p.CiName, p.relationship_id
      FROM svc s JOIN sup p ON p.service_id = s.service_id
     WHERE p.rel_status = N'ACTIVE' AND p.source_kind = N'SERVICE'
       AND ((s.rto_hours IS NOT NULL AND p.child_rto > s.rto_hours) OR (s.rpo_hours IS NOT NULL AND p.child_rpo > s.rpo_hours))
    UNION ALL
    SELECT s.service_id, s.service_name, N'SUPPORT_NOT_IN_USE',
           CAST(CONCAT(p.CiName, N' still supports the service but is no longer in use.') AS NVARCHAR(600)),
           p.source_kind, p.source_id, p.CiName, p.relationship_id
      FROM svc s JOIN sup p ON p.service_id = s.service_id
     WHERE ISNULL(p.IsUsable, 0) = 0
    UNION ALL
    SELECT s.service_id, s.service_name, N'SUPPORT_DISPUTED',
           CAST(CONCAT(N'The mapping of ', p.CiName, N' is disputed.') AS NVARCHAR(600)),
           p.source_kind, p.source_id, p.CiName, p.relationship_id
      FROM svc s JOIN sup p ON p.service_id = s.service_id
     WHERE p.rel_status = N'DISPUTED'
    UNION ALL
    SELECT s.service_id, s.service_name, N'NO_OWNER', CAST(N'The service is in operation without a business owner.' AS NVARCHAR(600)),
           NULL, NULL, NULL, NULL
      FROM svc s
     WHERE s.status IN (N'ACTIVE', N'DEGRADED') AND s.business_owner_employee_id IS NULL
    UNION ALL
    SELECT s.service_id, s.service_name, N'NO_SUPPORT', CAST(N'The service is in operation with no active supporting item.' AS NVARCHAR(600)),
           NULL, NULL, NULL, NULL
      FROM svc s
     WHERE s.status IN (N'ACTIVE', N'DEGRADED')
       AND NOT EXISTS (SELECT 1 FROM sup p WHERE p.service_id = s.service_id AND p.rel_status = N'ACTIVE')
    UNION ALL
    SELECT s.service_id, s.service_name, N'REVIEW_OVERDUE',
           CAST(CONCAT(N'The service review was due on ', CONVERT(NVARCHAR(10), s.review_date, 23), N'.') AS NVARCHAR(600)),
           NULL, NULL, NULL, NULL
      FROM svc s
     WHERE s.review_date < CAST(SYSUTCDATETIME() AS DATE);
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_business_service_history_add
    @service_id        BIGINT,
    @action_code       NVARCHAR(20),
    @note              NVARCHAR(1000) = NULL,
    @actor             NVARCHAR(100),
    @actor_employee_id BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT grac_practice.business_service_history
        (service_id, organization_id, version_no, action_code, status, snapshot_json, note, actor, actor_employee_id)
    SELECT b.service_id, b.organization_id, b.version_no, @action_code, b.status,
           (SELECT b2.service_code AS serviceCode, b2.service_name AS serviceName, b2.service_type AS serviceType,
                   b2.description AS description, b2.customer_outcome AS customerOutcome,
                   b2.business_owner_employee_id AS businessOwnerEmployeeId, b2.service_manager_employee_id AS serviceManagerEmployeeId,
                   b2.accountable_department_id AS accountableDepartmentId, b2.criticality_id AS criticalityId,
                   b2.confidentiality_rating AS confidentialityRating, b2.integrity_rating AS integrityRating,
                   b2.availability_rating AS availabilityRating, b2.rto_hours AS rtoHours, b2.rpo_hours AS rpoHours,
                   b2.mtpd_hours AS mtpdHours, b2.service_hours AS serviceHours, b2.sla_text AS slaText,
                   b2.data_classification AS dataClassification, b2.privacy_classification AS privacyClassification,
                   b2.status AS status, b2.review_date AS reviewDate, b2.pending_retirement AS pendingRetirement,
                   (SELECT c.ConsumerKind AS consumerKind, c.ConsumerRefId AS consumerRefId, c.ConsumerName AS consumerName
                      FROM grac_practice.fn_business_service_consumers(b2.service_id) c FOR JSON PATH) AS consumers
              FROM grac_practice.business_service b2 WHERE b2.service_id = b.service_id
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           @note, @actor, @actor_employee_id
      FROM grac_practice.business_service b
     WHERE b.service_id = @service_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'business-service', h.service_id, @action_code, NULL, h.snapshot_json, N'Active', @actor
      FROM grac_practice.business_service_history h
     WHERE h.history_id = SCOPE_IDENTITY();
END
GO
PRINT '441: helpers created.';
GO

-- =====================================================================
-- 6. Re-issued 440 relationship bodies (441 lines marked; the rest verbatim)
-- =====================================================================
-- 440 body + business services and contracts as configuration items.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_ci_catalog (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT N'ASSET' AS CiKind, a.asset_id AS CiId, CAST(a.asset_name AS NVARCHAR(400)) AS CiName,
           CAST(ISNULL(ty.asset_type_name, N'Asset') AS NVARCHAR(200)) AS CiClass,
           CAST(ISNULL(s.status_name, N'Active') AS NVARCHAR(120)) AS CiStatus,
           CAST(CASE WHEN ISNULL(s.status_code, N'ACTIVE') IN (N'DISPOSED', N'ARCHIVED') THEN 0 ELSE 1 END AS BIT) AS IsUsable,
           a.owner_id AS OwnerEmployeeId
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.dependency_asset_type_master ty ON ty.asset_type_id = a.asset_type_id
     WHERE a.organization_id = @organization_id
    UNION ALL
    SELECT N'APPLICATION', p.application_id, CAST(p.application_name AS NVARCHAR(400)), CAST(N'Application' AS NVARCHAR(200)),
           CAST(p.status AS NVARCHAR(120)), CAST(CASE WHEN p.status = N'Active' THEN 1 ELSE 0 END AS BIT), p.business_owner_id
      FROM grac_practice.organization_dependency_application p
     WHERE p.organization_id = @organization_id
    UNION ALL
    SELECT N'PROCESS', p.process_id, CAST(p.process_name AS NVARCHAR(400)), CAST(N'Process' AS NVARCHAR(200)),
           CAST(p.status AS NVARCHAR(120)), CAST(CASE WHEN p.status = N'Active' THEN 1 ELSE 0 END AS BIT), p.process_owner_id
      FROM grac_practice.organization_dependency_process p
     WHERE p.organization_id = @organization_id
    UNION ALL
    SELECT N'VENDOR', v.vendor_id, CAST(v.vendor_name AS NVARCHAR(400)), CAST(N'Vendor' AS NVARCHAR(200)),
           CAST(v.status AS NVARCHAR(120)), CAST(CASE WHEN v.status = N'Active' THEN 1 ELSE 0 END AS BIT), v.relationship_owner_id
      FROM grac_practice.organization_dependency_vendor v
     WHERE v.organization_id = @organization_id
    UNION ALL
    SELECT N'LOCATION', l.location_id, CAST(l.location_name AS NVARCHAR(400)), CAST(N'Location' AS NVARCHAR(200)),
           CAST(l.status AS NVARCHAR(120)), CAST(CASE WHEN l.status = N'Active' THEN 1 ELSE 0 END AS BIT), l.location_head_id
      FROM grac_practice.organization_location l
     WHERE l.organization_id = @organization_id
    UNION ALL
    -- 441: business services (usable until Retired) and contracts (usable until terminated).
    SELECT N'SERVICE', b.service_id, CAST(b.service_name AS NVARCHAR(400)),
           CAST(CONCAT(N'Service - ', LOWER(REPLACE(b.service_type, N'_', N' '))) AS NVARCHAR(200)),
           CAST(b.status AS NVARCHAR(120)), CAST(CASE WHEN b.status = N'RETIRED' THEN 0 ELSE 1 END AS BIT), b.business_owner_employee_id
      FROM grac_practice.business_service b
     WHERE b.organization_id = @organization_id
    UNION ALL
    SELECT N'CONTRACT', c.contract_id, CAST(CONCAT(c.contract_number, N' - ', c.contract_name) AS NVARCHAR(400)),
           CAST(CONCAT(N'Contract - ', c.contract_type) AS NVARCHAR(200)), CAST(c.contract_status AS NVARCHAR(120)),
           CAST(CASE WHEN c.contract_status = N'TERMINATED' THEN 0 ELSE 1 END AS BIT), cv.contract_owner_id
      FROM grac_practice.asset_contract c
      LEFT JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
     WHERE c.organization_id = @organization_id;
GO

-- 440 body + the role in the snapshot.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationship_history_add
    @relationship_id   BIGINT,
    @action_code       NVARCHAR(20),
    @note              NVARCHAR(1000) = NULL,
    @actor             NVARCHAR(100),
    @actor_employee_id BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT grac_practice.asset_relationship_history
        (relationship_id, organization_id, version_no, action_code, status, snapshot_json, note, actor, actor_employee_id)
    SELECT r.relationship_id, r.organization_id, r.version_no, @action_code, r.status,
           (SELECT r2.relationship_type_code AS typeCode, r2.source_kind AS sourceKind, r2.source_id AS sourceId,
                   r2.target_kind AS targetKind, r2.target_id AS targetId, r2.is_critical AS isCritical,
                   r2.dependency_criticality AS dependencyCriticality, r2.impact_weight AS impactWeight, r2.status AS status,
                   r2.effective_from AS effectiveFrom, r2.effective_to AS effectiveTo, r2.source_code AS sourceCode,
                   r2.confidence_pct AS confidencePct, r2.verification_status AS verificationStatus,
                   r2.owner_employee_id AS ownerEmployeeId, r2.verifier_employee_id AS verifierEmployeeId,
                   r2.evidence_reference AS evidenceReference, r2.change_reference AS changeReference, r2.reason AS reason,
                   r2.in_loop AS inLoop, r2.pending_action AS pendingAction, r2.retirement_accepted AS retirementAccepted,
                   r2.service_role AS serviceRole                                                   -- 441
              FROM grac_practice.asset_relationship r2 WHERE r2.relationship_id = r.relationship_id
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           @note, @actor, @actor_employee_id
      FROM grac_practice.asset_relationship r
     WHERE r.relationship_id = @relationship_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'asset-relationship', h.relationship_id, @action_code, NULL, h.snapshot_json, N'Active', @actor
      FROM grac_practice.asset_relationship_history h
     WHERE h.history_id = SCOPE_IDENTITY();
END
GO

-- 440 body + the role of the mapping.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationship_save
    @organization_id         BIGINT,
    @relationship_id         BIGINT         = NULL,
    @relationship_type_code  NVARCHAR(30)   = NULL,
    @source_kind             NVARCHAR(12)   = NULL,
    @source_id               BIGINT         = NULL,
    @target_kind             NVARCHAR(12)   = NULL,
    @target_id               BIGINT         = NULL,
    @is_critical             BIT            = 0,
    @dependency_criticality  NVARCHAR(10)   = NULL,
    @impact_weight           DECIMAL(5, 2)  = NULL,
    @effective_from          DATE           = NULL,
    @effective_to            DATE           = NULL,
    @confidence_pct          INT            = NULL,
    @owner_employee_id       BIGINT         = NULL,
    @verifier_employee_id    BIGINT         = NULL,
    @evidence_reference      NVARCHAR(400)  = NULL,
    @change_reference        NVARCHAR(200)  = NULL,
    @service_role            NVARCHAR(100)  = NULL,      -- 441: role of the mapping ("primary database")
    @reason                  NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @relationship_type_code = UPPER(LTRIM(RTRIM(ISNULL(@relationship_type_code, N''))));
    SET @source_kind = UPPER(LTRIM(RTRIM(ISNULL(@source_kind, N''))));
    SET @target_kind = UPPER(LTRIM(RTRIM(ISNULL(@target_kind, N''))));
    SET @is_critical = ISNULL(@is_critical, 0);
    SET @dependency_criticality = NULLIF(UPPER(LTRIM(RTRIM(@dependency_criticality))), N'');
    SET @evidence_reference = NULLIF(LTRIM(RTRIM(@evidence_reference)), N'');
    SET @change_reference = NULLIF(LTRIM(RTRIM(@change_reference)), N'');
    SET @service_role = NULLIF(LTRIM(RTRIM(@service_role)), N'');                                    -- 441
    SET @reason = NULLIF(LTRIM(RTRIM(@reason)), N'');
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    SET @effective_from = ISNULL(@effective_from, @today);

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54701, 'Organization not found.', 1;
    IF @effective_to IS NOT NULL AND @effective_to < @effective_from
        THROW 54714, 'The effective-to date must be on or after the effective-from date.', 1;
    IF @dependency_criticality IS NOT NULL AND @dependency_criticality NOT IN (N'CRITICAL', N'HIGH', N'MEDIUM', N'LOW')
        THROW 54717, 'The dependency criticality is Critical, High, Medium or Low.', 1;
    IF @is_critical = 1 AND @dependency_criticality IS NULL
        THROW 54717, 'Select the dependency criticality of a critical dependency.', 1;
    IF @impact_weight IS NOT NULL AND @impact_weight NOT BETWEEN 0 AND 100
        THROW 54717, 'The impact weight is between 0 and 100.', 1;
    IF @confidence_pct IS NOT NULL AND @confidence_pct NOT BETWEEN 0 AND 100
        THROW 54717, 'The confidence is between 0 and 100.', 1;
    IF (@owner_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                                        WHERE employee_id = @owner_employee_id AND organization_id = @organization_id
                                                          AND status = N'Active'))
       OR (@verifier_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                                              WHERE employee_id = @verifier_employee_id AND organization_id = @organization_id
                                                                AND status = N'Active'))
        THROW 54718, 'The owner and the verifier must be active employees of the organization.', 1;

    DECLARE @loop BIT, @id BIGINT, @result NVARCHAR(20);
    IF @relationship_id IS NULL
    BEGIN
        EXEC grac_practice.sp_asset_relationship_check @organization_id = @organization_id, @relationship_id = NULL,
             @type_code = @relationship_type_code, @source_kind = @source_kind, @source_id = @source_id,
             @target_kind = @target_kind, @target_id = @target_id, @out_loop = @loop OUTPUT;
        BEGIN TRAN;
        INSERT grac_practice.asset_relationship
            (organization_id, relationship_type_code, source_kind, source_id, target_kind, target_id, is_critical,
             dependency_criticality, impact_weight, status, effective_from, effective_to, source_code, confidence_pct,
             owner_employee_id, verifier_employee_id, evidence_reference, change_reference, reason, in_loop,
             proposed_by, proposed_by_employee_id, entered_by, service_role)                           -- 441
        VALUES (@organization_id, @relationship_type_code, @source_kind, @source_id, @target_kind, @target_id, @is_critical,
                @dependency_criticality, @impact_weight, N'PROPOSED', @effective_from, @effective_to, N'MANUAL', @confidence_pct,
                @owner_employee_id, @verifier_employee_id, @evidence_reference, @change_reference, @reason, ISNULL(@loop, 0),
                @actor, @actor_employee_id, @actor, @service_role);
        SET @id = SCOPE_IDENTITY();
        EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @id, @action_code = N'PROPOSE', @note = @reason,
             @actor = @actor, @actor_employee_id = @actor_employee_id;
        COMMIT;
        SELECT @id AS RelationshipId, N'PROPOSED' AS Result;
        RETURN;
    END

    DECLARE @found BIT = 0, @status NVARCHAR(10), @rv BIGINT, @was_critical BIT, @pending NVARCHAR(10);
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @was_critical = is_critical, @pending = pending_action
      FROM grac_practice.asset_relationship WHERE relationship_id = @relationship_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54709, 'Relationship not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54710, 'The relationship was changed by someone else; reload it and try again.', 1;
    IF @status IN (N'INACTIVE', N'RETIRED')
        THROW 54711, 'An inactive or retired relationship is kept for history and cannot be changed.', 1;
    IF @pending IS NOT NULL
        THROW 54712, 'A change of this relationship is waiting for approval; approve, reject or withdraw it first.', 1;
    IF @status = N'ACTIVE' AND @reason IS NULL
        THROW 54713, 'Enter the reason for changing an active relationship.', 1;

    BEGIN TRAN;
    IF @status = N'ACTIVE' AND (@was_critical = 1 OR @is_critical = 1)
    BEGIN
        UPDATE grac_practice.asset_relationship
           SET pending_action = N'UPDATE', pending_reason = @reason, pending_by = @actor, pending_by_employee_id = @actor_employee_id,
               pending_dt = SYSUTCDATETIME(),
               pending_json = (SELECT @is_critical AS isCritical, @dependency_criticality AS dependencyCriticality,
                                      @impact_weight AS impactWeight, @effective_from AS effectiveFrom, @effective_to AS effectiveTo,
                                      @confidence_pct AS confidencePct, @owner_employee_id AS ownerEmployeeId,
                                      @verifier_employee_id AS verifierEmployeeId, @evidence_reference AS evidenceReference,
                                      @change_reference AS changeReference, @reason AS reason,
                                      @service_role AS serviceRole                                -- 441
                                  FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @relationship_id, @action_code = N'CHANGE_REQUEST',
             @note = @reason, @actor = @actor, @actor_employee_id = @actor_employee_id;
        SET @result = N'PENDING_APPROVAL';
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_relationship
           SET is_critical = @is_critical, dependency_criticality = @dependency_criticality, impact_weight = @impact_weight,
               effective_from = @effective_from, effective_to = @effective_to, confidence_pct = @confidence_pct,
               owner_employee_id = @owner_employee_id, verifier_employee_id = @verifier_employee_id,
               evidence_reference = @evidence_reference, change_reference = @change_reference, reason = @reason,
               service_role = @service_role,                                                          -- 441
               version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @relationship_id, @action_code = N'UPDATE',
             @note = @reason, @actor = @actor, @actor_employee_id = @actor_employee_id;
        SET @result = N'UPDATED';
    END
    COMMIT;
    SELECT @relationship_id AS RelationshipId, @result AS Result;
END
GO

-- 440 body + the role in a pending change.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationship_action
    @organization_id         BIGINT,
    @relationship_id         BIGINT,
    @action                  NVARCHAR(20),
    @note                    NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @action = UPPER(LTRIM(RTRIM(ISNULL(@action, N''))));
    SET @note = NULLIF(LTRIM(RTRIM(@note)), N'');
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @found BIT = 0, @status NVARCHAR(10), @rv BIGINT, @critical BIT, @pending NVARCHAR(10), @pending_json NVARCHAR(MAX),
            @pending_by NVARCHAR(100), @pending_emp BIGINT, @pending_reason NVARCHAR(1000), @proposed_by NVARCHAR(100),
            @proposed_emp BIGINT, @type NVARCHAR(30), @sk NVARCHAR(12), @si BIGINT, @tk NVARCHAR(12), @ti BIGINT;
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @critical = is_critical, @pending = pending_action,
           @pending_json = pending_json, @pending_by = pending_by, @pending_emp = pending_by_employee_id,
           @pending_reason = pending_reason, @proposed_by = proposed_by, @proposed_emp = proposed_by_employee_id,
           @type = relationship_type_code, @sk = source_kind, @si = source_id, @tk = target_kind, @ti = target_id
      FROM grac_practice.asset_relationship WHERE relationship_id = @relationship_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54709, 'Relationship not found for this organization.', 1;
    IF @action NOT IN (N'APPROVE', N'REJECT', N'WITHDRAW', N'DISPUTE', N'CONFIRM', N'RETIRE', N'ACCEPT_RETIREMENT')
        THROW 54715, 'The action is Approve, Reject, Withdraw, Dispute, Confirm, Retire or Accept for retirement.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54710, 'The relationship was changed by someone else; reload it and try again.', 1;
    IF @action IN (N'REJECT', N'DISPUTE', N'CONFIRM', N'RETIRE', N'ACCEPT_RETIREMENT') AND @note IS NULL
        THROW 54713, 'Enter the note for this action.', 1;

    DECLARE @result NVARCHAR(20), @loop BIT, @hist NVARCHAR(20) = @action;
    BEGIN TRAN;
    IF @action = N'APPROVE' AND @status = N'PROPOSED'
    BEGIN
        IF @critical = 1 AND (@proposed_by = @actor OR (@proposed_emp IS NOT NULL AND @proposed_emp = @actor_employee_id))
            THROW 54716, 'Segregation of duties: the person who proposed a critical relationship cannot approve it.', 1;
        EXEC grac_practice.sp_asset_relationship_check @organization_id = @organization_id, @relationship_id = @relationship_id,
             @type_code = @type, @source_kind = @sk, @source_id = @si, @target_kind = @tk, @target_id = @ti, @out_loop = @loop OUTPUT;
        UPDATE grac_practice.asset_relationship
           SET status = N'ACTIVE', verification_status = N'VERIFIED', in_loop = ISNULL(@loop, 0), approved_by = @actor,
               approved_by_employee_id = @actor_employee_id, approved_dt = SYSUTCDATETIME(), status_note = @note,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        SET @result = N'ACTIVE';
    END
    ELSE IF @action = N'APPROVE' AND @pending IS NOT NULL
    BEGIN
        IF @pending_by = @actor OR (@pending_emp IS NOT NULL AND @pending_emp = @actor_employee_id)
            THROW 54716, 'Segregation of duties: the person who requested the change cannot approve it.', 1;
        IF @pending = N'UPDATE'
        BEGIN
            UPDATE r
               SET is_critical = ISNULL(j.isCritical, 0), dependency_criticality = j.dependencyCriticality, impact_weight = j.impactWeight,
                   effective_from = j.effectiveFrom, effective_to = j.effectiveTo, confidence_pct = j.confidencePct,
                   owner_employee_id = j.ownerEmployeeId, verifier_employee_id = j.verifierEmployeeId,
                   evidence_reference = j.evidenceReference, change_reference = j.changeReference, reason = j.reason,
                   service_role = j.serviceRole,                                                      -- 441
                   version_no = version_no + 1
              FROM grac_practice.asset_relationship r
             CROSS APPLY OPENJSON(@pending_json) WITH (
                    isCritical BIT, dependencyCriticality NVARCHAR(10), impactWeight DECIMAL(5, 2), effectiveFrom DATE,
                    effectiveTo DATE, confidencePct INT, ownerEmployeeId BIGINT, verifierEmployeeId BIGINT,
                    evidenceReference NVARCHAR(400), changeReference NVARCHAR(200), reason NVARCHAR(1000),
                    serviceRole NVARCHAR(100)) j                                                      -- 441
             WHERE r.relationship_id = @relationship_id;
            SET @result = N'UPDATED';
            SET @hist = N'APPROVE_CHANGE';
        END
        ELSE
        BEGIN
            UPDATE grac_practice.asset_relationship
               SET status = N'RETIRED', status_note = @pending_reason, version_no = version_no + 1,
                   effective_to = CASE WHEN effective_to IS NULL OR effective_to > @today THEN
                                           CASE WHEN effective_from > @today THEN effective_from ELSE @today END
                                       ELSE effective_to END
             WHERE relationship_id = @relationship_id;
            SET @result = N'RETIRED';
            SET @hist = N'APPROVE_RETIRE';
        END
        UPDATE grac_practice.asset_relationship
           SET pending_action = NULL, pending_json = NULL, pending_reason = NULL, pending_by = NULL, pending_by_employee_id = NULL,
               pending_dt = NULL, approved_by = @actor, approved_by_employee_id = @actor_employee_id, approved_dt = SYSUTCDATETIME(),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
    END
    ELSE IF @action IN (N'REJECT', N'WITHDRAW') AND (@status = N'PROPOSED' OR @pending IS NOT NULL)
    BEGIN
        IF @action = N'WITHDRAW'
           AND ((@pending IS NOT NULL AND ISNULL(@pending_by, N'') <> @actor)
                OR (@pending IS NULL AND @proposed_by <> @actor))
            THROW 54716, 'Only the person who proposed the relationship or requested the change can withdraw it.', 1;
        IF @pending IS NOT NULL
        BEGIN
            UPDATE grac_practice.asset_relationship
               SET pending_action = NULL, pending_json = NULL, pending_reason = NULL, pending_by = NULL, pending_by_employee_id = NULL,
                   pending_dt = NULL, status_note = ISNULL(@note, N'Withdrawn by the requester.'),
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @relationship_id;
            SET @result = @status;
            SET @hist = CONCAT(@action, N'_CHANGE');
        END
        ELSE
        BEGIN
            UPDATE grac_practice.asset_relationship
               SET status = N'RETIRED', status_note = ISNULL(@note, N'Withdrawn by the proposer.'), version_no = version_no + 1,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @relationship_id;
            SET @result = N'RETIRED';
        END
    END
    ELSE IF @action = N'DISPUTE' AND @status = N'ACTIVE' AND @pending IS NULL
    BEGIN
        UPDATE grac_practice.asset_relationship
           SET status = N'DISPUTED', status_note = @note, version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        SET @result = N'DISPUTED';
    END
    ELSE IF @action = N'CONFIRM' AND @status = N'DISPUTED'
    BEGIN
        UPDATE grac_practice.asset_relationship
           SET status = N'ACTIVE', verification_status = N'VERIFIED', status_note = @note, version_no = version_no + 1,
               approved_by = @actor, approved_by_employee_id = @actor_employee_id, approved_dt = SYSUTCDATETIME(),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        SET @result = N'ACTIVE';
    END
    ELSE IF @action = N'RETIRE' AND @status IN (N'ACTIVE', N'DISPUTED', N'INACTIVE') AND @pending IS NULL
    BEGIN
        IF @status = N'ACTIVE' AND @critical = 1
        BEGIN
            UPDATE grac_practice.asset_relationship
               SET pending_action = N'RETIRE', pending_json = NULL, pending_reason = @note, pending_by = @actor,
                   pending_by_employee_id = @actor_employee_id, pending_dt = SYSUTCDATETIME(),
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @relationship_id;
            SET @result = N'PENDING_APPROVAL';
            SET @hist = N'RETIRE_REQUEST';
        END
        ELSE
        BEGIN
            UPDATE grac_practice.asset_relationship
               SET status = N'RETIRED', status_note = @note, version_no = version_no + 1,
                   effective_to = CASE WHEN effective_to IS NULL OR effective_to > @today THEN
                                           CASE WHEN effective_from > @today THEN effective_from ELSE @today END
                                       ELSE effective_to END,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @relationship_id;
            SET @result = N'RETIRED';
        END
    END
    ELSE IF @action = N'ACCEPT_RETIREMENT' AND @status = N'ACTIVE' AND @critical = 1
    BEGIN
        UPDATE grac_practice.asset_relationship
           SET retirement_accepted = 1, retirement_note = @note, retirement_accepted_by = @actor,
               retirement_accepted_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        SET @result = N'ACCEPTED';
    END
    ELSE
        THROW 54715, 'This action is not available for the relationship in its current status.', 1;

    EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @relationship_id, @action_code = @hist, @note = @note,
         @actor = @actor, @actor_employee_id = @actor_employee_id;
    COMMIT;
    SELECT @relationship_id AS RelationshipId, @result AS Result;
END
GO

-- 440 body + ServiceRole.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationships
    @organization_id BIGINT,
    @ci_kind         NVARCHAR(12)  = NULL,
    @ci_id           BIGINT        = NULL,
    @type_code       NVARCHAR(30)  = NULL,
    @status          NVARCHAR(10)  = NULL,
    @critical_only   BIT           = 0,
    @pending_only    BIT           = 0,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54701, 'Organization not found.', 1;
    SET @ci_kind = NULLIF(UPPER(LTRIM(RTRIM(@ci_kind))), N'');
    SET @type_code = NULLIF(UPPER(LTRIM(RTRIM(@type_code))), N'');
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    EXEC grac_practice.sp_asset_relationship_sync @organization_id = @organization_id, @actor = @actor;

    SELECT r.relationship_id AS RelationshipId, r.relationship_type_code AS TypeCode, t.type_name AS TypeName,
           t.inverse_label AS InverseLabel, t.dependent_side AS DependentSide,
           r.source_kind AS SourceKind, r.source_id AS SourceId, sc.CiName AS SourceName, sc.CiClass AS SourceClass,
           sc.CiStatus AS SourceStatus, r.target_kind AS TargetKind, r.target_id AS TargetId, tc.CiName AS TargetName,
           tc.CiClass AS TargetClass, tc.CiStatus AS TargetStatus, r.is_critical AS IsCritical,
           r.dependency_criticality AS DependencyCriticality, r.impact_weight AS ImpactWeight,
           r.service_role AS ServiceRole,                                                             -- 441
           r.status AS Status,
           r.effective_from AS EffectiveFrom, r.effective_to AS EffectiveTo, r.source_code AS SourceCode,
           r.confidence_pct AS ConfidencePct, r.verification_status AS VerificationStatus, ow.employee_name AS OwnerName,
           vf.employee_name AS VerifierName, r.in_loop AS InLoop, r.version_no AS VersionNo, r.pending_action AS PendingAction,
           r.pending_reason AS PendingReason, r.pending_by AS PendingBy, r.retirement_accepted AS RetirementAccepted,
           r.proposed_by AS ProposedBy, r.approved_by AS ApprovedBy, r.approved_dt AS ApprovedDt, r.status_note AS StatusNote,
           CONVERT(BIGINT, r.record_version) AS RecordVersion,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_relationship r
      JOIN grac_practice.asset_relationship_type t ON t.type_code = r.relationship_type_code
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) sc ON sc.CiKind = r.source_kind AND sc.CiId = r.source_id
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) tc ON tc.CiKind = r.target_kind AND tc.CiId = r.target_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.owner_employee_id
      LEFT JOIN grac_practice.organization_employee vf ON vf.employee_id = r.verifier_employee_id
     WHERE r.organization_id = @organization_id
       AND (@ci_kind IS NULL OR @ci_id IS NULL
            OR (r.source_kind = @ci_kind AND r.source_id = @ci_id) OR (r.target_kind = @ci_kind AND r.target_id = @ci_id))
       AND (@type_code IS NULL OR r.relationship_type_code = @type_code)
       AND ((@status IS NULL AND r.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')) OR @status = N'ALL' OR r.status = @status)
       AND (ISNULL(@critical_only, 0) = 0 OR r.is_critical = 1)
       AND (ISNULL(@pending_only, 0) = 0 OR r.status = N'PROPOSED' OR r.pending_action IS NOT NULL)
       AND (@search IS NULL OR sc.CiName LIKE N'%' + @search + N'%' OR tc.CiName LIKE N'%' + @search + N'%')
     ORDER BY CASE WHEN r.status = N'PROPOSED' OR r.pending_action IS NOT NULL THEN 0 WHEN r.status = N'DISPUTED' THEN 1
                   WHEN r.status = N'ACTIVE' THEN 2 ELSE 3 END,
              r.is_critical DESC, sc.CiName, t.display_order, tc.CiName
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- 440 body + ServiceRole.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationship_get
    @organization_id BIGINT,
    @relationship_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_relationship
                    WHERE relationship_id = @relationship_id AND organization_id = @organization_id)
        THROW 54709, 'Relationship not found for this organization.', 1;
    SELECT r.relationship_id AS RelationshipId, r.relationship_type_code AS TypeCode, t.type_name AS TypeName,
           t.inverse_label AS InverseLabel, t.dependent_side AS DependentSide, r.source_kind AS SourceKind, r.source_id AS SourceId,
           sc.CiName AS SourceName, sc.CiClass AS SourceClass, sc.CiStatus AS SourceStatus, r.target_kind AS TargetKind,
           r.target_id AS TargetId, tc.CiName AS TargetName, tc.CiClass AS TargetClass, tc.CiStatus AS TargetStatus,
           r.is_critical AS IsCritical, r.dependency_criticality AS DependencyCriticality, r.impact_weight AS ImpactWeight,
           r.service_role AS ServiceRole,                                                             -- 441
           r.status AS Status, r.effective_from AS EffectiveFrom, r.effective_to AS EffectiveTo, r.source_code AS SourceCode,
           r.confidence_pct AS ConfidencePct, r.verification_status AS VerificationStatus, r.owner_employee_id AS OwnerEmployeeId,
           ow.employee_name AS OwnerName, r.verifier_employee_id AS VerifierEmployeeId, vf.employee_name AS VerifierName,
           r.evidence_reference AS EvidenceReference, r.change_reference AS ChangeReference, r.reason AS Reason, r.in_loop AS InLoop,
           r.version_no AS VersionNo, r.proposed_by AS ProposedBy, r.proposed_dt AS ProposedDt, r.approved_by AS ApprovedBy,
           r.approved_dt AS ApprovedDt, r.pending_action AS PendingAction, r.pending_json AS PendingJson,
           r.pending_reason AS PendingReason, r.pending_by AS PendingBy, r.pending_dt AS PendingDt,
           r.retirement_accepted AS RetirementAccepted, r.retirement_note AS RetirementNote,
           r.retirement_accepted_by AS RetirementAcceptedBy, r.retirement_accepted_dt AS RetirementAcceptedDt,
           r.status_note AS StatusNote, CONVERT(BIGINT, r.record_version) AS RecordVersion
      FROM grac_practice.asset_relationship r
      JOIN grac_practice.asset_relationship_type t ON t.type_code = r.relationship_type_code
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) sc ON sc.CiKind = r.source_kind AND sc.CiId = r.source_id
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) tc ON tc.CiKind = r.target_kind AND tc.CiId = r.target_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.owner_employee_id
      LEFT JOIN grac_practice.organization_employee vf ON vf.employee_id = r.verifier_employee_id
     WHERE r.relationship_id = @relationship_id;
    SELECT h.history_id AS HistoryId, h.version_no AS VersionNo, h.action_code AS ActionCode, h.status AS Status,
           h.note AS Note, h.actor AS Actor, e.employee_name AS ActorName, h.entered_dt AS EnteredDt, h.snapshot_json AS SnapshotJson
      FROM grac_practice.asset_relationship_history h
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = h.actor_employee_id
     WHERE h.relationship_id = @relationship_id
     ORDER BY h.history_id DESC;
END
GO

-- 440 body + 3. the business services reached, with owners, continuity
-- objectives and consumers (5.5.1).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_ci_impact
    @organization_id         BIGINT,
    @ci_kind                 NVARCHAR(12),
    @ci_id                   BIGINT,
    @direction               NVARCHAR(10)  = N'DOWNSTREAM',
    @max_depth               INT           = 5,
    @critical_only           BIT           = 0,
    @preview_relationship_id BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @ci_kind = UPPER(LTRIM(RTRIM(ISNULL(@ci_kind, N''))));
    SET @direction = UPPER(LTRIM(RTRIM(ISNULL(@direction, N'DOWNSTREAM'))));
    SET @max_depth = CASE WHEN ISNULL(@max_depth, 5) < 1 THEN 1 WHEN @max_depth > 10 THEN 10 ELSE @max_depth END;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54701, 'Organization not found.', 1;
    IF @direction NOT IN (N'DOWNSTREAM', N'UPSTREAM')
       OR NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_ci_catalog(@organization_id) WHERE CiKind = @ci_kind AND CiId = @ci_id)
        THROW 54720, 'Select a configuration item of this organization and the direction (downstream or upstream).', 1;

    CREATE TABLE #edge (rel BIGINT NOT NULL, type_code NVARCHAR(30) NOT NULL, crit BIT NOT NULL,
                        dk NVARCHAR(12) NOT NULL, di BIGINT NOT NULL, pk NVARCHAR(12) NOT NULL, pi BIGINT NOT NULL);
    INSERT #edge (rel, type_code, crit, dk, di, pk, pi)
    SELECT RelationshipId, TypeCode, IsCritical, DependentKind, DependentId, ProviderKind, ProviderId
      FROM grac_practice.fn_asset_relationship_edges(@organization_id, 1)
     WHERE ISNULL(@critical_only, 0) = 0 OR IsCritical = 1;
    IF @preview_relationship_id IS NOT NULL
        INSERT #edge (rel, type_code, crit, dk, di, pk, pi)
        SELECT e.RelationshipId, e.TypeCode, e.IsCritical, e.DependentKind, e.DependentId, e.ProviderKind, e.ProviderId
          FROM grac_practice.fn_asset_relationship_edges(@organization_id, 0) e
         WHERE e.RelationshipId = @preview_relationship_id
           AND NOT EXISTS (SELECT 1 FROM #edge x WHERE x.rel = e.RelationshipId);

    CREATE TABLE #seen (k NVARCHAR(12) NOT NULL, i BIGINT NOT NULL, lvl INT NOT NULL, rel BIGINT NULL,
                        from_k NVARCHAR(12) NULL, from_i BIGINT NULL, PRIMARY KEY (k, i));
    INSERT #seen (k, i, lvl) VALUES (@ci_kind, @ci_id, 0);
    DECLARE @lvl INT = 0;
    WHILE @lvl < @max_depth
    BEGIN
        -- one row per newly reached CI: the lowest relationship id reaching it from this level
        INSERT #seen (k, i, lvl, rel, from_k, from_i)
        SELECT x.k, x.i, @lvl + 1, x.rel, x.from_k, x.from_i
          FROM (SELECT CASE WHEN @direction = N'DOWNSTREAM' THEN e.dk ELSE e.pk END AS k,
                       CASE WHEN @direction = N'DOWNSTREAM' THEN e.di ELSE e.pi END AS i,
                       e.rel, s.k AS from_k, s.i AS from_i,
                       ROW_NUMBER() OVER (PARTITION BY CASE WHEN @direction = N'DOWNSTREAM' THEN e.dk ELSE e.pk END,
                                                       CASE WHEN @direction = N'DOWNSTREAM' THEN e.di ELSE e.pi END
                                          ORDER BY e.crit DESC, e.rel) AS rn
                  FROM #edge e
                  JOIN #seen s ON s.lvl = @lvl
                              AND ((@direction = N'DOWNSTREAM' AND s.k = e.pk AND s.i = e.pi)
                                   OR (@direction = N'UPSTREAM' AND s.k = e.dk AND s.i = e.di))) x
         WHERE x.rn = 1
           AND NOT EXISTS (SELECT 1 FROM #seen z WHERE z.k = x.k AND z.i = x.i);
        IF @@ROWCOUNT = 0 BREAK;
        SET @lvl = @lvl + 1;
    END

    SELECT s.k AS CiKind, s.i AS CiId, c.CiName, c.CiClass, c.CiStatus, s.lvl AS ImpactLevel, s.rel AS ViaRelationshipId,
           e.type_code AS ViaTypeCode,
           CASE WHEN @direction = N'DOWNSTREAM' THEN
                     CASE t.dependent_side WHEN N'SOURCE' THEN t.type_name ELSE t.inverse_label END
                ELSE CASE t.dependent_side WHEN N'SOURCE' THEN t.inverse_label ELSE t.type_name END END AS ViaLabel,
           e.crit AS ViaCritical, s.from_k AS FromKind, s.from_i AS FromId, fc.CiName AS FromName,
           CAST(CASE WHEN e.rel = @preview_relationship_id THEN 1 ELSE 0 END AS BIT) AS ViaPreview
      FROM #seen s
      JOIN #edge e ON e.rel = s.rel
      JOIN grac_practice.asset_relationship_type t ON t.type_code = e.type_code
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) c ON c.CiKind = s.k AND c.CiId = s.i
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) fc ON fc.CiKind = s.from_k AND fc.CiId = s.from_i
     WHERE s.lvl > 0
     ORDER BY s.lvl, c.CiKind, c.CiName;

    SELECT @ci_kind AS CiKind, @ci_id AS CiId, (SELECT CiName FROM grac_practice.fn_asset_ci_catalog(@organization_id)
                                                  WHERE CiKind = @ci_kind AND CiId = @ci_id) AS CiName,
           @direction AS Direction, @max_depth AS MaxDepth,
           (SELECT COUNT(*) FROM #seen WHERE lvl > 0) AS ReachedCount,
           (SELECT COUNT(*) FROM #seen s JOIN #edge e ON e.rel = s.rel WHERE s.lvl > 0 AND e.crit = 1) AS CriticalCount,
           (SELECT MAX(lvl) FROM #seen) AS DeepestLevel;

    -- 441: business services reached.
    SELECT s.i AS ServiceId, b.service_code AS ServiceCode, b.service_name AS ServiceName, b.service_type AS ServiceType,
           b.status AS ServiceStatus, s.lvl AS ImpactLevel, cm.criticality_code AS CriticalityCode, b.rto_hours AS RtoHours,
           b.rpo_hours AS RpoHours, b.mtpd_hours AS MtpdHours, bo.employee_name AS BusinessOwnerName,
           sm.employee_name AS ServiceManagerName, cn.Consumers
      FROM #seen s
      JOIN grac_practice.business_service b ON b.service_id = s.i
      LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id = b.criticality_id
      LEFT JOIN grac_practice.organization_employee bo ON bo.employee_id = b.business_owner_employee_id
      LEFT JOIN grac_practice.organization_employee sm ON sm.employee_id = b.service_manager_employee_id
     OUTER APPLY (SELECT STRING_AGG(c.ConsumerName, N', ') AS Consumers
                    FROM grac_practice.fn_business_service_consumers(b.service_id) c) cn
     WHERE s.k = N'SERVICE' AND s.lvl > 0
     ORDER BY s.lvl, b.service_name;
END
GO
PRINT '441: relationship bodies re-issued.';
GO

-- =====================================================================
-- 4. Writers (D88-D95)
-- =====================================================================
-- Create (Draft) or change a service; @consumers_json replaces the
-- consumers when given: [{"consumerKind":"DEPARTMENT","consumerRefId":3},
-- {"consumerKind":"EXTERNAL","consumerName":"Retail customers"}].
CREATE OR ALTER PROCEDURE grac_practice.sp_business_service_save
    @organization_id             BIGINT,
    @service_id                  BIGINT         = NULL,
    @service_code                NVARCHAR(40)   = NULL,
    @service_name                NVARCHAR(200)  = NULL,
    @service_type                NVARCHAR(16)   = NULL,
    @description                 NVARCHAR(2000) = NULL,
    @customer_outcome            NVARCHAR(1000) = NULL,
    @business_owner_employee_id  BIGINT         = NULL,
    @service_manager_employee_id BIGINT         = NULL,
    @accountable_department_id   BIGINT         = NULL,
    @criticality_id              INT            = NULL,
    @confidentiality_rating      TINYINT        = NULL,
    @integrity_rating            TINYINT        = NULL,
    @availability_rating         TINYINT        = NULL,
    @rto_hours                   DECIMAL(9, 2)  = NULL,
    @rpo_hours                   DECIMAL(9, 2)  = NULL,
    @mtpd_hours                  DECIMAL(9, 2)  = NULL,
    @service_hours               NVARCHAR(200)  = NULL,
    @sla_text                    NVARCHAR(1000) = NULL,
    @data_classification         NVARCHAR(100)  = NULL,
    @privacy_classification      NVARCHAR(100)  = NULL,
    @review_date                 DATE           = NULL,
    @consumers_json              NVARCHAR(MAX)  = NULL,
    @expected_record_version     BIGINT         = NULL,
    @actor_employee_id           BIGINT         = NULL,
    @actor                       NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @service_code = NULLIF(UPPER(LTRIM(RTRIM(@service_code))), N'');
    SET @service_name = NULLIF(LTRIM(RTRIM(@service_name)), N'');
    SET @service_type = UPPER(LTRIM(RTRIM(ISNULL(@service_type, N''))));
    SET @description = NULLIF(LTRIM(RTRIM(@description)), N'');
    SET @customer_outcome = NULLIF(LTRIM(RTRIM(@customer_outcome)), N'');
    SET @service_hours = NULLIF(LTRIM(RTRIM(@service_hours)), N'');
    SET @sla_text = NULLIF(LTRIM(RTRIM(@sla_text)), N'');
    SET @data_classification = NULLIF(LTRIM(RTRIM(@data_classification)), N'');
    SET @privacy_classification = NULLIF(LTRIM(RTRIM(@privacy_classification)), N'');
    SET @consumers_json = NULLIF(LTRIM(RTRIM(@consumers_json)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54730, 'Organization not found.', 1;
    IF @service_code IS NULL OR @service_name IS NULL
        THROW 54733, 'Enter the service ID and the service name.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.business_service
                WHERE organization_id = @organization_id AND service_id <> ISNULL(@service_id, -1)
                  AND (service_code = @service_code OR service_name = @service_name))
        THROW 54734, 'Another service already uses this service ID or name.', 1;
    IF @service_type NOT IN (N'BUSINESS', N'CUSTOMER_FACING', N'TECHNICAL', N'SHARED', N'SUPPORTING')
        THROW 54735, 'The service type is Business, Customer-facing, Technical, Shared or Supporting.', 1;
    IF (@business_owner_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
            WHERE employee_id = @business_owner_employee_id AND organization_id = @organization_id AND status = N'Active'))
       OR (@service_manager_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
            WHERE employee_id = @service_manager_employee_id AND organization_id = @organization_id AND status = N'Active'))
        THROW 54736, 'The business owner and the service manager must be active employees of the organization.', 1;
    IF @accountable_department_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_department
            WHERE department_id = @accountable_department_id AND organization_id = @organization_id)
        THROW 54737, 'The accountable department must belong to the organization.', 1;
    IF @criticality_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.criticality_master WHERE criticality_id = @criticality_id)
        THROW 54738, 'Select a valid criticality.', 1;
    IF @confidentiality_rating NOT BETWEEN 1 AND 5 OR @integrity_rating NOT BETWEEN 1 AND 5 OR @availability_rating NOT BETWEEN 1 AND 5
        THROW 54739, 'Confidentiality, integrity and availability are rated 1 to 5.', 1;
    IF @rto_hours < 0 OR @rpo_hours < 0 OR @mtpd_hours < 0 OR (@rto_hours IS NOT NULL AND @mtpd_hours IS NOT NULL AND @rto_hours > @mtpd_hours)
        THROW 54740, 'RTO, RPO and MTPD are hours of zero or more, and the RTO cannot exceed the MTPD.', 1;

    DECLARE @cons TABLE (consumer_kind NVARCHAR(18) NOT NULL, consumer_ref_id BIGINT NULL, consumer_name NVARCHAR(200) NULL,
                         note NVARCHAR(400) NULL);
    IF @consumers_json IS NOT NULL
    BEGIN
        IF ISJSON(@consumers_json) = 0 THROW 54749, 'The consumer list is not valid.', 1;
        INSERT @cons (consumer_kind, consumer_ref_id, consumer_name, note)
        SELECT DISTINCT UPPER(LTRIM(RTRIM(ISNULL(j.consumerKind, N'')))), j.consumerRefId, NULLIF(LTRIM(RTRIM(j.consumerName)), N''),
               NULLIF(LTRIM(RTRIM(j.note)), N'')
          FROM OPENJSON(@consumers_json) WITH (consumerKind NVARCHAR(18), consumerRefId BIGINT, consumerName NVARCHAR(200),
                                               note NVARCHAR(400)) j;
        IF EXISTS (SELECT 1 FROM @cons c
                    WHERE NOT ((c.consumer_kind = N'EXTERNAL' AND c.consumer_name IS NOT NULL)
                            OR (c.consumer_kind = N'DEPARTMENT' AND EXISTS (SELECT 1 FROM grac_practice.organization_department d
                                    WHERE d.department_id = c.consumer_ref_id AND d.organization_id = @organization_id))
                            OR (c.consumer_kind = N'BUSINESS_FUNCTION' AND EXISTS (SELECT 1 FROM grac_practice.organization_business_function f
                                    WHERE f.business_function_id = c.consumer_ref_id AND f.organization_id = @organization_id))
                            OR (c.consumer_kind = N'LOCATION' AND EXISTS (SELECT 1 FROM grac_practice.organization_location l
                                    WHERE l.location_id = c.consumer_ref_id AND l.organization_id = @organization_id))))
            THROW 54749, 'Every consumer is a department, business function or location of the organization, or a named external consumer.', 1;
    END

    DECLARE @id BIGINT = @service_id, @result NVARCHAR(20);
    IF @service_id IS NOT NULL
    BEGIN
        DECLARE @found BIT = 0, @status NVARCHAR(10), @rv BIGINT;
        SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version)
          FROM grac_practice.business_service WHERE service_id = @service_id AND organization_id = @organization_id;
        IF @found = 0 THROW 54731, 'Business service not found for this organization.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54732, 'The service was changed by someone else; reload it and try again.', 1;
        IF @status = N'RETIRED' THROW 54751, 'A retired service is kept for history and cannot be changed.', 1;
    END

    BEGIN TRAN;
    IF @id IS NULL
    BEGIN
        INSERT grac_practice.business_service
            (organization_id, service_code, service_name, service_type, description, customer_outcome, business_owner_employee_id,
             service_manager_employee_id, accountable_department_id, criticality_id, confidentiality_rating, integrity_rating,
             availability_rating, rto_hours, rpo_hours, mtpd_hours, service_hours, sla_text, data_classification,
             privacy_classification, status, review_date, entered_by)
        VALUES (@organization_id, @service_code, @service_name, @service_type, @description, @customer_outcome,
                @business_owner_employee_id, @service_manager_employee_id, @accountable_department_id, @criticality_id,
                @confidentiality_rating, @integrity_rating, @availability_rating, @rto_hours, @rpo_hours, @mtpd_hours,
                @service_hours, @sla_text, @data_classification, @privacy_classification, N'DRAFT', @review_date, @actor);
        SET @id = SCOPE_IDENTITY();
        SET @result = N'CREATED';
    END
    ELSE
    BEGIN
        UPDATE grac_practice.business_service
           SET service_code = @service_code, service_name = @service_name, service_type = @service_type, description = @description,
               customer_outcome = @customer_outcome, business_owner_employee_id = @business_owner_employee_id,
               service_manager_employee_id = @service_manager_employee_id, accountable_department_id = @accountable_department_id,
               criticality_id = @criticality_id, confidentiality_rating = @confidentiality_rating, integrity_rating = @integrity_rating,
               availability_rating = @availability_rating, rto_hours = @rto_hours, rpo_hours = @rpo_hours, mtpd_hours = @mtpd_hours,
               service_hours = @service_hours, sla_text = @sla_text, data_classification = @data_classification,
               privacy_classification = @privacy_classification, review_date = @review_date, version_no = version_no + 1,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE service_id = @id;
        SET @result = N'SAVED';
    END
    IF @consumers_json IS NOT NULL
    BEGIN
        DELETE FROM grac_practice.business_service_consumer WHERE service_id = @id;
        INSERT grac_practice.business_service_consumer (service_id, consumer_kind, consumer_ref_id, consumer_name, note, entered_by)
        SELECT @id, consumer_kind, CASE WHEN consumer_kind = N'EXTERNAL' THEN NULL ELSE consumer_ref_id END,
               CASE WHEN consumer_kind = N'EXTERNAL' THEN consumer_name END, note, @actor
          FROM @cons;
    END
    EXEC grac_practice.sp_business_service_history_add @service_id = @id, @action_code = @result, @actor = @actor,
         @actor_employee_id = @actor_employee_id;
    COMMIT;
    SELECT @id AS ServiceId, @result AS Result;
END
GO

-- Retires a service (inside the transaction of the caller): status Retired;
-- its current relationships (supporting it, or it supporting others) are
-- retired with a history row (D94).
CREATE OR ALTER PROCEDURE grac_practice.sp_business_service_retire_apply
    @service_id        BIGINT,
    @note              NVARCHAR(1000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    UPDATE grac_practice.business_service
       SET status = N'RETIRED', retired_dt = SYSUTCDATETIME(), status_note = @note, pending_retirement = 0, pending_by = NULL,
           pending_by_employee_id = NULL, pending_dt = NULL, version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE service_id = @service_id;
    DECLARE @ended TABLE (relationship_id BIGINT NOT NULL);
    UPDATE grac_practice.asset_relationship
       SET status = N'RETIRED', status_note = N'The business service was retired.', version_no = version_no + 1,
           pending_action = NULL, pending_json = NULL, pending_reason = NULL, pending_by = NULL, pending_by_employee_id = NULL,
           pending_dt = NULL,
           effective_to = CASE WHEN effective_to IS NULL OR effective_to > @today THEN
                                   CASE WHEN effective_from > @today THEN effective_from ELSE @today END
                               ELSE effective_to END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
    OUTPUT inserted.relationship_id INTO @ended (relationship_id)
     WHERE status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')
       AND ((target_kind = N'SERVICE' AND target_id = @service_id) OR (source_kind = N'SERVICE' AND source_id = @service_id));
    DECLARE @rid BIGINT;
    DECLARE rel_cur CURSOR LOCAL STATIC FOR SELECT relationship_id FROM @ended;
    OPEN rel_cur;
    FETCH NEXT FROM rel_cur INTO @rid;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @rid, @action_code = N'SERVICE_RETIRED',
             @note = N'The business service was retired.', @actor = @actor, @actor_employee_id = @actor_employee_id;
        FETCH NEXT FROM rel_cur INTO @rid;
    END
    CLOSE rel_cur;
    DEALLOCATE rel_cur;
    EXEC grac_practice.sp_business_service_history_add @service_id = @service_id, @action_code = N'RETIRED', @note = @note,
         @actor = @actor, @actor_employee_id = @actor_employee_id;
END
GO

-- Status changes (5.5, 5.5.1; D91-D94):
--   Draft -> Design | Retired;  Design -> Draft | Active | Retired;
--   Active -> Degraded | Suspended | Retiring;  Degraded -> Active | Suspended | Retiring;
--   Suspended -> Active | Retiring;  Retiring -> Active | Retired.
-- To Active: a business owner and the minimum active supporting
-- relationships. To Retired: no active critical relationship relying on the
-- service; from Retiring also the consumer review and contract assessment
-- notes and, where configured, approval by another person (pending).
CREATE OR ALTER PROCEDURE grac_practice.sp_business_service_transition
    @organization_id          BIGINT,
    @service_id               BIGINT,
    @to_status                NVARCHAR(10),
    @note                     NVARCHAR(1000) = NULL,
    @consumer_review_note     NVARCHAR(1000) = NULL,
    @contract_assessment_note NVARCHAR(1000) = NULL,
    @expected_record_version  BIGINT         = NULL,
    @actor_employee_id        BIGINT         = NULL,
    @actor                    NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @to_status = UPPER(LTRIM(RTRIM(ISNULL(@to_status, N''))));
    SET @note = NULLIF(LTRIM(RTRIM(@note)), N'');
    SET @consumer_review_note = NULLIF(LTRIM(RTRIM(@consumer_review_note)), N'');
    SET @contract_assessment_note = NULLIF(LTRIM(RTRIM(@contract_assessment_note)), N'');
    DECLARE @found BIT = 0, @from NVARCHAR(10), @rv BIGINT, @owner BIGINT, @pending BIT, @msg NVARCHAR(1400);
    SELECT @found = 1, @from = status, @rv = CONVERT(BIGINT, record_version), @owner = business_owner_employee_id,
           @pending = pending_retirement
      FROM grac_practice.business_service WHERE service_id = @service_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54731, 'Business service not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54732, 'The service was changed by someone else; reload it and try again.', 1;
    IF @pending = 1
        THROW 54747, 'The retirement of this service is waiting for approval; approve, reject or withdraw it first.', 1;
    IF CHARINDEX(CONCAT(N'|', @from, N'>', @to_status, N'|'),
                 N'|DRAFT>DESIGN|DRAFT>RETIRED|DESIGN>DRAFT|DESIGN>ACTIVE|DESIGN>RETIRED|ACTIVE>DEGRADED|ACTIVE>SUSPENDED|ACTIVE>RETIRING|'
                 + N'DEGRADED>ACTIVE|DEGRADED>SUSPENDED|DEGRADED>RETIRING|SUSPENDED>ACTIVE|SUSPENDED>RETIRING|RETIRING>ACTIVE|RETIRING>RETIRED|') = 0
    BEGIN
        SET @msg = CONCAT(N'A service cannot move from ', @from, N' to ', @to_status, N'.');
        THROW 54741, @msg, 1;
    END
    IF @note IS NULL AND NOT (@from IN (N'DRAFT', N'DESIGN') AND @to_status IN (N'DESIGN', N'ACTIVE'))
        THROW 54742, 'Enter a note for this status change.', 1;

    DECLARE @min INT = ISNULL((SELECT min_supporting_relationships FROM grac_practice.business_service_setting
                                WHERE organization_id = @organization_id), 1);
    DECLARE @approval BIT = ISNULL((SELECT retirement_approval_required FROM grac_practice.business_service_setting
                                     WHERE organization_id = @organization_id), 1);
    IF @to_status = N'ACTIVE'
    BEGIN
        IF @owner IS NULL THROW 54743, 'Set the business owner before the service becomes Active.', 1;
        DECLARE @support INT = (SELECT COUNT(*) FROM grac_practice.asset_relationship
                                 WHERE organization_id = @organization_id AND relationship_type_code = N'SUPPORTS_SERVICE'
                                   AND target_kind = N'SERVICE' AND target_id = @service_id AND status = N'ACTIVE'
                                   AND effective_from <= CAST(SYSUTCDATETIME() AS DATE)
                                   AND (effective_to IS NULL OR effective_to >= CAST(SYSUTCDATETIME() AS DATE)));
        IF @support < @min
        BEGIN
            SET @msg = CONCAT(N'The service needs at least ', @min, N' active supporting relationship(s) before it becomes Active (it has ',
                              @support, N'). Map its assets, applications, suppliers or child services first.');
            THROW 54744, @msg, 1;
        END
    END
    IF @to_status = N'RETIRED'
    BEGIN
        DECLARE @blockers NVARCHAR(1000) = (
            SELECT LEFT(STRING_AGG(CONCAT(c.CiName, N' (', t.type_name, N')'), N', '), 900)
              FROM grac_practice.fn_asset_relationship_blockers(@organization_id, N'SERVICE', @service_id) b
              JOIN grac_practice.asset_relationship_type t ON t.type_code = b.TypeCode
              LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) c ON c.CiKind = b.DependentKind AND c.CiId = b.DependentId);
        IF @blockers IS NOT NULL
        BEGIN
            SET @msg = CONCAT(N'Active critical dependencies still rely on this service: ', @blockers,
                              N'. Migrate or retire them, or accept them for retirement (Asset Relationships), first.');
            THROW 54745, @msg, 1;
        END
        IF @from = N'RETIRING' AND (@consumer_review_note IS NULL OR @contract_assessment_note IS NULL)
            THROW 54746, 'Record the consumer review and the contract assessment before retiring the service.', 1;
    END

    DECLARE @result NVARCHAR(20);
    BEGIN TRAN;
    IF @to_status = N'RETIRED' AND @from = N'RETIRING' AND @approval = 1
    BEGIN
        UPDATE grac_practice.business_service
           SET pending_retirement = 1, consumer_review_note = @consumer_review_note, contract_assessment_note = @contract_assessment_note,
               status_note = @note, pending_by = @actor, pending_by_employee_id = @actor_employee_id, pending_dt = SYSUTCDATETIME(),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE service_id = @service_id;
        EXEC grac_practice.sp_business_service_history_add @service_id = @service_id, @action_code = N'RETIRE_REQUEST', @note = @note,
             @actor = @actor, @actor_employee_id = @actor_employee_id;
        SET @result = N'PENDING_APPROVAL';
    END
    ELSE IF @to_status = N'RETIRED'
    BEGIN
        UPDATE grac_practice.business_service
           SET consumer_review_note = ISNULL(@consumer_review_note, consumer_review_note),
               contract_assessment_note = ISNULL(@contract_assessment_note, contract_assessment_note)
         WHERE service_id = @service_id;
        EXEC grac_practice.sp_business_service_retire_apply @service_id = @service_id, @note = @note,
             @actor_employee_id = @actor_employee_id, @actor = @actor;
        SET @result = N'RETIRED';
    END
    ELSE
    BEGIN
        UPDATE grac_practice.business_service
           SET status = @to_status, status_note = @note, version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE service_id = @service_id;
        EXEC grac_practice.sp_business_service_history_add @service_id = @service_id, @action_code = N'STATUS', @note = @note,
             @actor = @actor, @actor_employee_id = @actor_employee_id;
        SET @result = @to_status;
    END
    COMMIT;
    SELECT @service_id AS ServiceId, @result AS Result;
END
GO

-- Decide a pending retirement: APPROVE / REJECT (another person; reject
-- needs a note) or WITHDRAW (the requester). Approval checks the dependants
-- again.
CREATE OR ALTER PROCEDURE grac_practice.sp_business_service_retirement_decide
    @organization_id         BIGINT,
    @service_id              BIGINT,
    @decision                NVARCHAR(10),
    @decision_note           NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @decision = UPPER(LTRIM(RTRIM(ISNULL(@decision, N''))));
    SET @decision_note = NULLIF(LTRIM(RTRIM(@decision_note)), N'');
    DECLARE @found BIT = 0, @pending BIT, @rv BIGINT, @by NVARCHAR(100), @by_emp BIGINT, @note NVARCHAR(1000);
    SELECT @found = 1, @pending = pending_retirement, @rv = CONVERT(BIGINT, record_version), @by = pending_by,
           @by_emp = pending_by_employee_id, @note = status_note
      FROM grac_practice.business_service WHERE service_id = @service_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54731, 'Business service not found for this organization.', 1;
    IF @pending = 0 THROW 54747, 'No retirement of this service is waiting for a decision.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54732, 'The service was changed by someone else; reload it and try again.', 1;
    IF @decision NOT IN (N'APPROVE', N'REJECT', N'WITHDRAW')
        THROW 54741, 'The decision is Approve, Reject or Withdraw.', 1;
    IF @decision = N'WITHDRAW' AND ISNULL(@by, N'') <> @actor
        THROW 54748, 'Only the person who requested the retirement can withdraw it.', 1;
    IF @decision IN (N'APPROVE', N'REJECT') AND (@by = @actor OR (@by_emp IS NOT NULL AND @by_emp = @actor_employee_id))
        THROW 54748, 'Segregation of duties: the person who requested the retirement cannot approve or reject it.', 1;
    IF @decision = N'REJECT' AND @decision_note IS NULL
        THROW 54742, 'Give the reason for rejecting the retirement.', 1;
    IF @decision = N'APPROVE' AND EXISTS (SELECT 1 FROM grac_practice.fn_asset_relationship_blockers(@organization_id, N'SERVICE', @service_id))
        THROW 54745, 'Active critical dependencies now rely on this service; reject the retirement or clear them first.', 1;

    BEGIN TRAN;
    IF @decision = N'APPROVE'
    BEGIN
        EXEC grac_practice.sp_business_service_retire_apply @service_id = @service_id,
             @note = @note, @actor_employee_id = @actor_employee_id, @actor = @actor;
    END
    ELSE
    BEGIN
        UPDATE grac_practice.business_service
           SET pending_retirement = 0, pending_by = NULL, pending_by_employee_id = NULL, pending_dt = NULL,
               status_note = ISNULL(@decision_note, N'Retirement withdrawn by the requester.'), updated_by = @actor,
               updated_dt = SYSUTCDATETIME()
         WHERE service_id = @service_id;
        EXEC grac_practice.sp_business_service_history_add @service_id = @service_id, @action_code = @decision,
             @note = @decision_note, @actor = @actor, @actor_employee_id = @actor_employee_id;
    END
    COMMIT;
    SELECT @service_id AS ServiceId, CASE @decision WHEN N'APPROVE' THEN N'RETIRED' WHEN N'REJECT' THEN N'REJECTED'
                                                    ELSE N'WITHDRAWN' END AS Result;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_business_service_setting_save
    @organization_id              BIGINT,
    @min_supporting_relationships INT  = 1,
    @retirement_approval_required BIT  = 1,
    @actor                        NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54730, 'Organization not found.', 1;
    IF @min_supporting_relationships IS NULL OR @min_supporting_relationships NOT BETWEEN 0 AND 50
        THROW 54750, 'The minimum supporting relationships is between 0 and 50.', 1;
    DECLARE @before NVARCHAR(MAX) = (SELECT min_supporting_relationships AS minSupportingRelationships,
                                            retirement_approval_required AS retirementApprovalRequired
                                       FROM grac_practice.business_service_setting WHERE organization_id = @organization_id
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRAN;
    MERGE grac_practice.business_service_setting AS t
    USING (SELECT @organization_id AS organization_id) AS s ON t.organization_id = s.organization_id
    WHEN MATCHED THEN UPDATE SET min_supporting_relationships = @min_supporting_relationships,
        retirement_approval_required = ISNULL(@retirement_approval_required, 1), updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (organization_id, min_supporting_relationships, retirement_approval_required, updated_by)
        VALUES (@organization_id, @min_supporting_relationships, ISNULL(@retirement_approval_required, 1), @actor);
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'business-service-setting', @organization_id, CASE WHEN @before IS NULL THEN N'CREATE' ELSE N'UPDATE' END, @before,
            (SELECT @min_supporting_relationships AS minSupportingRelationships,
                    ISNULL(@retirement_approval_required, 1) AS retirementApprovalRequired FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @organization_id AS OrganizationId, N'SAVED' AS Result;
END
GO
PRINT '441: writers created.';
GO

-- =====================================================================
-- 5. Readers
-- =====================================================================
-- 1. settings (defaults when none saved)  2. active employees  3. departments
-- 4. business functions  5. locations  6. criticalities.
CREATE OR ALTER PROCEDURE grac_practice.sp_business_service_config_get
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54730, 'Organization not found.', 1;
    SELECT ISNULL(s.min_supporting_relationships, 1) AS MinSupportingRelationships,
           CAST(ISNULL(s.retirement_approval_required, 1) AS BIT) AS RetirementApprovalRequired
      FROM (SELECT 1 AS x) d
      LEFT JOIN grac_practice.business_service_setting s ON s.organization_id = @organization_id;
    SELECT employee_id AS EmployeeId, employee_name AS EmployeeName
      FROM grac_practice.organization_employee WHERE organization_id = @organization_id AND status = N'Active' ORDER BY employee_name;
    SELECT department_id AS DepartmentId, department_name AS DepartmentName
      FROM grac_practice.organization_department WHERE organization_id = @organization_id AND status = N'Active' ORDER BY department_name;
    SELECT business_function_id AS BusinessFunctionId, function_name AS FunctionName
      FROM grac_practice.organization_business_function WHERE organization_id = @organization_id AND status = N'Active'
     ORDER BY function_name;
    SELECT location_id AS LocationId, location_name AS LocationName
      FROM grac_practice.organization_location WHERE organization_id = @organization_id AND status = N'Active' ORDER BY location_name;
    SELECT criticality_id AS CriticalityId, criticality_code AS CriticalityCode
      FROM grac_practice.criticality_master
     ORDER BY CASE criticality_code WHEN N'Critical' THEN 1 WHEN N'High' THEN 2 WHEN N'Medium' THEN 3 WHEN N'Low' THEN 4 ELSE 5 END;
END
GO

-- Services. @status: NULL = every status but Retired, ALL, or one status.
CREATE OR ALTER PROCEDURE grac_practice.sp_business_services
    @organization_id BIGINT,
    @status          NVARCHAR(10)  = NULL,
    @service_type    NVARCHAR(16)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54730, 'Organization not found.', 1;
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @service_type = NULLIF(UPPER(LTRIM(RTRIM(@service_type))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @conf TABLE (service_id BIGINT NOT NULL PRIMARY KEY, n INT NOT NULL);
    INSERT @conf (service_id, n)
    SELECT ServiceId, COUNT(*) FROM grac_practice.fn_business_service_conflicts(@organization_id) GROUP BY ServiceId;

    SELECT b.service_id AS ServiceId, b.service_code AS ServiceCode, b.service_name AS ServiceName, b.service_type AS ServiceType,
           b.status AS Status, cm.criticality_code AS CriticalityCode, bo.employee_name AS BusinessOwnerName,
           sm.employee_name AS ServiceManagerName, d.department_name AS AccountableDepartmentName, b.rto_hours AS RtoHours,
           b.rpo_hours AS RpoHours, b.mtpd_hours AS MtpdHours, b.review_date AS ReviewDate,
           (SELECT COUNT(*) FROM grac_practice.asset_relationship r
             WHERE r.relationship_type_code = N'SUPPORTS_SERVICE' AND r.target_kind = N'SERVICE' AND r.target_id = b.service_id
               AND r.status = N'ACTIVE' AND r.effective_from <= @today AND (r.effective_to IS NULL OR r.effective_to >= @today)) AS SupportCount,
           (SELECT COUNT(*) FROM grac_practice.asset_relationship r
             WHERE r.relationship_type_code = N'SUPPORTS_SERVICE' AND r.source_kind = N'SERVICE' AND r.source_id = b.service_id
               AND r.status = N'ACTIVE' AND r.effective_from <= @today AND (r.effective_to IS NULL OR r.effective_to >= @today)) AS SupportsCount,
           (SELECT COUNT(*) FROM grac_practice.business_service_consumer c WHERE c.service_id = b.service_id) AS ConsumerCount,
           ISNULL(cf.n, 0) AS ConflictCount, b.pending_retirement AS PendingRetirement, b.version_no AS VersionNo,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.business_service b
      LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id = b.criticality_id
      LEFT JOIN grac_practice.organization_employee bo ON bo.employee_id = b.business_owner_employee_id
      LEFT JOIN grac_practice.organization_employee sm ON sm.employee_id = b.service_manager_employee_id
      LEFT JOIN grac_practice.organization_department d ON d.department_id = b.accountable_department_id
      LEFT JOIN @conf cf ON cf.service_id = b.service_id
     WHERE b.organization_id = @organization_id
       AND ((@status IS NULL AND b.status <> N'RETIRED') OR @status = N'ALL' OR b.status = @status)
       AND (@service_type IS NULL OR b.service_type = @service_type)
       AND (@search IS NULL OR b.service_name LIKE N'%' + @search + N'%' OR b.service_code LIKE N'%' + @search + N'%')
     ORDER BY CASE WHEN b.pending_retirement = 1 THEN 0 ELSE 1 END, b.service_name
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- One service: 1. service  2. consumers  3. supporting items (relationships
-- into the service)  4. services it supports  5. conflicts  6. history.
CREATE OR ALTER PROCEDURE grac_practice.sp_business_service_get
    @organization_id BIGINT,
    @service_id      BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.business_service WHERE service_id = @service_id AND organization_id = @organization_id)
        THROW 54731, 'Business service not found for this organization.', 1;
    SELECT b.service_id AS ServiceId, b.service_code AS ServiceCode, b.service_name AS ServiceName, b.service_type AS ServiceType,
           b.description AS Description, b.customer_outcome AS CustomerOutcome, b.business_owner_employee_id AS BusinessOwnerEmployeeId,
           bo.employee_name AS BusinessOwnerName, b.service_manager_employee_id AS ServiceManagerEmployeeId,
           sm.employee_name AS ServiceManagerName, b.accountable_department_id AS AccountableDepartmentId,
           d.department_name AS AccountableDepartmentName, b.criticality_id AS CriticalityId, cm.criticality_code AS CriticalityCode,
           b.confidentiality_rating AS ConfidentialityRating, b.integrity_rating AS IntegrityRating,
           b.availability_rating AS AvailabilityRating, b.rto_hours AS RtoHours, b.rpo_hours AS RpoHours, b.mtpd_hours AS MtpdHours,
           b.service_hours AS ServiceHours, b.sla_text AS SlaText, b.data_classification AS DataClassification,
           b.privacy_classification AS PrivacyClassification, b.status AS Status, b.review_date AS ReviewDate,
           b.version_no AS VersionNo, b.status_note AS StatusNote, b.pending_retirement AS PendingRetirement,
           b.consumer_review_note AS ConsumerReviewNote, b.contract_assessment_note AS ContractAssessmentNote,
           b.pending_by AS PendingBy, b.pending_dt AS PendingDt, b.retired_dt AS RetiredDt,
           CONVERT(BIGINT, b.record_version) AS RecordVersion
      FROM grac_practice.business_service b
      LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id = b.criticality_id
      LEFT JOIN grac_practice.organization_employee bo ON bo.employee_id = b.business_owner_employee_id
      LEFT JOIN grac_practice.organization_employee sm ON sm.employee_id = b.service_manager_employee_id
      LEFT JOIN grac_practice.organization_department d ON d.department_id = b.accountable_department_id
     WHERE b.service_id = @service_id;
    SELECT ConsumerId, ConsumerKind, ConsumerRefId, ConsumerName, Note
      FROM grac_practice.fn_business_service_consumers(@service_id) ORDER BY ConsumerKind, ConsumerName;
    SELECT r.relationship_id AS RelationshipId, r.source_kind AS CiKind, r.source_id AS CiId, c.CiName, c.CiClass, c.CiStatus,
           r.service_role AS ServiceRole, r.is_critical AS IsCritical, r.dependency_criticality AS DependencyCriticality,
           r.status AS Status, r.effective_from AS EffectiveFrom, r.effective_to AS EffectiveTo, r.source_code AS SourceCode,
           r.pending_action AS PendingAction
      FROM grac_practice.asset_relationship r
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) c ON c.CiKind = r.source_kind AND c.CiId = r.source_id
     WHERE r.organization_id = @organization_id AND r.relationship_type_code = N'SUPPORTS_SERVICE'
       AND r.target_kind = N'SERVICE' AND r.target_id = @service_id AND r.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')
     ORDER BY r.is_critical DESC, c.CiKind, c.CiName;
    SELECT r.relationship_id AS RelationshipId, r.target_id AS ServiceId, b.service_name AS ServiceName, b.status AS ServiceStatus,
           r.service_role AS ServiceRole, r.is_critical AS IsCritical, r.status AS Status
      FROM grac_practice.asset_relationship r
      JOIN grac_practice.business_service b ON b.service_id = r.target_id
     WHERE r.organization_id = @organization_id AND r.relationship_type_code = N'SUPPORTS_SERVICE'
       AND r.source_kind = N'SERVICE' AND r.source_id = @service_id AND r.target_kind = N'SERVICE'
       AND r.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')
     ORDER BY b.service_name;
    SELECT ConflictCode, Message, CiKind, CiId, CiName, RelationshipId
      FROM grac_practice.fn_business_service_conflicts(@organization_id) WHERE ServiceId = @service_id
     ORDER BY ConflictCode;
    SELECT h.history_id AS HistoryId, h.version_no AS VersionNo, h.action_code AS ActionCode, h.status AS Status, h.note AS Note,
           h.actor AS Actor, e.employee_name AS ActorName, h.entered_dt AS EnteredDt
      FROM grac_practice.business_service_history h
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = h.actor_employee_id
     WHERE h.service_id = @service_id
     ORDER BY h.history_id DESC;
END
GO

-- Conflicts of every service (or one).
CREATE OR ALTER PROCEDURE grac_practice.sp_business_service_conflicts
    @organization_id BIGINT,
    @service_id      BIGINT        = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    SELECT ServiceId, ServiceName, ConflictCode, Message, CiKind, CiId, CiName, RelationshipId, COUNT(*) OVER () AS TotalRows
      FROM grac_practice.fn_business_service_conflicts(@organization_id)
     WHERE (@service_id IS NULL OR ServiceId = @service_id)
       AND (@search IS NULL OR ServiceName LIKE N'%' + @search + N'%' OR CiName LIKE N'%' + @search + N'%')
     ORDER BY ServiceName, ConflictCode, CiName
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- Service hierarchy: 1. services (not retired)  2. links child -> parent
-- (Supports Service between services; proposed / active / disputed).
CREATE OR ALTER PROCEDURE grac_practice.sp_business_service_tree
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.service_id AS ServiceId, b.service_code AS ServiceCode, b.service_name AS ServiceName, b.service_type AS ServiceType,
           b.status AS Status, cm.criticality_code AS CriticalityCode, bo.employee_name AS BusinessOwnerName,
           b.rto_hours AS RtoHours, b.rpo_hours AS RpoHours
      FROM grac_practice.business_service b
      LEFT JOIN grac_practice.criticality_master cm ON cm.criticality_id = b.criticality_id
      LEFT JOIN grac_practice.organization_employee bo ON bo.employee_id = b.business_owner_employee_id
     WHERE b.organization_id = @organization_id AND b.status <> N'RETIRED'
     ORDER BY b.service_name;
    SELECT r.relationship_id AS RelationshipId, r.source_id AS ChildServiceId, r.target_id AS ParentServiceId,
           r.status AS Status, r.is_critical AS IsCritical, r.service_role AS ServiceRole
      FROM grac_practice.asset_relationship r
     WHERE r.organization_id = @organization_id AND r.relationship_type_code = N'SUPPORTS_SERVICE'
       AND r.source_kind = N'SERVICE' AND r.target_kind = N'SERVICE' AND r.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED');
END
GO
PRINT '441: readers created.';
GO

-- =====================================================================
-- 8. Menu: Asset & Contract -> Business Services (also carried in 274)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'business-services', N'Business Services', N'Practice/Index/business-services', 362, N'sitemap', N'Asset & Contract')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-441', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-441');
PRINT CONCAT('441: menu row upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-441', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-asset-contract'
 WHERE c.menu_key = N'business-services' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 1, N'Active', @active_rs, N'seed-441', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m ON m.menu_key = N'business-services'
 WHERE r.role_name = N'Admin' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('441: Admin grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '441-a service tables' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.business_service','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.business_service_consumer','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.business_service_history','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.business_service_setting','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '441-b relationships: role column, CONTRACT kind, Supports Service active',
       CASE WHEN COL_LENGTH('grac_practice.asset_relationship', 'service_role') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_asset_rel_skind' AND definition LIKE '%CONTRACT%')
             AND EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_asset_rel_tkind' AND definition LIKE '%CONTRACT%')
             AND EXISTS (SELECT 1 FROM grac_practice.asset_relationship_type
                          WHERE type_code = N'SUPPORTS_SERVICE' AND is_active = 1 AND source_kinds LIKE N'%SERVICE%')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '441-c functions and procedures present',
       CASE WHEN OBJECT_ID('grac_practice.fn_business_service_consumers') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_business_service_conflicts') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_duration_hours') IS NOT NULL
             AND (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_business_service_history_add', 'sp_business_service_save', 'sp_business_service_retire_apply',
                                'sp_business_service_transition', 'sp_business_service_retirement_decide',
                                'sp_business_service_setting_save', 'sp_business_service_config_get', 'sp_business_services',
                                'sp_business_service_get', 'sp_business_service_conflicts', 'sp_business_service_tree')) = 11
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '441-d re-issues carry the 441 additions',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_asset_ci_catalog')) LIKE '%business_service%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_asset_ci_catalog')) LIKE '%asset_contract%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_relationship_save')) LIKE '%service_role%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_relationship_action')) LIKE '%serviceRole%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_relationship_history_add')) LIKE '%serviceRole%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_relationships')) LIKE '%ServiceRole%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_relationship_get')) LIKE '%ServiceRole%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_ci_impact')) LIKE '%fn_business_service_consumers%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '441-e duration parsing ("4 hours", "30 minutes", "2 days")',
       CASE WHEN grac_practice.fn_asset_duration_hours(N'4 hours') = 4
             AND grac_practice.fn_asset_duration_hours(N'30 minutes') = 0.5
             AND grac_practice.fn_asset_duration_hours(N'2 days') = 48
             AND grac_practice.fn_asset_duration_hours(N'daily') IS NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '441-f menu row Active under Asset & Contract',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                          WHERE c.menu_key = N'business-services' AND c.status = N'Active') THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build; re-login for the menu grant)
--   Needs: users R (requests) and A (approves) with business-services and
--   asset-relationships; application APP1 (criticality Medium); asset DB1
--   with RPO "24 hours"; a department FIN.
--   1. Business Services -> New: PAY "Payments", Customer-facing,
--      criticality High, RTO 4, RPO 1, MTPD 8, consumer FIN and external
--      "Retail customers" -> Draft. RTO 10 with MTPD 8 -> refused (54740).
--   2. Design -> Active without owner -> refused (54743); with an owner but
--      no supporting item -> refused (54744).
--   3. Supporting items -> add APP1 (role "Payment application"), DB1
--      (critical, High), then approve both in Asset Relationships. Activate.
--   4. Conflicts: APP1 rated Medium for a High service; DB1 RPO 24 h > 1 h.
--   5. New service CORE (Shared); add PAY as a supporting service of CORE
--      -> Hierarchy shows CORE above PAY. Asset Relationships -> Impact of
--      DB1 downstream lists PAY and CORE; the service list shows owners, RTO
--      / RPO / MTPD and consumers.
--   6. PAY -> Retiring (note) -> Retired without the review notes ->
--      refused (54746); with them -> waits for approval; R cannot approve
--      (54748); with the CORE mapping critical -> refused (54745) until it
--      is accepted for retirement. A approves -> Retired; its relationships
--      are retired and stay in their history.
-- =====================================================================
