-- =====================================================================
-- 522_tpm_cr2_registration_exposure_rollback.sql
--
-- Reverses 522_tpm_cr2_registration_exposure.sql:
--   * The 521 / 488 procedure bodies 522 re-issued are restored verbatim
--     (fn_tprm_vendor_transitions, sp_tprm_third_party_save,
--     sp_tprm_vendor_match_review_save, sp_tprm_sample_load,
--     sp_tprm_engagement_get, sp_tprm_engagement_save from 521;
--     sp_tprm_scope_item_save, sp_tprm_scope_item_remove,
--     sp_tprm_risk_assessment_start from 488).
--   * The baseline TP_STATUS value DRAFT and the 521 list meanings come
--     back; organization DRAFT values 522 retired are active again.
--     Organization overrides of the baseline DRAFT value (relabels) that
--     522 deleted are NOT recreated. Vendors 522 activated STAY ACTIVE
--     (activation is not undone).
--   * sp_tprm_engagement_exposure_save, sp_tprm_engagement_flag_material,
--     sp_tprm_engagement_answers_derive and fn_tprm_scope_item_key are
--     dropped, and the 522 engagement columns (the eight gating answers,
--     data_processing_details, contract_start_dt, contract_end_dt,
--     contract_documents, exposure_saved_dt, exposure_saved_by) are
--     dropped WITH their data. Proposed scope items saved through the
--     exposure page stay.
--   * Navigation returns to the 521 names: "Engagements", the dashboard and
--     Reviews & Monitoring back in the sidebar, "Configuration" back under
--     Third-Party Management.
-- Deploy the previous API / Web build first. Run AFTER the 523 rollback
-- (refuses while 523 is installed) and BEFORE the 521 rollback.
-- 274 and 490 carry the 522 menu names and places: after this rollback,
-- re-run them only from the versions of 521 (version control), or they
-- move Third-Party Settings back under Settings.
-- Before re-running 487 after this rollback, take the 487 of 521 from
-- version control (the 522 one has no DRAFT value).
-- Generated from the 521 / 488 sources. ASCII-only. SAFE TO RE-RUN.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.tprm_third_party','U') IS NULL
BEGIN
    PRINT '522 rollback: TPRM is not installed -- nothing to do.';
    SET NOEXEC ON;
END
GO

-- 523 builds on 522 (its procedures read the 522 columns): roll 523 back
-- first.
IF COL_LENGTH('grac_practice.tprm_engagement', 'applicability_status') IS NOT NULL
BEGIN
    PRINT '522 rollback ABORTED: 523 is installed. Run 523_tpm_cr2_screening_admission_rollback.sql first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. TP_STATUS: the DRAFT value and the 521 meanings
-- =====================================================================
UPDATE grac_practice.tprm_reference_list
   SET allowed_meanings = N'DRAFT,ACTIVE,INACTIVE,SUSPENDED,ARCHIVED',
       description = N'Lifecycle status of a vendor in the Vendor Registry (521). Each value maps to a lifecycle meaning; the transitions between meanings are fixed (fn_tprm_vendor_transitions).',
       updated_by = N'rollback-522', updated_dt = SYSUTCDATETIME()
 WHERE list_code = N'TP_STATUS';
IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_reference_value
                WHERE organization_id IS NULL AND list_code = N'TP_STATUS' AND value_code = N'DRAFT')
    INSERT grac_practice.tprm_reference_value
        (list_code, organization_id, value_code, label, meaning_code, color_hex, display_order, status, entered_by)
    VALUES (N'TP_STATUS', NULL, N'DRAFT', N'Draft', N'DRAFT', N'#64748b', 5, N'Active', N'rollback-522');
UPDATE grac_practice.tprm_reference_value
   SET status = N'Active', updated_by = N'rollback-522', updated_dt = SYSUTCDATETIME()
 WHERE list_code = N'TP_STATUS' AND organization_id IS NOT NULL AND meaning_code = N'DRAFT'
   AND status = N'Retired' AND updated_by = N'migration-522';
GO

-- =====================================================================
-- 2. Procedures as they were before 522
-- =====================================================================

-- restored from 521
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_vendor_transitions (@organization_id BIGINT, @third_party_id BIGINT)
RETURNS TABLE
AS
RETURN
(
WITH v AS (
    SELECT t.third_party_id, t.organization_id, t.legal_name, t.trading_name, t.registration_number, t.tax_id, t.lei_code,
           t.website, t.first_activated_dt,
           grac_practice.fn_tprm_vendor_status_meaning(t.organization_id, t.lifecycle_status_code) AS meaning,
           (SELECT STRING_AGG(ct.email, N',') FROM grac_practice.tprm_third_party_contact ct
             WHERE ct.third_party_id = t.third_party_id AND ct.status = N'Active' AND ct.email IS NOT NULL) AS emails,
           (SELECT COUNT(*) FROM grac_practice.tprm_engagement e
             WHERE e.third_party_id = t.third_party_id AND e.stage_code NOT IN (N'EXITED', N'REJECTED', N'CANCELLED')) AS open_engagements,
           NULLIF(CONCAT_WS(N', ',
               CASE WHEN t.provider_type_code IS NULL THEN N'vendor type' END,
               CASE WHEN t.primary_service_category_code IS NULL THEN N'primary service category' END,
               CASE WHEN NULLIF(LTRIM(RTRIM(t.country)), N'') IS NULL THEN N'country' END,
               CASE WHEN t.relationship_owner_employee_id IS NULL THEN N'relationship owner' END,
               CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party_contact ct
                                      WHERE ct.third_party_id = t.third_party_id AND ct.status = N'Active' AND ct.is_primary = 1)
                    THEN N'a primary contact' END), N'') AS missing
    FROM   grac_practice.tprm_third_party t
    WHERE  t.third_party_id = @third_party_id
      AND  t.organization_id = @organization_id
),
g AS (
    SELECT v.*, um.unreviewed
    FROM   v
    OUTER  APPLY (SELECT COUNT(*) AS unreviewed
                  FROM grac_practice.fn_tprm_third_party_matches(v.organization_id, v.legal_name, v.trading_name,
                           v.registration_number, v.tax_id, v.lei_code, v.website, v.emails, v.third_party_id) m
                  WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_vendor_match_review r
                                     WHERE r.vendor_a_id = CASE WHEN m.match_id < v.third_party_id THEN m.match_id ELSE v.third_party_id END
                                       AND r.vendor_b_id = CASE WHEN m.match_id < v.third_party_id THEN v.third_party_id ELSE m.match_id END)) um
)
SELECT x.action_code AS ActionCode,
       g.meaning     AS FromMeaning,
       x.to_meaning  AS ToMeaning,
       ISNULL(grac_practice.fn_tprm_meaning_code(g.organization_id, N'TP_STATUS', x.to_meaning), x.to_meaning) AS ToStatusCode,
       x.permission  AS Permission,
       x.sort_no     AS SortNo,
       CAST(CASE WHEN b.block_reason IS NULL THEN 1 ELSE 0 END AS BIT) AS IsAllowed,
       b.block_reason AS BlockReason
FROM   g
CROSS  APPLY (VALUES
        (N'DRAFT',     N'ACTIVATE',   N'ACTIVE',    N'EDIT',    10),
        (N'DRAFT',     N'ARCHIVE',    N'ARCHIVED',  N'APPROVE', 90),
        (N'ACTIVE',    N'SUSPEND',    N'SUSPENDED', N'APPROVE', 20),
        (N'ACTIVE',    N'INACTIVATE', N'INACTIVE',  N'APPROVE', 30),
        (N'SUSPENDED', N'REINSTATE',  N'ACTIVE',    N'APPROVE', 10),
        (N'SUSPENDED', N'INACTIVATE', N'INACTIVE',  N'APPROVE', 30),
        (N'INACTIVE',  N'REACTIVATE', N'ACTIVE',    N'APPROVE', 10),
        (N'INACTIVE',  N'ARCHIVE',    N'ARCHIVED',  N'APPROVE', 90),
        (N'ARCHIVED',  N'RESTORE',    N'DRAFT',     N'APPROVE', 10),
        (N'ARCHIVED',  N'RESTORE',    N'INACTIVE',  N'APPROVE', 10)
       ) x(from_meaning, action_code, to_meaning, permission, sort_no)
CROSS  APPLY (SELECT CASE
        WHEN x.action_code IN (N'ACTIVATE', N'REACTIVATE') AND g.missing IS NOT NULL
             THEN CAST(CONCAT(N'Complete the profile first: ', g.missing, N'.') AS NVARCHAR(400))
        WHEN x.action_code = N'ACTIVATE' AND g.unreviewed > 0
             THEN CAST(CONCAT(N'Review the ', g.unreviewed, N' possible duplicate(s) first.') AS NVARCHAR(400))
        WHEN x.action_code IN (N'INACTIVATE', N'ARCHIVE') AND g.open_engagements > 0
             THEN CAST(CONCAT(N'Close, exit or cancel its ', g.open_engagements, N' open engagement(s) first.') AS NVARCHAR(400))
        END AS block_reason) b
WHERE  x.from_meaning = g.meaning
  AND  NOT (x.action_code = N'RESTORE' AND x.to_meaning = N'DRAFT'    AND g.first_activated_dt IS NOT NULL)
  AND  NOT (x.action_code = N'RESTORE' AND x.to_meaning = N'INACTIVE' AND g.first_activated_dt IS NULL)
);
GO

-- restored from 521
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
    @match_reviews_json            NVARCHAR(MAX)  = NULL,
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
        THROW 57603, 'Choose a vendor type from the list.', 1;
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
    IF @match_reviews_json IS NOT NULL AND ISJSON(@match_reviews_json) <> 1 THROW 58000, 'The duplicate reviews are not valid.', 1;

    DECLARE @current_meaning NVARCHAR(40);
    IF @third_party_id IS NOT NULL
    BEGIN
        DECLARE @rv BIGINT, @rec_status NVARCHAR(20);
        SELECT @rv = CONVERT(BIGINT, record_version), @rec_status = status,
               @current_meaning = grac_practice.fn_tprm_vendor_status_meaning(organization_id, lifecycle_status_code)
        FROM grac_practice.tprm_third_party
         WHERE third_party_id = @third_party_id AND organization_id = @organization_id;
        IF @rv IS NULL THROW 57601, 'That vendor was not found.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 57611, 'Someone else changed this vendor. Reload and try again.', 1;
        IF @current_meaning = N'ARCHIVED' THROW 58001, 'An archived vendor cannot be changed. Restore it first.', 1;
    END

    -- Source 4.1: possible duplicates are reviewed, never silently merged.
    -- Matches already reviewed for this vendor do not ask again.
    DECLARE @emails NVARCHAR(2000) =
        CASE WHEN @contacts_json IS NOT NULL
             THEN (SELECT STRING_AGG(j.email, N',') FROM OPENJSON(@contacts_json) WITH (email NVARCHAR(250) '$.email') j
                    WHERE NULLIF(LTRIM(RTRIM(j.email)), N'') IS NOT NULL)
             ELSE (SELECT STRING_AGG(c.email, N',') FROM grac_practice.tprm_third_party_contact c
                    WHERE c.third_party_id = @third_party_id AND c.status = N'Active' AND c.email IS NOT NULL) END;
    DECLARE @m TABLE (match_id BIGINT PRIMARY KEY, match_code NVARCHAR(20), match_name NVARCHAR(250), match_status_code NVARCHAR(60),
                      strength INT, match_reason NVARCHAR(1000), rationale NVARCHAR(1000));
    INSERT @m (match_id, match_code, match_name, match_status_code, strength, match_reason)
    SELECT m.match_id, m.match_code, m.match_name, m.match_status_code, m.strength, m.match_reason
    FROM   grac_practice.fn_tprm_third_party_matches(@organization_id, @legal_name, @trading_name, @registration_number,
                                                     @tax_id, @lei_code, @website, @emails, @third_party_id) m
    WHERE  @third_party_id IS NULL
       OR  NOT EXISTS (SELECT 1 FROM grac_practice.tprm_vendor_match_review r
                        WHERE r.vendor_a_id = CASE WHEN m.match_id < @third_party_id THEN m.match_id ELSE @third_party_id END
                          AND r.vendor_b_id = CASE WHEN m.match_id < @third_party_id THEN @third_party_id ELSE m.match_id END);
    IF @match_reviews_json IS NOT NULL
        UPDATE m SET rationale = NULLIF(LTRIM(RTRIM(j.rationale)), N'')
        FROM @m m
        JOIN OPENJSON(@match_reviews_json) WITH (matchId BIGINT '$.matchId', rationale NVARCHAR(1000) '$.rationale') j
             ON j.matchId = m.match_id;
    IF EXISTS (SELECT 1 FROM @m WHERE rationale IS NULL)
    BEGIN
        SELECT @third_party_id AS ThirdPartyId, N'DUPLICATES' AS Result;
        SELECT CASE WHEN m.strength >= 2 THEN N'STRONG' ELSE N'POSSIBLE' END AS MatchKind,
               m.match_id AS MatchId, m.match_code AS MatchCode, m.match_name AS MatchName, m.match_reason AS MatchReason,
               m.match_status_code AS MatchStatusCode, st.label AS MatchStatus
        FROM   @m m
        LEFT   JOIN grac_practice.fn_tprm_reference_effective(@organization_id) st
               ON st.list_code = N'TP_STATUS' AND st.value_code = m.match_status_code
        WHERE  m.rationale IS NULL
        ORDER  BY m.strength DESC, m.match_name;
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
                ISNULL(grac_practice.fn_tprm_meaning_code(@organization_id, N'TP_STATUS', N'DRAFT'), N'DRAFT'),
                @relationship_owner_employee_id, @actor);
        SET @id = SCOPE_IDENTITY();
        SET @created = 1;
        INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor_employee_id, actor)
        SELECT @id, NULL, lifecycle_status_code, N'Registered in the Vendor Registry.', 0, @actor_employee_id, @actor
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

    -- the reviews given with this save
    INSERT grac_practice.tprm_vendor_match_review
        (organization_id, vendor_a_id, vendor_b_id, decision, match_reason, rationale, reviewed_by_employee_id, reviewed_by)
    SELECT @organization_id,
           CASE WHEN m.match_id < @id THEN m.match_id ELSE @id END,
           CASE WHEN m.match_id < @id THEN @id ELSE m.match_id END,
           N'NOT_DUPLICATE', m.match_reason, m.rationale, @actor_employee_id, @actor
    FROM   @m m
    WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.tprm_vendor_match_review r
                        WHERE r.vendor_a_id = CASE WHEN m.match_id < @id THEN m.match_id ELSE @id END
                          AND r.vendor_b_id = CASE WHEN m.match_id < @id THEN @id ELSE m.match_id END);
    DECLARE @reviewed INT = @@ROWCOUNT;

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
    IF @reviewed > 0
    BEGIN
        DECLARE @review_detail NVARCHAR(2000) = CONCAT(@reviewed, N' possible duplicate(s) reviewed as different vendors.');
        EXEC grac_practice.sp_tprm_audit N'tprm-third-party', @id, N'DUPLICATE_REVIEW', @review_detail, @actor;
    END
    SELECT @id AS ThirdPartyId, CASE WHEN @created = 1 THEN N'CREATED' ELSE N'SAVED' END AS Result;
END
GO

-- restored from 521
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_vendor_match_review_save
    @organization_id        BIGINT,
    @third_party_id         BIGINT,
    @matched_third_party_id BIGINT,
    @decision               NVARCHAR(20),
    @rationale              NVARCHAR(1000),
    @actor_employee_id      BIGINT        = NULL,
    @actor                  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @decision = UPPER(NULLIF(LTRIM(RTRIM(@decision)), N''));
    SET @rationale = NULLIF(LTRIM(RTRIM(@rationale)), N'');
    IF @decision IS NULL OR @decision NOT IN (N'NOT_DUPLICATE', N'DUPLICATE') THROW 58020, 'Choose whether the two are different vendors or a duplicate.', 1;
    IF @rationale IS NULL THROW 58021, 'Give the reason for the decision.', 1;
    IF @third_party_id = @matched_third_party_id THROW 58022, 'Choose another vendor.', 1;

    DECLARE @this_status NVARCHAR(20), @this_code NVARCHAR(60), @other_status NVARCHAR(20), @other_code NVARCHAR(20);
    SELECT @this_status = status, @this_code = lifecycle_status_code FROM grac_practice.tprm_third_party
     WHERE third_party_id = @third_party_id AND organization_id = @organization_id;
    SELECT @other_status = status, @other_code = third_party_code FROM grac_practice.tprm_third_party
     WHERE third_party_id = @matched_third_party_id AND organization_id = @organization_id;
    IF @this_status IS NULL OR @other_status IS NULL THROW 57601, 'That vendor was not found.', 1;

    DECLARE @a BIGINT = CASE WHEN @third_party_id < @matched_third_party_id THEN @third_party_id ELSE @matched_third_party_id END;
    DECLARE @b BIGINT = CASE WHEN @third_party_id < @matched_third_party_id THEN @matched_third_party_id ELSE @third_party_id END;
    -- why the two match today (kept with the review)
    DECLARE @reason_text NVARCHAR(1000), @ln NVARCHAR(250), @tn NVARCHAR(250), @rn NVARCHAR(100), @tx NVARCHAR(100),
            @lei NVARCHAR(40), @web NVARCHAR(300), @mails NVARCHAR(2000);
    SELECT @ln = legal_name, @tn = trading_name, @rn = registration_number, @tx = tax_id, @lei = lei_code, @web = website
    FROM grac_practice.tprm_third_party WHERE third_party_id = @third_party_id;
    SELECT @mails = STRING_AGG(email, N',') FROM grac_practice.tprm_third_party_contact
     WHERE third_party_id = @third_party_id AND status = N'Active' AND email IS NOT NULL;
    SELECT TOP (1) @reason_text = m.match_reason
    FROM grac_practice.fn_tprm_third_party_matches(@organization_id, @ln, @tn, @rn, @tx, @lei, @web, @mails, @third_party_id) m
    WHERE m.match_id = @matched_third_party_id;

    -- A pair already decided as a duplicate is undone by restoring the
    -- archived vendor (RESTORE), which also records the reversal.
    IF @decision = N'NOT_DUPLICATE'
       AND EXISTS (SELECT 1 FROM grac_practice.tprm_vendor_match_review
                    WHERE vendor_a_id = @a AND vendor_b_id = @b AND duplicate_vendor_id IS NOT NULL)
        THROW 58026, 'These two were marked as duplicates. Restore the archived vendor to reverse that decision.', 1;

    IF @decision = N'DUPLICATE'
    BEGIN
        IF @this_status <> N'Active' THROW 58023, 'This vendor is already archived.', 1;
        -- Same gate as ARCHIVE (fn_tprm_vendor_transitions): only a draft or
        -- inactive vendor can be archived; make an active one inactive first.
        IF grac_practice.fn_tprm_vendor_status_meaning(@organization_id, @this_code) NOT IN (N'DRAFT', N'INACTIVE')
            THROW 58027, 'Only a draft or inactive vendor can be marked as a duplicate. Make it inactive first.', 1;
        IF @other_status <> N'Active' THROW 58024, 'The vendor it duplicates is archived. Restore that vendor first.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE third_party_id = @third_party_id
                     AND stage_code NOT IN (N'EXITED', N'REJECTED', N'CANCELLED'))
            THROW 58025, 'This vendor has open engagements. Close or cancel them (and open them on the other vendor) before marking it as a duplicate.', 1;
    END

    BEGIN TRAN;
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_vendor_match_review WHERE vendor_a_id = @a AND vendor_b_id = @b)
        UPDATE grac_practice.tprm_vendor_match_review
           SET decision = @decision, duplicate_vendor_id = CASE WHEN @decision = N'DUPLICATE' THEN @third_party_id END,
               match_reason = COALESCE(@reason_text, match_reason), rationale = @rationale,
               reviewed_by_employee_id = @actor_employee_id, reviewed_by = @actor, reviewed_dt = SYSUTCDATETIME()
         WHERE vendor_a_id = @a AND vendor_b_id = @b;
    ELSE
        INSERT grac_practice.tprm_vendor_match_review
            (organization_id, vendor_a_id, vendor_b_id, decision, duplicate_vendor_id, match_reason, rationale, reviewed_by_employee_id, reviewed_by)
        VALUES (@organization_id, @a, @b, @decision, CASE WHEN @decision = N'DUPLICATE' THEN @third_party_id END,
                @reason_text, @rationale, @actor_employee_id, @actor);

    IF @decision = N'DUPLICATE'
    BEGIN
        DECLARE @archived NVARCHAR(60) = ISNULL(grac_practice.fn_tprm_meaning_code(@organization_id, N'TP_STATUS', N'ARCHIVED'), N'ARCHIVED');
        UPDATE grac_practice.tprm_third_party
           SET duplicate_of_third_party_id = @matched_third_party_id, lifecycle_status_code = @archived, status = N'Archived',
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE third_party_id = @third_party_id;
        INSERT grac_practice.tprm_third_party_status_history
            (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor_employee_id, actor)
        VALUES (@third_party_id, @this_code, @archived, LEFT(CONCAT(N'Duplicate of ', @other_code, N': ', @rationale), 1000),
                0, @actor_employee_id, @actor);
    END
    COMMIT;

    DECLARE @detail NVARCHAR(2000) = CONCAT(@decision, N' with ', @other_code, N': ', @rationale);
    EXEC grac_practice.sp_tprm_audit N'tprm-third-party', @third_party_id, N'DUPLICATE_REVIEW', @detail, @actor;
    SELECT @third_party_id AS ThirdPartyId, CASE WHEN @decision = N'DUPLICATE' THEN N'MARKED_DUPLICATE' ELSE N'REVIEWED' END AS Result;
END
GO

-- restored from 521
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
    DECLARE @draft NVARCHAR(60) = ISNULL(grac_practice.fn_tprm_meaning_code(@organization_id, N'TP_STATUS', N'DRAFT'), N'DRAFT');
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
               p.service_category_code, p.country, @draft,
               CONCAT(N'Illustrative sample record - not a real provider and not a completed assessment. ', p.notes),
               1, @actor
        FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code;
        SET @tp = SCOPE_IDENTITY();
        INSERT grac_practice.tprm_third_party_category (third_party_id, service_category_code)
        SELECT @tp, p.service_category_code FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code;
        INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor_employee_id, actor)
        VALUES (@tp, NULL, @draft, N'Sample record loaded.', 0, @actor_employee_id, @actor);

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

-- restored from 521
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
           t.lifecycle_status_code AS ThirdPartyStatusCode, ts.label AS ThirdPartyStatus,
           grac_practice.fn_tprm_vendor_status_meaning(t.organization_id, t.lifecycle_status_code) AS ThirdPartyStatusMeaning,
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
           e.service_recipient AS ServiceRecipient, e.substitutability_code AS SubstitutabilityCode, sb.label AS Substitutability,
           e.customer_impact_code AS CustomerImpactCode, ci.label AS CustomerImpact, e.exit_dependencies AS ExitDependencies,
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
    LEFT   JOIN ref sb ON sb.list_code = N'SUBSTITUTABILITY' AND sb.value_code = e.substitutability_code
    LEFT   JOIN ref ci ON ci.list_code = N'CUSTOMER_IMPACT' AND ci.value_code = e.customer_impact_code
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

-- restored from 521
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
    @service_recipient             NVARCHAR(250)  = NULL,
    @substitutability_code         NVARCHAR(60)   = NULL,
    @customer_impact_code          NVARCHAR(60)   = NULL,
    @exit_dependencies             NVARCHAR(2000) = NULL,
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
        (N'DATA_EXPOSURE',    @data_exposure_code,    N'data exposure'),
        (N'SUBSTITUTABILITY', @substitutability_code, N'substitutability'),
        (N'CUSTOMER_IMPACT',  @customer_impact_code,  N'customer impact')) x(list_code, code, what)
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
    DECLARE @o_crit NVARCHAR(60), @o_data NVARCHAR(60), @o_model NVARCHAR(60), @o_loc NVARCHAR(1000),
            @o_sub NVARCHAR(60), @o_cust NVARCHAR(60);
    IF @id IS NOT NULL
    BEGIN
        DECLARE @rv BIGINT;
        SELECT @rv = CONVERT(BIGINT, record_version), @stage = stage_code, @tp = third_party_id,
               @o_crit = service_criticality_code, @o_data = data_exposure_code, @o_model = service_model_code, @o_loc = delivery_locations,
               @o_sub = substitutability_code, @o_cust = customer_impact_code
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
            THROW 57641, 'Choose a registered vendor for the engagement.', 1;
        -- 521: an engagement is opened for a DRAFT or ACTIVE vendor only
        -- (not a suspended, inactive or archived one).
        IF (SELECT grac_practice.fn_tprm_vendor_status_meaning(organization_id, lifecycle_status_code)
              FROM grac_practice.tprm_third_party WHERE third_party_id = @tp) NOT IN (N'DRAFT', N'ACTIVE')
            THROW 58030, 'A new engagement can be opened only for a draft or active vendor.', 1;
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
             data_exposure_code, rto_hours, rpo_hours, sla_summary, service_recipient, substitutability_code, customer_impact_code,
             exit_dependencies, notes, stage_code, entered_by)
        VALUES (@organization_id, @tp, @code, @engagement_title, @service_description, @scope_description, @business_purpose,
                @service_category_code, @engagement_type_code, @service_model_code, @delivery_locations, ISNULL(@is_existing, 0), @contract_id,
                @contract_reference, @contract_value, @currency_code, @proposed_start_dt, @proposed_end_dt, @actual_start_dt, @actual_end_dt,
                @renewal_dt, @business_owner_employee_id, @relationship_owner_employee_id, @assessor_employee_id, @service_criticality_code,
                @data_exposure_code, @rto_hours, @rpo_hours, @sla_summary, NULLIF(LTRIM(RTRIM(@service_recipient)), N''),
                @substitutability_code, @customer_impact_code, NULLIF(LTRIM(RTRIM(@exit_dependencies)), N''), @notes, N'SCOPING', @actor);
        SET @id = SCOPE_IDENTITY();
        SET @created = 1;
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
               rto_hours = @rto_hours, rpo_hours = @rpo_hours, sla_summary = @sla_summary,
               service_recipient = NULLIF(LTRIM(RTRIM(@service_recipient)), N''), substitutability_code = @substitutability_code,
               customer_impact_code = @customer_impact_code, exit_dependencies = NULLIF(LTRIM(RTRIM(@exit_dependencies)), N''),
               notes = @notes,
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
            CASE WHEN ISNULL(@o_loc, N'') <> ISNULL(@delivery_locations, N'') THEN N'delivery locations changed' END,
            CASE WHEN ISNULL(@o_cust, N'') <> ISNULL(@customer_impact_code, N'') THEN CONCAT(N'customer impact ', @o_cust, N' -> ', @customer_impact_code) END,
            CASE WHEN ISNULL(@o_sub, N'') <> ISNULL(@substitutability_code, N'') THEN CONCAT(N'substitutability ', @o_sub, N' -> ', @substitutability_code) END);
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
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_scope_item_save
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @scope_item_id     BIGINT         = NULL,
    @item_kind         NVARCHAR(30),
    @exposure_mode     NVARCHAR(20)   = N'PROPOSED',
    @ref_id            BIGINT         = NULL,
    @item_code         NVARCHAR(60)   = NULL,
    @item_name         NVARCHAR(300)  = NULL,
    @criticality_code  NVARCHAR(60)   = NULL,
    @country           NVARCHAR(120)  = NULL,
    @is_critical       BIT            = 0,
    @notes             NVARCHAR(1000) = NULL,
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
    IF @item_kind NOT IN (N'BUSINESS_FUNCTION', N'PROCESS', N'APPLICATION', N'DATA_CATEGORY', N'ACCESS', N'LOCATION', N'FOURTH_PARTY')
        THROW 57642, 'Unknown scope item type.', 1;
    IF ISNULL(@exposure_mode, N'') NOT IN (N'PROPOSED', N'ACTUAL') THROW 57643, 'Exposure must be proposed or actual.', 1;
    SET @item_code = NULLIF(LTRIM(RTRIM(@item_code)), N'');
    SET @item_name = NULLIF(LTRIM(RTRIM(@item_name)), N'');

    -- GRAC objects are picked, not typed: resolve the name from the record.
    IF @item_kind = N'BUSINESS_FUNCTION' AND @ref_id IS NOT NULL
        SELECT @item_name = function_name FROM grac_practice.organization_business_function
         WHERE business_function_id = @ref_id AND organization_id = @organization_id;
    ELSE IF @item_kind = N'PROCESS' AND @ref_id IS NOT NULL
        SELECT @item_name = process_name FROM grac_practice.organization_dependency_process
         WHERE process_id = @ref_id AND organization_id = @organization_id;
    ELSE IF @item_kind = N'APPLICATION' AND @ref_id IS NOT NULL
        SELECT @item_name = application_name FROM grac_practice.organization_dependency_application
         WHERE application_id = @ref_id AND organization_id = @organization_id;
    ELSE IF @item_kind = N'FOURTH_PARTY' AND @ref_id IS NOT NULL
        SELECT @item_name = COALESCE(@item_name, legal_name) FROM grac_practice.tprm_third_party
         WHERE third_party_id = @ref_id AND organization_id = @organization_id;

    IF @item_kind IN (N'BUSINESS_FUNCTION', N'PROCESS', N'APPLICATION') AND @ref_id IS NULL AND @item_name IS NULL
        THROW 57644, 'Pick the GRAC record or name the item.', 1;
    IF @item_kind IN (N'DATA_CATEGORY', N'ACCESS')
    BEGIN
        DECLARE @list NVARCHAR(60) = CASE @item_kind WHEN N'DATA_CATEGORY' THEN N'DATA_EXPOSURE' ELSE N'ACCESS_CATEGORY' END;
        SELECT @item_name = COALESCE(@item_name, label) FROM grac_practice.fn_tprm_reference_effective(@organization_id)
         WHERE list_code = @list AND value_code = @item_code;
        IF @item_code IS NULL OR @item_name IS NULL THROW 57645, 'Choose a value from the list.', 1;
    END
    IF @item_kind = N'FOURTH_PARTY' AND @item_code IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id)
                        WHERE list_code = N'FOURTH_PARTY_CATEGORY' AND value_code = @item_code)
        THROW 57645, 'Choose a value from the list.', 1;
    IF @item_name IS NULL THROW 57646, 'The item needs a name.', 1;

    IF @scope_item_id IS NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope
                    WHERE engagement_id = @engagement_id AND item_kind = @item_kind AND exposure_mode = @exposure_mode
                      AND status = N'Active'
                      AND ((@ref_id IS NOT NULL AND ref_id = @ref_id) OR (@item_code IS NOT NULL AND item_code = @item_code AND @item_kind IN (N'DATA_CATEGORY', N'ACCESS'))
                           OR (@ref_id IS NULL AND @item_kind NOT IN (N'DATA_CATEGORY', N'ACCESS') AND item_name = @item_name)))
            THROW 57647, 'That item is already in the scope.', 1;
        INSERT grac_practice.tprm_engagement_scope
            (engagement_id, organization_id, item_kind, exposure_mode, ref_id, item_code, item_name, criticality_code, country,
             is_critical, notes, entered_by)
        VALUES (@engagement_id, @organization_id, @item_kind, @exposure_mode, @ref_id, @item_code, @item_name, @criticality_code,
                @country, ISNULL(@is_critical, 0), @notes, @actor);
        SET @scope_item_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope WHERE scope_item_id = @scope_item_id AND engagement_id = @engagement_id)
            THROW 57648, 'That scope item was not found.', 1;
        UPDATE grac_practice.tprm_engagement_scope
           SET item_kind = @item_kind, exposure_mode = @exposure_mode, ref_id = @ref_id, item_code = @item_code, item_name = @item_name,
               criticality_code = @criticality_code, country = @country, is_critical = ISNULL(@is_critical, 0), notes = @notes,
               status = N'Active', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE scope_item_id = @scope_item_id;
    END

    -- On a live engagement a change of data / access / location / fourth
    -- party in the ACTUAL exposure is a reassessment trigger (BRD 4).
    IF @stage IN (N'ACTIVE', N'SUSPENDED') AND @exposure_mode = N'ACTUAL'
       AND @item_kind IN (N'DATA_CATEGORY', N'ACCESS', N'LOCATION', N'FOURTH_PARTY')
    BEGIN
        UPDATE grac_practice.tprm_engagement
           SET reassessment_required = 1,
               reassessment_reason = LEFT(CONCAT(N'Scope change: ', @item_kind, N' ', @item_name), 1000)
         WHERE engagement_id = @engagement_id;
        DECLARE @sdetail NVARCHAR(2000) = CONCAT(N'Scope change: ', @item_kind, N' ', @item_name);
        EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'SCOPE_CHANGE', @stage, @stage, @sdetail, @actor_employee_id, @actor;
    END
    ELSE
    BEGIN
        DECLARE @adetail NVARCHAR(2000) = CONCAT(@exposure_mode, N' ', @item_kind, N': ', @item_name);
        EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'SCOPE_SAVED', @stage, @stage, @adetail, @actor_employee_id, @actor;
    END
    SELECT @scope_item_id AS ScopeItemId, N'SAVED' AS Result;
END
GO

-- restored from 488
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_scope_item_remove
    @organization_id   BIGINT,
    @scope_item_id     BIGINT,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @eng BIGINT, @stage NVARCHAR(30), @kind NVARCHAR(30), @name NVARCHAR(300), @mode NVARCHAR(20);
    SELECT @eng = s.engagement_id, @stage = e.stage_code, @kind = s.item_kind, @name = s.item_name, @mode = s.exposure_mode
    FROM grac_practice.tprm_engagement_scope s
    JOIN grac_practice.tprm_engagement e ON e.engagement_id = s.engagement_id
    WHERE s.scope_item_id = @scope_item_id AND s.organization_id = @organization_id AND s.status = N'Active';
    IF @eng IS NULL THROW 57648, 'That scope item was not found.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;

    UPDATE grac_practice.tprm_engagement_scope SET status = N'Removed', updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE scope_item_id = @scope_item_id;
    IF @stage IN (N'ACTIVE', N'SUSPENDED') AND @mode = N'ACTUAL' AND @kind IN (N'DATA_CATEGORY', N'ACCESS', N'LOCATION', N'FOURTH_PARTY')
        UPDATE grac_practice.tprm_engagement
           SET reassessment_required = 1, reassessment_reason = LEFT(CONCAT(N'Scope change: ', @kind, N' ', @name, N' removed'), 1000)
         WHERE engagement_id = @eng;
    DECLARE @detail NVARCHAR(2000) = CONCAT(@mode, N' ', @kind, N' removed: ', @name);
    EXEC grac_practice.sp_tprm_engagement_event @eng, N'SCOPE_REMOVED', @stage, @stage, @detail, @actor_employee_id, @actor;
    SELECT @scope_item_id AS ScopeItemId, N'REMOVED' AS Result;
END
GO

-- restored from 488
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_risk_assessment_start
    @organization_id   BIGINT,
    @engagement_id     BIGINT,
    @trigger_code      NVARCHAR(60)  = N'INITIAL',
    @trigger_note      NVARCHAR(1000) = NULL,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @stage NVARCHAR(30) = (SELECT stage_code FROM grac_practice.tprm_engagement
                                    WHERE engagement_id = @engagement_id AND organization_id = @organization_id);
    IF @stage IS NULL THROW 57630, 'That engagement was not found.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED', N'EXITING') THROW 57640, 'A closed engagement cannot be reassessed.', 1;
    IF @stage = N'PENDING_DECISION' THROW 57660, 'A decision is pending. Withdraw it before reassessing.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_risk_assessment WHERE engagement_id = @engagement_id AND status = N'DRAFT')
        THROW 57661, 'An assessment is already in progress.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope WHERE engagement_id = @engagement_id AND status = N'Active')
       AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND data_exposure_code IS NOT NULL)
        THROW 57662, 'Record the scope (at least the data exposure) before assessing risk.', 1;

    DECLARE @version BIGINT = (SELECT version_id FROM grac_practice.fn_tprm_risk_model_version(@organization_id));
    IF @version IS NULL THROW 57663, 'No risk model is in force. Activate one in TPRM Configuration.', 1;
    SET @trigger_code = ISNULL(NULLIF(LTRIM(RTRIM(@trigger_code)), N''), N'INITIAL');

    DECLARE @id BIGINT, @no INT;
    BEGIN TRAN;
        SELECT @no = ISNULL(MAX(assessment_no), 0) + 1 FROM grac_practice.tprm_risk_assessment WITH (UPDLOCK, HOLDLOCK)
         WHERE engagement_id = @engagement_id;
        INSERT grac_practice.tprm_risk_assessment
            (engagement_id, organization_id, assessment_no, risk_model_version_id, trigger_code, trigger_note, status,
             assessed_by_employee_id, entered_by)
        VALUES (@engagement_id, @organization_id, @no, @version, @trigger_code, @trigger_note, N'DRAFT', @actor_employee_id, @actor);
        SET @id = SCOPE_IDENTITY();

        -- prefill from the scope
        ;WITH sig AS (SELECT * FROM grac_practice.fn_tprm_engagement_signals(@engagement_id)),
        ranked AS (
            SELECT f.factor_id, o.option_id, o.score,
                   ROW_NUMBER() OVER (PARTITION BY f.factor_id
                                      ORDER BY ISNULL(rv.rank_no, 0) DESC, o.score DESC) AS rn
            FROM   grac_practice.tprm_rm_factor f
            JOIN   grac_practice.tprm_rm_factor_option o ON o.factor_id = f.factor_id
            CROSS  JOIN sig
            CROSS  APPLY grac_practice.fn_tprm_split_codes(o.prefill_match_code) m
            OUTER  APPLY (SELECT TOP (1) r.rank_no FROM grac_practice.fn_tprm_reference_effective(@organization_id) r
                          WHERE r.value_code = m.code
                            AND r.list_code = CASE f.prefill_source WHEN N'DATA_EXPOSURE' THEN N'DATA_EXPOSURE'
                                                                    WHEN N'ACCESS' THEN N'ACCESS_CATEGORY'
                                                                    WHEN N'SERVICE_CRITICALITY' THEN N'CRITICALITY' ELSE N'-' END) rv
            WHERE  f.version_id = @version
              AND  f.prefill_source IS NOT NULL
              AND  (   (f.prefill_source = N'SERVICE_CRITICALITY' AND m.code = sig.service_criticality_code)
                    OR (f.prefill_source = N'SERVICE_MODEL' AND m.code = sig.service_model_code)
                    OR (f.prefill_source = N'IS_EXISTING' AND m.code = CASE WHEN sig.is_existing = 1 THEN N'YES' ELSE N'NO' END)
                    OR (f.prefill_source = N'DATA_EXPOSURE' AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(sig.data_codes) x WHERE x.code = m.code))
                    OR (f.prefill_source = N'ACCESS' AND EXISTS (SELECT 1 FROM grac_practice.fn_tprm_split_codes(sig.access_codes) x WHERE x.code = m.code))
                    OR (f.prefill_source = N'FOURTH_PARTY_COUNT'
                        AND m.code = CASE WHEN sig.fourth_party_count >= 3 THEN N'3+' ELSE CAST(sig.fourth_party_count AS NVARCHAR(5)) END)
                    OR (f.prefill_source = N'LOCATION_COUNT'
                        AND m.code = CASE WHEN sig.location_count >= 3 THEN N'3+' ELSE CAST(sig.location_count AS NVARCHAR(5)) END))
        )
        INSERT grac_practice.tprm_risk_assessment_answer (assessment_id, factor_id, option_id, score, is_prefilled, updated_by)
        SELECT @id, factor_id, option_id, score, 1, @actor FROM ranked WHERE rn = 1;

        EXEC grac_practice.sp_tprm_risk_score @id;
    COMMIT;

    DECLARE @sdetail NVARCHAR(2000) = CONCAT(N'Inherent assessment ', @no, N' started (', @trigger_code, N').');
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'RISK_ASSESSMENT_STARTED', @stage, @stage, @sdetail, @actor_employee_id, @actor;
    SELECT @id AS AssessmentId, N'STARTED' AS Result;
END
GO


-- =====================================================================
-- 3. Objects 522 added
-- =====================================================================
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_engagement_exposure_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_engagement_answers_derive;
DROP PROCEDURE IF EXISTS grac_practice.sp_tprm_engagement_flag_material;
DROP FUNCTION IF EXISTS grac_practice.fn_tprm_scope_item_key;
GO

DECLARE @drop NVARCHAR(MAX) = N'';
SELECT @drop = @drop + N'ALTER TABLE grac_practice.tprm_engagement DROP CONSTRAINT ' + QUOTENAME(cc.name) + N';'
FROM sys.check_constraints cc
WHERE cc.parent_object_id = OBJECT_ID('grac_practice.tprm_engagement')
  AND cc.name IN (N'ck_pm_tprm_eng_ans_app', N'ck_pm_tprm_eng_ans_premises', N'ck_pm_tprm_eng_ans_data', N'ck_pm_tprm_eng_ans_sub',
                  N'ck_pm_tprm_eng_ans_process', N'ck_pm_tprm_eng_ans_disruption', N'ck_pm_tprm_eng_ans_sla', N'ck_pm_tprm_eng_ans_contract');
SELECT @drop = @drop + N'ALTER TABLE grac_practice.tprm_engagement DROP COLUMN ' + QUOTENAME(c.name) + N';'
FROM sys.columns c
WHERE c.object_id = OBJECT_ID('grac_practice.tprm_engagement')
  AND c.name IN (N'app_access_answer', N'premises_access_answer', N'data_processing_answer', N'subcontracting_answer',
                 N'important_process_answer', N'disruption_impact_answer', N'service_commitment_answer', N'contract_answer',
                 N'data_processing_details', N'contract_start_dt', N'contract_end_dt', N'contract_documents',
                 N'exposure_saved_dt', N'exposure_saved_by');
IF @drop <> N'' EXEC sp_executesql @drop;
PRINT '522 rollback: engagement columns dropped.';
GO

-- =====================================================================
-- 4. Navigation as 521 left it
-- =====================================================================
UPDATE grac_practice.menu_master
   SET menu_name = N'Engagements', updated_by = N'rollback-522', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'tprm-engagements';
IF COL_LENGTH('grac_practice.menu_master', 'show_in_sidebar') IS NOT NULL
    EXEC sp_executesql N'UPDATE grac_practice.menu_master SET show_in_sidebar = 1, updated_by = N''rollback-522'', updated_dt = SYSUTCDATETIME()
                         WHERE menu_key IN (N''tprm-dashboard'', N''tprm-reviews'');';
DECLARE @tpm_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-tprm');
IF @tpm_id IS NOT NULL
    UPDATE grac_practice.menu_master
       SET menu_name = N'Configuration', parent_menu_id = @tpm_id, display_order = 374,
           module_type = N'Third-Party Management', updated_by = N'rollback-522', updated_dt = SYSUTCDATETIME()
     WHERE menu_key = N'tprm-configuration';
GO

-- =====================================================================
-- 5. Verification
-- =====================================================================
SELECT '522 rollback: 522 objects and columns gone' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_tprm_engagement_exposure_save', 'P') IS NULL
             AND OBJECT_ID('grac_practice.fn_tprm_scope_item_key') IS NULL
             AND COL_LENGTH('grac_practice.tprm_engagement', 'exposure_saved_dt') IS NULL
             AND COL_LENGTH('grac_practice.tprm_engagement', 'app_access_answer') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '522 rollback: DRAFT value and 521 navigation back',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.tprm_reference_value
                          WHERE organization_id IS NULL AND list_code = N'TP_STATUS' AND value_code = N'DRAFT')
             AND EXISTS (SELECT 1 FROM grac_practice.menu_master c JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
                          WHERE c.menu_key = N'tprm-configuration' AND p.menu_key = N'nav-tprm')
            THEN 'PASS' ELSE 'FAIL' END;
GO

PRINT '522 rollback complete.';
GO
