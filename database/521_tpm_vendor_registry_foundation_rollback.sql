-- =====================================================================
-- 521_tpm_vendor_registry_foundation_rollback.sql
--
-- Reverses 521_tpm_vendor_registry_foundation.sql:
--   * tprm_third_party.vendor_id (FK, unique index) and the VENDOR link
--     kind are restored, EMPTY -- the legacy vendor links 521 removed are
--     not recreated.
--   * The 486 / 488 / 489 procedure bodies 521 re-issued (and the vendor
--     discovery / import procedures it dropped) are restored verbatim.
--   * TP_STATUS returns to PROSPECTIVE / UNDER_ASSESSMENT / APPROVED /
--     ACTIVE / SUSPENDED / EXITED (DRAFT -> PROSPECTIVE, INACTIVE and
--     ARCHIVED -> EXITED; archived records stay archived).
--   * tprm_vendor_match_review, the 521 functions and procedure, and the
--     521 columns (duplicate_of_third_party_id, first_activated_dt,
--     status-history evidence_reference, engagement service_recipient /
--     substitutability_code / customer_impact_code / exit_dependencies)
--     are dropped WITH their data.
--   * Menu names return to the 490 names.
-- NOT reversed: values of custom fields that referenced the legacy vendor
-- (521 cleared them; the fields stay THIRD_PARTY references), and the 487
-- lists VENDOR_MATCH_ATTRIBUTE / SUBSTITUTABILITY / CUSTOMER_IMPACT (they
-- belong to 487). Before re-running 487 after this rollback, take the 487
-- that predates 521 from version control.
-- Run BEFORE the 490 -> 486 rollbacks. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.tprm_third_party','U') IS NULL
BEGIN
    PRINT '521 rollback: TPRM is not installed -- nothing to do.';
    SET NOEXEC ON;
END
GO

-- 1. Schema the restored procedures need
IF COL_LENGTH('grac_practice.tprm_third_party', 'vendor_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.tprm_third_party ADD vendor_id BIGINT NULL
        CONSTRAINT fk_pm_tprm_tp_vendor REFERENCES grac_practice.organization_dependency_vendor(vendor_id);
    PRINT '521 rollback: tprm_third_party.vendor_id restored (empty).';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ux_pm_tprm_tp_vendor' AND object_id = OBJECT_ID('grac_practice.tprm_third_party'))
    CREATE UNIQUE INDEX ux_pm_tprm_tp_vendor ON grac_practice.tprm_third_party(vendor_id) WHERE vendor_id IS NOT NULL;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints cc
            WHERE cc.name = N'ck_pm_tprm_el_kind' AND cc.parent_object_id = OBJECT_ID('grac_practice.tprm_engagement_link')
              AND CHARINDEX(N'VENDOR', cc.[definition]) = 0)
BEGIN
    ALTER TABLE grac_practice.tprm_engagement_link DROP CONSTRAINT ck_pm_tprm_el_kind;
    ALTER TABLE grac_practice.tprm_engagement_link ADD CONSTRAINT ck_pm_tprm_el_kind
        CHECK (link_kind IN (N'VENDOR', N'PRACTICE_INSTANCE', N'DEPENDENCY', N'APPLICATION',
                             N'CONTRACT', N'ENTERPRISE_RISK', N'RISK_CANDIDATE', N'GAP'));
    PRINT '521 rollback: ck_pm_tprm_el_kind restored with VENDOR.';
END
GO

-- 2. TP_STATUS back to the 487 (pre-521) model
MERGE grac_practice.tprm_reference_list AS t
USING (VALUES (N'TP_STATUS', N'Third-party lifecycle statuses', N'Lifecycle status of a third party. Each value maps to a lifecycle meaning the workflow uses.',
               N'PROSPECTIVE,UNDER_ASSESSMENT,APPROVED,ACTIVE,SUSPENDED,EXITED'),
              (N'PROVIDER_TYPE', N'Provider types', N'Legal / organizational form of the third party.', NULL)
      ) AS s(list_code, list_name, description, allowed_meanings)
ON t.list_code = s.list_code
WHEN MATCHED THEN UPDATE SET list_name = s.list_name, description = s.description, allowed_meanings = s.allowed_meanings,
    updated_by = N'rollback-521', updated_dt = SYSUTCDATETIME();
MERGE grac_practice.tprm_reference_value AS t
USING (VALUES (N'PROSPECTIVE', N'Prospective', 10), (N'UNDER_ASSESSMENT', N'Under assessment', 20), (N'APPROVED', N'Approved', 30),
              (N'ACTIVE', N'Active', 40), (N'SUSPENDED', N'Suspended', 50), (N'EXITED', N'Exited', 60)
      ) AS s(value_code, label, display_order)
ON t.organization_id IS NULL AND t.list_code = N'TP_STATUS' AND t.value_code = s.value_code
WHEN MATCHED THEN UPDATE SET label = s.label, meaning_code = s.value_code, color_hex = NULL, display_order = s.display_order,
    status = N'Active', updated_by = N'rollback-521', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN INSERT (list_code, organization_id, value_code, label, meaning_code, is_mandatory, display_order, status, entered_by)
    VALUES (N'TP_STATUS', NULL, s.value_code, s.label, s.value_code, 0, s.display_order, N'Active', N'rollback-521');
GO

DECLARE @back TABLE (new_meaning NVARCHAR(40) PRIMARY KEY, old_meaning NVARCHAR(40) NOT NULL);
INSERT @back VALUES (N'DRAFT', N'PROSPECTIVE'), (N'ACTIVE', N'ACTIVE'), (N'SUSPENDED', N'SUSPENDED'),
                    (N'INACTIVE', N'EXITED'), (N'ARCHIVED', N'EXITED');
IF OBJECT_ID('grac_practice.fn_tprm_vendor_status_meaning') IS NOT NULL
BEGIN
    DECLARE @vm TABLE (third_party_id BIGINT PRIMARY KEY, old_meaning NVARCHAR(40));
    INSERT @vm
    SELECT t.third_party_id, b.old_meaning
    FROM grac_practice.tprm_third_party t
    JOIN @back b ON b.new_meaning = grac_practice.fn_tprm_vendor_status_meaning(t.organization_id, t.lifecycle_status_code);

    UPDATE v SET meaning_code = b.old_meaning, updated_by = N'rollback-521', updated_dt = SYSUTCDATETIME()
    FROM grac_practice.tprm_reference_value v
    JOIN @back b ON b.new_meaning = v.meaning_code
    WHERE v.list_code = N'TP_STATUS' AND v.organization_id IS NOT NULL AND v.baseline_value_id IS NULL;

    DELETE o FROM grac_practice.tprm_reference_value o
    JOIN grac_practice.tprm_reference_value b ON b.value_id = o.baseline_value_id
    WHERE b.organization_id IS NULL AND b.list_code = N'TP_STATUS' AND b.value_code IN (N'DRAFT', N'INACTIVE', N'ARCHIVED');
    DELETE FROM grac_practice.tprm_reference_value
    WHERE organization_id IS NULL AND list_code = N'TP_STATUS' AND value_code IN (N'DRAFT', N'INACTIVE', N'ARCHIVED');

    UPDATE t SET lifecycle_status_code = ISNULL(grac_practice.fn_tprm_meaning_code(t.organization_id, N'TP_STATUS', vm.old_meaning), vm.old_meaning),
                 updated_by = N'rollback-521', updated_dt = SYSUTCDATETIME()
    FROM grac_practice.tprm_third_party t
    JOIN @vm vm ON vm.third_party_id = t.third_party_id;
    PRINT CONCAT('521 rollback: vendor statuses moved back: ', @@ROWCOUNT);
END
GO

-- 3. Procedures as they were before 521
-- restored from 488
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_third_party_matches
    (@organization_id BIGINT, @legal_name NVARCHAR(250), @trading_name NVARCHAR(250),
     @registration_number NVARCHAR(100), @tax_id NVARCHAR(100), @lei_code NVARCHAR(40), @exclude_id BIGINT)
RETURNS TABLE
AS
RETURN
(
WITH n AS (
    SELECT grac_practice.fn_tprm_normalize_name(@legal_name)   AS legal_n,
           grac_practice.fn_tprm_normalize_name(@trading_name) AS trading_n
)
SELECT N'THIRD_PARTY' AS match_kind, t.third_party_id AS match_id, t.third_party_code AS match_code, t.legal_name AS match_name,
       CASE WHEN NULLIF(LTRIM(RTRIM(@registration_number)), N'') IS NOT NULL AND t.registration_number = LTRIM(RTRIM(@registration_number)) THEN N'Same registration number'
            WHEN NULLIF(LTRIM(RTRIM(@tax_id)), N'') IS NOT NULL AND t.tax_id = LTRIM(RTRIM(@tax_id)) THEN N'Same tax identifier'
            WHEN NULLIF(LTRIM(RTRIM(@lei_code)), N'') IS NOT NULL AND t.lei_code = LTRIM(RTRIM(@lei_code)) THEN N'Same LEI'
            WHEN t.normalized_name = n.legal_n OR (n.trading_n <> N'' AND t.normalized_name = n.trading_n) THEN N'Same name'
            ELSE N'Similar name' END AS match_reason
FROM   grac_practice.tprm_third_party t
CROSS  JOIN n
WHERE  t.organization_id = @organization_id
  AND  t.status = N'Active'
  AND  t.third_party_id <> ISNULL(@exclude_id, -1)
  AND  (   (NULLIF(LTRIM(RTRIM(@registration_number)), N'') IS NOT NULL AND t.registration_number = LTRIM(RTRIM(@registration_number)))
        OR (NULLIF(LTRIM(RTRIM(@tax_id)), N'') IS NOT NULL AND t.tax_id = LTRIM(RTRIM(@tax_id)))
        OR (NULLIF(LTRIM(RTRIM(@lei_code)), N'') IS NOT NULL AND t.lei_code = LTRIM(RTRIM(@lei_code)))
        OR (n.legal_n <> N'' AND t.normalized_name = n.legal_n)
        OR (n.trading_n <> N'' AND t.normalized_name = n.trading_n)
        OR (LEN(n.legal_n) >= 5 AND LEN(t.normalized_name) >= 5
            AND (t.normalized_name LIKE N'%' + n.legal_n + N'%' OR n.legal_n LIKE N'%' + t.normalized_name + N'%')))
UNION ALL
SELECT N'VENDOR', v.vendor_id, CAST(NULL AS NVARCHAR(20)), v.vendor_name, N'GRAC vendor with the same name'
FROM   grac_practice.organization_dependency_vendor v
CROSS  JOIN n
WHERE  v.organization_id = @organization_id
  AND  v.status = N'Active'
  AND  n.legal_n <> N''
  AND  grac_practice.fn_tprm_normalize_name(v.vendor_name) IN (n.legal_n, n.trading_n)
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party t WHERE t.vendor_id = v.vendor_id)
);
GO

-- restored from 488
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_third_party_sync_status
    @third_party_id BIGINT,
    @actor          NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @org BIGINT, @current NVARCHAR(60), @current_meaning NVARCHAR(40);
    SELECT @org = t.organization_id, @current = t.lifecycle_status_code
    FROM grac_practice.tprm_third_party t WHERE t.third_party_id = @third_party_id;
    IF @org IS NULL RETURN;
    SELECT TOP (1) @current_meaning = e.meaning_code FROM grac_practice.fn_tprm_reference_effective(@org) e
     WHERE e.list_code = N'TP_STATUS' AND e.value_code = @current;
    IF @current_meaning = N'SUSPENDED' RETURN;

    DECLARE @target NVARCHAR(40) =
        CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE third_party_id = @third_party_id AND stage_code = N'ACTIVE')
                  THEN N'ACTIVE'
             WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE third_party_id = @third_party_id
                            AND stage_code IN (N'APPROVED', N'ONBOARDING', N'SUSPENDED', N'EXITING'))
                  THEN N'APPROVED'
             WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE third_party_id = @third_party_id
                            AND stage_code IN (N'SCOPING', N'RISK_ASSESSED', N'DUE_DILIGENCE', N'PENDING_DECISION'))
                  THEN N'UNDER_ASSESSMENT'
             WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE third_party_id = @third_party_id AND stage_code = N'EXITED')
                  THEN N'EXITED'
        END;
    IF @target IS NULL OR @target = @current_meaning RETURN;
    -- forward only, except a full exit (EXITED) and a reactivation (back to ACTIVE)
    IF @target NOT IN (N'EXITED', N'ACTIVE')
       AND CASE @current_meaning WHEN N'PROSPECTIVE' THEN 1 WHEN N'UNDER_ASSESSMENT' THEN 2 WHEN N'APPROVED' THEN 3
                                 WHEN N'ACTIVE' THEN 4 WHEN N'EXITED' THEN 5 ELSE 0 END
         >= CASE @target WHEN N'UNDER_ASSESSMENT' THEN 2 WHEN N'APPROVED' THEN 3 ELSE 0 END
       AND @current_meaning <> N'EXITED'
        RETURN;

    DECLARE @code NVARCHAR(60) = grac_practice.fn_tprm_meaning_code(@org, N'TP_STATUS', @target);
    IF @code IS NULL OR @code = @current RETURN;
    UPDATE grac_practice.tprm_third_party SET lifecycle_status_code = @code, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE third_party_id = @third_party_id;
    INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor)
    VALUES (@third_party_id, @current, @code, N'Set from the status of its engagements.', 1, ISNULL(@actor, N'system'));
END
GO

-- restored from 488
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_lookups
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 57600, 'Select an organization.', 1;

    -- 1 reference values in force
    SELECT e.list_code AS ListCode, e.value_code AS ValueCode, e.label AS Label, e.description AS Description,
           e.meaning_code AS MeaningCode, e.rank_no AS RankNo, e.color_hex AS ColorHex, e.is_mandatory AS IsMandatory,
           e.display_order AS DisplayOrder
    FROM   grac_practice.fn_tprm_reference_effective(@organization_id) e
    ORDER  BY e.list_code, e.display_order, e.label;

    -- 2 employees
    SELECT employee_id AS EmployeeId, employee_name AS EmployeeName, employee_code AS EmployeeCode
    FROM   grac_practice.organization_employee
    WHERE  organization_id = @organization_id AND status = N'Active'
    ORDER  BY employee_name;

    -- 3 business functions  4 processes  5 applications
    SELECT business_function_id AS Id, function_name AS Name, criticality AS Criticality
    FROM   grac_practice.organization_business_function
    WHERE  organization_id = @organization_id AND status = N'Active' ORDER BY function_name;
    SELECT process_id AS Id, process_name AS Name
    FROM   grac_practice.organization_dependency_process
    WHERE  organization_id = @organization_id AND status = N'Active' ORDER BY process_name;
    SELECT application_id AS Id, application_name AS Name, vendor_id AS VendorId
    FROM   grac_practice.organization_dependency_application
    WHERE  organization_id = @organization_id AND status = N'Active' ORDER BY application_name;

    -- 6 vendors (GRAC dependency register) with the third party they are linked to
    SELECT v.vendor_id AS VendorId, v.vendor_name AS VendorName, t.third_party_id AS ThirdPartyId, t.third_party_code AS ThirdPartyCode
    FROM   grac_practice.organization_dependency_vendor v
    LEFT   JOIN grac_practice.tprm_third_party t ON t.vendor_id = v.vendor_id
    WHERE  v.organization_id = @organization_id AND v.status = N'Active'
    ORDER  BY v.vendor_name;

    -- 7 contracts (Asset & Contract, 434) when installed
    IF OBJECT_ID('grac_practice.asset_contract','U') IS NOT NULL
        EXEC sp_executesql N'SELECT c.contract_id AS ContractId, c.contract_number AS ContractNumber, c.contract_name AS ContractName,
                                    c.vendor_id AS VendorId, c.contract_status AS ContractStatus
                             FROM grac_practice.asset_contract c WHERE c.organization_id = @o ORDER BY c.contract_number;',
                           N'@o BIGINT', @o = @organization_id;
    ELSE
        SELECT CAST(NULL AS BIGINT) AS ContractId, CAST(NULL AS NVARCHAR(60)) AS ContractNumber, CAST(NULL AS NVARCHAR(250)) AS ContractName,
               CAST(NULL AS BIGINT) AS VendorId, CAST(NULL AS NVARCHAR(20)) AS ContractStatus WHERE 1 = 0;

    -- 8 library in force
    SELECT l.library_code AS LibraryCode, l.item_code AS ItemCode, l.item_name AS ItemName, l.description AS Description,
           l.category_code AS CategoryCode, l.dimension_code AS DimensionCode, l.guidance AS Guidance,
           l.effectiveness_criteria AS EffectivenessCriteria, l.is_contract_clause AS IsContractClause,
           l.evidence_requirement_code AS EvidenceRequirementCode, l.evidence_type_id AS EvidenceTypeId,
           l.validity_months AS ValidityMonths, l.default_due_days AS DefaultDueDays, l.default_owner_hint AS DefaultOwnerHint
    FROM   grac_practice.fn_tprm_library_effective(@organization_id) l
    ORDER  BY l.library_code, l.display_order, l.item_name;

    -- 9 custom fields
    SELECT f.field_id AS FieldId, f.entity_code AS EntityCode, f.field_code AS FieldCode, f.label AS Label,
           f.description AS Description, f.data_type AS DataType, f.is_mandatory AS IsMandatory,
           f.default_value AS DefaultValue, f.validation_regex AS ValidationRegex, f.min_value AS MinValue,
           f.max_value AS MaxValue, f.max_length AS MaxLength, f.options_json AS OptionsJson,
           f.reference_kind AS ReferenceKind, f.visible_when_field_code AS VisibleWhenFieldCode,
           f.visible_when_value AS VisibleWhenValue, f.access_role_names AS AccessRoleNames,
           f.is_filterable AS IsFilterable, f.display_order AS DisplayOrder
    FROM   grac_practice.tprm_custom_field f
    WHERE  f.organization_id = @organization_id AND f.status = N'Active'
    ORDER  BY f.entity_code, f.display_order, f.label;

    -- 10 risk model in force + its dimensions
    SELECT m.version_id AS VersionId, m.template_id AS TemplateId, m.template_name AS TemplateName, m.origin AS Origin,
           v.version_no AS VersionNo
    FROM   grac_practice.fn_tprm_risk_model_version(@organization_id) m
    JOIN   grac_practice.tprm_template_version v ON v.version_id = m.version_id;
    SELECT d.dimension_code AS DimensionCode, d.dimension_name AS DimensionName, d.weight AS Weight
    FROM   grac_practice.fn_tprm_risk_model_version(@organization_id) m
    JOIN   grac_practice.tprm_rm_dimension d ON d.version_id = m.version_id
    ORDER  BY d.display_order;
    SELECT b.band_code AS BandCode, b.band_name AS BandName, b.min_score AS MinScore, b.rank_no AS RankNo, b.color_hex AS ColorHex
    FROM   grac_practice.fn_tprm_risk_model_version(@organization_id) m
    JOIN   grac_practice.tprm_rm_band b ON b.version_id = m.version_id
    ORDER  BY b.min_score;

    -- 13 evidence types (Evidence Center) when installed
    IF OBJECT_ID('grac_practice.evidence_type_master','U') IS NOT NULL
        EXEC sp_executesql N'SELECT evidence_type_id AS EvidenceTypeId, evidence_type_name AS EvidenceType
                             FROM grac_practice.evidence_type_master ORDER BY evidence_type_name;';
    ELSE
        SELECT CAST(NULL AS INT) AS EvidenceTypeId, CAST(NULL AS NVARCHAR(200)) AS EvidenceType WHERE 1 = 0;

    -- 14 roles
    SELECT role_id AS RoleId, role_name AS RoleName
    FROM   grac_practice.organization_role
    WHERE  organization_id = @organization_id AND status = N'Active' ORDER BY role_name;
END
GO

-- restored from 488
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_third_party_list
    @organization_id       BIGINT,
    @search                NVARCHAR(200) = NULL,
    @status_code           NVARCHAR(60)  = NULL,
    @service_category_code NVARCHAR(60)  = NULL,
    @include_archived      BIT           = 0,
    @sample                NVARCHAR(10)  = NULL,   -- NULL all / ONLY / EXCLUDE
    @page_number           INT           = 1,
    @page_size             INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 57600, 'Select an organization.', 1;
    SET @page_number = CASE WHEN ISNULL(@page_number, 0) < 1 THEN 1 ELSE @page_number END;
    SET @page_size   = CASE WHEN ISNULL(@page_size, 0) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    DECLARE @s NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@search)), N'');

    ;WITH ref AS (SELECT list_code, value_code, label, color_hex, rank_no FROM grac_practice.fn_tprm_reference_effective(@organization_id)),
    agg AS (
        SELECT e.third_party_id,
               COUNT(*) AS engagement_count,
               SUM(CASE WHEN e.stage_code = N'ACTIVE' THEN 1 ELSE 0 END) AS active_count,
               SUM(CASE WHEN e.stage_code IN (N'SCOPING', N'RISK_ASSESSED', N'DUE_DILIGENCE', N'PENDING_DECISION') THEN 1 ELSE 0 END) AS in_assessment_count,
               MAX(e.residual_score) AS highest_residual_score,
               MAX(e.inherent_score) AS highest_inherent_score
        FROM   grac_practice.tprm_engagement e
        WHERE  e.organization_id = @organization_id
        GROUP  BY e.third_party_id
    )
    SELECT t.third_party_id AS ThirdPartyId, t.third_party_code AS ThirdPartyCode, t.legal_name AS LegalName,
           t.trading_name AS TradingName, t.provider_type_code AS ProviderTypeCode, pt.label AS ProviderType,
           t.primary_service_category_code AS ServiceCategoryCode, sc.label AS ServiceCategory,
           t.country AS Country, t.lifecycle_status_code AS StatusCode, st.label AS StatusLabel, st.color_hex AS StatusColor,
           t.relationship_owner_employee_id AS RelationshipOwnerEmployeeId, ro.employee_name AS RelationshipOwnerName,
           t.vendor_id AS VendorId, v.vendor_name AS VendorName, t.is_sample AS IsSample, t.status AS RecordStatus,
           ISNULL(a.engagement_count, 0) AS EngagementCount, ISNULL(a.active_count, 0) AS ActiveEngagementCount,
           ISNULL(a.in_assessment_count, 0) AS InAssessmentCount,
           a.highest_inherent_score AS HighestInherentScore, a.highest_residual_score AS HighestResidualScore,
           COUNT(*) OVER () AS TotalRows
    FROM   grac_practice.tprm_third_party t
    LEFT   JOIN agg a ON a.third_party_id = t.third_party_id
    LEFT   JOIN ref pt ON pt.list_code = N'PROVIDER_TYPE' AND pt.value_code = t.provider_type_code
    LEFT   JOIN ref sc ON sc.list_code = N'SERVICE_CATEGORY' AND sc.value_code = t.primary_service_category_code
    LEFT   JOIN ref st ON st.list_code = N'TP_STATUS' AND st.value_code = t.lifecycle_status_code
    LEFT   JOIN grac_practice.organization_employee ro ON ro.employee_id = t.relationship_owner_employee_id
    LEFT   JOIN grac_practice.organization_dependency_vendor v ON v.vendor_id = t.vendor_id
    WHERE  t.organization_id = @organization_id
      AND  (ISNULL(@include_archived, 0) = 1 OR t.status = N'Active')
      AND  (@status_code IS NULL OR t.lifecycle_status_code = @status_code)
      AND  (@service_category_code IS NULL
            OR t.primary_service_category_code = @service_category_code
            OR EXISTS (SELECT 1 FROM grac_practice.tprm_third_party_category c
                        WHERE c.third_party_id = t.third_party_id AND c.service_category_code = @service_category_code))
      AND  (@sample IS NULL OR (@sample = N'ONLY' AND t.is_sample = 1) OR (@sample = N'EXCLUDE' AND t.is_sample = 0))
      AND  (@s IS NULL OR t.legal_name LIKE N'%' + @s + N'%' OR t.trading_name LIKE N'%' + @s + N'%'
            OR t.third_party_code LIKE N'%' + @s + N'%' OR t.registration_number LIKE N'%' + @s + N'%'
            OR EXISTS (SELECT 1 FROM grac_practice.tprm_custom_field_value cv
                        JOIN grac_practice.tprm_custom_field cf ON cf.field_id = cv.field_id AND cf.is_searchable = 1
                        WHERE cv.entity_code = N'THIRD_PARTY' AND cv.record_id = t.third_party_id
                          AND cv.value_text LIKE N'%' + @s + N'%'))
    ORDER  BY t.legal_name, t.third_party_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- restored from 488
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_third_party_get
    @organization_id BIGINT,
    @third_party_id  BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party WHERE third_party_id = @third_party_id AND organization_id = @organization_id)
        THROW 57601, 'That third party was not found.', 1;

    ;WITH ref AS (SELECT list_code, value_code, label, color_hex FROM grac_practice.fn_tprm_reference_effective(@organization_id))
    SELECT t.third_party_id AS ThirdPartyId, t.third_party_code AS ThirdPartyCode, t.legal_name AS LegalName,
           t.trading_name AS TradingName, t.registration_number AS RegistrationNumber, t.tax_id AS TaxId, t.lei_code AS LeiCode,
           t.provider_type_code AS ProviderTypeCode, pt.label AS ProviderType,
           t.primary_service_category_code AS ServiceCategoryCode, sc.label AS ServiceCategory,
           t.reporting_category_code AS ReportingCategoryCode, rc.label AS ReportingCategory,
           t.country AS Country, t.state_region AS StateRegion, t.city AS City, t.address AS Address, t.website AS Website,
           t.parent_company AS ParentCompany, t.year_established AS YearEstablished, t.employee_count_band AS EmployeeCountBand,
           t.annual_revenue_band AS AnnualRevenueBand, t.certifications_text AS CertificationsText, t.profile_notes AS ProfileNotes,
           t.lifecycle_status_code AS StatusCode, st.label AS StatusLabel, st.color_hex AS StatusColor,
           t.relationship_owner_employee_id AS RelationshipOwnerEmployeeId, ro.employee_name AS RelationshipOwnerName,
           t.vendor_id AS VendorId, v.vendor_name AS VendorName, t.is_sample AS IsSample, t.status AS RecordStatus,
           CONVERT(BIGINT, t.record_version) AS RecordVersion, t.entered_by AS EnteredBy, t.entered_dt AS EnteredDt,
           t.updated_by AS UpdatedBy, t.updated_dt AS UpdatedDt
    FROM   grac_practice.tprm_third_party t
    LEFT   JOIN ref pt ON pt.list_code = N'PROVIDER_TYPE' AND pt.value_code = t.provider_type_code
    LEFT   JOIN ref sc ON sc.list_code = N'SERVICE_CATEGORY' AND sc.value_code = t.primary_service_category_code
    LEFT   JOIN ref rc ON rc.list_code = N'REPORTING_CATEGORY' AND rc.value_code = t.reporting_category_code
    LEFT   JOIN ref st ON st.list_code = N'TP_STATUS' AND st.value_code = t.lifecycle_status_code
    LEFT   JOIN grac_practice.organization_employee ro ON ro.employee_id = t.relationship_owner_employee_id
    LEFT   JOIN grac_practice.organization_dependency_vendor v ON v.vendor_id = t.vendor_id
    WHERE  t.third_party_id = @third_party_id;

    SELECT c.service_category_code AS ServiceCategoryCode, r.label AS Label
    FROM   grac_practice.tprm_third_party_category c
    LEFT   JOIN grac_practice.fn_tprm_reference_effective(@organization_id) r
           ON r.list_code = N'SERVICE_CATEGORY' AND r.value_code = c.service_category_code
    WHERE  c.third_party_id = @third_party_id;

    SELECT contact_id AS ContactId, contact_name AS ContactName, contact_role AS ContactRole, email AS Email,
           phone AS Phone, is_primary AS IsPrimary
    FROM   grac_practice.tprm_third_party_contact
    WHERE  third_party_id = @third_party_id AND status = N'Active'
    ORDER  BY is_primary DESC, contact_name;

    SELECT e.engagement_id AS EngagementId, e.engagement_code AS EngagementCode, e.engagement_title AS EngagementTitle,
           e.stage_code AS StageCode, e.service_criticality_code AS CriticalityCode, e.inherent_score AS InherentScore,
           e.inherent_band_code AS InherentBandCode, e.residual_score AS ResidualScore, e.residual_band_code AS ResidualBandCode,
           e.dd_tier_code AS DdTierCode, e.next_review_dt AS NextReviewDt, e.is_existing AS IsExisting,
           bo.employee_name AS BusinessOwnerName
    FROM   grac_practice.tprm_engagement e
    LEFT   JOIN grac_practice.organization_employee bo ON bo.employee_id = e.business_owner_employee_id
    WHERE  e.third_party_id = @third_party_id
    ORDER  BY e.engagement_id DESC;

    SELECT h.history_id AS HistoryId, h.from_status_code AS FromStatusCode, h.to_status_code AS ToStatusCode,
           h.reason AS Reason, h.is_automatic AS IsAutomatic, h.actor AS Actor, ae.employee_name AS ActorName, h.changed_dt AS ChangedDt
    FROM   grac_practice.tprm_third_party_status_history h
    LEFT   JOIN grac_practice.organization_employee ae ON ae.employee_id = h.actor_employee_id
    WHERE  h.third_party_id = @third_party_id
    ORDER  BY h.history_id DESC;

    SELECT cv.field_id AS FieldId, cv.field_code AS FieldCode, cv.label AS Label, cv.data_type AS DataType, cv.value_string AS Value
    FROM   grac_practice.fn_tprm_custom_values(@organization_id, N'THIRD_PARTY', @third_party_id) cv;

    DECLARE @ln NVARCHAR(250), @tn NVARCHAR(250), @rn NVARCHAR(100), @tx NVARCHAR(100), @lei NVARCHAR(40);
    SELECT @ln = legal_name, @tn = trading_name, @rn = registration_number, @tx = tax_id, @lei = lei_code
    FROM grac_practice.tprm_third_party WHERE third_party_id = @third_party_id;
    SELECT m.match_kind AS MatchKind, m.match_id AS MatchId, m.match_code AS MatchCode, m.match_name AS MatchName, m.match_reason AS MatchReason
    FROM   grac_practice.fn_tprm_third_party_matches(@organization_id, @ln, @tn, @rn, @tx, @lei, @third_party_id) m;
END
GO

-- restored from 488
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_third_party_save
    @organization_id               BIGINT,
    @third_party_id                BIGINT         = NULL,
    @legal_name                    NVARCHAR(250),
    @trading_name                  NVARCHAR(250)  = NULL,
    @registration_number           NVARCHAR(100)  = NULL,
    @tax_id                        NVARCHAR(100)  = NULL,
    @lei_code                      NVARCHAR(40)   = NULL,
    @provider_type_code            NVARCHAR(60)   = NULL,
    @primary_service_category_code NVARCHAR(60)   = NULL,
    @categories_csv                NVARCHAR(1000) = NULL,
    @reporting_category_code       NVARCHAR(60)   = NULL,
    @country                       NVARCHAR(120)  = NULL,
    @state_region                  NVARCHAR(120)  = NULL,
    @city                          NVARCHAR(120)  = NULL,
    @address                       NVARCHAR(1000) = NULL,
    @website                       NVARCHAR(300)  = NULL,
    @parent_company                NVARCHAR(250)  = NULL,
    @year_established              INT            = NULL,
    @employee_count_band           NVARCHAR(60)   = NULL,
    @annual_revenue_band           NVARCHAR(60)   = NULL,
    @certifications_text           NVARCHAR(1000) = NULL,
    @profile_notes                 NVARCHAR(MAX)  = NULL,
    @relationship_owner_employee_id BIGINT        = NULL,
    @contacts_json                 NVARCHAR(MAX)  = NULL,
    @custom_json                   NVARCHAR(MAX)  = NULL,
    @confirm_duplicates            BIT            = 0,
    @expected_record_version       BIGINT         = NULL,
    @caller_role_names             NVARCHAR(600)  = NULL,
    @caller_is_admin               BIT            = 0,
    @actor_employee_id             BIGINT         = NULL,
    @actor                         NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL THROW 57600, 'Select an organization.', 1;
    SET @legal_name = NULLIF(LTRIM(RTRIM(@legal_name)), N'');
    IF @legal_name IS NULL THROW 57602, 'Legal name is required.', 1;
    SET @primary_service_category_code = NULLIF(LTRIM(RTRIM(@primary_service_category_code)), N'');
    SET @provider_type_code = NULLIF(LTRIM(RTRIM(@provider_type_code)), N'');
    SET @reporting_category_code = NULLIF(LTRIM(RTRIM(@reporting_category_code)), N'');

    IF @provider_type_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                                                        WHERE list_code = N'PROVIDER_TYPE' AND value_code = @provider_type_code)
        THROW 57603, 'Choose a provider type from the list.', 1;
    IF @primary_service_category_code IS NULL THROW 57604, 'Choose the main service category.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(CONCAT_WS(N',', @primary_service_category_code, @categories_csv)) c
                WHERE NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id) r
                                   WHERE r.list_code = N'SERVICE_CATEGORY' AND r.value_code = c.code))
        THROW 57605, 'A service category is not in the list.', 1;
    IF @reporting_category_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                                                             WHERE list_code = N'REPORTING_CATEGORY' AND value_code = @reporting_category_code)
        THROW 57606, 'Choose a reporting category from the list.', 1;
    IF @relationship_owner_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                        WHERE employee_id = @relationship_owner_employee_id AND organization_id = @organization_id AND status = N'Active')
        THROW 57607, 'The relationship owner must be an active employee of this organization.', 1;
    IF @year_established IS NOT NULL AND (@year_established < 1800 OR @year_established > YEAR(SYSUTCDATETIME()))
        THROW 57608, 'Year established is not valid.', 1;
    IF @contacts_json IS NOT NULL AND ISJSON(@contacts_json) <> 1 THROW 57609, 'Contacts are not valid.', 1;
    IF @contacts_json IS NOT NULL AND EXISTS (SELECT 1 FROM OPENJSON(@contacts_json) WITH (name NVARCHAR(200) '$.name') WHERE NULLIF(LTRIM(RTRIM(name)), N'') IS NULL)
        THROW 57610, 'Every contact needs a name.', 1;

    IF @third_party_id IS NOT NULL
    BEGIN
        DECLARE @rv BIGINT;
        SELECT @rv = CONVERT(BIGINT, record_version) FROM grac_practice.tprm_third_party
         WHERE third_party_id = @third_party_id AND organization_id = @organization_id;
        IF @rv IS NULL THROW 57601, 'That third party was not found.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 57611, 'Someone else changed this third party. Reload and try again.', 1;
    END

    -- BRD step 1: identify possible duplicate records before registering.
    IF ISNULL(@confirm_duplicates, 0) = 0
       AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_third_party_matches(@organization_id, @legal_name, @trading_name,
                                   @registration_number, @tax_id, @lei_code, @third_party_id) m
                    WHERE m.match_kind = N'THIRD_PARTY' OR @third_party_id IS NULL)
    BEGIN
        SELECT @third_party_id AS ThirdPartyId, N'DUPLICATES' AS Result;
        SELECT m.match_kind AS MatchKind, m.match_id AS MatchId, m.match_code AS MatchCode, m.match_name AS MatchName, m.match_reason AS MatchReason
        FROM grac_practice.fn_tprm_third_party_matches(@organization_id, @legal_name, @trading_name,
                                   @registration_number, @tax_id, @lei_code, @third_party_id) m;
        RETURN;
    END

    DECLARE @id BIGINT = @third_party_id, @created BIT = 0;
    BEGIN TRAN;
    IF @id IS NULL
    BEGIN
        DECLARE @next INT, @code NVARCHAR(20);
        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(third_party_code, 4, 20))), 0) + 1
        FROM   grac_practice.tprm_third_party WITH (UPDLOCK, HOLDLOCK)
        WHERE  organization_id = @organization_id AND third_party_code LIKE N'TP-%';
        SET @code = N'TP-' + FORMAT(@next, '000');

        INSERT grac_practice.tprm_third_party
            (organization_id, third_party_code, legal_name, trading_name, normalized_name, registration_number, tax_id, lei_code,
             provider_type_code, primary_service_category_code, reporting_category_code, country, state_region, city, address,
             website, parent_company, year_established, employee_count_band, annual_revenue_band, certifications_text, profile_notes,
             lifecycle_status_code, relationship_owner_employee_id, entered_by)
        VALUES (@organization_id, @code, @legal_name, NULLIF(LTRIM(RTRIM(@trading_name)), N''), grac_practice.fn_tprm_normalize_name(@legal_name),
                NULLIF(LTRIM(RTRIM(@registration_number)), N''), NULLIF(LTRIM(RTRIM(@tax_id)), N''), NULLIF(LTRIM(RTRIM(@lei_code)), N''),
                @provider_type_code, @primary_service_category_code, @reporting_category_code, @country, @state_region, @city, @address,
                @website, @parent_company, @year_established, @employee_count_band, @annual_revenue_band, @certifications_text, @profile_notes,
                ISNULL(grac_practice.fn_tprm_meaning_code(@organization_id, N'TP_STATUS', N'PROSPECTIVE'), N'PROSPECTIVE'),
                @relationship_owner_employee_id, @actor);
        SET @id = SCOPE_IDENTITY();
        SET @created = 1;
        INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor_employee_id, actor)
        SELECT @id, NULL, lifecycle_status_code, N'Registered.', 0, @actor_employee_id, @actor
        FROM grac_practice.tprm_third_party WHERE third_party_id = @id;
    END
    ELSE
        UPDATE grac_practice.tprm_third_party
           SET legal_name = @legal_name, trading_name = NULLIF(LTRIM(RTRIM(@trading_name)), N''),
               normalized_name = grac_practice.fn_tprm_normalize_name(@legal_name),
               registration_number = NULLIF(LTRIM(RTRIM(@registration_number)), N''), tax_id = NULLIF(LTRIM(RTRIM(@tax_id)), N''),
               lei_code = NULLIF(LTRIM(RTRIM(@lei_code)), N''), provider_type_code = @provider_type_code,
               primary_service_category_code = @primary_service_category_code, reporting_category_code = @reporting_category_code,
               country = @country, state_region = @state_region, city = @city, address = @address, website = @website,
               parent_company = @parent_company, year_established = @year_established, employee_count_band = @employee_count_band,
               annual_revenue_band = @annual_revenue_band, certifications_text = @certifications_text, profile_notes = @profile_notes,
               relationship_owner_employee_id = @relationship_owner_employee_id, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE third_party_id = @id;

    DELETE FROM grac_practice.tprm_third_party_category WHERE third_party_id = @id;
    INSERT grac_practice.tprm_third_party_category (third_party_id, service_category_code)
    SELECT @id, c.code FROM grac_practice.fn_tprm_split_codes(CONCAT_WS(N',', @primary_service_category_code, @categories_csv)) c;

    IF @contacts_json IS NOT NULL
    BEGIN
        UPDATE c SET status = N'Removed', updated_by = @actor, updated_dt = SYSUTCDATETIME()
        FROM grac_practice.tprm_third_party_contact c
        WHERE c.third_party_id = @id AND c.status = N'Active'
          AND NOT EXISTS (SELECT 1 FROM OPENJSON(@contacts_json) WITH (contactId BIGINT '$.contactId') j WHERE j.contactId = c.contact_id);
        UPDATE c SET contact_name = LTRIM(RTRIM(j.name)), contact_role = j.role, email = j.email, phone = j.phone,
                     is_primary = ISNULL(j.isPrimary, 0), updated_by = @actor, updated_dt = SYSUTCDATETIME()
        FROM grac_practice.tprm_third_party_contact c
        JOIN OPENJSON(@contacts_json) WITH (contactId BIGINT '$.contactId', name NVARCHAR(200) '$.name', role NVARCHAR(150) '$.role',
                                            email NVARCHAR(250) '$.email', phone NVARCHAR(60) '$.phone', isPrimary BIT '$.isPrimary') j
             ON j.contactId = c.contact_id
        WHERE c.third_party_id = @id;
        INSERT grac_practice.tprm_third_party_contact (third_party_id, organization_id, contact_name, contact_role, email, phone, is_primary, entered_by)
        SELECT @id, @organization_id, LTRIM(RTRIM(j.name)), j.role, j.email, j.phone, ISNULL(j.isPrimary, 0), @actor
        FROM OPENJSON(@contacts_json) WITH (contactId BIGINT '$.contactId', name NVARCHAR(200) '$.name', role NVARCHAR(150) '$.role',
                                            email NVARCHAR(250) '$.email', phone NVARCHAR(60) '$.phone', isPrimary BIT '$.isPrimary') j
        WHERE j.contactId IS NULL OR NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party_contact c
                                                  WHERE c.contact_id = j.contactId AND c.third_party_id = @id);
    END

    -- custom-field access follows the caller's GRAC role (organization_employee.role_id)
    IF @caller_role_names IS NULL AND @actor_employee_id IS NOT NULL
        SELECT @caller_role_names = r.role_name FROM grac_practice.organization_employee e
        JOIN grac_practice.organization_role r ON r.role_id = e.role_id WHERE e.employee_id = @actor_employee_id;
    EXEC grac_practice.sp_tprm_custom_values_save @organization_id, N'THIRD_PARTY', @id, @custom_json,
         @caller_role_names, @caller_is_admin, @actor;
    COMMIT;

    -- EXEC arguments must be constants or variables (no expressions)
    DECLARE @audit_action NVARCHAR(80) = CASE WHEN @created = 1 THEN N'CREATE' ELSE N'UPDATE' END;
    EXEC grac_practice.sp_tprm_audit N'tprm-third-party', @id, @audit_action, @legal_name, @actor;
    SELECT @id AS ThirdPartyId, CASE WHEN @created = 1 THEN N'CREATED' ELSE N'SAVED' END AS Result;
END
GO

-- restored from 488
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_third_party_status
    @organization_id   BIGINT,
    @third_party_id    BIGINT,
    @status_code       NVARCHAR(60)  = NULL,
    @archive           BIT           = NULL,     -- 1 archive, 0 restore, NULL leave
    @reason            NVARCHAR(1000) = NULL,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @current NVARCHAR(60);
    SELECT @current = lifecycle_status_code FROM grac_practice.tprm_third_party
     WHERE third_party_id = @third_party_id AND organization_id = @organization_id;
    IF @current IS NULL THROW 57601, 'That third party was not found.', 1;
    IF NULLIF(LTRIM(RTRIM(@reason)), N'') IS NULL THROW 57612, 'Give a reason for the change.', 1;

    IF @status_code IS NOT NULL AND @status_code <> @current
    BEGIN
        DECLARE @meaning NVARCHAR(40) = (SELECT TOP (1) meaning_code FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                                          WHERE list_code = N'TP_STATUS' AND value_code = @status_code);
        IF @meaning IS NULL THROW 57613, 'Choose a status from the list.', 1;
        IF @meaning = N'EXITED' AND EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE third_party_id = @third_party_id
                                             AND stage_code NOT IN (N'EXITED', N'REJECTED', N'CANCELLED'))
            THROW 57614, 'Close, exit or cancel every engagement before marking the third party as exited.', 1;
        IF @meaning = N'ACTIVE' AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE third_party_id = @third_party_id
                                                 AND stage_code = N'ACTIVE')
            THROW 57615, 'A third party is active only when one of its engagements is active.', 1;
        UPDATE grac_practice.tprm_third_party SET lifecycle_status_code = @status_code, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE third_party_id = @third_party_id;
        INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor_employee_id, actor)
        VALUES (@third_party_id, @current, @status_code, @reason, 0, @actor_employee_id, @actor);
    END

    IF @archive IS NOT NULL
    BEGIN
        IF @archive = 1 AND EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE third_party_id = @third_party_id
                                     AND stage_code NOT IN (N'EXITED', N'REJECTED', N'CANCELLED'))
            THROW 57616, 'A third party with open engagements cannot be archived.', 1;
        UPDATE grac_practice.tprm_third_party SET status = CASE WHEN @archive = 1 THEN N'Archived' ELSE N'Active' END,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE third_party_id = @third_party_id;
    END

    EXEC grac_practice.sp_tprm_audit N'tprm-third-party', @third_party_id, N'STATUS', @reason, @actor;
    SELECT @third_party_id AS ThirdPartyId, N'SAVED' AS Result;
END
GO

-- restored from 488
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_vendor_discovery
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @only_unlinked   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 57600, 'Select an organization.', 1;
    DECLARE @s NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@search)), N'');
    DECLARE @vendor_type INT = (SELECT TOP (1) dependency_type_id FROM grac_practice.dependency_type_master
                                 WHERE dependency_type_code = N'Vendor');

    SELECT v.vendor_id AS VendorId, v.vendor_name AS VendorName, sc.service_category_name AS ServiceCategory,
           cm.criticality_name AS Criticality, v.contract_start_dt AS ContractStartDt, v.contract_end_dt AS ContractEndDt,
           ro.employee_name AS RelationshipOwnerName,
           (SELECT COUNT(DISTINCT r.practice_instance_id) FROM grac_practice.practice_dependency_resolution r
             WHERE r.organization_id = @organization_id AND r.dependency_type_id = @vendor_type
               AND r.resolved_dependency_id = v.vendor_id AND r.is_active = 1) AS PracticeInstanceCount,
           (SELECT COUNT(*) FROM grac_practice.organization_dependency_application a
             WHERE a.vendor_id = v.vendor_id AND a.status = N'Active') AS ApplicationCount,
           (SELECT COUNT(*) FROM grac_practice.risk_register rr
             WHERE rr.organization_id = @organization_id AND rr.linked_vendor_id = v.vendor_id
               AND rr.status_code NOT IN (N'Closed', N'Retired')) AS OpenRiskCount,
           t.third_party_id AS ThirdPartyId, t.third_party_code AS ThirdPartyCode, t.legal_name AS ThirdPartyName,
           sug.third_party_id AS SuggestedThirdPartyId, sug.third_party_code AS SuggestedThirdPartyCode, sug.legal_name AS SuggestedThirdPartyName
    FROM   grac_practice.organization_dependency_vendor v
    LEFT   JOIN grac_practice.dependency_service_category_master sc ON sc.service_category_id = v.service_category_id
    LEFT   JOIN grac_practice.criticality_master cm ON cm.criticality_id = v.criticality_id
    LEFT   JOIN grac_practice.organization_employee ro ON ro.employee_id = v.relationship_owner_id
    LEFT   JOIN grac_practice.tprm_third_party t ON t.vendor_id = v.vendor_id
    OUTER  APPLY (SELECT TOP (1) x.third_party_id, x.third_party_code, x.legal_name
                  FROM grac_practice.tprm_third_party x
                  WHERE t.third_party_id IS NULL AND x.organization_id = @organization_id AND x.vendor_id IS NULL
                    AND x.status = N'Active' AND x.normalized_name = grac_practice.fn_tprm_normalize_name(v.vendor_name)) sug
    WHERE  v.organization_id = @organization_id
      AND  v.status = N'Active'
      AND  (ISNULL(@only_unlinked, 0) = 0 OR t.third_party_id IS NULL)
      AND  (@s IS NULL OR v.vendor_name LIKE N'%' + @s + N'%')
    ORDER  BY CASE WHEN t.third_party_id IS NULL THEN 0 ELSE 1 END, v.vendor_name;
END
GO

-- restored from 488
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_vendor_import
    @organization_id    BIGINT,
    @vendor_id          BIGINT,
    @third_party_id     BIGINT        = NULL,     -- link to this third party instead of creating one
    @create_engagement  BIT           = 1,
    @confirm_duplicates BIT           = 0,
    @actor_employee_id  BIGINT        = NULL,
    @actor              NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @vname NVARCHAR(220), @owner BIGINT, @cstart DATE, @cend DATE, @renew DATE, @crit NVARCHAR(40), @cat NVARCHAR(160);
    SELECT @vname = v.vendor_name, @owner = v.relationship_owner_id, @cstart = v.contract_start_dt, @cend = v.contract_end_dt,
           @renew = v.renewal_dt, @crit = UPPER(cm.criticality_code), @cat = sc.service_category_name
    FROM   grac_practice.organization_dependency_vendor v
    LEFT   JOIN grac_practice.criticality_master cm ON cm.criticality_id = v.criticality_id
    LEFT   JOIN grac_practice.dependency_service_category_master sc ON sc.service_category_id = v.service_category_id
    WHERE  v.vendor_id = @vendor_id AND v.organization_id = @organization_id AND v.status = N'Active';
    IF @vname IS NULL THROW 57620, 'That vendor was not found in this organization.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_third_party WHERE vendor_id = @vendor_id)
        THROW 57621, 'That vendor is already linked to a third party.', 1;
    IF @owner IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                          WHERE employee_id = @owner AND organization_id = @organization_id AND status = N'Active')
        SET @owner = NULL;

    -- Category: a SERVICE_CATEGORY value whose label matches the vendor's
    -- category, else OTHER.
    DECLARE @cat_code NVARCHAR(60) = (SELECT TOP (1) value_code FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                                       WHERE list_code = N'SERVICE_CATEGORY' AND label = @cat);
    IF @cat_code IS NULL SET @cat_code = (SELECT TOP (1) value_code FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                                          WHERE list_code = N'SERVICE_CATEGORY' ORDER BY CASE WHEN value_code = N'OTHER' THEN 0 ELSE 1 END, display_order DESC);
    DECLARE @crit_code NVARCHAR(60) = (SELECT TOP (1) value_code FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                                        WHERE list_code = N'CRITICALITY' AND value_code = @crit);

    IF @third_party_id IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party WHERE third_party_id = @third_party_id
                         AND organization_id = @organization_id AND status = N'Active')
            THROW 57601, 'That third party was not found.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_third_party WHERE third_party_id = @third_party_id AND vendor_id IS NOT NULL)
            THROW 57622, 'That third party is already linked to another vendor.', 1;
    END
    ELSE IF ISNULL(@confirm_duplicates, 0) = 0
       AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_third_party_matches(@organization_id, @vname, NULL, NULL, NULL, NULL, NULL) m
                    WHERE m.match_kind = N'THIRD_PARTY')
    BEGIN
        SELECT CAST(NULL AS BIGINT) AS ThirdPartyId, CAST(NULL AS BIGINT) AS EngagementId, N'DUPLICATES' AS Result;
        SELECT m.match_kind AS MatchKind, m.match_id AS MatchId, m.match_code AS MatchCode, m.match_name AS MatchName, m.match_reason AS MatchReason
        FROM grac_practice.fn_tprm_third_party_matches(@organization_id, @vname, NULL, NULL, NULL, NULL, NULL) m
        WHERE m.match_kind = N'THIRD_PARTY';
        RETURN;
    END

    DECLARE @tp BIGINT = @third_party_id, @eng BIGINT;
    BEGIN TRAN;
    IF @tp IS NULL
    BEGIN
        DECLARE @next INT, @code NVARCHAR(20);
        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(third_party_code, 4, 20))), 0) + 1
        FROM   grac_practice.tprm_third_party WITH (UPDLOCK, HOLDLOCK)
        WHERE  organization_id = @organization_id AND third_party_code LIKE N'TP-%';
        SET @code = N'TP-' + FORMAT(@next, '000');
        INSERT grac_practice.tprm_third_party
            (organization_id, third_party_code, legal_name, normalized_name, primary_service_category_code, lifecycle_status_code,
             relationship_owner_employee_id, vendor_id, profile_notes, entered_by)
        VALUES (@organization_id, @code, @vname, grac_practice.fn_tprm_normalize_name(@vname), @cat_code,
                ISNULL(grac_practice.fn_tprm_meaning_code(@organization_id, N'TP_STATUS', N'PROSPECTIVE'), N'PROSPECTIVE'),
                @owner, @vendor_id, N'Created from the GRAC vendor register.', @actor);
        SET @tp = SCOPE_IDENTITY();
        INSERT grac_practice.tprm_third_party_category (third_party_id, service_category_code) VALUES (@tp, @cat_code);
        INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor_employee_id, actor)
        SELECT @tp, NULL, lifecycle_status_code, N'Created from the GRAC vendor register.', 0, @actor_employee_id, @actor
        FROM grac_practice.tprm_third_party WHERE third_party_id = @tp;
    END
    ELSE
        UPDATE grac_practice.tprm_third_party SET vendor_id = @vendor_id, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE third_party_id = @tp;

    IF ISNULL(@create_engagement, 0) = 1
    BEGIN
        DECLARE @enext INT, @ecode NVARCHAR(20);
        SELECT @enext = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(engagement_code, 5, 20))), 0) + 1
        FROM   grac_practice.tprm_engagement WITH (UPDLOCK, HOLDLOCK)
        WHERE  organization_id = @organization_id AND engagement_code LIKE N'ENG-%';
        SET @ecode = N'ENG-' + FORMAT(@enext, '000');
        INSERT grac_practice.tprm_engagement
            (organization_id, third_party_id, engagement_code, engagement_title, service_description, service_category_code,
             engagement_type_code, is_existing, proposed_start_dt, proposed_end_dt, actual_start_dt, renewal_dt,
             relationship_owner_employee_id, service_criticality_code, stage_code, entered_by)
        VALUES (@organization_id, @tp, @ecode, LEFT(CONCAT(N'Existing relationship - ', @vname), 250),
                N'Existing service relationship brought in from the GRAC vendor register. Complete the scope before assessing.',
                @cat_code, (SELECT TOP (1) value_code FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                             WHERE list_code = N'ENGAGEMENT_TYPE' AND value_code = N'ONGOING'),
                1, @cstart, @cend, @cstart, @renew, @owner, @crit_code, N'SCOPING', @actor);
        SET @eng = SCOPE_IDENTITY();
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source,
                                                   is_validated, validated_by, validated_dt, entered_by)
        VALUES (@eng, @organization_id, N'VENDOR', @vendor_id, @vname, N'DISCOVERED', 1, @actor, SYSUTCDATETIME(), @actor);
        EXEC grac_practice.sp_tprm_engagement_event @eng, N'CREATED', NULL, N'SCOPING', N'Existing relationship imported from the vendor register.', @actor_employee_id, @actor;
    END
    COMMIT;

    EXEC grac_practice.sp_tprm_third_party_sync_status @tp, @actor;
    EXEC grac_practice.sp_tprm_audit N'tprm-third-party', @tp, N'VENDOR_IMPORT', @vname, @actor;
    SELECT @tp AS ThirdPartyId, @eng AS EngagementId, N'IMPORTED' AS Result;
END
GO

-- restored from 488
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_sample_load
    @organization_id   BIGINT,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 57600, 'Select an organization.', 1;

    DECLARE @loaded INT = 0, @code NVARCHAR(60), @tp BIGINT, @eng BIGINT, @next INT, @tcode NVARCHAR(20), @ecode NVARCHAR(20);
    DECLARE @prospective NVARCHAR(60) = ISNULL(grac_practice.fn_tprm_meaning_code(@organization_id, N'TP_STATUS', N'PROSPECTIVE'), N'PROSPECTIVE');
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT p.sample_code FROM grac_practice.tprm_sample_profile p
        WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party t
                           WHERE t.organization_id = @organization_id AND t.is_sample = 1 AND t.legal_name = p.legal_name)
        ORDER BY p.display_order;
    OPEN c;
    FETCH NEXT FROM c INTO @code;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRAN;
        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(third_party_code, 4, 20))), 0) + 1
        FROM grac_practice.tprm_third_party WITH (UPDLOCK, HOLDLOCK)
        WHERE organization_id = @organization_id AND third_party_code LIKE N'TP-%';
        SET @tcode = N'TP-' + FORMAT(@next, '000');
        INSERT grac_practice.tprm_third_party
            (organization_id, third_party_code, legal_name, normalized_name, provider_type_code, primary_service_category_code,
             country, lifecycle_status_code, profile_notes, is_sample, entered_by)
        SELECT @organization_id, @tcode, p.legal_name, grac_practice.fn_tprm_normalize_name(p.legal_name), p.provider_type_code,
               p.service_category_code, p.country, @prospective,
               CONCAT(N'Illustrative sample record - not a real provider and not a completed assessment. ', p.notes),
               1, @actor
        FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code;
        SET @tp = SCOPE_IDENTITY();
        INSERT grac_practice.tprm_third_party_category (third_party_id, service_category_code)
        SELECT @tp, p.service_category_code FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code;
        INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor_employee_id, actor)
        VALUES (@tp, NULL, @prospective, N'Sample record loaded.', 0, @actor_employee_id, @actor);

        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(engagement_code, 5, 20))), 0) + 1
        FROM grac_practice.tprm_engagement WITH (UPDLOCK, HOLDLOCK)
        WHERE organization_id = @organization_id AND engagement_code LIKE N'ENG-%';
        SET @ecode = N'ENG-' + FORMAT(@next, '000');
        INSERT grac_practice.tprm_engagement
            (organization_id, third_party_id, engagement_code, engagement_title, service_description, scope_description, business_purpose,
             service_category_code, engagement_type_code, service_model_code, delivery_locations, is_existing, service_criticality_code,
             data_exposure_code, rto_hours, rpo_hours, notes, is_sample, stage_code, entered_by)
        SELECT @organization_id, @tp, @ecode, p.engagement_title, p.service_description, p.scope_description, p.business_purpose,
               p.service_category_code, p.engagement_type_code, p.service_model_code, p.country, 0, p.criticality_code,
               p.data_exposure_code, p.rto_hours, p.rpo_hours,
               CONCAT(N'Sample guidance -- key safeguards: ', p.key_safeguards, N'. Evidence expected: ', p.evidence_expectations,
                      N'. Review triggers: ', p.review_triggers, N'.'),
               1, N'SCOPING', @actor
        FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code;
        SET @eng = SCOPE_IDENTITY();

        INSERT grac_practice.tprm_engagement_scope (engagement_id, organization_id, item_kind, exposure_mode, item_code, item_name, entered_by)
        SELECT @eng, @organization_id, N'DATA_CATEGORY', N'PROPOSED', p.data_exposure_code,
               ISNULL((SELECT TOP (1) label FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                        WHERE list_code = N'DATA_EXPOSURE' AND value_code = p.data_exposure_code), p.data_exposure_code), @actor
        FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code AND p.data_exposure_code IS NOT NULL;
        INSERT grac_practice.tprm_engagement_scope (engagement_id, organization_id, item_kind, exposure_mode, item_code, item_name, entered_by)
        SELECT @eng, @organization_id, N'ACCESS', N'PROPOSED', a.code,
               ISNULL((SELECT TOP (1) label FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                        WHERE list_code = N'ACCESS_CATEGORY' AND value_code = a.code), a.code), @actor
        FROM grac_practice.tprm_sample_profile p
        CROSS APPLY grac_practice.fn_tprm_split_codes(p.access_codes) a
        WHERE p.sample_code = @code;
        -- fourth parties: name|category|country;...
        INSERT grac_practice.tprm_engagement_scope (engagement_id, organization_id, item_kind, exposure_mode, item_code, item_name, country, entered_by)
        SELECT @eng, @organization_id, N'FOURTH_PARTY', N'PROPOSED',
               NULLIF(PARSENAME(REPLACE(REPLACE(f.value, N'.', N' '), N'|', N'.'), 2), N''),
               LEFT(PARSENAME(REPLACE(REPLACE(f.value, N'.', N' '), N'|', N'.'), 3), 300),
               NULLIF(PARSENAME(REPLACE(REPLACE(f.value, N'.', N' '), N'|', N'.'), 1), N''), @actor
        FROM grac_practice.tprm_sample_profile p
        CROSS APPLY STRING_SPLIT(ISNULL(p.fourth_parties, N''), N';') f
        WHERE p.sample_code = @code AND LTRIM(RTRIM(f.value)) <> N''
          AND PARSENAME(REPLACE(REPLACE(f.value, N'.', N' '), N'|', N'.'), 3) IS NOT NULL;

        EXEC grac_practice.sp_tprm_engagement_event @eng, N'CREATED', NULL, N'SCOPING', N'Sample engagement loaded.', @actor_employee_id, @actor;
        COMMIT;
        EXEC grac_practice.sp_tprm_third_party_sync_status @tp, @actor;
        SET @loaded = @loaded + 1;
        FETCH NEXT FROM c INTO @code;
    END
    CLOSE c;
    DEALLOCATE c;

    EXEC grac_practice.sp_tprm_audit N'tprm-sample', @organization_id, N'LOAD', NULL, @actor;
    SELECT @loaded AS LoadedCount, N'LOADED' AS Result;
END
GO

-- restored from 488
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_get
    @organization_id BIGINT,
    @engagement_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id)
        THROW 57630, 'That engagement was not found.', 1;

    ;WITH ref AS (SELECT list_code, value_code, label, color_hex FROM grac_practice.fn_tprm_reference_effective(@organization_id))
    SELECT e.engagement_id AS EngagementId, e.engagement_code AS EngagementCode, e.engagement_title AS EngagementTitle,
           e.third_party_id AS ThirdPartyId, t.third_party_code AS ThirdPartyCode, t.legal_name AS ThirdPartyName,
           t.vendor_id AS ThirdPartyVendorId, t.lifecycle_status_code AS ThirdPartyStatusCode, ts.label AS ThirdPartyStatus,
           e.service_description AS ServiceDescription, e.scope_description AS ScopeDescription, e.business_purpose AS BusinessPurpose,
           e.service_category_code AS ServiceCategoryCode, sc.label AS ServiceCategory,
           e.engagement_type_code AS EngagementTypeCode, et.label AS EngagementType,
           e.service_model_code AS ServiceModelCode, sm.label AS ServiceModel,
           e.delivery_locations AS DeliveryLocations, e.is_existing AS IsExisting,
           e.contract_id AS ContractId, e.contract_reference AS ContractReference, e.contract_value AS ContractValue,
           e.currency_code AS CurrencyCode, e.proposed_start_dt AS ProposedStartDt, e.proposed_end_dt AS ProposedEndDt,
           e.actual_start_dt AS ActualStartDt, e.actual_end_dt AS ActualEndDt, e.renewal_dt AS RenewalDt,
           e.business_owner_employee_id AS BusinessOwnerEmployeeId, bo.employee_name AS BusinessOwnerName,
           e.relationship_owner_employee_id AS RelationshipOwnerEmployeeId, ro.employee_name AS RelationshipOwnerName,
           e.assessor_employee_id AS AssessorEmployeeId, ae.employee_name AS AssessorName,
           e.service_criticality_code AS CriticalityCode, cr.label AS Criticality, cr.color_hex AS CriticalityColor,
           e.data_exposure_code AS DataExposureCode, de.label AS DataExposure,
           e.rto_hours AS RtoHours, e.rpo_hours AS RpoHours, e.sla_summary AS SlaSummary,
           e.stage_code AS StageCode, e.stage_dt AS StageDt,
           e.current_risk_assessment_id AS CurrentRiskAssessmentId, e.risk_model_version_id AS RiskModelVersionId,
           e.inherent_score AS InherentScore, e.inherent_band_code AS InherentBandCode, ib.band_name AS InherentBand, ib.color_hex AS InherentBandColor,
           e.dd_tier_code AS DdTierCode, dt.label AS DdTier,
           e.residual_score AS ResidualScore, e.residual_band_code AS ResidualBandCode, rb.band_name AS ResidualBand, rb.color_hex AS ResidualBandColor,
           e.acceptance_until AS AcceptanceUntil, e.next_review_dt AS NextReviewDt, e.last_review_dt AS LastReviewDt,
           e.reassessment_required AS ReassessmentRequired, e.reassessment_reason AS ReassessmentReason,
           e.notes AS Notes, e.is_sample AS IsSample, CONVERT(BIGINT, e.record_version) AS RecordVersion,
           (SELECT TOP (1) a.assessment_id FROM grac_practice.tprm_risk_assessment a
             WHERE a.engagement_id = e.engagement_id AND a.status = N'DRAFT') AS DraftRiskAssessmentId,
           e.entered_by AS EnteredBy, e.entered_dt AS EnteredDt, e.updated_by AS UpdatedBy, e.updated_dt AS UpdatedDt
    FROM   grac_practice.tprm_engagement e
    JOIN   grac_practice.tprm_third_party t ON t.third_party_id = e.third_party_id
    LEFT   JOIN ref ts ON ts.list_code = N'TP_STATUS' AND ts.value_code = t.lifecycle_status_code
    LEFT   JOIN ref sc ON sc.list_code = N'SERVICE_CATEGORY' AND sc.value_code = e.service_category_code
    LEFT   JOIN ref et ON et.list_code = N'ENGAGEMENT_TYPE' AND et.value_code = e.engagement_type_code
    LEFT   JOIN ref sm ON sm.list_code = N'SERVICE_MODEL' AND sm.value_code = e.service_model_code
    LEFT   JOIN ref cr ON cr.list_code = N'CRITICALITY' AND cr.value_code = e.service_criticality_code
    LEFT   JOIN ref de ON de.list_code = N'DATA_EXPOSURE' AND de.value_code = e.data_exposure_code
    LEFT   JOIN ref dt ON dt.list_code = N'DD_TIER' AND dt.value_code = e.dd_tier_code
    LEFT   JOIN grac_practice.tprm_rm_band ib ON ib.version_id = e.risk_model_version_id AND ib.band_code = e.inherent_band_code
    LEFT   JOIN grac_practice.tprm_rm_band rb ON rb.version_id = e.risk_model_version_id AND rb.band_code = e.residual_band_code
    LEFT   JOIN grac_practice.organization_employee bo ON bo.employee_id = e.business_owner_employee_id
    LEFT   JOIN grac_practice.organization_employee ro ON ro.employee_id = e.relationship_owner_employee_id
    LEFT   JOIN grac_practice.organization_employee ae ON ae.employee_id = e.assessor_employee_id
    WHERE  e.engagement_id = @engagement_id;

    SELECT s.scope_item_id AS ScopeItemId, s.item_kind AS ItemKind, s.exposure_mode AS ExposureMode, s.ref_id AS RefId,
           s.item_code AS ItemCode, s.item_name AS ItemName, s.criticality_code AS CriticalityCode, s.country AS Country,
           s.is_critical AS IsCritical, s.notes AS Notes, s.entered_by AS EnteredBy, s.entered_dt AS EnteredDt
    FROM   grac_practice.tprm_engagement_scope s
    WHERE  s.engagement_id = @engagement_id AND s.status = N'Active'
    ORDER  BY s.exposure_mode, s.item_kind, s.item_name;

    SELECT l.link_id AS LinkId, l.link_kind AS LinkKind, l.target_id AS TargetId, l.target_label AS TargetLabel,
           l.link_source AS LinkSource, l.is_validated AS IsValidated, l.validated_by AS ValidatedBy, l.validated_dt AS ValidatedDt,
           l.note AS Note, l.status AS Status, l.entered_by AS EnteredBy, l.entered_dt AS EnteredDt
    FROM   grac_practice.tprm_engagement_link l
    WHERE  l.engagement_id = @engagement_id AND l.status = N'Active'
    ORDER  BY l.link_kind, l.target_label;

    SELECT s.snapshot_id AS SnapshotId, s.snapshot_kind AS SnapshotKind, s.summary_json AS SummaryJson,
           s.taken_by AS TakenBy, s.taken_dt AS TakenDt
    FROM   grac_practice.tprm_exposure_snapshot s
    WHERE  s.engagement_id = @engagement_id
    ORDER  BY s.snapshot_id DESC;

    SELECT h.history_id AS HistoryId, h.event_code AS EventCode, h.from_stage_code AS FromStageCode, h.to_stage_code AS ToStageCode,
           h.detail AS Detail, h.actor AS Actor, ae.employee_name AS ActorName, h.event_dt AS EventDt
    FROM   grac_practice.tprm_engagement_history h
    LEFT   JOIN grac_practice.organization_employee ae ON ae.employee_id = h.actor_employee_id
    WHERE  h.engagement_id = @engagement_id
    ORDER  BY h.history_id DESC;

    SELECT cv.field_id AS FieldId, cv.field_code AS FieldCode, cv.label AS Label, cv.data_type AS DataType, cv.value_string AS Value
    FROM   grac_practice.fn_tprm_custom_values(@organization_id, N'ENGAGEMENT', @engagement_id) cv;

    SELECT d.dimension_code AS DimensionCode, md.dimension_name AS DimensionName, d.weight AS Weight,
           d.inherent_score AS InherentScore, d.reduction_pct AS ReductionPct, d.uplift_pct AS UpliftPct,
           d.residual_score AS ResidualScore, d.safeguard_summary AS SafeguardSummary
    FROM   grac_practice.tprm_engagement e
    JOIN   grac_practice.tprm_risk_assessment_dimension d ON d.assessment_id = e.current_risk_assessment_id
    JOIN   grac_practice.tprm_rm_dimension md ON md.dimension_id = d.dimension_id
    WHERE  e.engagement_id = @engagement_id
    ORDER  BY md.display_order;
END
GO

-- restored from 488
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_save
    @organization_id               BIGINT,
    @engagement_id                 BIGINT         = NULL,
    @third_party_id                BIGINT         = NULL,
    @engagement_title              NVARCHAR(250),
    @service_description           NVARCHAR(2000) = NULL,
    @scope_description             NVARCHAR(2000) = NULL,
    @business_purpose              NVARCHAR(1000) = NULL,
    @service_category_code         NVARCHAR(60)   = NULL,
    @engagement_type_code          NVARCHAR(60)   = NULL,
    @service_model_code            NVARCHAR(60)   = NULL,
    @delivery_locations            NVARCHAR(1000) = NULL,
    @is_existing                   BIT            = 0,
    @contract_id                   BIGINT         = NULL,
    @contract_reference            NVARCHAR(200)  = NULL,
    @contract_value                DECIMAL(19,2)  = NULL,
    @currency_code                 NVARCHAR(10)   = NULL,
    @proposed_start_dt             DATE           = NULL,
    @proposed_end_dt               DATE           = NULL,
    @actual_start_dt               DATE           = NULL,
    @actual_end_dt                 DATE           = NULL,
    @renewal_dt                    DATE           = NULL,
    @business_owner_employee_id    BIGINT         = NULL,
    @relationship_owner_employee_id BIGINT        = NULL,
    @assessor_employee_id          BIGINT         = NULL,
    @service_criticality_code      NVARCHAR(60)   = NULL,
    @data_exposure_code            NVARCHAR(60)   = NULL,
    @rto_hours                     INT            = NULL,
    @rpo_hours                     INT            = NULL,
    @sla_summary                   NVARCHAR(2000) = NULL,
    @notes                         NVARCHAR(MAX)  = NULL,
    @custom_json                   NVARCHAR(MAX)  = NULL,
    @expected_record_version       BIGINT         = NULL,
    @caller_role_names             NVARCHAR(600)  = NULL,
    @caller_is_admin               BIT            = 0,
    @actor_employee_id             BIGINT         = NULL,
    @actor                         NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL THROW 57600, 'Select an organization.', 1;
    SET @engagement_title = NULLIF(LTRIM(RTRIM(@engagement_title)), N'');
    IF @engagement_title IS NULL THROW 57631, 'Engagement title is required.', 1;
    IF @service_criticality_code IS NULL THROW 57632, 'Choose the service criticality.', 1;

    DECLARE @bad NVARCHAR(200);
    SELECT TOP (1) @bad = x.what FROM (VALUES
        (N'SERVICE_CATEGORY', @service_category_code, N'service category'),
        (N'ENGAGEMENT_TYPE',  @engagement_type_code,  N'engagement type'),
        (N'SERVICE_MODEL',    @service_model_code,    N'service model'),
        (N'CRITICALITY',      @service_criticality_code, N'criticality'),
        (N'DATA_EXPOSURE',    @data_exposure_code,    N'data exposure')) x(list_code, code, what)
    WHERE x.code IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id) r
                       WHERE r.list_code = x.list_code AND r.value_code = x.code);
    IF @bad IS NOT NULL
    BEGIN
        DECLARE @bad_msg NVARCHAR(300) = CONCAT(N'Choose a ', @bad, N' from the list.');
        THROW 57633, @bad_msg, 1;
    END
    IF EXISTS (SELECT 1 FROM (VALUES (@business_owner_employee_id), (@relationship_owner_employee_id), (@assessor_employee_id)) x(id)
                WHERE x.id IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                   WHERE employee_id = x.id AND organization_id = @organization_id AND status = N'Active'))
        THROW 57634, 'Owners and assessor must be active employees of this organization.', 1;
    IF @proposed_end_dt IS NOT NULL AND @proposed_start_dt IS NOT NULL AND @proposed_end_dt < @proposed_start_dt
        THROW 57635, 'The proposed end date is before the start date.', 1;
    IF @actual_end_dt IS NOT NULL AND @actual_start_dt IS NOT NULL AND @actual_end_dt < @actual_start_dt
        THROW 57636, 'The actual end date is before the start date.', 1;
    IF (@rto_hours IS NOT NULL AND @rto_hours < 0) OR (@rpo_hours IS NOT NULL AND @rpo_hours < 0)
        THROW 57637, 'RTO and RPO cannot be negative.', 1;
    IF @contract_id IS NOT NULL
    BEGIN
        IF OBJECT_ID('grac_practice.asset_contract','U') IS NULL THROW 57638, 'Contracts are not available in this installation.', 1;
        DECLARE @contract_ok INT;
        EXEC sp_executesql N'SELECT @n = COUNT(*) FROM grac_practice.asset_contract WHERE contract_id = @c AND organization_id = @o;',
             N'@n INT OUTPUT, @c BIGINT, @o BIGINT', @n = @contract_ok OUTPUT, @c = @contract_id, @o = @organization_id;
        IF ISNULL(@contract_ok, 0) = 0 THROW 57638, 'That contract was not found in this organization.', 1;
    END

    DECLARE @id BIGINT = @engagement_id, @created BIT = 0, @stage NVARCHAR(30), @tp BIGINT;
    DECLARE @o_crit NVARCHAR(60), @o_data NVARCHAR(60), @o_model NVARCHAR(60), @o_loc NVARCHAR(1000);
    IF @id IS NOT NULL
    BEGIN
        DECLARE @rv BIGINT;
        SELECT @rv = CONVERT(BIGINT, record_version), @stage = stage_code, @tp = third_party_id,
               @o_crit = service_criticality_code, @o_data = data_exposure_code, @o_model = service_model_code, @o_loc = delivery_locations
        FROM grac_practice.tprm_engagement WHERE engagement_id = @id AND organization_id = @organization_id;
        IF @rv IS NULL THROW 57630, 'That engagement was not found.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 57639, 'Someone else changed this engagement. Reload and try again.', 1;
        IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED')
            THROW 57640, 'A closed engagement cannot be changed.', 1;
    END
    ELSE
    BEGIN
        SET @tp = @third_party_id;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party WHERE third_party_id = @tp
                         AND organization_id = @organization_id AND status = N'Active')
            THROW 57641, 'Choose a registered third party for the engagement.', 1;
    END

    BEGIN TRAN;
    IF @id IS NULL
    BEGIN
        DECLARE @next INT, @code NVARCHAR(20);
        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(engagement_code, 5, 20))), 0) + 1
        FROM   grac_practice.tprm_engagement WITH (UPDLOCK, HOLDLOCK)
        WHERE  organization_id = @organization_id AND engagement_code LIKE N'ENG-%';
        SET @code = N'ENG-' + FORMAT(@next, '000');
        INSERT grac_practice.tprm_engagement
            (organization_id, third_party_id, engagement_code, engagement_title, service_description, scope_description, business_purpose,
             service_category_code, engagement_type_code, service_model_code, delivery_locations, is_existing, contract_id,
             contract_reference, contract_value, currency_code, proposed_start_dt, proposed_end_dt, actual_start_dt, actual_end_dt,
             renewal_dt, business_owner_employee_id, relationship_owner_employee_id, assessor_employee_id, service_criticality_code,
             data_exposure_code, rto_hours, rpo_hours, sla_summary, notes, stage_code, entered_by)
        VALUES (@organization_id, @tp, @code, @engagement_title, @service_description, @scope_description, @business_purpose,
                @service_category_code, @engagement_type_code, @service_model_code, @delivery_locations, ISNULL(@is_existing, 0), @contract_id,
                @contract_reference, @contract_value, @currency_code, @proposed_start_dt, @proposed_end_dt, @actual_start_dt, @actual_end_dt,
                @renewal_dt, @business_owner_employee_id, @relationship_owner_employee_id, @assessor_employee_id, @service_criticality_code,
                @data_exposure_code, @rto_hours, @rpo_hours, @sla_summary, @notes, N'SCOPING', @actor);
        SET @id = SCOPE_IDENTITY();
        SET @created = 1;
        -- the third party's vendor (when there is one) is this engagement's vendor until told otherwise
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @id, @organization_id, N'VENDOR', t.vendor_id, v.vendor_name, N'DISCOVERED', @actor
        FROM grac_practice.tprm_third_party t
        JOIN grac_practice.organization_dependency_vendor v ON v.vendor_id = t.vendor_id
        WHERE t.third_party_id = @tp;
    END
    ELSE
        UPDATE grac_practice.tprm_engagement
           SET engagement_title = @engagement_title, service_description = @service_description, scope_description = @scope_description,
               business_purpose = @business_purpose, service_category_code = @service_category_code,
               engagement_type_code = @engagement_type_code, service_model_code = @service_model_code,
               delivery_locations = @delivery_locations, is_existing = ISNULL(@is_existing, 0), contract_id = @contract_id,
               contract_reference = @contract_reference, contract_value = @contract_value, currency_code = @currency_code,
               proposed_start_dt = @proposed_start_dt, proposed_end_dt = @proposed_end_dt, actual_start_dt = @actual_start_dt,
               actual_end_dt = @actual_end_dt, renewal_dt = @renewal_dt, business_owner_employee_id = @business_owner_employee_id,
               relationship_owner_employee_id = @relationship_owner_employee_id, assessor_employee_id = @assessor_employee_id,
               service_criticality_code = @service_criticality_code, data_exposure_code = @data_exposure_code,
               rto_hours = @rto_hours, rpo_hours = @rpo_hours, sla_summary = @sla_summary, notes = @notes,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @id;

    -- custom-field access follows the caller's GRAC role (organization_employee.role_id)
    IF @caller_role_names IS NULL AND @actor_employee_id IS NOT NULL
        SELECT @caller_role_names = r.role_name FROM grac_practice.organization_employee e
        JOIN grac_practice.organization_role r ON r.role_id = e.role_id WHERE e.employee_id = @actor_employee_id;
    EXEC grac_practice.sp_tprm_custom_values_save @organization_id, N'ENGAGEMENT', @id, @custom_json,
         @caller_role_names, @caller_is_admin, @actor;

    DECLARE @material NVARCHAR(1000) = NULL;
    IF @created = 0 AND @stage IN (N'ACTIVE', N'SUSPENDED', N'ONBOARDING', N'APPROVED')
    BEGIN
        SET @material = CONCAT_WS(N'; ',
            CASE WHEN ISNULL(@o_crit, N'') <> ISNULL(@service_criticality_code, N'') THEN CONCAT(N'criticality ', @o_crit, N' -> ', @service_criticality_code) END,
            CASE WHEN ISNULL(@o_data, N'') <> ISNULL(@data_exposure_code, N'') THEN CONCAT(N'data exposure ', @o_data, N' -> ', @data_exposure_code) END,
            CASE WHEN ISNULL(@o_model, N'') <> ISNULL(@service_model_code, N'') THEN CONCAT(N'service model ', @o_model, N' -> ', @service_model_code) END,
            CASE WHEN ISNULL(@o_loc, N'') <> ISNULL(@delivery_locations, N'') THEN N'delivery locations changed' END);
        IF @material = N'' SET @material = NULL;
        IF @material IS NOT NULL
            UPDATE grac_practice.tprm_engagement
               SET reassessment_required = 1,
                   reassessment_reason = LEFT(CONCAT(N'Material change: ', @material), 1000)
             WHERE engagement_id = @id;
    END
    COMMIT;

    IF @created = 1
    BEGIN
        EXEC grac_practice.sp_tprm_engagement_event @id, N'CREATED', NULL, N'SCOPING', @engagement_title, @actor_employee_id, @actor;
        EXEC grac_practice.sp_tprm_third_party_sync_status @tp, @actor;
    END
    ELSE IF @material IS NOT NULL
    BEGIN
        DECLARE @mdetail NVARCHAR(2000) = CONCAT(N'Material change: ', @material);
        EXEC grac_practice.sp_tprm_engagement_event @id, N'MATERIAL_CHANGE', @stage, @stage, @mdetail, @actor_employee_id, @actor;
    END
    ELSE
        EXEC grac_practice.sp_tprm_engagement_event @id, N'UPDATED', @stage, @stage, NULL, @actor_employee_id, @actor;

    SELECT @id AS EngagementId, CASE WHEN @created = 1 THEN N'CREATED' WHEN @material IS NOT NULL THEN N'MATERIAL_CHANGE' ELSE N'SAVED' END AS Result;
END
GO

-- restored from 488
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_discover
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @persist           BIT           = 0,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tp BIGINT, @stage NVARCHAR(30);
    SELECT @tp = third_party_id, @stage = stage_code FROM grac_practice.tprm_engagement
     WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF @tp IS NULL THROW 57630, 'That engagement was not found.', 1;

    DECLARE @vendor_type INT = (SELECT TOP (1) dependency_type_id FROM grac_practice.dependency_type_master WHERE dependency_type_code = N'Vendor');
    DECLARE @app_type    INT = (SELECT TOP (1) dependency_type_id FROM grac_practice.dependency_type_master WHERE dependency_type_code = N'Application');

    -- temp table (not a table variable): the optional contract read below
    -- is dynamic SQL and must see it.
    CREATE TABLE #v (vendor_id BIGINT PRIMARY KEY);
    INSERT #v SELECT vendor_id FROM grac_practice.tprm_third_party WHERE third_party_id = @tp AND vendor_id IS NOT NULL;
    INSERT #v SELECT DISTINCT l.target_id FROM grac_practice.tprm_engagement_link l
     WHERE l.engagement_id = @engagement_id AND l.link_kind = N'VENDOR' AND l.status = N'Active'
       AND NOT EXISTS (SELECT 1 FROM #v x WHERE x.vendor_id = l.target_id);

    DECLARE @apps TABLE (application_id BIGINT PRIMARY KEY, application_name NVARCHAR(220));
    INSERT @apps SELECT a.application_id, a.application_name FROM grac_practice.organization_dependency_application a
     JOIN #v v ON v.vendor_id = a.vendor_id
     WHERE a.organization_id = @organization_id AND a.status = N'Active';

    -- instances: directly on the vendor, or through an application of the vendor
    DECLARE @pi TABLE (practice_instance_id BIGINT PRIMARY KEY, via NVARCHAR(20), resolution_id BIGINT);
    INSERT @pi (practice_instance_id, via, resolution_id)
    SELECT r.practice_instance_id, N'VENDOR', MIN(r.resolution_id)
    FROM   grac_practice.practice_dependency_resolution r
    JOIN   #v v ON v.vendor_id = r.resolved_dependency_id
    WHERE  r.organization_id = @organization_id AND r.dependency_type_id = @vendor_type AND r.is_active = 1
    GROUP  BY r.practice_instance_id;
    INSERT @pi (practice_instance_id, via, resolution_id)
    SELECT r.practice_instance_id, N'APPLICATION', MIN(r.resolution_id)
    FROM   grac_practice.practice_dependency_resolution r
    JOIN   @apps a ON a.application_id = r.resolved_dependency_id
    WHERE  r.organization_id = @organization_id AND r.dependency_type_id = @app_type AND r.is_active = 1
      AND  NOT EXISTS (SELECT 1 FROM @pi x WHERE x.practice_instance_id = r.practice_instance_id)
    GROUP  BY r.practice_instance_id;

    DECLARE @counts TABLE (k NVARCHAR(40), n INT);

    -- 2 practice instances
    SELECT pi.practice_instance_id AS PracticeInstanceId, pi.instance_code AS InstanceCode, pi.instance_name AS InstanceName,
           p.practice_id AS PracticeId, p.practice_code AS PracticeCode, p.practice_name AS PracticeName,
           pi.criticality AS Criticality, pi.implementation_status AS ImplementationStatus, pi.status AS Status,
           x.via AS Via, x.resolution_id AS ResolutionId,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                                    AND l.link_kind = N'PRACTICE_INSTANCE' AND l.target_id = pi.practice_instance_id AND l.status = N'Active')
                     THEN 1 ELSE 0 END AS BIT) AS IsLinked
    INTO   #instances
    FROM   @pi x
    JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = x.practice_instance_id
    JOIN   grac_practice.practice p ON p.practice_id = pi.practice_id;
    INSERT @counts SELECT N'PracticeInstances', COUNT(*) FROM #instances;
    INSERT @counts SELECT N'Practices', COUNT(DISTINCT PracticeId) FROM #instances;

    -- 3 obligations (instance obligations + practice-level obligations)
    SELECT N'INSTANCE' AS Level, pio.practice_instance_obligation_id AS ObligationRowId, pio.practice_instance_id AS PracticeInstanceId,
           i.InstanceCode, pio.obligation_name AS ObligationName, pio.obligation_type_code AS ObligationTypeCode,
           pio.execution_frequency AS ExecutionFrequency, pio.responsibility AS Responsibility
    INTO   #obligations
    FROM   grac_practice.practice_instance_obligation pio
    JOIN   #instances i ON i.PracticeInstanceId = pio.practice_instance_id
    WHERE  pio.status = N'Active'
    UNION ALL
    SELECT N'PRACTICE', po.practice_obligation_id, NULL, NULL, po.obligation_name, po.obligation_type_code,
           po.execution_frequency, po.responsibility
    FROM   grac_practice.practice_obligation po
    WHERE  po.organization_id = @organization_id AND po.status = N'Active'
      AND  po.practice_id IN (SELECT DISTINCT PracticeId FROM #instances);
    INSERT @counts SELECT N'Obligations', COUNT(*) FROM #obligations;

    -- 4 dependencies: the vendor resolutions themselves, and the vendor's applications
    SELECT N'VENDOR_RESOLUTION' AS DependencyKind, r.resolution_id AS DependencyId, r.resolved_dependency_name AS DependencyName,
           r.practice_instance_id AS PracticeInstanceId, pi.instance_code AS InstanceCode, r.resolution_status AS ResolutionStatus
    INTO   #deps
    FROM   grac_practice.practice_dependency_resolution r
    JOIN   #v v ON v.vendor_id = r.resolved_dependency_id
    JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = r.practice_instance_id
    WHERE  r.organization_id = @organization_id AND r.dependency_type_id = @vendor_type AND r.is_active = 1
    UNION ALL
    SELECT N'APPLICATION', a.application_id, a.application_name, NULL, NULL, NULL
    FROM   @apps a;
    INSERT @counts SELECT N'Dependencies', COUNT(*) FROM #deps;

    -- 5 assurance findings on the vendor or the instances
    SELECT o.org_assurance_observation_id AS ObservationId, o.observation_code AS ObservationCode, o.observation_title AS ObservationTitle,
           o.observation_type AS ObservationType, o.severity_code AS SeverityCode, o.severity_name AS SeverityName,
           sm.status_name AS StatusName, sm.is_terminal AS IsClosed, o.observed_dt AS ObservedDt,
           ee.dimension_code AS DimensionCode, ee.entity_name AS EntityName, o.execution_code AS ExecutionCode
    INTO   #findings
    FROM   grac_practice.org_assurance_observation o
    JOIN   grac_practice.org_assurance_execution_entity ee ON ee.org_assurance_execution_entity_id = o.org_assurance_execution_entity_id
    LEFT   JOIN grac_practice.org_assurance_observation_status_master sm ON sm.org_assurance_observation_status_id = o.observation_status_id
    WHERE  o.organization_id = @organization_id
      AND  ((ee.dimension_code = N'VENDOR' AND ee.entity_id IN (SELECT vendor_id FROM #v))
         OR (ee.dimension_code = N'PRACTICE_INSTANCE' AND ee.entity_id IN (SELECT PracticeInstanceId FROM #instances)));
    INSERT @counts SELECT N'AssuranceFindings', COUNT(*) FROM #findings;
    INSERT @counts SELECT N'OpenAssuranceFindings', COUNT(*) FROM #findings WHERE ISNULL(IsClosed, 0) = 0;

    -- 6 gaps of the instances
    SELECT g.practice_gap_id AS PracticeGapId, g.practice_instance_id AS PracticeInstanceId, i.InstanceCode, i.InstanceName,
           g.gap_status AS GapStatus, g.opened_dt AS OpenedDt, g.closed_dt AS ClosedDt
    INTO   #gaps
    FROM   grac_practice.practice_gap g
    JOIN   #instances i ON i.PracticeInstanceId = g.practice_instance_id;
    INSERT @counts SELECT N'OpenGaps', COUNT(*) FROM #gaps WHERE GapStatus = N'Open';

    -- 7 enterprise risks on the vendor
    SELECT rr.risk_register_id AS RiskRegisterId, rr.risk_number AS RiskNumber, rr.risk_title AS RiskTitle,
           rr.status_code AS StatusCode, rr.inherent_rating_name AS InherentRating,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                                    AND l.link_kind = N'ENTERPRISE_RISK' AND l.target_id = rr.risk_register_id AND l.status = N'Active')
                     THEN 1 ELSE 0 END AS BIT) AS IsLinked
    INTO   #risks
    FROM   grac_practice.risk_register rr
    WHERE  rr.organization_id = @organization_id AND rr.linked_vendor_id IN (SELECT vendor_id FROM #v);
    INSERT @counts SELECT N'Risks', COUNT(*) FROM #risks;

    -- 8 contracts of the vendor
    CREATE TABLE #contracts (ContractId BIGINT, ContractNumber NVARCHAR(60), ContractName NVARCHAR(250), ContractStatus NVARCHAR(20));
    IF OBJECT_ID('grac_practice.asset_contract','U') IS NOT NULL
        INSERT #contracts
        EXEC sp_executesql N'SELECT c.contract_id, c.contract_number, c.contract_name, c.contract_status
                             FROM grac_practice.asset_contract c
                             WHERE c.organization_id = @o AND c.vendor_id IN (SELECT vendor_id FROM #v);',
             N'@o BIGINT', @o = @organization_id;
    INSERT @counts SELECT N'Contracts', COUNT(*) FROM #contracts;
    INSERT @counts SELECT N'Vendors', COUNT(*) FROM #v;

    IF ISNULL(@persist, 0) = 1
    BEGIN
        IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;
        BEGIN TRAN;
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @engagement_id, @organization_id, N'PRACTICE_INSTANCE', i.PracticeInstanceId,
               LEFT(CONCAT(i.InstanceCode, N' - ', i.InstanceName, N' (', i.PracticeName, N')'), 400), N'DISCOVERED', @actor
        FROM #instances i
        WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                            AND l.link_kind = N'PRACTICE_INSTANCE' AND l.target_id = i.PracticeInstanceId AND l.status = N'Active');
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @engagement_id, @organization_id, N'DEPENDENCY', d.DependencyId,
               LEFT(CONCAT(d.InstanceCode, N' depends on ', d.DependencyName), 400), N'DISCOVERED', @actor
        FROM #deps d
        WHERE d.DependencyKind = N'VENDOR_RESOLUTION'
          AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                            AND l.link_kind = N'DEPENDENCY' AND l.target_id = d.DependencyId AND l.status = N'Active');
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @engagement_id, @organization_id, N'APPLICATION', d.DependencyId, LEFT(d.DependencyName, 400), N'DISCOVERED', @actor
        FROM #deps d
        WHERE d.DependencyKind = N'APPLICATION'
          AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                            AND l.link_kind = N'APPLICATION' AND l.target_id = d.DependencyId AND l.status = N'Active');
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @engagement_id, @organization_id, N'CONTRACT', c.ContractId, LEFT(CONCAT(c.ContractNumber, N' - ', c.ContractName), 400), N'DISCOVERED', @actor
        FROM #contracts c
        WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                            AND l.link_kind = N'CONTRACT' AND l.target_id = c.ContractId AND l.status = N'Active');
        INSERT grac_practice.tprm_engagement_link (engagement_id, organization_id, link_kind, target_id, target_label, link_source, entered_by)
        SELECT @engagement_id, @organization_id, N'ENTERPRISE_RISK', r.RiskRegisterId, LEFT(CONCAT(r.RiskNumber, N' - ', r.RiskTitle), 400), N'DISCOVERED', @actor
        FROM #risks r
        WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = @engagement_id
                            AND l.link_kind = N'ENTERPRISE_RISK' AND l.target_id = r.RiskRegisterId AND l.status = N'Active');

        INSERT grac_practice.tprm_exposure_snapshot (engagement_id, organization_id, snapshot_kind, summary_json, items_json, taken_by)
        VALUES (@engagement_id, @organization_id, N'DISCOVERED',
                (SELECT k AS [key], n AS [count] FROM @counts FOR JSON PATH),
                (SELECT (SELECT PracticeInstanceId AS id, InstanceCode AS code, InstanceName AS name, PracticeName AS practice FROM #instances FOR JSON PATH) AS instances,
                        (SELECT DependencyKind AS kind, DependencyId AS id, DependencyName AS name FROM #deps FOR JSON PATH) AS dependencies,
                        (SELECT ContractId AS id, ContractNumber AS code FROM #contracts FOR JSON PATH) AS contracts,
                        (SELECT RiskRegisterId AS id, RiskNumber AS code FROM #risks FOR JSON PATH) AS risks
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                @actor);
        COMMIT;
        DECLARE @ddetail NVARCHAR(2000) = (SELECT STRING_AGG(CONCAT(k, N' ', n), N', ') FROM @counts);
        EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'DISCOVERY_RECORDED', @stage, @stage, @ddetail, @actor_employee_id, @actor;
    END

    SELECT k AS CountKey, n AS CountValue FROM @counts;
    SELECT * FROM #instances ORDER BY InstanceCode;
    SELECT * FROM #obligations ORDER BY Level, ObligationName;
    SELECT * FROM #deps ORDER BY DependencyKind, DependencyName;
    SELECT * FROM #findings ORDER BY ISNULL(IsClosed, 0), ObservedDt DESC;
    SELECT * FROM #gaps ORDER BY GapStatus DESC, OpenedDt DESC;
    SELECT * FROM #risks ORDER BY RiskNumber;
    SELECT * FROM #contracts ORDER BY ContractNumber;
END
GO

-- restored from 488
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_link_save
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @link_kind         NVARCHAR(30),
    @target_id         BIGINT,
    @note              NVARCHAR(1000) = NULL,
    @link_source       NVARCHAR(20)   = N'MANUAL',
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30) = (SELECT stage_code FROM grac_practice.tprm_engagement
                                    WHERE engagement_id = @engagement_id AND organization_id = @organization_id);
    IF @stage IS NULL THROW 57630, 'That engagement was not found.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;
    IF ISNULL(@link_source, N'') NOT IN (N'MANUAL', N'ONBOARDING') SET @link_source = N'MANUAL';

    -- The target must be a record of the same organization.
    DECLARE @label NVARCHAR(400);
    IF @link_kind = N'VENDOR'
        SELECT @label = vendor_name FROM grac_practice.organization_dependency_vendor
         WHERE vendor_id = @target_id AND organization_id = @organization_id AND status = N'Active';
    ELSE IF @link_kind = N'PRACTICE_INSTANCE'
        SELECT @label = LEFT(CONCAT(pi.instance_code, N' - ', pi.instance_name, N' (', p.practice_name, N')'), 400)
        FROM grac_practice.practice_instance pi JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
        WHERE pi.practice_instance_id = @target_id AND pi.organization_id = @organization_id;
    ELSE IF @link_kind = N'DEPENDENCY'
        SELECT @label = LEFT(CONCAT(pi.instance_code, N' depends on ', r.resolved_dependency_name), 400)
        FROM grac_practice.practice_dependency_resolution r
        JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = r.practice_instance_id
        WHERE r.resolution_id = @target_id AND r.organization_id = @organization_id AND r.is_active = 1;
    ELSE IF @link_kind = N'APPLICATION'
        SELECT @label = application_name FROM grac_practice.organization_dependency_application
         WHERE application_id = @target_id AND organization_id = @organization_id;
    ELSE IF @link_kind = N'ENTERPRISE_RISK'
        SELECT @label = LEFT(CONCAT(risk_number, N' - ', risk_title), 400) FROM grac_practice.risk_register
         WHERE risk_register_id = @target_id AND organization_id = @organization_id;
    ELSE IF @link_kind = N'GAP'
        SELECT @label = LEFT(title, 400) FROM grac_practice.custom_gap
         WHERE custom_gap_id = @target_id AND organization_id = @organization_id;
    ELSE IF @link_kind = N'CONTRACT' AND OBJECT_ID('grac_practice.asset_contract','U') IS NOT NULL
        EXEC sp_executesql N'SELECT @l = LEFT(CONCAT(contract_number, N'' - '', contract_name), 400)
                             FROM grac_practice.asset_contract WHERE contract_id = @t AND organization_id = @o;',
             N'@l NVARCHAR(400) OUTPUT, @t BIGINT, @o BIGINT', @l = @label OUTPUT, @t = @target_id, @o = @organization_id;
    ELSE
        THROW 57650, 'That kind of record cannot be linked here.', 1;
    IF @label IS NULL THROW 57651, 'That record was not found in this organization.', 1;

    DECLARE @link_id BIGINT = (SELECT link_id FROM grac_practice.tprm_engagement_link
                                WHERE engagement_id = @engagement_id AND link_kind = @link_kind AND target_id = @target_id AND status = N'Active');
    IF @link_id IS NOT NULL
        UPDATE grac_practice.tprm_engagement_link
           SET is_validated = 1, validated_by = @actor, validated_dt = SYSUTCDATETIME(), note = COALESCE(@note, note),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE link_id = @link_id;
    ELSE
    BEGIN
        INSERT grac_practice.tprm_engagement_link
            (engagement_id, organization_id, link_kind, target_id, target_label, link_source, is_validated, validated_by, validated_dt, note, entered_by)
        VALUES (@engagement_id, @organization_id, @link_kind, @target_id, @label, @link_source, 1, @actor, SYSUTCDATETIME(), @note, @actor);
        SET @link_id = SCOPE_IDENTITY();
    END
    DECLARE @ldetail NVARCHAR(2000) = CONCAT(@link_kind, N': ', @label);
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'LINKED', @stage, @stage, @ldetail, @actor_employee_id, @actor;
    SELECT @link_id AS LinkId, N'LINKED' AS Result;
END
GO

-- restored from 489
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_monitoring_sweep
    @organization_id BIGINT        = NULL,
    @actor           NVARCHAR(100) = N'tprm-scheduler'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME()), @raised INT = 0;
    DECLARE @q TABLE (organization_id BIGINT, engagement_id BIGINT, review_type NVARCHAR(30), trigger_code NVARCHAR(60),
                      detail NVARCHAR(2000), due_dt DATE, source_key NVARCHAR(200));

    ;WITH live AS (
        SELECT e.engagement_id, e.organization_id, e.next_review_dt, COALESCE(e.actual_end_dt, e.proposed_end_dt) AS end_dt,
               e.acceptance_until, e.reassessment_required, e.reassessment_reason, e.actual_start_dt, e.third_party_id,
               rr.review_lead_days, rr.contract_expiry_alert_days, rr.cert_expiry_alert_days
        FROM grac_practice.tprm_engagement e
        CROSS APPLY grac_practice.fn_tprm_engagement_ranks(e.engagement_id) k
        OUTER APPLY grac_practice.fn_tprm_match_review_rule(e.organization_id, k.band_rank, k.criticality_rank) rr
        WHERE e.stage_code IN (N'ACTIVE', N'SUSPENDED')
          AND (@organization_id IS NULL OR e.organization_id = @organization_id)
    )
    INSERT @q
    SELECT organization_id, engagement_id, N'PERIODIC', N'SCHEDULED', N'Periodic engagement risk review.', next_review_dt,
           CONCAT(N'PERIODIC:', engagement_id, N':', CONVERT(NVARCHAR(10), next_review_dt, 23))
    FROM live WHERE next_review_dt IS NOT NULL AND next_review_dt <= DATEADD(DAY, ISNULL(review_lead_days, 30), @today)
    UNION ALL
    SELECT organization_id, engagement_id, N'CONTRACT_EXPIRY', N'CONTRACT_EXPIRY',
           CONCAT(N'The engagement ends on ', CONVERT(NVARCHAR(10), end_dt, 23), N': renew, re-tender or plan the exit.'),
           CASE WHEN end_dt < @today THEN @today ELSE end_dt END,
           CONCAT(N'CONTRACT:', engagement_id, N':', CONVERT(NVARCHAR(10), end_dt, 23))
    FROM live WHERE end_dt IS NOT NULL AND contract_expiry_alert_days IS NOT NULL AND end_dt <= DATEADD(DAY, contract_expiry_alert_days, @today)
    UNION ALL
    SELECT organization_id, engagement_id, N'ACCEPTANCE_EXPIRY', N'ACCEPTANCE_EXPIRY',
           CONCAT(N'Risk acceptance ends on ', CONVERT(NVARCHAR(10), acceptance_until, 23), N'.'),
           CASE WHEN acceptance_until < @today THEN @today ELSE acceptance_until END,
           CONCAT(N'ACCEPTANCE:', engagement_id, N':', CONVERT(NVARCHAR(10), acceptance_until, 23))
    FROM live WHERE acceptance_until IS NOT NULL AND acceptance_until <= DATEADD(DAY, 30, @today)
    UNION ALL
    SELECT organization_id, engagement_id, N'TRIGGERED', N'MATERIAL_CHANGE', ISNULL(reassessment_reason, N'Reassessment required.'),
           DATEADD(DAY, 30, @today), CONCAT(N'REASSESS:', engagement_id, N':', FORMAT(@today, 'yyyyMM'))
    FROM live WHERE reassessment_required = 1
      AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_review r WHERE r.engagement_id = live.engagement_id AND r.status = N'OPEN'
                        AND r.review_type = N'TRIGGERED')
    UNION ALL
    SELECT l.organization_id, l.engagement_id, N'TRIGGERED', N'OVERDUE_REMEDIATION',
           CONCAT(COUNT(*), N' remediation action(s) are overdue.'), DATEADD(DAY, 14, @today),
           CONCAT(N'OVERDUE:', l.engagement_id, N':', FORMAT(@today, 'yyyyMM'))
    FROM live l
    JOIN grac_practice.tprm_finding f ON f.engagement_id = l.engagement_id AND f.status IN (N'OPEN', N'IN_PROGRESS') AND f.due_dt < @today
    GROUP BY l.organization_id, l.engagement_id;

    INSERT @q
    SELECT l.organization_id, l.engagement_id, N'CERTIFICATION_EXPIRY', N'CERTIFICATION_EXPIRY',
           CONCAT(N'Evidence "', v.title, N'" expires on ', CONVERT(NVARCHAR(10), v.valid_to, 23), N'.'),
           CASE WHEN v.valid_to < @today THEN @today ELSE v.valid_to END,
           CONCAT(N'EVIDENCE:', v.tprm_evidence_id, N':', CONVERT(NVARCHAR(10), v.valid_to, 23))
    FROM grac_practice.tprm_evidence_link v
    JOIN grac_practice.tprm_engagement l ON l.engagement_id = v.engagement_id AND l.stage_code IN (N'ACTIVE', N'SUSPENDED')
    CROSS APPLY grac_practice.fn_tprm_engagement_ranks(l.engagement_id) k
    OUTER APPLY grac_practice.fn_tprm_match_review_rule(l.organization_id, k.band_rank, k.criticality_rank) rr
    WHERE v.status = N'Active' AND v.review_status = N'ACCEPTED' AND v.valid_to IS NOT NULL
      AND v.valid_to <= DATEADD(DAY, ISNULL(rr.cert_expiry_alert_days, 30), @today)
      AND (@organization_id IS NULL OR v.organization_id = @organization_id)
      -- only the latest evidence for the same requirement and target counts
      AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_evidence_link n WHERE n.engagement_id = v.engagement_id AND n.status = N'Active'
                        AND n.review_status = N'ACCEPTED' AND n.target_kind = v.target_kind AND n.target_id = v.target_id
                        AND ISNULL(n.evidence_requirement_code, N'') = ISNULL(v.evidence_requirement_code, N'')
                        AND n.valid_to > v.valid_to);

    -- new open assurance findings on the vendor or on linked practice instances, since activation
    INSERT @q
    SELECT e.organization_id, e.engagement_id, N'TRIGGERED', N'ASSURANCE_FAILURE',
           LEFT(CONCAT(N'Assurance finding ', o.observation_code, N': ', o.observation_title, N' (', o.severity_name, N').'), 2000),
           DATEADD(DAY, 30, @today), CONCAT(N'ASSURANCE:', e.engagement_id, N':', o.org_assurance_observation_id)
    FROM grac_practice.tprm_engagement e
    JOIN grac_practice.tprm_third_party t ON t.third_party_id = e.third_party_id
    JOIN grac_practice.org_assurance_observation o ON o.organization_id = e.organization_id
    JOIN grac_practice.org_assurance_execution_entity ee ON ee.org_assurance_execution_entity_id = o.org_assurance_execution_entity_id
    LEFT JOIN grac_practice.org_assurance_observation_status_master sm ON sm.org_assurance_observation_status_id = o.observation_status_id
    WHERE e.stage_code IN (N'ACTIVE', N'SUSPENDED')
      AND (@organization_id IS NULL OR e.organization_id = @organization_id)
      AND ISNULL(sm.is_terminal, 0) = 0
      AND o.observed_dt >= ISNULL(CAST(e.actual_start_dt AS DATETIME2), e.stage_dt)
      AND (   (ee.dimension_code = N'VENDOR' AND (ee.entity_id = t.vendor_id
                  OR EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l WHERE l.engagement_id = e.engagement_id
                               AND l.link_kind = N'VENDOR' AND l.target_id = ee.entity_id AND l.status = N'Active')))
           OR (ee.dimension_code = N'PRACTICE_INSTANCE' AND EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_link l
                               WHERE l.engagement_id = e.engagement_id AND l.link_kind = N'PRACTICE_INSTANCE'
                                 AND l.target_id = ee.entity_id AND l.status = N'Active')));

    DECLARE @o BIGINT, @e BIGINT, @t NVARCHAR(30), @tc NVARCHAR(60), @d NVARCHAR(2000), @due DATE, @k NVARCHAR(200), @rid BIGINT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT organization_id, engagement_id, review_type, trigger_code, detail, due_dt, source_key FROM @q;
    OPEN c;
    FETCH NEXT FROM c INTO @o, @e, @t, @tc, @d, @due, @k;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @rid = NULL;
            BEGIN TRAN;   -- holds the review-number lock until the review exists
            EXEC grac_practice.sp_tprm_review_create @o, @e, @t, @tc, @d, @due, NULL, @k, @actor, @rid OUTPUT;
            COMMIT;
            IF @rid IS NOT NULL SET @raised = @raised + 1;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            -- one engagement must not stop the pass; the next run retries it
            PRINT CONCAT('sp_tprm_monitoring_sweep: engagement ', @e, ' skipped - ', ERROR_MESSAGE());
        END CATCH
        FETCH NEXT FROM c INTO @o, @e, @t, @tc, @d, @due, @k;
    END
    CLOSE c;
    DEALLOCATE c;

    SELECT @raised AS ReviewsRaised, (SELECT COUNT(*) FROM @q) AS Candidates, SYSUTCDATETIME() AS RunDt;
END
GO

-- restored from 486
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_custom_field_save
    @organization_id         BIGINT,
    @field_id                BIGINT         = NULL,
    @entity_code             NVARCHAR(30),
    @field_code              NVARCHAR(60),
    @label                   NVARCHAR(200),
    @description             NVARCHAR(1000) = NULL,
    @data_type               NVARCHAR(20),
    @is_mandatory            BIT            = 0,
    @default_value           NVARCHAR(500)  = NULL,
    @validation_regex        NVARCHAR(300)  = NULL,
    @min_value               DECIMAL(19,4)  = NULL,
    @max_value               DECIMAL(19,4)  = NULL,
    @max_length              INT            = NULL,
    @options_json            NVARCHAR(MAX)  = NULL,
    @reference_kind          NVARCHAR(60)   = NULL,
    @visible_when_field_code NVARCHAR(60)   = NULL,
    @visible_when_value      NVARCHAR(200)  = NULL,
    @access_role_names       NVARCHAR(600)  = NULL,
    @is_searchable           BIT            = 0,
    @is_filterable           BIT            = 0,
    @is_reportable           BIT            = 1,
    @display_order           INT            = 100,
    @status                  NVARCHAR(20)   = N'Active',
    @actor                   NVARCHAR(100)  = N'system',
    @out_field_id            BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL THROW 57508, 'Select an organization.', 1;
    EXEC grac_practice.sp_tprm_config_scope_check @organization_id, 0;

    SET @field_code = UPPER(NULLIF(LTRIM(RTRIM(@field_code)), N''));
    SET @label = NULLIF(LTRIM(RTRIM(@label)), N'');
    SET @options_json = NULLIF(LTRIM(RTRIM(@options_json)), N'');
    SET @reference_kind = NULLIF(LTRIM(RTRIM(@reference_kind)), N'');
    IF @field_code IS NULL OR @label IS NULL THROW 57540, 'Code and label are both required.', 1;
    IF @field_code LIKE N'%[^A-Z0-9_]%' THROW 57504, 'Codes may contain only letters, digits and underscores.', 1;
    IF @entity_code NOT IN (N'THIRD_PARTY', N'ENGAGEMENT', N'FINDING', N'REVIEW') THROW 57541, 'Unknown record type.', 1;
    IF @data_type NOT IN (N'TEXT', N'NUMBER', N'DATE', N'BOOLEAN', N'SINGLE_SELECT', N'MULTI_SELECT', N'REFERENCE')
        THROW 57542, 'Unknown data type.', 1;
    IF @data_type IN (N'SINGLE_SELECT', N'MULTI_SELECT')
       AND (@options_json IS NULL OR ISJSON(@options_json) <> 1
            OR (SELECT COUNT(*) FROM OPENJSON(@options_json) WITH (code NVARCHAR(60) '$.code', label NVARCHAR(200) '$.label')
                 WHERE NULLIF(code, N'') IS NOT NULL AND NULLIF(label, N'') IS NOT NULL) < 1)
        THROW 57543, 'A select field needs at least one option with a code and a label.', 1;
    IF @data_type = N'REFERENCE'
       AND (@reference_kind IS NULL
            OR (@reference_kind NOT IN (N'EMPLOYEE', N'THIRD_PARTY', N'VENDOR', N'BUSINESS_FUNCTION')
                AND (@reference_kind NOT LIKE N'LIST:%'
                     OR NOT EXISTS (SELECT 1 FROM grac_practice.tprm_reference_list
                                     WHERE list_code = SUBSTRING(@reference_kind, 6, 60)))))
        THROW 57544, 'Choose what a reference field points to.', 1;
    IF @min_value IS NOT NULL AND @max_value IS NOT NULL AND @max_value < @min_value
        THROW 57545, 'The maximum is below the minimum.', 1;
    IF @visible_when_field_code IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_custom_field
                        WHERE organization_id = @organization_id AND entity_code = @entity_code
                          AND field_code = UPPER(@visible_when_field_code) AND ISNULL(field_id, 0) <> ISNULL(@field_id, -1))
        THROW 57546, 'The field this one depends on does not exist on the same record type.', 1;
    IF ISNULL(@status, N'') NOT IN (N'Active', N'Retired') SET @status = N'Active';

    IF @field_id IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_custom_field
                    WHERE organization_id = @organization_id AND entity_code = @entity_code AND field_code = @field_code)
            THROW 57547, 'A field with that code already exists on this record type.', 1;
        INSERT grac_practice.tprm_custom_field
            (organization_id, entity_code, field_code, label, description, data_type, is_mandatory, default_value,
             validation_regex, min_value, max_value, max_length, options_json, reference_kind, visible_when_field_code,
             visible_when_value, access_role_names, is_searchable, is_filterable, is_reportable, display_order, status, entered_by)
        VALUES (@organization_id, @entity_code, @field_code, @label, @description, @data_type, ISNULL(@is_mandatory, 0), @default_value,
                @validation_regex, @min_value, @max_value, @max_length, @options_json, @reference_kind,
                UPPER(NULLIF(LTRIM(RTRIM(@visible_when_field_code)), N'')), @visible_when_value,
                NULLIF(LTRIM(RTRIM(@access_role_names)), N''), ISNULL(@is_searchable, 0), ISNULL(@is_filterable, 0),
                ISNULL(@is_reportable, 1), ISNULL(@display_order, 100), @status, @actor);
        SET @out_field_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        DECLARE @old_type NVARCHAR(20) = (SELECT data_type FROM grac_practice.tprm_custom_field
                                            WHERE field_id = @field_id AND organization_id = @organization_id);
        IF @old_type IS NULL THROW 57548, 'That field was not found.', 1;
        -- Stored values would lose their meaning if the type changed.
        IF @old_type <> @data_type AND EXISTS (SELECT 1 FROM grac_practice.tprm_custom_field_value WHERE field_id = @field_id)
            THROW 57549, 'This field already has values; its data type cannot change. Retire it and add a new field.', 1;
        UPDATE grac_practice.tprm_custom_field
           SET label = @label, description = @description, data_type = @data_type, is_mandatory = ISNULL(@is_mandatory, 0),
               default_value = @default_value, validation_regex = @validation_regex, min_value = @min_value, max_value = @max_value,
               max_length = @max_length, options_json = @options_json, reference_kind = @reference_kind,
               visible_when_field_code = UPPER(NULLIF(LTRIM(RTRIM(@visible_when_field_code)), N'')),
               visible_when_value = @visible_when_value, access_role_names = NULLIF(LTRIM(RTRIM(@access_role_names)), N''),
               is_searchable = ISNULL(@is_searchable, 0), is_filterable = ISNULL(@is_filterable, 0),
               is_reportable = ISNULL(@is_reportable, 1), display_order = ISNULL(@display_order, 100),
               status = @status, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE field_id = @field_id;
        SET @out_field_id = @field_id;
    END
    EXEC grac_practice.sp_tprm_audit N'tprm-custom-field', @out_field_id, N'SAVE', @field_code, @actor;
END
GO


-- 4. Objects and columns 521 added
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_vendor_match_review_save;
DROP FUNCTION IF EXISTS grac_practice.fn_tprm_vendor_transitions;
DROP FUNCTION IF EXISTS grac_practice.fn_tprm_domain;
DROP FUNCTION IF EXISTS grac_practice.fn_tprm_vendor_status_meaning;
GO
IF OBJECT_ID('grac_practice.tprm_vendor_match_review', 'U') IS NOT NULL
BEGIN
    DROP TABLE grac_practice.tprm_vendor_match_review;
    PRINT '521 rollback: tprm_vendor_match_review dropped.';
END
GO
IF COL_LENGTH('grac_practice.tprm_third_party', 'duplicate_of_third_party_id') IS NOT NULL
BEGIN
    IF OBJECT_ID('grac_practice.fk_pm_tprm_tp_dup', 'F') IS NOT NULL
        ALTER TABLE grac_practice.tprm_third_party DROP CONSTRAINT fk_pm_tprm_tp_dup;
    ALTER TABLE grac_practice.tprm_third_party DROP COLUMN duplicate_of_third_party_id;
END
IF COL_LENGTH('grac_practice.tprm_third_party', 'first_activated_dt') IS NOT NULL
    ALTER TABLE grac_practice.tprm_third_party DROP COLUMN first_activated_dt;
IF COL_LENGTH('grac_practice.tprm_third_party_status_history', 'evidence_reference') IS NOT NULL
    ALTER TABLE grac_practice.tprm_third_party_status_history DROP COLUMN evidence_reference;
IF COL_LENGTH('grac_practice.tprm_engagement', 'service_recipient') IS NOT NULL
    ALTER TABLE grac_practice.tprm_engagement DROP COLUMN service_recipient;
IF COL_LENGTH('grac_practice.tprm_engagement', 'substitutability_code') IS NOT NULL
    ALTER TABLE grac_practice.tprm_engagement DROP COLUMN substitutability_code;
IF COL_LENGTH('grac_practice.tprm_engagement', 'customer_impact_code') IS NOT NULL
    ALTER TABLE grac_practice.tprm_engagement DROP COLUMN customer_impact_code;
IF COL_LENGTH('grac_practice.tprm_engagement', 'exit_dependencies') IS NOT NULL
    ALTER TABLE grac_practice.tprm_engagement DROP COLUMN exit_dependencies;
PRINT '521 rollback: 521 columns dropped.';
GO

-- 5. Menu names of 490
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'nav-tprm',           N'Third-Party Risk'),
    (N'tprm-dashboard',     N'Dashboard'),
    (N'tprm-third-parties', N'Third Parties'),
    (N'tprm-engagements',   N'Engagements'),
    (N'tprm-reviews',       N'Reviews'),
    (N'tprm-configuration', N'TPRM Configuration')
) AS s(menu_key, menu_name)
ON t.menu_key = s.menu_key
WHEN MATCHED THEN UPDATE SET menu_name = s.menu_name, module_type = N'Third-Party Risk',
    updated_by = N'rollback-521', updated_dt = SYSUTCDATETIME();
GO

SELECT '521 rollback' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.tprm_third_party', 'vendor_id') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_vendor_import', 'P') IS NOT NULL
             AND OBJECT_ID('grac_practice.tprm_vendor_match_review', 'U') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
GO
PRINT '521 rollback complete. Deploy the API and Web builds from before 521, and the 274 / 490 menu names from before 521 if they are re-run.';
GO
