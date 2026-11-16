-- =====================================================================
-- 522_tpm_cr2_registration_exposure.sql
--
-- REQUEST (2026-11-08)
-- --------------------
--   "Change Document -- GRAC Third-Party Management (TPM) Redesign"
--   (CR 2). Design and phase plan: docs/tpm-lifecycle-redesign.md. This
--   file is ROUND A -- CR 2 sections 3, 4 and 5: lightweight vendor
--   registration with immediate activation, progressive vendor
--   information, the engagement initial form, progressive exposure
--   capture, and the CR 2 menu structure. Screening, the applicability
--   decision and admission (Round B) and the TP Risk Register (Round C)
--   follow in later migrations.
--
-- WHAT CHANGES
-- ------------
--   1. Registration activates (CR 2 4.2). A new vendor is ACTIVE on save
--      -- no approval, no separate activation step -- and the audit trail
--      records CREATE and ACTIVATE. The DRAFT state of 521 is retired:
--      DRAFT vendors become ACTIVE, the baseline DRAFT value is deleted,
--      organization values of meaning DRAFT are retired, and TP_STATUS
--      allows ACTIVE / INACTIVE / SUSPENDED / ARCHIVED.
--   2. Registration fields (CR 2 4.1): relationship owner, country and a
--      primary contact with an e-mail address are mandatory on every
--      vendor save, beside legal name and primary service category.
--   3. Vendor transitions without DRAFT; RESTORE returns to INACTIVE;
--      "mark as duplicate" is allowed from any non-archived state when
--      the vendor has no open engagement.
--   4. Engagement initial form (CR 2 5.1): sp_tprm_engagement_save holds
--      the core and administrative fields only, with the CR 2 mandatory
--      set; service criticality is no longer asked at creation; a new
--      engagement needs an ACTIVE vendor.
--   5. Progressive exposure (CR 2 5.2, 5.3): eight gating answers
--      (YES / NO / UNKNOWN) and the exposure fields are saved by the new
--      sp_tprm_engagement_exposure_save, which keeps only the dimensions
--      answered Yes, saves the proposed scope items as one set, derives
--      the data exposure from the data categories and records when Scope
--      & Exposure was saved (the Round B screening trigger). Proposed
--      scope items are no longer added one at a time
--      (sp_tprm_scope_item_save / _remove refuse PROPOSED). An inherent
--      risk assessment needs Scope & Exposure saved.
--   6. Navigation (CR 2 3): "Engagement Management"; the dashboard and
--      Reviews & Monitoring leave the sidebar (show_in_sidebar = 0, 390 --
--      still reachable); Configuration moves to Settings as "Third-Party
--      Settings". 274_menu_master_seed.sql carries the same.
--
-- RUN ORDER
-- ---------
--   After 521. Re-running 487 (regenerated for 522: TP_STATUS without
--   DRAFT) is recommended but not required -- this file updates the
--   TP_STATUS list itself. After 522, 521 refuses to run again.
--
-- ERROR NUMBERS: 58050-58099.
-- DEPENDS ON: 486-490, 507, 521; 390 (menu_master.show_in_sidebar).
-- Rollback: 522_tpm_cr2_registration_exposure_rollback.sql
-- SAFE TO RE-RUN. ASCII-only. SQL Server 2017+.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.tprm_vendor_match_review','U') IS NULL
   OR COL_LENGTH('grac_practice.tprm_third_party', 'first_activated_dt') IS NULL
   OR COL_LENGTH('grac_practice.tprm_engagement', 'service_recipient') IS NULL
BEGIN PRINT 'ABORT (522): run 521_tpm_vendor_registry_foundation.sql first.'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.menu_master', 'show_in_sidebar') IS NULL
BEGIN PRINT 'ABORT (522): run 390_home_route_and_my_work_on_home.sql first (menu_master.show_in_sidebar).'; SET @ok = 0; END
-- 523 re-issues several of these procedures (screening on save, admission
-- gate); running 522 again would take that out.
IF COL_LENGTH('grac_practice.tprm_engagement', 'applicability_status') IS NOT NULL
BEGIN PRINT 'ABORT (522): superseded by 523_tpm_cr2_screening_admission.sql, which is already applied. Do not re-run 522.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('522_tpm_cr2_registration_exposure: prerequisites missing -- see the messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Schema: gating answers and exposure columns (CR 2 5.2, 5.3)
-- =====================================================================
-- Each answer: YES (the dimension applies -- its details are asked),
-- NO (it does not -- its details are not kept), UNKNOWN (not sure yet --
-- an information gap for the screening), NULL (not answered).
IF COL_LENGTH('grac_practice.tprm_engagement', 'app_access_answer') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD app_access_answer NVARCHAR(10) NULL
        CONSTRAINT ck_pm_tprm_eng_ans_app CHECK (app_access_answer IN (N'YES', N'NO', N'UNKNOWN'));
IF COL_LENGTH('grac_practice.tprm_engagement', 'premises_access_answer') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD premises_access_answer NVARCHAR(10) NULL
        CONSTRAINT ck_pm_tprm_eng_ans_premises CHECK (premises_access_answer IN (N'YES', N'NO', N'UNKNOWN'));
IF COL_LENGTH('grac_practice.tprm_engagement', 'data_processing_answer') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD data_processing_answer NVARCHAR(10) NULL
        CONSTRAINT ck_pm_tprm_eng_ans_data CHECK (data_processing_answer IN (N'YES', N'NO', N'UNKNOWN'));
IF COL_LENGTH('grac_practice.tprm_engagement', 'subcontracting_answer') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD subcontracting_answer NVARCHAR(10) NULL
        CONSTRAINT ck_pm_tprm_eng_ans_sub CHECK (subcontracting_answer IN (N'YES', N'NO', N'UNKNOWN'));
IF COL_LENGTH('grac_practice.tprm_engagement', 'important_process_answer') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD important_process_answer NVARCHAR(10) NULL
        CONSTRAINT ck_pm_tprm_eng_ans_process CHECK (important_process_answer IN (N'YES', N'NO', N'UNKNOWN'));
IF COL_LENGTH('grac_practice.tprm_engagement', 'disruption_impact_answer') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD disruption_impact_answer NVARCHAR(10) NULL
        CONSTRAINT ck_pm_tprm_eng_ans_disruption CHECK (disruption_impact_answer IN (N'YES', N'NO', N'UNKNOWN'));
IF COL_LENGTH('grac_practice.tprm_engagement', 'service_commitment_answer') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD service_commitment_answer NVARCHAR(10) NULL
        CONSTRAINT ck_pm_tprm_eng_ans_sla CHECK (service_commitment_answer IN (N'YES', N'NO', N'UNKNOWN'));
IF COL_LENGTH('grac_practice.tprm_engagement', 'contract_answer') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD contract_answer NVARCHAR(10) NULL
        CONSTRAINT ck_pm_tprm_eng_ans_contract CHECK (contract_answer IN (N'YES', N'NO', N'UNKNOWN'));
-- Data processing details (CR 2 5.3: "request data categories and
-- processing details"); contract validity and related documents (CR 2
-- 5.2 "Contractual Information").
IF COL_LENGTH('grac_practice.tprm_engagement', 'data_processing_details') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD data_processing_details NVARCHAR(2000) NULL;
IF COL_LENGTH('grac_practice.tprm_engagement', 'contract_start_dt') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD contract_start_dt DATE NULL;
IF COL_LENGTH('grac_practice.tprm_engagement', 'contract_end_dt') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD contract_end_dt DATE NULL;
IF COL_LENGTH('grac_practice.tprm_engagement', 'contract_documents') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD contract_documents NVARCHAR(1000) NULL;
-- When Scope & Exposure was last saved (CR 2 6.1: the screening trigger).
IF COL_LENGTH('grac_practice.tprm_engagement', 'exposure_saved_dt') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD exposure_saved_dt DATETIME2 NULL;
IF COL_LENGTH('grac_practice.tprm_engagement', 'exposure_saved_by') IS NULL
    ALTER TABLE grac_practice.tprm_engagement ADD exposure_saved_by NVARCHAR(100) NULL;
GO
PRINT '522: engagement gating answers and exposure columns ready.';
GO

-- =====================================================================
-- 2. Vendor states: DRAFT retired (CR 2 4.2 -- registration activates)
-- =====================================================================
-- 2a. Vendors on a DRAFT meaning move to the organization's ACTIVE value
--     (read while the DRAFT values still exist).
DECLARE @moved TABLE (third_party_id BIGINT PRIMARY KEY, old_code NVARCHAR(60), new_code NVARCHAR(60));
UPDATE t
   SET lifecycle_status_code = ISNULL(grac_practice.fn_tprm_meaning_code(t.organization_id, N'TP_STATUS', N'ACTIVE'), N'ACTIVE'),
       first_activated_dt = ISNULL(t.first_activated_dt, SYSUTCDATETIME()),
       updated_by = N'migration-522', updated_dt = SYSUTCDATETIME()
OUTPUT inserted.third_party_id, deleted.lifecycle_status_code, inserted.lifecycle_status_code INTO @moved
FROM grac_practice.tprm_third_party t
WHERE t.status = N'Active'
  AND grac_practice.fn_tprm_vendor_status_meaning(t.organization_id, t.lifecycle_status_code) = N'DRAFT';
INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor)
SELECT m.third_party_id, m.old_code, m.new_code,
       N'Draft retired: registration now activates the vendor (migration 522, CR 2 4.2).', 1, N'migration-522'
FROM @moved m;
PRINT CONCAT('522: draft vendors activated: ', @@ROWCOUNT);

-- 2b. Every registered vendor has been active since registration: a later
--     RESTORE returns to INACTIVE (archived drafts included).
UPDATE grac_practice.tprm_third_party
   SET first_activated_dt = COALESCE(updated_dt, entered_dt)
 WHERE first_activated_dt IS NULL;
GO

-- 2c. Organization values of meaning DRAFT are retired (their codes stay
--     readable in the history); overrides of the baseline DRAFT value and
--     the value itself are removed.
UPDATE grac_practice.tprm_reference_value
   SET status = N'Retired', updated_by = N'migration-522', updated_dt = SYSUTCDATETIME()
 WHERE list_code = N'TP_STATUS' AND organization_id IS NOT NULL AND baseline_value_id IS NULL
   AND meaning_code = N'DRAFT' AND status <> N'Retired';
IF @@ROWCOUNT > 0 PRINT '522: organization TP_STATUS values of meaning DRAFT retired.';
DELETE o FROM grac_practice.tprm_reference_value o
JOIN grac_practice.tprm_reference_value b ON b.value_id = o.baseline_value_id
WHERE b.organization_id IS NULL AND b.list_code = N'TP_STATUS' AND b.value_code = N'DRAFT';
DELETE FROM grac_practice.tprm_reference_value
 WHERE organization_id IS NULL AND list_code = N'TP_STATUS' AND value_code = N'DRAFT';
IF @@ROWCOUNT > 0 PRINT '522: baseline TP_STATUS value DRAFT removed.';

-- 2d. The list's meanings (487 regenerated carries the same).
UPDATE grac_practice.tprm_reference_list
   SET allowed_meanings = N'ACTIVE,INACTIVE,SUSPENDED,ARCHIVED',
       description = N'Lifecycle status of a vendor in the Vendor Registry. Registration activates the vendor (522); activation is not a TPRM assessment or admission. Each value maps to a lifecycle meaning; the transitions between meanings are fixed (fn_tprm_vendor_transitions).',
       updated_by = N'migration-522', updated_dt = SYSUTCDATETIME()
 WHERE list_code = N'TP_STATUS' AND ISNULL(allowed_meanings, N'') <> N'ACTIVE,INACTIVE,SUSPENDED,ARCHIVED';
GO

-- =====================================================================
-- 3. Vendor lifecycle transitions (CR 2 4.2: no DRAFT)
-- =====================================================================
-- The changes allowed from a vendor's current state, each with the
-- screen permission it needs (the Web tier checks APPROVE) and, when it
-- is blocked, why.
--   ACTIVE    -> SUSPENDED (SUSPEND) | INACTIVE (INACTIVATE: no open engagement)
--   SUSPENDED -> ACTIVE (REINSTATE) | INACTIVE (INACTIVATE: no open engagement)
--   INACTIVE  -> ACTIVE (REACTIVATE: registration fields complete) | ARCHIVED (ARCHIVE)
--   ARCHIVED  -> INACTIVE (RESTORE)
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_vendor_transitions (@organization_id BIGINT, @third_party_id BIGINT)
RETURNS TABLE
AS
RETURN
(
WITH g AS (
    SELECT t.third_party_id, t.organization_id,
           grac_practice.fn_tprm_vendor_status_meaning(t.organization_id, t.lifecycle_status_code) AS meaning,
           (SELECT COUNT(*) FROM grac_practice.tprm_engagement e
             WHERE e.third_party_id = t.third_party_id AND e.stage_code NOT IN (N'EXITED', N'REJECTED', N'CANCELLED')) AS open_engagements,
           NULLIF(CONCAT_WS(N', ',
               CASE WHEN t.primary_service_category_code IS NULL THEN N'primary service category' END,
               CASE WHEN NULLIF(LTRIM(RTRIM(t.country)), N'') IS NULL THEN N'country' END,
               CASE WHEN t.relationship_owner_employee_id IS NULL THEN N'relationship owner' END,
               CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party_contact ct
                                      WHERE ct.third_party_id = t.third_party_id AND ct.status = N'Active' AND ct.is_primary = 1
                                        AND NULLIF(LTRIM(RTRIM(ct.email)), N'') IS NOT NULL)
                    THEN N'a primary contact with an e-mail address' END), N'') AS missing
    FROM   grac_practice.tprm_third_party t
    WHERE  t.third_party_id = @third_party_id
      AND  t.organization_id = @organization_id
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
        (N'ACTIVE',    N'SUSPEND',    N'SUSPENDED', N'APPROVE', 20),
        (N'ACTIVE',    N'INACTIVATE', N'INACTIVE',  N'APPROVE', 30),
        (N'SUSPENDED', N'REINSTATE',  N'ACTIVE',    N'APPROVE', 10),
        (N'SUSPENDED', N'INACTIVATE', N'INACTIVE',  N'APPROVE', 30),
        (N'INACTIVE',  N'REACTIVATE', N'ACTIVE',    N'APPROVE', 10),
        (N'INACTIVE',  N'ARCHIVE',    N'ARCHIVED',  N'APPROVE', 90),
        (N'ARCHIVED',  N'RESTORE',    N'INACTIVE',  N'APPROVE', 10)
       ) x(from_meaning, action_code, to_meaning, permission, sort_no)
CROSS  APPLY (SELECT CASE
        WHEN x.action_code = N'REACTIVATE' AND g.missing IS NOT NULL
             THEN CAST(CONCAT(N'Complete the registration first: ', g.missing, N'.') AS NVARCHAR(400))
        WHEN x.action_code IN (N'INACTIVATE', N'ARCHIVE') AND g.open_engagements > 0
             THEN CAST(CONCAT(N'Close, exit or cancel its ', g.open_engagements, N' open engagement(s) first.') AS NVARCHAR(400))
        END AS block_reason) b
WHERE  x.from_meaning = g.meaning
);
GO

-- =====================================================================
-- 4. Vendor Registry: registration and duplicate review
-- =====================================================================
-- Register / update a vendor (CR 2 4.1, 4.2). Mandatory on every save:
-- legal name, primary service category, relationship owner, country and
-- one primary contact with a name and an e-mail address. A NEW vendor is
-- ACTIVE at once -- no approval -- and the audit trail records CREATE
-- and ACTIVATE. Activation makes the vendor available for engagements;
-- it is not a TPRM assessment, approval or admission.
-- Result: one row (ThirdPartyId, Result). Result DUPLICATES = nothing was
-- saved; a second result set lists the possible duplicates that still
-- need a review. Save again with @match_reviews_json giving, for each of
-- them, why it is a different vendor; the reviews are recorded
-- (tprm_vendor_match_review, NOT_DUPLICATE) with the save.
--   @categories_csv     : SERVICE_CATEGORY codes (the primary one is added)
--   @contacts_json      : [{"contactId":null,"name","role","email","phone","isPrimary"}] -- the full list
--   @custom_json        : see sp_tprm_custom_values_save
--   @match_reviews_json : [{"matchId":123,"rationale":"..."}]
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
    SET @country = NULLIF(LTRIM(RTRIM(@country)), N'');

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
    -- 522 (CR 2 4.1): relationship owner and country are registration fields.
    IF @relationship_owner_employee_id IS NULL THROW 58050, 'Choose the relationship owner.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                    WHERE employee_id = @relationship_owner_employee_id AND organization_id = @organization_id AND status = N'Active')
        THROW 57607, 'The relationship owner must be an active employee of this organization.', 1;
    IF @country IS NULL THROW 58051, 'Country is required.', 1;
    IF @year_established IS NOT NULL AND (@year_established < 1800 OR @year_established > YEAR(SYSUTCDATETIME()))
        THROW 57608, 'Year established is not valid.', 1;
    IF @contacts_json IS NOT NULL AND ISJSON(@contacts_json) <> 1 THROW 57609, 'Contacts are not valid.', 1;
    IF @contacts_json IS NOT NULL AND EXISTS (SELECT 1 FROM OPENJSON(@contacts_json) WITH (name NVARCHAR(200) '$.name') WHERE NULLIF(LTRIM(RTRIM(name)), N'') IS NULL)
        THROW 57610, 'Every contact needs a name.', 1;
    IF @match_reviews_json IS NOT NULL AND ISJSON(@match_reviews_json) <> 1 THROW 58000, 'The duplicate reviews are not valid.', 1;

    -- 522 (CR 2 4.1): one primary contact with a name and an e-mail
    -- address, from the list given or, when none is given, the stored one.
    DECLARE @primaries INT, @primary_ok INT;
    IF @contacts_json IS NOT NULL
        SELECT @primaries = COUNT(*),
               @primary_ok = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(j.email)), N'') IS NOT NULL THEN 1 ELSE 0 END)
        FROM OPENJSON(@contacts_json) WITH (email NVARCHAR(250) '$.email', isPrimary BIT '$.isPrimary') j
        WHERE ISNULL(j.isPrimary, 0) = 1;
    ELSE
        SELECT @primaries = COUNT(*),
               @primary_ok = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(c.email)), N'') IS NOT NULL THEN 1 ELSE 0 END)
        FROM grac_practice.tprm_third_party_contact c
        WHERE c.third_party_id = @third_party_id AND c.status = N'Active' AND c.is_primary = 1;
    IF ISNULL(@primaries, 0) > 1 THROW 58054, 'Only one contact can be the primary contact.', 1;
    IF ISNULL(@primary_ok, 0) = 0 THROW 58052, 'Give the primary contact''s name and e-mail address.', 1;
    DECLARE @bad_email NVARCHAR(250);
    SELECT TOP (1) @bad_email = LTRIM(RTRIM(j.email))
    FROM OPENJSON(ISNULL(@contacts_json, N'[]')) WITH (email NVARCHAR(250) '$.email') j
    WHERE NULLIF(LTRIM(RTRIM(j.email)), N'') IS NOT NULL
      AND (LTRIM(RTRIM(j.email)) NOT LIKE N'%_@_%._%' OR CHARINDEX(N' ', LTRIM(RTRIM(j.email))) > 0);
    IF @bad_email IS NOT NULL
    BEGIN
        DECLARE @email_msg NVARCHAR(400) = CONCAT(N'"', @bad_email, N'" is not a valid e-mail address.');
        THROW 58053, @email_msg, 1;
    END

    DECLARE @current_meaning NVARCHAR(40);
    IF @third_party_id IS NOT NULL
    BEGIN
        DECLARE @rv BIGINT;
        SELECT @rv = CONVERT(BIGINT, record_version),
               @current_meaning = grac_practice.fn_tprm_vendor_status_meaning(organization_id, lifecycle_status_code)
        FROM grac_practice.tprm_third_party
         WHERE third_party_id = @third_party_id AND organization_id = @organization_id;
        IF @rv IS NULL THROW 57601, 'That vendor was not found.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 57611, 'Someone else changed this vendor. Reload and try again.', 1;
        IF @current_meaning = N'ARCHIVED' THROW 58001, 'An archived vendor cannot be changed. Restore it first.', 1;
    END

    -- CR 2 4.2-1: possible duplicates are identified before registration
    -- and reviewed, never silently merged. Matches already reviewed for
    -- this vendor do not ask again.
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

        -- CR 2 4.2-3: activated immediately, no approval workflow.
        INSERT grac_practice.tprm_third_party
            (organization_id, third_party_code, legal_name, trading_name, normalized_name, registration_number, tax_id, lei_code,
             provider_type_code, primary_service_category_code, reporting_category_code, country, state_region, city, address,
             website, parent_company, year_established, employee_count_band, annual_revenue_band, certifications_text, profile_notes,
             lifecycle_status_code, first_activated_dt, relationship_owner_employee_id, entered_by)
        VALUES (@organization_id, @code, @legal_name, NULLIF(LTRIM(RTRIM(@trading_name)), N''), grac_practice.fn_tprm_normalize_name(@legal_name),
                NULLIF(LTRIM(RTRIM(@registration_number)), N''), NULLIF(LTRIM(RTRIM(@tax_id)), N''), NULLIF(LTRIM(RTRIM(@lei_code)), N''),
                @provider_type_code, @primary_service_category_code, @reporting_category_code, @country, @state_region, @city, @address,
                @website, @parent_company, @year_established, @employee_count_band, @annual_revenue_band, @certifications_text, @profile_notes,
                ISNULL(grac_practice.fn_tprm_meaning_code(@organization_id, N'TP_STATUS', N'ACTIVE'), N'ACTIVE'), SYSUTCDATETIME(),
                @relationship_owner_employee_id, @actor);
        SET @id = SCOPE_IDENTITY();
        SET @created = 1;
        INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor_employee_id, actor)
        SELECT @id, NULL, lifecycle_status_code,
               N'Registered and activated in the Vendor Registry. Activation makes the vendor available for engagements; it is not a TPRM assessment, approval or admission.',
               0, @actor_employee_id, @actor
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
        UPDATE c SET contact_name = LTRIM(RTRIM(j.name)), contact_role = j.role, email = NULLIF(LTRIM(RTRIM(j.email)), N''),
                     phone = j.phone, is_primary = ISNULL(j.isPrimary, 0), updated_by = @actor, updated_dt = SYSUTCDATETIME()
        FROM grac_practice.tprm_third_party_contact c
        JOIN OPENJSON(@contacts_json) WITH (contactId BIGINT '$.contactId', name NVARCHAR(200) '$.name', role NVARCHAR(150) '$.role',
                                            email NVARCHAR(250) '$.email', phone NVARCHAR(60) '$.phone', isPrimary BIT '$.isPrimary') j
             ON j.contactId = c.contact_id
        WHERE c.third_party_id = @id;
        INSERT grac_practice.tprm_third_party_contact (third_party_id, organization_id, contact_name, contact_role, email, phone, is_primary, entered_by)
        SELECT @id, @organization_id, LTRIM(RTRIM(j.name)), j.role, NULLIF(LTRIM(RTRIM(j.email)), N''), j.phone, ISNULL(j.isPrimary, 0), @actor
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
    IF @created = 1
    BEGIN
        -- CR 2 4.2-6: registration and activation are both in the audit history.
        EXEC grac_practice.sp_tprm_audit N'tprm-third-party', @id, N'CREATE', @legal_name, @actor;
        DECLARE @activate_detail NVARCHAR(2000) = N'Activated on registration (no approval). Not a TPRM assessment or admission.';
        EXEC grac_practice.sp_tprm_audit N'tprm-third-party', @id, N'ACTIVATE', @activate_detail, @actor;
    END
    ELSE
        EXEC grac_practice.sp_tprm_audit N'tprm-third-party', @id, N'UPDATE', @legal_name, @actor;
    IF @reviewed > 0
    BEGIN
        DECLARE @review_detail NVARCHAR(2000) = CONCAT(@reviewed, N' possible duplicate(s) reviewed as different vendors.');
        EXEC grac_practice.sp_tprm_audit N'tprm-third-party', @id, N'DUPLICATE_REVIEW', @review_detail, @actor;
    END
    SELECT @id AS ThirdPartyId, CASE WHEN @created = 1 THEN N'CREATED' ELSE N'SAVED' END AS Result;
END
GO

-- Review a possible duplicate from the vendor's page (521; CR 2 4.2-1).
--   NOT_DUPLICATE : the two are different vendors; both stay.
--   DUPLICATE     : @third_party_id is a duplicate of @matched_third_party_id.
--                   It is archived with duplicate_of_third_party_id set;
--                   nothing is merged or moved. It must have no open
--                   engagement (move the work to the other vendor first).
--                   522: allowed from any non-archived state (a vendor is
--                   active from registration, so 521's draft / inactive
--                   gate would always block a just-registered duplicate).
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

-- =====================================================================
-- 5. Engagement Management (CR 2 5)
-- =====================================================================
-- Identity of a proposed scope item, used to save the Scope & Exposure
-- page as one set: a GRAC record by its id, a list value by its code, a
-- location or fourth party by name and country, anything else by its name.
CREATE OR ALTER FUNCTION grac_practice.fn_tprm_scope_item_key
    (@item_kind NVARCHAR(30), @ref_id BIGINT, @item_code NVARCHAR(60), @item_name NVARCHAR(300), @country NVARCHAR(120))
RETURNS NVARCHAR(500)
AS
BEGIN
    RETURN CONCAT(@item_kind, N'|',
        CASE WHEN @item_kind IN (N'BUSINESS_FUNCTION', N'PROCESS', N'APPLICATION') AND @ref_id IS NOT NULL THEN CONCAT(N'#', @ref_id)
             WHEN @item_kind IN (N'DATA_CATEGORY', N'ACCESS') THEN @item_code
             WHEN @item_kind IN (N'LOCATION', N'FOURTH_PARTY') THEN CONCAT(UPPER(LTRIM(RTRIM(@item_name))), N'|', UPPER(LTRIM(RTRIM(ISNULL(@country, N'')))))
             ELSE UPPER(LTRIM(RTRIM(@item_name))) END);
END
GO

-- A material change on an approved or live engagement (488 / 521 rule,
-- shared by the core save and the exposure save): flags the engagement
-- for reassessment and logs MATERIAL_CHANGE. @flagged = 1 when it did.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_flag_material
    @engagement_id     BIGINT,
    @stage             NVARCHAR(30),
    @material          NVARCHAR(1000),
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system',
    @flagged           BIT           = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @flagged = 0;
    SET @material = NULLIF(LTRIM(RTRIM(@material)), N'');
    IF @material IS NULL OR ISNULL(@stage, N'') NOT IN (N'APPROVED', N'ONBOARDING', N'ACTIVE', N'SUSPENDED') RETURN;
    UPDATE grac_practice.tprm_engagement
       SET reassessment_required = 1,
           reassessment_reason = LEFT(CONCAT(N'Material change: ', @material), 1000)
     WHERE engagement_id = @engagement_id;
    DECLARE @detail NVARCHAR(2000) = CONCAT(N'Material change: ', @material);
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'MATERIAL_CHANGE', @stage, @stage, @detail, @actor_employee_id, @actor;
    SET @flagged = 1;
END
GO

-- Answers the gating questions that are still empty from what an
-- engagement already records (migration backfill and sample records):
-- a Yes where details exist, a No for data when the data exposure is the
-- rank-0 value; otherwise left unanswered. A data exposure recorded
-- without its data category gets the category as a proposed scope item,
-- so the derived data exposure (sp_tprm_engagement_exposure_save) keeps
-- it. The baseline ACCESS_CATEGORY codes PHYSICAL (premises) and NONE
-- are read by code.
--   @engagement_id NULL = every engagement
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_answers_derive
    @engagement_id BIGINT        = NULL,
    @actor         NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    INSERT grac_practice.tprm_engagement_scope (engagement_id, organization_id, item_kind, exposure_mode, item_code, item_name, entered_by)
    SELECT e.engagement_id, e.organization_id, N'DATA_CATEGORY', N'PROPOSED', e.data_exposure_code, dx.label, ISNULL(@actor, N'system')
    FROM   grac_practice.tprm_engagement e
    CROSS  APPLY (SELECT TOP (1) v.label, v.rank_no FROM grac_practice.fn_tprm_reference_effective(e.organization_id) v
                  WHERE v.list_code = N'DATA_EXPOSURE' AND v.value_code = e.data_exposure_code) dx
    WHERE  (@engagement_id IS NULL OR e.engagement_id = @engagement_id)
      AND  ISNULL(dx.rank_no, 0) > 0
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope s
                        WHERE s.engagement_id = e.engagement_id AND s.item_kind = N'DATA_CATEGORY' AND s.exposure_mode = N'PROPOSED'
                          AND s.status = N'Active' AND s.item_code = e.data_exposure_code);

    ;WITH items AS (
        SELECT s.engagement_id, s.item_kind, s.item_code, ISNULL(r.rank_no, 0) AS rank_no
        FROM   grac_practice.tprm_engagement_scope s
        OUTER  APPLY (SELECT TOP (1) v.rank_no FROM grac_practice.fn_tprm_reference_effective(s.organization_id) v
                      WHERE v.list_code = CASE s.item_kind WHEN N'DATA_CATEGORY' THEN N'DATA_EXPOSURE' ELSE N'ACCESS_CATEGORY' END
                        AND v.value_code = s.item_code) r
        WHERE  s.exposure_mode = N'PROPOSED' AND s.status = N'Active'
          AND  (@engagement_id IS NULL OR s.engagement_id = @engagement_id)
    )
    UPDATE e
       SET app_access_answer = ISNULL(e.app_access_answer,
               CASE WHEN EXISTS (SELECT 1 FROM items i WHERE i.engagement_id = e.engagement_id
                                   AND (i.item_kind = N'APPLICATION'
                                        OR (i.item_kind = N'ACCESS' AND ISNULL(i.item_code, N'') NOT IN (N'NONE', N'PHYSICAL'))))
                    THEN N'YES' END),
           premises_access_answer = ISNULL(e.premises_access_answer,
               CASE WHEN EXISTS (SELECT 1 FROM items i WHERE i.engagement_id = e.engagement_id
                                   AND i.item_kind = N'ACCESS' AND i.item_code = N'PHYSICAL') THEN N'YES' END),
           data_processing_answer = ISNULL(e.data_processing_answer,
               CASE WHEN EXISTS (SELECT 1 FROM items i WHERE i.engagement_id = e.engagement_id
                                   AND i.item_kind = N'DATA_CATEGORY' AND i.rank_no > 0) THEN N'YES'
                    WHEN dx.rank_no = 0 THEN N'NO' END),
           subcontracting_answer = ISNULL(e.subcontracting_answer,
               CASE WHEN EXISTS (SELECT 1 FROM items i WHERE i.engagement_id = e.engagement_id AND i.item_kind = N'FOURTH_PARTY')
                    THEN N'YES' END),
           important_process_answer = ISNULL(e.important_process_answer,
               CASE WHEN EXISTS (SELECT 1 FROM items i WHERE i.engagement_id = e.engagement_id
                                   AND i.item_kind IN (N'BUSINESS_FUNCTION', N'PROCESS')) THEN N'YES' END),
           disruption_impact_answer = ISNULL(e.disruption_impact_answer,
               CASE WHEN e.customer_impact_code IS NOT NULL OR e.substitutability_code IS NOT NULL
                         OR NULLIF(LTRIM(RTRIM(e.exit_dependencies)), N'') IS NOT NULL THEN N'YES' END),
           service_commitment_answer = ISNULL(e.service_commitment_answer,
               CASE WHEN NULLIF(LTRIM(RTRIM(e.sla_summary)), N'') IS NOT NULL OR e.rto_hours IS NOT NULL OR e.rpo_hours IS NOT NULL
                    THEN N'YES' END),
           contract_answer = ISNULL(e.contract_answer,
               CASE WHEN e.contract_id IS NOT NULL OR NULLIF(LTRIM(RTRIM(e.contract_reference)), N'') IS NOT NULL
                         OR e.contract_value IS NOT NULL OR e.renewal_dt IS NOT NULL THEN N'YES' END)
    FROM   grac_practice.tprm_engagement e
    OUTER  APPLY (SELECT TOP (1) v.rank_no FROM grac_practice.fn_tprm_reference_effective(e.organization_id) v
                  WHERE v.list_code = N'DATA_EXPOSURE' AND v.value_code = e.data_exposure_code) dx
    WHERE  (@engagement_id IS NULL OR e.engagement_id = @engagement_id);

    -- The data exposure follows the data categories from now on (the rule
    -- of sp_tprm_engagement_exposure_save): align it here, so the first
    -- save of the page does not report a change nobody made.
    UPDATE e
       SET data_exposure_code = top_item.item_code
    FROM   grac_practice.tprm_engagement e
    CROSS  APPLY (SELECT TOP (1) s.item_code
                  FROM grac_practice.tprm_engagement_scope s
                  OUTER APPLY (SELECT TOP (1) v.rank_no, v.display_order FROM grac_practice.fn_tprm_reference_effective(s.organization_id) v
                               WHERE v.list_code = N'DATA_EXPOSURE' AND v.value_code = s.item_code) r
                  WHERE s.engagement_id = e.engagement_id AND s.item_kind = N'DATA_CATEGORY' AND s.exposure_mode = N'PROPOSED'
                    AND s.status = N'Active' AND s.item_code IS NOT NULL
                  ORDER BY ISNULL(r.rank_no, 0) DESC, ISNULL(r.display_order, 9999)) top_item
    WHERE  (@engagement_id IS NULL OR e.engagement_id = @engagement_id)
      AND  e.data_processing_answer = N'YES'
      AND  ISNULL(e.data_exposure_code, N'') <> top_item.item_code;
END
GO

-- Result sets: 1 header  2 scope  3 links  4 snapshots  5 history
--              6 custom values  7 dimensions of the current assessment
-- (re-issued by 522: the gating answers and exposure columns of CR 2 5.2)
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
           e.currency_code AS CurrencyCode, e.contract_start_dt AS ContractStartDt, e.contract_end_dt AS ContractEndDt,
           e.contract_documents AS ContractDocuments,
           e.proposed_start_dt AS ProposedStartDt, e.proposed_end_dt AS ProposedEndDt,
           e.actual_start_dt AS ActualStartDt, e.actual_end_dt AS ActualEndDt, e.renewal_dt AS RenewalDt,
           e.business_owner_employee_id AS BusinessOwnerEmployeeId, bo.employee_name AS BusinessOwnerName,
           e.relationship_owner_employee_id AS RelationshipOwnerEmployeeId, ro.employee_name AS RelationshipOwnerName,
           e.assessor_employee_id AS AssessorEmployeeId, ae.employee_name AS AssessorName,
           e.service_criticality_code AS CriticalityCode, cr.label AS Criticality, cr.color_hex AS CriticalityColor,
           e.data_exposure_code AS DataExposureCode, de.label AS DataExposure, e.data_processing_details AS DataProcessingDetails,
           e.rto_hours AS RtoHours, e.rpo_hours AS RpoHours, e.sla_summary AS SlaSummary,
           e.service_recipient AS ServiceRecipient, e.substitutability_code AS SubstitutabilityCode, sb.label AS Substitutability,
           e.customer_impact_code AS CustomerImpactCode, ci.label AS CustomerImpact, e.exit_dependencies AS ExitDependencies,
           e.app_access_answer AS AppAccessAnswer, e.premises_access_answer AS PremisesAccessAnswer,
           e.data_processing_answer AS DataProcessingAnswer, e.subcontracting_answer AS SubcontractingAnswer,
           e.important_process_answer AS ImportantProcessAnswer, e.disruption_impact_answer AS DisruptionImpactAnswer,
           e.service_commitment_answer AS ServiceCommitmentAnswer, e.contract_answer AS ContractAnswer,
           e.exposure_saved_dt AS ExposureSavedDt, e.exposure_saved_by AS ExposureSavedBy,
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

-- Create / update an engagement -- the initial form (CR 2 5.1) and the
-- administrative fields. Re-issued by 522: the exposure fields moved to
-- sp_tprm_engagement_exposure_save. Mandatory: engagement name, service
-- category, service description, business purpose, service recipient,
-- engagement type, service model, delivery location, proposed start date,
-- relationship owner. A new engagement needs an ACTIVE vendor. On an
-- approved or live engagement a change of service model or delivery
-- locations is a material change (sp_tprm_engagement_flag_material).
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_save
    @organization_id               BIGINT,
    @engagement_id                 BIGINT         = NULL,
    @third_party_id                BIGINT         = NULL,
    @engagement_title              NVARCHAR(250),
    @service_category_code         NVARCHAR(60)   = NULL,
    @service_description           NVARCHAR(2000) = NULL,
    @business_purpose              NVARCHAR(1000) = NULL,
    @service_recipient             NVARCHAR(250)  = NULL,
    @engagement_type_code          NVARCHAR(60)   = NULL,
    @service_model_code            NVARCHAR(60)   = NULL,
    @delivery_locations            NVARCHAR(1000) = NULL,
    @proposed_start_dt             DATE           = NULL,
    @proposed_end_dt               DATE           = NULL,
    @relationship_owner_employee_id BIGINT        = NULL,
    @scope_description             NVARCHAR(2000) = NULL,
    @is_existing                   BIT            = 0,
    @business_owner_employee_id    BIGINT         = NULL,
    @assessor_employee_id          BIGINT         = NULL,
    @actual_start_dt               DATE           = NULL,
    @actual_end_dt                 DATE           = NULL,
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
    IF @engagement_title IS NULL THROW 57631, 'Engagement name is required.', 1;
    SELECT @service_category_code = NULLIF(LTRIM(RTRIM(@service_category_code)), N''),
           @service_description = NULLIF(LTRIM(RTRIM(@service_description)), N''),
           @business_purpose = NULLIF(LTRIM(RTRIM(@business_purpose)), N''),
           @service_recipient = NULLIF(LTRIM(RTRIM(@service_recipient)), N''),
           @engagement_type_code = NULLIF(LTRIM(RTRIM(@engagement_type_code)), N''),
           @service_model_code = NULLIF(LTRIM(RTRIM(@service_model_code)), N''),
           @delivery_locations = NULLIF(LTRIM(RTRIM(@delivery_locations)), N'');

    -- CR 2 5.1: the mandatory initial information.
    DECLARE @missing NVARCHAR(400) = NULLIF(CONCAT_WS(N', ',
        CASE WHEN @service_category_code IS NULL THEN N'service category' END,
        CASE WHEN @service_description IS NULL THEN N'service description' END,
        CASE WHEN @business_purpose IS NULL THEN N'business purpose' END,
        CASE WHEN @service_recipient IS NULL THEN N'service recipient' END,
        CASE WHEN @engagement_type_code IS NULL THEN N'engagement type' END,
        CASE WHEN @service_model_code IS NULL THEN N'service model' END,
        CASE WHEN @delivery_locations IS NULL THEN N'delivery location' END,
        CASE WHEN @proposed_start_dt IS NULL THEN N'proposed start date' END,
        CASE WHEN @relationship_owner_employee_id IS NULL THEN N'relationship owner' END), N'');
    IF @missing IS NOT NULL
    BEGIN
        DECLARE @missing_msg NVARCHAR(500) = CONCAT(N'Complete the required fields: ', @missing, N'.');
        THROW 58060, @missing_msg, 1;
    END

    DECLARE @bad NVARCHAR(200);
    SELECT TOP (1) @bad = x.what FROM (VALUES
        (N'SERVICE_CATEGORY', @service_category_code, N'service category'),
        (N'ENGAGEMENT_TYPE',  @engagement_type_code,  N'engagement type'),
        (N'SERVICE_MODEL',    @service_model_code,    N'service model')) x(list_code, code, what)
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
    IF @proposed_end_dt IS NOT NULL AND @proposed_end_dt < @proposed_start_dt
        THROW 57635, 'The proposed end date is before the start date.', 1;
    IF @actual_end_dt IS NOT NULL AND @actual_start_dt IS NOT NULL AND @actual_end_dt < @actual_start_dt
        THROW 57636, 'The actual end date is before the start date.', 1;

    DECLARE @id BIGINT = @engagement_id, @created BIT = 0, @stage NVARCHAR(30), @tp BIGINT;
    DECLARE @o_model NVARCHAR(60), @o_loc NVARCHAR(1000);
    IF @id IS NOT NULL
    BEGIN
        DECLARE @rv BIGINT;
        SELECT @rv = CONVERT(BIGINT, record_version), @stage = stage_code, @tp = third_party_id,
               @o_model = service_model_code, @o_loc = delivery_locations
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
        -- 522 (CR 2 4.2-5): engagements are created for ACTIVE vendors.
        IF (SELECT grac_practice.fn_tprm_vendor_status_meaning(organization_id, lifecycle_status_code)
              FROM grac_practice.tprm_third_party WHERE third_party_id = @tp) <> N'ACTIVE'
            THROW 58061, 'A new engagement can be opened only for an active vendor.', 1;
    END

    DECLARE @flagged BIT = 0;
    BEGIN TRAN;
    IF @id IS NULL
    BEGIN
        DECLARE @next INT, @code NVARCHAR(20);
        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(engagement_code, 5, 20))), 0) + 1
        FROM   grac_practice.tprm_engagement WITH (UPDLOCK, HOLDLOCK)
        WHERE  organization_id = @organization_id AND engagement_code LIKE N'ENG-%';
        SET @code = N'ENG-' + FORMAT(@next, '000');
        INSERT grac_practice.tprm_engagement
            (organization_id, third_party_id, engagement_code, engagement_title, service_category_code, service_description,
             business_purpose, service_recipient, engagement_type_code, service_model_code, delivery_locations,
             proposed_start_dt, proposed_end_dt, relationship_owner_employee_id, scope_description, is_existing,
             business_owner_employee_id, assessor_employee_id, actual_start_dt, actual_end_dt, notes, stage_code, entered_by)
        VALUES (@organization_id, @tp, @code, @engagement_title, @service_category_code, @service_description,
                @business_purpose, @service_recipient, @engagement_type_code, @service_model_code, @delivery_locations,
                @proposed_start_dt, @proposed_end_dt, @relationship_owner_employee_id, NULLIF(LTRIM(RTRIM(@scope_description)), N''),
                ISNULL(@is_existing, 0), @business_owner_employee_id, @assessor_employee_id, @actual_start_dt, @actual_end_dt,
                @notes, N'SCOPING', @actor);
        SET @id = SCOPE_IDENTITY();
        SET @created = 1;
    END
    ELSE
        UPDATE grac_practice.tprm_engagement
           SET engagement_title = @engagement_title, service_category_code = @service_category_code,
               service_description = @service_description, business_purpose = @business_purpose,
               service_recipient = @service_recipient, engagement_type_code = @engagement_type_code,
               service_model_code = @service_model_code, delivery_locations = @delivery_locations,
               proposed_start_dt = @proposed_start_dt, proposed_end_dt = @proposed_end_dt,
               relationship_owner_employee_id = @relationship_owner_employee_id,
               scope_description = NULLIF(LTRIM(RTRIM(@scope_description)), N''), is_existing = ISNULL(@is_existing, 0),
               business_owner_employee_id = @business_owner_employee_id, assessor_employee_id = @assessor_employee_id,
               actual_start_dt = @actual_start_dt, actual_end_dt = @actual_end_dt, notes = @notes,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE engagement_id = @id;

    -- custom-field access follows the caller's GRAC role (organization_employee.role_id)
    IF @caller_role_names IS NULL AND @actor_employee_id IS NOT NULL
        SELECT @caller_role_names = r.role_name FROM grac_practice.organization_employee e
        JOIN grac_practice.organization_role r ON r.role_id = e.role_id WHERE e.employee_id = @actor_employee_id;
    EXEC grac_practice.sp_tprm_custom_values_save @organization_id, N'ENGAGEMENT', @id, @custom_json,
         @caller_role_names, @caller_is_admin, @actor;

    IF @created = 0
    BEGIN
        DECLARE @material NVARCHAR(1000) = NULLIF(CONCAT_WS(N'; ',
            CASE WHEN ISNULL(@o_model, N'') <> ISNULL(@service_model_code, N'') THEN CONCAT(N'service model ', @o_model, N' -> ', @service_model_code) END,
            CASE WHEN ISNULL(@o_loc, N'') <> ISNULL(@delivery_locations, N'') THEN N'delivery locations changed' END), N'');
        EXEC grac_practice.sp_tprm_engagement_flag_material @id, @stage, @material, @actor_employee_id, @actor, @flagged OUTPUT;
        IF @flagged = 0
            EXEC grac_practice.sp_tprm_engagement_event @id, N'UPDATED', @stage, @stage, NULL, @actor_employee_id, @actor;
    END
    ELSE
        EXEC grac_practice.sp_tprm_engagement_event @id, N'CREATED', NULL, N'SCOPING', @engagement_title, @actor_employee_id, @actor;
    COMMIT;

    SELECT @id AS EngagementId, CASE WHEN @created = 1 THEN N'CREATED' WHEN @flagged = 1 THEN N'MATERIAL_CHANGE' ELSE N'SAVED' END AS Result;
END
GO

-- Save Scope & Exposure (CR 2 5.2, 5.3) -- progressive exposure capture.
-- Gating answers (YES / NO / UNKNOWN, NULL = not answered):
--   @app_access_answer          applications and systems; access
--   @premises_access_answer     access (physical)
--   @data_processing_answer     data categories, processing details
--   @subcontracting_answer      fourth parties
--   @important_process_answer   business functions and processes
--   @disruption_impact_answer   customer impact, substitutability, exit dependencies
--   @service_commitment_answer  SLA, RTO, RPO
--   @contract_answer            contract record, reference, value, validity, renewal, documents
-- Always asked: service criticality (mandatory) and delivery locations.
-- Only the dimensions answered YES keep their fields and proposed scope
-- items; the rest are cleared ("only relevant dimensions"). UNKNOWN is
-- kept as the answer -- the information gap Round B's screening reports.
--   @scope_json : the proposed scope items, ALL of them, as one set:
--                 [{"kind":"APPLICATION","refId":12,"itemCode":null,"itemName":null,"country":null}, ...]
--                 kinds BUSINESS_FUNCTION / PROCESS / APPLICATION (refId of
--                 the GRAC record, or itemName when not in GRAC),
--                 DATA_CATEGORY / ACCESS (itemCode of DATA_EXPOSURE /
--                 ACCESS_CATEGORY), LOCATION (itemName, country),
--                 FOURTH_PARTY (itemName, itemCode of FOURTH_PARTY_CATEGORY, country).
--                 Items no longer listed are removed; unchanged items keep
--                 their criticality and notes.
-- The data exposure (data_exposure_code: risk prefill, questionnaire
-- applicability) is derived: the highest-rank data category when data is
-- in scope, the rank-0 value when it is not, empty when not known.
-- On an approved or live engagement a change of criticality, data
-- exposure, customer impact or substitutability is a material change.
CREATE OR ALTER PROCEDURE grac_practice.sp_tprm_engagement_exposure_save
    @organization_id           BIGINT,
    @engagement_id             BIGINT,
    @app_access_answer         NVARCHAR(10)   = NULL,
    @premises_access_answer    NVARCHAR(10)   = NULL,
    @data_processing_answer    NVARCHAR(10)   = NULL,
    @subcontracting_answer     NVARCHAR(10)   = NULL,
    @important_process_answer  NVARCHAR(10)   = NULL,
    @disruption_impact_answer  NVARCHAR(10)   = NULL,
    @service_commitment_answer NVARCHAR(10)   = NULL,
    @contract_answer           NVARCHAR(10)   = NULL,
    @service_criticality_code  NVARCHAR(60)   = NULL,
    @data_processing_details   NVARCHAR(2000) = NULL,
    @customer_impact_code      NVARCHAR(60)   = NULL,
    @substitutability_code     NVARCHAR(60)   = NULL,
    @exit_dependencies         NVARCHAR(2000) = NULL,
    @sla_summary               NVARCHAR(2000) = NULL,
    @rto_hours                 INT            = NULL,
    @rpo_hours                 INT            = NULL,
    @contract_id               BIGINT         = NULL,
    @contract_reference        NVARCHAR(200)  = NULL,
    @contract_value            DECIMAL(19,2)  = NULL,
    @currency_code             NVARCHAR(10)   = NULL,
    @contract_start_dt         DATE           = NULL,
    @contract_end_dt           DATE           = NULL,
    @renewal_dt                DATE           = NULL,
    @contract_documents        NVARCHAR(1000) = NULL,
    @scope_json                NVARCHAR(MAX)  = NULL,
    @expected_record_version   BIGINT         = NULL,
    @actor_employee_id         BIGINT         = NULL,
    @actor                     NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @rv BIGINT, @stage NVARCHAR(30), @o_crit NVARCHAR(60), @o_data NVARCHAR(60), @o_sub NVARCHAR(60), @o_cust NVARCHAR(60);
    SELECT @rv = CONVERT(BIGINT, record_version), @stage = stage_code,
           @o_crit = service_criticality_code, @o_data = data_exposure_code, @o_sub = substitutability_code, @o_cust = customer_impact_code
    FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND organization_id = @organization_id;
    IF @rv IS NULL THROW 57630, 'That engagement was not found.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 57639, 'Someone else changed this engagement. Reload and try again.', 1;
    IF @stage IN (N'EXITED', N'REJECTED', N'CANCELLED') THROW 57640, 'A closed engagement cannot be changed.', 1;

    SELECT @app_access_answer         = UPPER(NULLIF(LTRIM(RTRIM(@app_access_answer)), N'')),
           @premises_access_answer    = UPPER(NULLIF(LTRIM(RTRIM(@premises_access_answer)), N'')),
           @data_processing_answer    = UPPER(NULLIF(LTRIM(RTRIM(@data_processing_answer)), N'')),
           @subcontracting_answer     = UPPER(NULLIF(LTRIM(RTRIM(@subcontracting_answer)), N'')),
           @important_process_answer  = UPPER(NULLIF(LTRIM(RTRIM(@important_process_answer)), N'')),
           @disruption_impact_answer  = UPPER(NULLIF(LTRIM(RTRIM(@disruption_impact_answer)), N'')),
           @service_commitment_answer = UPPER(NULLIF(LTRIM(RTRIM(@service_commitment_answer)), N'')),
           @contract_answer           = UPPER(NULLIF(LTRIM(RTRIM(@contract_answer)), N''));
    IF EXISTS (SELECT 1 FROM (VALUES (@app_access_answer), (@premises_access_answer), (@data_processing_answer),
                                     (@subcontracting_answer), (@important_process_answer), (@disruption_impact_answer),
                                     (@service_commitment_answer), (@contract_answer)) x(answer)
                WHERE x.answer IS NOT NULL AND x.answer NOT IN (N'YES', N'NO', N'UNKNOWN'))
        THROW 58063, 'Answer each question Yes, No or Not sure.', 1;
    SET @service_criticality_code = NULLIF(LTRIM(RTRIM(@service_criticality_code)), N'');
    IF @service_criticality_code IS NULL THROW 58070, 'Choose the service criticality.', 1;

    -- Only the dimensions that apply are kept (CR 2 5.2: "the system must
    -- not force users to populate every exposure dimension").
    SELECT @data_processing_details = NULLIF(LTRIM(RTRIM(@data_processing_details)), N''),
           @customer_impact_code = NULLIF(LTRIM(RTRIM(@customer_impact_code)), N''),
           @substitutability_code = NULLIF(LTRIM(RTRIM(@substitutability_code)), N''),
           @exit_dependencies = NULLIF(LTRIM(RTRIM(@exit_dependencies)), N''),
           @sla_summary = NULLIF(LTRIM(RTRIM(@sla_summary)), N''),
           @contract_reference = NULLIF(LTRIM(RTRIM(@contract_reference)), N''),
           @currency_code = NULLIF(LTRIM(RTRIM(@currency_code)), N''),
           @contract_documents = NULLIF(LTRIM(RTRIM(@contract_documents)), N'');
    IF ISNULL(@data_processing_answer, N'') <> N'YES' SET @data_processing_details = NULL;
    IF ISNULL(@disruption_impact_answer, N'') <> N'YES'
        SELECT @customer_impact_code = NULL, @substitutability_code = NULL, @exit_dependencies = NULL;
    IF ISNULL(@service_commitment_answer, N'') <> N'YES'
        SELECT @sla_summary = NULL, @rto_hours = NULL, @rpo_hours = NULL;
    IF ISNULL(@contract_answer, N'') <> N'YES'
        SELECT @contract_id = NULL, @contract_reference = NULL, @contract_value = NULL, @currency_code = NULL,
               @contract_start_dt = NULL, @contract_end_dt = NULL, @renewal_dt = NULL, @contract_documents = NULL;

    DECLARE @bad NVARCHAR(200);
    SELECT TOP (1) @bad = x.what FROM (VALUES
        (N'CRITICALITY',      @service_criticality_code, N'service criticality'),
        (N'CUSTOMER_IMPACT',  @customer_impact_code,     N'customer impact'),
        (N'SUBSTITUTABILITY', @substitutability_code,    N'substitutability')) x(list_code, code, what)
    WHERE x.code IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_tprm_reference_effective(@organization_id) r
                       WHERE r.list_code = x.list_code AND r.value_code = x.code);
    IF @bad IS NOT NULL
    BEGIN
        DECLARE @bad_msg NVARCHAR(300) = CONCAT(N'Choose a ', @bad, N' from the list.');
        THROW 57633, @bad_msg, 1;
    END
    IF (@rto_hours IS NOT NULL AND @rto_hours < 0) OR (@rpo_hours IS NOT NULL AND @rpo_hours < 0)
        THROW 57637, 'RTO and RPO cannot be negative.', 1;
    IF @contract_end_dt IS NOT NULL AND @contract_start_dt IS NOT NULL AND @contract_end_dt < @contract_start_dt
        THROW 58069, 'The contract end date is before its start date.', 1;
    IF @contract_id IS NOT NULL
    BEGIN
        IF OBJECT_ID('grac_practice.asset_contract','U') IS NULL THROW 57638, 'Contracts are not available in this installation.', 1;
        DECLARE @contract_ok INT;
        EXEC sp_executesql N'SELECT @n = COUNT(*) FROM grac_practice.asset_contract WHERE contract_id = @c AND organization_id = @o;',
             N'@n INT OUTPUT, @c BIGINT, @o BIGINT', @n = @contract_ok OUTPUT, @c = @contract_id, @o = @organization_id;
        IF ISNULL(@contract_ok, 0) = 0 THROW 57638, 'That contract was not found in this organization.', 1;
    END

    -- ---- the proposed scope items, as one set
    IF @scope_json IS NOT NULL AND ISJSON(@scope_json) <> 1 THROW 58064, 'The scope items are not valid.', 1;
    DECLARE @in TABLE (row_no INT IDENTITY(1,1) PRIMARY KEY, item_kind NVARCHAR(30), ref_id BIGINT, item_code NVARCHAR(60),
                       item_name NVARCHAR(300), country NVARCHAR(120), item_key NVARCHAR(500));
    INSERT @in (item_kind, ref_id, item_code, item_name, country)
    SELECT UPPER(NULLIF(LTRIM(RTRIM(j.kind)), N'')), j.refId, NULLIF(LTRIM(RTRIM(j.itemCode)), N''),
           NULLIF(LTRIM(RTRIM(j.itemName)), N''), NULLIF(LTRIM(RTRIM(j.country)), N'')
    FROM OPENJSON(ISNULL(@scope_json, N'[]'))
         WITH (kind NVARCHAR(30) '$.kind', refId BIGINT '$.refId', itemCode NVARCHAR(60) '$.itemCode',
               itemName NVARCHAR(300) '$.itemName', country NVARCHAR(120) '$.country') j;
    IF EXISTS (SELECT 1 FROM @in WHERE item_kind IS NULL OR item_kind NOT IN (N'BUSINESS_FUNCTION', N'PROCESS', N'APPLICATION',
                                                                              N'DATA_CATEGORY', N'ACCESS', N'LOCATION', N'FOURTH_PARTY'))
        THROW 58065, 'Unknown scope item type.', 1;
    -- a dimension that does not apply keeps no items
    DELETE FROM @in
    WHERE (item_kind = N'APPLICATION' AND ISNULL(@app_access_answer, N'') <> N'YES')
       OR (item_kind = N'ACCESS' AND ISNULL(@app_access_answer, N'') <> N'YES' AND ISNULL(@premises_access_answer, N'') <> N'YES')
       OR (item_kind = N'DATA_CATEGORY' AND ISNULL(@data_processing_answer, N'') <> N'YES')
       OR (item_kind = N'FOURTH_PARTY' AND ISNULL(@subcontracting_answer, N'') <> N'YES')
       OR (item_kind IN (N'BUSINESS_FUNCTION', N'PROCESS') AND ISNULL(@important_process_answer, N'') <> N'YES');
    UPDATE @in SET ref_id = NULL WHERE item_kind NOT IN (N'BUSINESS_FUNCTION', N'PROCESS', N'APPLICATION');
    -- GRAC records are picked, not typed: the name comes from the record.
    IF EXISTS (SELECT 1 FROM @in i WHERE i.ref_id IS NOT NULL
                 AND NOT ((i.item_kind = N'BUSINESS_FUNCTION' AND EXISTS (SELECT 1 FROM grac_practice.organization_business_function f
                                                                           WHERE f.business_function_id = i.ref_id AND f.organization_id = @organization_id))
                       OR (i.item_kind = N'PROCESS' AND EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process p
                                                                 WHERE p.process_id = i.ref_id AND p.organization_id = @organization_id))
                       OR (i.item_kind = N'APPLICATION' AND EXISTS (SELECT 1 FROM grac_practice.organization_dependency_application a
                                                                     WHERE a.application_id = i.ref_id AND a.organization_id = @organization_id))))
        THROW 58066, 'A GRAC record in the scope was not found in this organization.', 1;
    UPDATE i SET item_name = f.function_name FROM @in i
    JOIN grac_practice.organization_business_function f ON f.business_function_id = i.ref_id
    WHERE i.item_kind = N'BUSINESS_FUNCTION';
    UPDATE i SET item_name = p.process_name FROM @in i
    JOIN grac_practice.organization_dependency_process p ON p.process_id = i.ref_id
    WHERE i.item_kind = N'PROCESS';
    UPDATE i SET item_name = a.application_name FROM @in i
    JOIN grac_practice.organization_dependency_application a ON a.application_id = i.ref_id
    WHERE i.item_kind = N'APPLICATION';
    -- list values: the code must be in force; the name is its label
    DECLARE @lv TABLE (list_code NVARCHAR(60), value_code NVARCHAR(60), label NVARCHAR(200), rank_no INT, display_order INT);
    INSERT @lv (list_code, value_code, label, rank_no, display_order)
    SELECT r.list_code, r.value_code, r.label, r.rank_no, r.display_order
    FROM grac_practice.fn_tprm_reference_effective(@organization_id) r
    WHERE r.list_code IN (N'DATA_EXPOSURE', N'ACCESS_CATEGORY', N'FOURTH_PARTY_CATEGORY');
    -- A value no longer in force (retired / hidden) that this engagement
    -- already records stays valid, so a save never drops it silently.
    DECLARE @kept TABLE (item_kind NVARCHAR(30), item_code NVARCHAR(60), item_name NVARCHAR(300));
    INSERT @kept (item_kind, item_code, item_name)
    SELECT s.item_kind, s.item_code, MAX(s.item_name) FROM grac_practice.tprm_engagement_scope s
    WHERE s.engagement_id = @engagement_id AND s.exposure_mode = N'PROPOSED' AND s.status = N'Active' AND s.item_code IS NOT NULL
    GROUP BY s.item_kind, s.item_code;
    IF EXISTS (SELECT 1 FROM @in i
                WHERE (i.item_kind IN (N'DATA_CATEGORY', N'ACCESS')
                       AND (i.item_code IS NULL
                            OR (NOT EXISTS (SELECT 1 FROM @lv l
                                             WHERE l.list_code = CASE i.item_kind WHEN N'DATA_CATEGORY' THEN N'DATA_EXPOSURE' ELSE N'ACCESS_CATEGORY' END
                                               AND l.value_code = i.item_code)
                                AND NOT EXISTS (SELECT 1 FROM @kept k WHERE k.item_kind = i.item_kind AND k.item_code = i.item_code))))
                   OR (i.item_kind = N'FOURTH_PARTY' AND i.item_code IS NOT NULL
                       AND NOT EXISTS (SELECT 1 FROM @lv l WHERE l.list_code = N'FOURTH_PARTY_CATEGORY' AND l.value_code = i.item_code)
                       AND NOT EXISTS (SELECT 1 FROM @kept k WHERE k.item_kind = N'FOURTH_PARTY' AND k.item_code = i.item_code)))
        THROW 58067, 'Choose the scope values from the lists.', 1;
    UPDATE i SET item_name = k.item_name FROM @in i
    JOIN @kept k ON k.item_kind = i.item_kind AND k.item_code = i.item_code
    WHERE i.item_kind IN (N'DATA_CATEGORY', N'ACCESS');
    UPDATE i SET item_name = l.label FROM @in i
    JOIN @lv l ON l.list_code = CASE i.item_kind WHEN N'DATA_CATEGORY' THEN N'DATA_EXPOSURE' ELSE N'ACCESS_CATEGORY' END
              AND l.value_code = i.item_code
    WHERE i.item_kind IN (N'DATA_CATEGORY', N'ACCESS');
    UPDATE @in SET item_code = NULL WHERE item_kind IN (N'BUSINESS_FUNCTION', N'PROCESS', N'APPLICATION', N'LOCATION');
    UPDATE @in SET country = NULL WHERE item_kind NOT IN (N'LOCATION', N'FOURTH_PARTY');
    IF EXISTS (SELECT 1 FROM @in WHERE item_name IS NULL) THROW 58068, 'Every scope item needs a name.', 1;
    UPDATE @in SET item_key = grac_practice.fn_tprm_scope_item_key(item_kind, ref_id, item_code, item_name, country);
    DELETE i FROM @in i WHERE EXISTS (SELECT 1 FROM @in d WHERE d.item_key = i.item_key AND d.row_no < i.row_no);

    -- the derived data exposure
    DECLARE @data_code NVARCHAR(60) = NULL;
    IF @data_processing_answer = N'YES'
        SELECT TOP (1) @data_code = i.item_code
        FROM @in i LEFT JOIN @lv l ON l.list_code = N'DATA_EXPOSURE' AND l.value_code = i.item_code
        WHERE i.item_kind = N'DATA_CATEGORY'
        ORDER BY ISNULL(l.rank_no, 0) DESC, ISNULL(l.display_order, 9999);
    ELSE IF @data_processing_answer = N'NO'
        SELECT TOP (1) @data_code = l.value_code FROM @lv l
        WHERE l.list_code = N'DATA_EXPOSURE' AND l.rank_no = 0
        ORDER BY l.display_order;

    DECLARE @added INT = 0, @removed INT = 0, @flagged BIT = 0;
    BEGIN TRAN;
    UPDATE grac_practice.tprm_engagement
       SET app_access_answer = @app_access_answer, premises_access_answer = @premises_access_answer,
           data_processing_answer = @data_processing_answer, subcontracting_answer = @subcontracting_answer,
           important_process_answer = @important_process_answer, disruption_impact_answer = @disruption_impact_answer,
           service_commitment_answer = @service_commitment_answer, contract_answer = @contract_answer,
           service_criticality_code = @service_criticality_code, data_exposure_code = @data_code,
           data_processing_details = @data_processing_details,
           customer_impact_code = @customer_impact_code, substitutability_code = @substitutability_code,
           exit_dependencies = @exit_dependencies,
           sla_summary = @sla_summary, rto_hours = @rto_hours, rpo_hours = @rpo_hours,
           contract_id = @contract_id, contract_reference = @contract_reference, contract_value = @contract_value,
           currency_code = @currency_code, contract_start_dt = @contract_start_dt, contract_end_dt = @contract_end_dt,
           renewal_dt = @renewal_dt, contract_documents = @contract_documents,
           exposure_saved_dt = SYSUTCDATETIME(), exposure_saved_by = @actor,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE engagement_id = @engagement_id;

    -- items no longer listed
    UPDATE s SET status = N'Removed', updated_by = @actor, updated_dt = SYSUTCDATETIME()
    FROM grac_practice.tprm_engagement_scope s
    WHERE s.engagement_id = @engagement_id AND s.exposure_mode = N'PROPOSED' AND s.status = N'Active'
      AND NOT EXISTS (SELECT 1 FROM @in i
                       WHERE i.item_key = grac_practice.fn_tprm_scope_item_key(s.item_kind, s.ref_id, s.item_code, s.item_name, s.country));
    SET @removed = @@ROWCOUNT;
    -- items kept: the name and the fourth-party category follow the page
    UPDATE s SET item_name = i.item_name,
                 item_code = CASE WHEN s.item_kind = N'FOURTH_PARTY' THEN i.item_code ELSE s.item_code END,
                 updated_by = @actor, updated_dt = SYSUTCDATETIME()
    FROM grac_practice.tprm_engagement_scope s
    JOIN @in i ON i.item_key = grac_practice.fn_tprm_scope_item_key(s.item_kind, s.ref_id, s.item_code, s.item_name, s.country)
    WHERE s.engagement_id = @engagement_id AND s.exposure_mode = N'PROPOSED' AND s.status = N'Active'
      AND (s.item_name <> i.item_name
           OR (s.item_kind = N'FOURTH_PARTY' AND ISNULL(s.item_code, N'') <> ISNULL(i.item_code, N'')));
    -- new items
    INSERT grac_practice.tprm_engagement_scope
        (engagement_id, organization_id, item_kind, exposure_mode, ref_id, item_code, item_name, country, entered_by)
    SELECT @engagement_id, @organization_id, i.item_kind, N'PROPOSED', i.ref_id, i.item_code, i.item_name, i.country, @actor
    FROM @in i
    WHERE NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope s
                       WHERE s.engagement_id = @engagement_id AND s.exposure_mode = N'PROPOSED' AND s.status = N'Active'
                         AND grac_practice.fn_tprm_scope_item_key(s.item_kind, s.ref_id, s.item_code, s.item_name, s.country) = i.item_key);
    SET @added = @@ROWCOUNT;

    DECLARE @material NVARCHAR(1000) = NULLIF(CONCAT_WS(N'; ',
        CASE WHEN ISNULL(@o_crit, N'') <> ISNULL(@service_criticality_code, N'') THEN CONCAT(N'criticality ', @o_crit, N' -> ', @service_criticality_code) END,
        CASE WHEN ISNULL(@o_data, N'') <> ISNULL(@data_code, N'') THEN CONCAT(N'data exposure ', @o_data, N' -> ', @data_code) END,
        CASE WHEN ISNULL(@o_cust, N'') <> ISNULL(@customer_impact_code, N'') THEN CONCAT(N'customer impact ', @o_cust, N' -> ', @customer_impact_code) END,
        CASE WHEN ISNULL(@o_sub, N'') <> ISNULL(@substitutability_code, N'') THEN CONCAT(N'substitutability ', @o_sub, N' -> ', @substitutability_code) END), N'');
    EXEC grac_practice.sp_tprm_engagement_flag_material @engagement_id, @stage, @material, @actor_employee_id, @actor, @flagged OUTPUT;
    DECLARE @detail NVARCHAR(2000) = CONCAT(N'Scope & exposure saved: ', @added, N' proposed item(s) added, ', @removed, N' removed.');
    EXEC grac_practice.sp_tprm_engagement_event @engagement_id, N'EXPOSURE_SAVED', @stage, @stage, @detail, @actor_employee_id, @actor;
    COMMIT;

    SELECT @engagement_id AS EngagementId, CASE WHEN @flagged = 1 THEN N'MATERIAL_CHANGE' ELSE N'SAVED' END AS Result;
END
GO

-- Scope items one at a time (488) -- re-issued by 522: the PROPOSED
-- exposure belongs to the Scope & Exposure page
-- (sp_tprm_engagement_exposure_save), where its gating answers decide
-- which items apply; ACTUAL items (onboarding) work as before.
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
    IF @exposure_mode = N'PROPOSED'
       OR EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope
                   WHERE scope_item_id = @scope_item_id AND engagement_id = @engagement_id AND exposure_mode = N'PROPOSED')
        THROW 58062, 'The proposed exposure is recorded on the Scope & Exposure page.', 1;
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
    IF @mode = N'PROPOSED' THROW 58062, 'The proposed exposure is recorded on the Scope & Exposure page.', 1;

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

-- Start an inherent assessment (488) -- re-issued by 522: Scope &
-- Exposure must have been saved (service criticality is asked there, not
-- at creation; the risk-model prefill and the approval rules read it).
-- Pins the risk model in force and prefills the factors whose option
-- matches the scope (the assessor confirms or changes every answer).
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
    IF EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id
                 AND (exposure_saved_dt IS NULL OR service_criticality_code IS NULL))
        THROW 58071, 'Save Scope & Exposure (with the service criticality) before assessing risk.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement_scope WHERE engagement_id = @engagement_id AND status = N'Active')
       AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_engagement WHERE engagement_id = @engagement_id AND data_exposure_code IS NOT NULL)
        THROW 57662, 'Record the scope (at least the data exposure) before assessing risk.', 1;

    DECLARE @version BIGINT = (SELECT version_id FROM grac_practice.fn_tprm_risk_model_version(@organization_id));
    IF @version IS NULL THROW 57663, 'No risk model is in force. Activate one in Third-Party Settings.', 1;
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

-- BRD 5.2 sample records (re-issued by 522: sample vendors are registered
-- as ACTIVE, like any other registration, with the person who loads
-- them as relationship owner -- a primary contact is added on Edit vendor
-- before the sample vendor is first saved; their engagements' gating
-- questions are answered from the sample scope and their Scope &
-- Exposure counts as saved).
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
    DECLARE @active NVARCHAR(60) = ISNULL(grac_practice.fn_tprm_meaning_code(@organization_id, N'TP_STATUS', N'ACTIVE'), N'ACTIVE');
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
             country, lifecycle_status_code, first_activated_dt, relationship_owner_employee_id, profile_notes, is_sample, entered_by)
        SELECT @organization_id, @tcode, p.legal_name, grac_practice.fn_tprm_normalize_name(p.legal_name), p.provider_type_code,
               p.service_category_code, p.country, @active, SYSUTCDATETIME(), @actor_employee_id,
               CONCAT(N'Illustrative sample record - not a real provider and not a completed assessment. ', p.notes),
               1, @actor
        FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code;
        SET @tp = SCOPE_IDENTITY();
        INSERT grac_practice.tprm_third_party_category (third_party_id, service_category_code)
        SELECT @tp, p.service_category_code FROM grac_practice.tprm_sample_profile p WHERE p.sample_code = @code;
        INSERT grac_practice.tprm_third_party_status_history (third_party_id, from_status_code, to_status_code, reason, is_automatic, actor_employee_id, actor)
        VALUES (@tp, NULL, @active, N'Sample record loaded (registered and activated).', 0, @actor_employee_id, @actor);

        SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(engagement_code, 5, 20))), 0) + 1
        FROM grac_practice.tprm_engagement WITH (UPDLOCK, HOLDLOCK)
        WHERE organization_id = @organization_id AND engagement_code LIKE N'ENG-%';
        SET @ecode = N'ENG-' + FORMAT(@next, '000');
        INSERT grac_practice.tprm_engagement
            (organization_id, third_party_id, engagement_code, engagement_title, service_description, scope_description, business_purpose,
             service_category_code, engagement_type_code, service_model_code, delivery_locations, is_existing, service_criticality_code,
             data_exposure_code, rto_hours, rpo_hours, notes, is_sample, stage_code, exposure_saved_dt, exposure_saved_by, entered_by)
        SELECT @organization_id, @tp, @ecode, p.engagement_title, p.service_description, p.scope_description, p.business_purpose,
               p.service_category_code, p.engagement_type_code, p.service_model_code, p.country, 0, p.criticality_code,
               p.data_exposure_code, p.rto_hours, p.rpo_hours,
               CONCAT(N'Sample guidance -- key safeguards: ', p.key_safeguards, N'. Evidence expected: ', p.evidence_expectations,
                      N'. Review triggers: ', p.review_triggers, N'.'),
               1, N'SCOPING', SYSUTCDATETIME(), @actor, @actor
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

        -- the gating questions, answered from what the sample records
        EXEC grac_practice.sp_tprm_engagement_answers_derive @eng, @actor;
        EXEC grac_practice.sp_tprm_engagement_event @eng, N'CREATED', NULL, N'SCOPING', N'Sample engagement loaded.', @actor_employee_id, @actor;
        COMMIT;
        SET @loaded = @loaded + 1;
        FETCH NEXT FROM c INTO @code;
    END
    CLOSE c;
    DEALLOCATE c;

    EXEC grac_practice.sp_tprm_audit N'tprm-sample', @organization_id, N'LOAD', NULL, @actor;
    SELECT @loaded AS LoadedCount, N'LOADED' AS Result;
END
GO

-- =====================================================================
-- 6. Existing engagements: gating answers and the exposure save date
-- =====================================================================
-- Engagements recorded before 522 answer the gating questions from what
-- they already hold; those with a service criticality (required by 521)
-- count as having saved Scope & Exposure.
EXEC grac_practice.sp_tprm_engagement_answers_derive NULL, N'migration-522';
UPDATE grac_practice.tprm_engagement
   SET exposure_saved_dt = COALESCE(updated_dt, entered_dt), exposure_saved_by = N'migration-522'
 WHERE exposure_saved_dt IS NULL AND service_criticality_code IS NOT NULL;
PRINT CONCAT('522: engagements marked as exposure saved: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 7. Navigation (CR 2 section 3). Keys unchanged -- grants, drill links
--    and ManagementDashboards keep working. Also in 274_menu_master_seed.sql.
-- =====================================================================
UPDATE grac_practice.menu_master
   SET menu_name = N'Engagement Management', updated_by = N'migration-522', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'tprm-engagements' AND menu_name <> N'Engagement Management';

-- Reachable, not in the sidebar (390): the dashboard (Home card, its
-- drill links) and Reviews & Monitoring (opened from an engagement).
UPDATE grac_practice.menu_master
   SET show_in_sidebar = 0, updated_by = N'migration-522', updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'tprm-dashboard', N'tprm-reviews') AND show_in_sidebar = 1;
PRINT CONCAT('522: TPM rows hidden from the sidebar: ', @@ROWCOUNT);

-- Configuration moves to Settings, beside Risk Settings (458).
DECLARE @settings_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-organization');
IF @settings_id IS NOT NULL
    UPDATE grac_practice.menu_master
       SET menu_name = N'Third-Party Settings', parent_menu_id = @settings_id, display_order = 266,
           module_type = N'Organization', updated_by = N'migration-522', updated_dt = SYSUTCDATETIME()
     WHERE menu_key = N'tprm-configuration'
       AND (menu_name <> N'Third-Party Settings' OR ISNULL(parent_menu_id, -1) <> @settings_id
            OR display_order <> 266 OR ISNULL(module_type, N'') <> N'Organization');
PRINT CONCAT('522: Third-Party Settings under Settings: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 8. Verification
-- =====================================================================
SELECT '522-a vendor states: no DRAFT left' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party t
                              WHERE grac_practice.fn_tprm_vendor_status_meaning(t.organization_id, t.lifecycle_status_code)
                                    NOT IN (N'ACTIVE', N'INACTIVE', N'SUSPENDED', N'ARCHIVED'))
             AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_reference_value
                              WHERE organization_id IS NULL AND list_code = N'TP_STATUS' AND value_code = N'DRAFT')
             AND NOT EXISTS (SELECT 1 FROM grac_practice.tprm_third_party WHERE first_activated_dt IS NULL)
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '522-b registration activates; transitions without DRAFT',
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules m WHERE m.object_id = OBJECT_ID('grac_practice.sp_tprm_third_party_save')
                           AND CHARINDEX(N'58050', m.[definition]) > 0
                           AND CHARINDEX(CONCAT(NCHAR(39), N'ACTIVATE', NCHAR(39)), m.[definition]) > 0)
             AND NOT EXISTS (SELECT 1 FROM sys.sql_modules m WHERE m.object_id = OBJECT_ID('grac_practice.fn_tprm_vendor_transitions')
                               AND CHARINDEX(CONCAT(NCHAR(39), N'DRAFT', NCHAR(39)), m.[definition]) > 0)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '522-c engagement core and exposure saves',
       CASE WHEN OBJECT_ID('grac_practice.sp_tprm_engagement_exposure_save', 'P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_tprm_engagement_flag_material', 'P') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_tprm_scope_item_key') IS NOT NULL
             AND COL_LENGTH('grac_practice.tprm_engagement', 'contract_answer') IS NOT NULL
             AND COL_LENGTH('grac_practice.tprm_engagement', 'exposure_saved_dt') IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM sys.parameters p WHERE p.object_id = OBJECT_ID('grac_practice.sp_tprm_engagement_save')
                               AND p.name = N'@service_criticality_code')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '522-d navigation: Engagement Management; settings under Settings; dashboard and reviews off the sidebar',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'tprm-engagements' AND menu_name = N'Engagement Management')
             AND EXISTS (SELECT 1 FROM grac_practice.menu_master c JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
                          WHERE c.menu_key = N'tprm-configuration' AND p.menu_key = N'nav-organization'
                            AND c.menu_name = N'Third-Party Settings' AND c.module_type = N'Organization')
             AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master
                              WHERE menu_key IN (N'tprm-dashboard', N'tprm-reviews') AND show_in_sidebar = 1)
            THEN 'PASS' ELSE 'FAIL' END;
GO

PRINT '522 complete. Deploy the API and Web builds of this change, then sign out and in again.';
GO
