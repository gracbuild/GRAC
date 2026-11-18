-- =====================================================================
-- 569_org_registry_schema.sql
--
-- Organization Registry -- schema (workbook "GRAC_Organization_Registry_
-- Muthoot_Lakeshore_Pilot_Populated.xlsx", sheets 01-13 and 15).
--
-- HIERARCHY. Two levels: Organization -> Legal Entity.
--   * Organization (sheet 01, the GRAC tenant / group profile) is NEW:
--     grac_practice.registry_organization.
--   * Legal Entity (sheet 02) IS the existing grac_practice.organization
--     row. Every organization_id already in the database keeps its meaning
--     and its data; it is now read as a Legal Entity and gains the sheet-02
--     columns plus registry_organization_id (up to its Organization) and
--     parent_organization_id (holding / subsidiary structure).
--   * Existing rows are NOT assigned to an Organization here -- that would
--     invent Organization records. They stay registry_organization_id NULL
--     ("not yet assigned") until someone assigns them on the Registry
--     screen. in_scope_for_grac is backfilled 'Yes' (they are GRAC tenants).
--
-- REGISTRY AREAS reuse the tables GRAC already has, so the registry is the
-- one master (START HERE: "must not create duplicate master records"):
--   03 Organization Units  -> organization_division
--   04 Locations           -> organization_location
--   05 Departments         -> organization_department
--   06 Business Functions  -> organization_business_function
--   07 Teams               -> organization_team
--   08 People              -> organization_employee
--   09 Committees          -> organization_committee
--   10 Committee Members   -> organization_committee_member
--   11 Business Processes  -> organization_dependency_process
-- NEW tables only where GRAC had none:
--   12 Products & Services -> organization_product_service
--   13 Delivery Channels   -> organization_delivery_channel
--   bridges                -> organization_channel_product,
--                             organization_channel_process,
--                             organization_process_risk_category
-- Controlled values (sheet 15) -> org_registry_master_value (seeded by 570).
--
-- Every column added here is NULLable: the existing screens (Organization
-- Administration, Dependencies) write these tables through the
-- pm_manage_practice_repository monolith, which knows none of them, and
-- an UPDATE that omits a column leaves it as it is.
--
-- Codes: the existing per-organization UNIQUE constraints already cover
-- division_code / department_code / function_code / employee_code and the
-- global organization_code; new code columns get the same per-Legal-Entity
-- rule as filtered unique indexes (NULL allowed for rows created before
-- the registry). registry_organization.organization_code is global.
--
-- Idempotent: every statement is guarded. ASCII only.
-- Rollback: 569_org_registry_schema_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Prerequisites: the tables this migration extends (002, 133, 360, 370, 404).
IF OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_division','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_location','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_department','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_business_function','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_team','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_committee','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_committee_member','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_dependency_process','U') IS NULL
   OR OBJECT_ID('grac_practice.location_type_master','U') IS NULL
   OR OBJECT_ID('grac_practice.committee_designation_master','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.frequency_master','U') IS NULL
BEGIN
    PRINT 'ABORT (569): a prerequisite table is missing (002/133/360/370/404). Nothing was changed.';
    SET NOEXEC ON;
END
GO
IF COL_LENGTH('grac_practice.organization','address_line1') IS NULL
   OR COL_LENGTH('grac_practice.organization','state_province') IS NULL
   OR COL_LENGTH('grac_practice.organization_location','address_line1') IS NULL
   OR COL_LENGTH('grac_practice.organization_location','country') IS NULL
   OR COL_LENGTH('grac_practice.organization_team','team_type') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','party_type') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_process','effective_dt') IS NULL
BEGIN
    PRINT 'ABORT (569): run 133, 360 and 404 first (address / team type / party type columns). Nothing was changed.';
    SET NOEXEC ON;
END
GO

-- 1. Controlled values (sheet 15). One row per value of a list.
--    is_workbook_value = 0 marks a value that appears in the workbook's
--    sample rows but NOT in 15 Masters & Codes (seeded by 570 so those rows
--    can load; shown flagged on screen until a data owner approves it).
IF OBJECT_ID('grac_practice.org_registry_master_value','U') IS NULL
CREATE TABLE grac_practice.org_registry_master_value(
    master_value_id   INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_orgreg_master_value PRIMARY KEY,
    master_group      NVARCHAR(60)  NOT NULL,
    value_label       NVARCHAR(120) NOT NULL,
    display_order     INT           NOT NULL CONSTRAINT df_orgreg_master_order DEFAULT 100,
    is_workbook_value BIT           NOT NULL CONSTRAINT df_orgreg_master_wb DEFAULT 1,
    source_note       NVARCHAR(400) NULL,
    status            NVARCHAR(30)  NOT NULL CONSTRAINT df_orgreg_master_status DEFAULT N'Active',
    entered_by        NVARCHAR(100) NOT NULL CONSTRAINT df_orgreg_master_by DEFAULT N'system',
    entered_dt        DATETIME2     NOT NULL CONSTRAINT df_orgreg_master_dt DEFAULT SYSUTCDATETIME(),
    updated_by        NVARCHAR(100) NULL,
    updated_dt        DATETIME2     NULL,
    CONSTRAINT uq_orgreg_master_value UNIQUE(master_group, value_label)
);
GO

-- 2. Organization (sheet 01) -- the level above Legal Entity.
IF OBJECT_ID('grac_practice.registry_organization','U') IS NULL
CREATE TABLE grac_practice.registry_organization(
    registry_organization_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_registry_organization PRIMARY KEY,
    organization_code NVARCHAR(80) NOT NULL,
    registered_name NVARCHAR(250) NOT NULL,
    brand_name NVARCHAR(250) NULL,
    organization_type NVARCHAR(120) NOT NULL,
    industry NVARCHAR(160) NOT NULL,
    regulator_classification NVARCHAR(400) NULL,
    registration_cin NVARCHAR(80) NULL,
    lei NVARCHAR(40) NULL,
    incorporation_dt DATE NULL,
    registered_office_address NVARCHAR(500) NULL,
    city NVARCHAR(120) NULL,
    state NVARCHAR(120) NULL,
    country NVARCHAR(120) NULL,
    pin_code NVARCHAR(20) NULL,
    corporate_website NVARCHAR(300) NULL,
    financial_year_start NVARCHAR(5) NULL,
    financial_year_end NVARCHAR(5) NULL,
    primary_contact_role NVARCHAR(200) NULL,
    primary_contact_email NVARCHAR(250) NULL,
    data_cutoff_dt DATE NULL,
    record_status NVARCHAR(120) NOT NULL,
    remarks NVARCHAR(MAX) NULL,
    data_quality_note NVARCHAR(1000) NULL,
    entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_registry_org_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL CONSTRAINT df_registry_org_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,
    CONSTRAINT uq_registry_organization_code UNIQUE(organization_code)
);
GO

-- 12 Products & Services (new table).
IF OBJECT_ID('grac_practice.organization_product_service','U') IS NULL
CREATE TABLE grac_practice.organization_product_service(
    product_service_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_organization_product_service PRIMARY KEY,
    product_code NVARCHAR(80) NOT NULL,
    product_name NVARCHAR(200) NOT NULL,
    product_category NVARCHAR(120) NOT NULL,
    scheme_variant NVARCHAR(200) NULL,
    description NVARCHAR(MAX) NULL,
    owning_function_id BIGINT NULL,
    owning_department_id BIGINT NULL,
    product_owner_id BIGINT NULL,
    organization_id BIGINT NOT NULL,
    customer_segment NVARCHAR(200) NULL,
    secured_unsecured NVARCHAR(120) NULL,
    regulatory_classification NVARCHAR(400) NULL,
    launch_dt DATE NULL,
    withdrawal_dt DATE NULL,
    status NVARCHAR(120) NOT NULL,
    remarks NVARCHAR(MAX) NULL,
    entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_organization_product_service_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL CONSTRAINT df_organization_product_service_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,
    CONSTRAINT fk_organization_product_service_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT uq_organization_product_service_code UNIQUE(organization_id, product_code)
);
GO

-- 13 Delivery Channels (new table).
IF OBJECT_ID('grac_practice.organization_delivery_channel','U') IS NULL
CREATE TABLE grac_practice.organization_delivery_channel(
    channel_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_organization_delivery_channel PRIMARY KEY,
    channel_code NVARCHAR(80) NOT NULL,
    channel_name NVARCHAR(200) NOT NULL,
    channel_type NVARCHAR(120) NOT NULL,
    description NVARCHAR(MAX) NULL,
    owning_function_id BIGINT NULL,
    channel_owner_id BIGINT NULL,
    organization_id BIGINT NOT NULL,
    primary_division_id BIGINT NULL,
    customer_facing NVARCHAR(120) NOT NULL,
    operational_hours NVARCHAR(300) NULL,
    geographic_scope NVARCHAR(300) NULL,
    status NVARCHAR(120) NOT NULL,
    remarks NVARCHAR(MAX) NULL,
    entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_organization_delivery_channel_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL CONSTRAINT df_organization_delivery_channel_dt DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL,
    CONSTRAINT fk_organization_delivery_channel_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT uq_organization_delivery_channel_code UNIQUE(organization_id, channel_code)
);
GO

-- 3. Sheet columns on the existing tables (all NULLable; see header).
-- 02 Legal Entities -> grac_practice.organization
IF COL_LENGTH('grac_practice.organization','registry_organization_id') IS NULL
    ALTER TABLE grac_practice.organization ADD registry_organization_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization','short_name') IS NULL
    ALTER TABLE grac_practice.organization ADD short_name NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization','parent_organization_id') IS NULL
    ALTER TABLE grac_practice.organization ADD parent_organization_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization','registration_number') IS NULL
    ALTER TABLE grac_practice.organization ADD registration_number NVARCHAR(80) NULL;
IF COL_LENGTH('grac_practice.organization','incorporation_dt') IS NULL
    ALTER TABLE grac_practice.organization ADD incorporation_dt DATE NULL;
IF COL_LENGTH('grac_practice.organization','regulator') IS NULL
    ALTER TABLE grac_practice.organization ADD regulator NVARCHAR(250) NULL;
IF COL_LENGTH('grac_practice.organization','regulatory_classification') IS NULL
    ALTER TABLE grac_practice.organization ADD regulatory_classification NVARCHAR(400) NULL;
IF COL_LENGTH('grac_practice.organization','business_activity') IS NULL
    ALTER TABLE grac_practice.organization ADD business_activity NVARCHAR(500) NULL;
IF COL_LENGTH('grac_practice.organization','in_scope_for_grac') IS NULL
    ALTER TABLE grac_practice.organization ADD in_scope_for_grac NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization','entity_owner_employee_id') IS NULL
    ALTER TABLE grac_practice.organization ADD entity_owner_employee_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization','effective_from') IS NULL
    ALTER TABLE grac_practice.organization ADD effective_from DATE NULL;
IF COL_LENGTH('grac_practice.organization','effective_to') IS NULL
    ALTER TABLE grac_practice.organization ADD effective_to DATE NULL;
IF COL_LENGTH('grac_practice.organization','legal_entity_remarks') IS NULL
    ALTER TABLE grac_practice.organization ADD legal_entity_remarks NVARCHAR(MAX) NULL;
GO
-- 03 Organization Units -> grac_practice.organization_division
IF COL_LENGTH('grac_practice.organization_division','unit_type') IS NULL
    ALTER TABLE grac_practice.organization_division ADD unit_type NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_division','parent_division_id') IS NULL
    ALTER TABLE grac_practice.organization_division ADD parent_division_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_division','primary_location_id') IS NULL
    ALTER TABLE grac_practice.organization_division ADD primary_location_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_division','head_designation') IS NULL
    ALTER TABLE grac_practice.organization_division ADD head_designation NVARCHAR(200) NULL;
IF COL_LENGTH('grac_practice.organization_division','business_unit_type') IS NULL
    ALTER TABLE grac_practice.organization_division ADD business_unit_type NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_division','state_region') IS NULL
    ALTER TABLE grac_practice.organization_division ADD state_region NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_division','cost_centre') IS NULL
    ALTER TABLE grac_practice.organization_division ADD cost_centre NVARCHAR(80) NULL;
IF COL_LENGTH('grac_practice.organization_division','is_operational') IS NULL
    ALTER TABLE grac_practice.organization_division ADD is_operational NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_division','effective_from') IS NULL
    ALTER TABLE grac_practice.organization_division ADD effective_from DATE NULL;
IF COL_LENGTH('grac_practice.organization_division','effective_to') IS NULL
    ALTER TABLE grac_practice.organization_division ADD effective_to DATE NULL;
IF COL_LENGTH('grac_practice.organization_division','remarks') IS NULL
    ALTER TABLE grac_practice.organization_division ADD remarks NVARCHAR(MAX) NULL;
GO
-- 04 Locations -> grac_practice.organization_location
IF COL_LENGTH('grac_practice.organization_location','location_code') IS NULL
    ALTER TABLE grac_practice.organization_location ADD location_code NVARCHAR(80) NULL;
IF COL_LENGTH('grac_practice.organization_location','division_id') IS NULL
    ALTER TABLE grac_practice.organization_location ADD division_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_location','parent_location_id') IS NULL
    ALTER TABLE grac_practice.organization_location ADD parent_location_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_location','district') IS NULL
    ALTER TABLE grac_practice.organization_location ADD district NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_location','latitude') IS NULL
    ALTER TABLE grac_practice.organization_location ADD latitude DECIMAL(9,6) NULL;
IF COL_LENGTH('grac_practice.organization_location','longitude') IS NULL
    ALTER TABLE grac_practice.organization_location ADD longitude DECIMAL(9,6) NULL;
IF COL_LENGTH('grac_practice.organization_location','opening_dt') IS NULL
    ALTER TABLE grac_practice.organization_location ADD opening_dt DATE NULL;
IF COL_LENGTH('grac_practice.organization_location','closure_dt') IS NULL
    ALTER TABLE grac_practice.organization_location ADD closure_dt DATE NULL;
IF COL_LENGTH('grac_practice.organization_location','customer_facing') IS NULL
    ALTER TABLE grac_practice.organization_location ADD customer_facing NVARCHAR(120) NULL;
GO
-- 05 Departments -> grac_practice.organization_department
IF COL_LENGTH('grac_practice.organization_department','short_name') IS NULL
    ALTER TABLE grac_practice.organization_department ADD short_name NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_department','department_type') IS NULL
    ALTER TABLE grac_practice.organization_department ADD department_type NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_department','parent_department_id') IS NULL
    ALTER TABLE grac_practice.organization_department ADD parent_department_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_department','primary_division_id') IS NULL
    ALTER TABLE grac_practice.organization_department ADD primary_division_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_department','head_designation') IS NULL
    ALTER TABLE grac_practice.organization_department ADD head_designation NVARCHAR(200) NULL;
IF COL_LENGTH('grac_practice.organization_department','primary_business_function_id') IS NULL
    ALTER TABLE grac_practice.organization_department ADD primary_business_function_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_department','cost_centre') IS NULL
    ALTER TABLE grac_practice.organization_department ADD cost_centre NVARCHAR(80) NULL;
IF COL_LENGTH('grac_practice.organization_department','centralisation') IS NULL
    ALTER TABLE grac_practice.organization_department ADD centralisation NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_department','effective_from') IS NULL
    ALTER TABLE grac_practice.organization_department ADD effective_from DATE NULL;
IF COL_LENGTH('grac_practice.organization_department','effective_to') IS NULL
    ALTER TABLE grac_practice.organization_department ADD effective_to DATE NULL;
IF COL_LENGTH('grac_practice.organization_department','remarks') IS NULL
    ALTER TABLE grac_practice.organization_department ADD remarks NVARCHAR(MAX) NULL;
GO
-- 06 Business Functions -> grac_practice.organization_business_function
IF COL_LENGTH('grac_practice.organization_business_function','function_category') IS NULL
    ALTER TABLE grac_practice.organization_business_function ADD function_category NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_business_function','parent_function_id') IS NULL
    ALTER TABLE grac_practice.organization_business_function ADD parent_function_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_business_function','business_unit_type') IS NULL
    ALTER TABLE grac_practice.organization_business_function ADD business_unit_type NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_business_function','owner_employee_id') IS NULL
    ALTER TABLE grac_practice.organization_business_function ADD owner_employee_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_business_function','accountable_department_id') IS NULL
    ALTER TABLE grac_practice.organization_business_function ADD accountable_department_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_business_function','executive_sponsor_employee_id') IS NULL
    ALTER TABLE grac_practice.organization_business_function ADD executive_sponsor_employee_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_business_function','description') IS NULL
    ALTER TABLE grac_practice.organization_business_function ADD description NVARCHAR(MAX) NULL;
IF COL_LENGTH('grac_practice.organization_business_function','key_responsibilities') IS NULL
    ALTER TABLE grac_practice.organization_business_function ADD key_responsibilities NVARCHAR(MAX) NULL;
IF COL_LENGTH('grac_practice.organization_business_function','effective_from') IS NULL
    ALTER TABLE grac_practice.organization_business_function ADD effective_from DATE NULL;
IF COL_LENGTH('grac_practice.organization_business_function','effective_to') IS NULL
    ALTER TABLE grac_practice.organization_business_function ADD effective_to DATE NULL;
IF COL_LENGTH('grac_practice.organization_business_function','remarks') IS NULL
    ALTER TABLE grac_practice.organization_business_function ADD remarks NVARCHAR(MAX) NULL;
GO
-- 07 Teams -> grac_practice.organization_team
IF COL_LENGTH('grac_practice.organization_team','team_code') IS NULL
    ALTER TABLE grac_practice.organization_team ADD team_code NVARCHAR(80) NULL;
IF COL_LENGTH('grac_practice.organization_team','team_classification') IS NULL
    ALTER TABLE grac_practice.organization_team ADD team_classification NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_team','primary_function_id') IS NULL
    ALTER TABLE grac_practice.organization_team ADD primary_function_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_team','division_id') IS NULL
    ALTER TABLE grac_practice.organization_team ADD division_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_team','team_purpose') IS NULL
    ALTER TABLE grac_practice.organization_team ADD team_purpose NVARCHAR(MAX) NULL;
IF COL_LENGTH('grac_practice.organization_team','effective_from') IS NULL
    ALTER TABLE grac_practice.organization_team ADD effective_from DATE NULL;
IF COL_LENGTH('grac_practice.organization_team','effective_to') IS NULL
    ALTER TABLE grac_practice.organization_team ADD effective_to DATE NULL;
GO
-- 08 People -> grac_practice.organization_employee
IF COL_LENGTH('grac_practice.organization_employee','person_category') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD person_category NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_employee','employment_type') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD employment_type NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_employee','reference_no') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD reference_no NVARCHAR(80) NULL;
IF COL_LENGTH('grac_practice.organization_employee','official_phone') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD official_phone NVARCHAR(40) NULL;
IF COL_LENGTH('grac_practice.organization_employee','functional_role') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD functional_role NVARCHAR(200) NULL;
IF COL_LENGTH('grac_practice.organization_employee','primary_team_id') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD primary_team_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_employee','functional_reporting_to_id') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD functional_reporting_to_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_employee','appointment_dt') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD appointment_dt DATE NULL;
IF COL_LENGTH('grac_practice.organization_employee','exit_dt') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD exit_dt DATE NULL;
IF COL_LENGTH('grac_practice.organization_employee','person_status') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD person_status NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_employee','is_kmp') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD is_kmp NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_employee','remarks') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD remarks NVARCHAR(MAX) NULL;
GO
-- 09 Committees -> grac_practice.organization_committee
IF COL_LENGTH('grac_practice.organization_committee','committee_code') IS NULL
    ALTER TABLE grac_practice.organization_committee ADD committee_code NVARCHAR(80) NULL;
IF COL_LENGTH('grac_practice.organization_committee','committee_type') IS NULL
    ALTER TABLE grac_practice.organization_committee ADD committee_type NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_committee','mandate') IS NULL
    ALTER TABLE grac_practice.organization_committee ADD mandate NVARCHAR(MAX) NULL;
IF COL_LENGTH('grac_practice.organization_committee','scope_responsibilities') IS NULL
    ALTER TABLE grac_practice.organization_committee ADD scope_responsibilities NVARCHAR(MAX) NULL;
IF COL_LENGTH('grac_practice.organization_committee','review_frequency') IS NULL
    ALTER TABLE grac_practice.organization_committee ADD review_frequency NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_committee','tor_reference') IS NULL
    ALTER TABLE grac_practice.organization_committee ADD tor_reference NVARCHAR(200) NULL;
IF COL_LENGTH('grac_practice.organization_committee','constituted_dt') IS NULL
    ALTER TABLE grac_practice.organization_committee ADD constituted_dt DATE NULL;
IF COL_LENGTH('grac_practice.organization_committee','last_reviewed_dt') IS NULL
    ALTER TABLE grac_practice.organization_committee ADD last_reviewed_dt DATE NULL;
IF COL_LENGTH('grac_practice.organization_committee','next_review_due_dt') IS NULL
    ALTER TABLE grac_practice.organization_committee ADD next_review_due_dt DATE NULL;
IF COL_LENGTH('grac_practice.organization_committee','effective_from') IS NULL
    ALTER TABLE grac_practice.organization_committee ADD effective_from DATE NULL;
IF COL_LENGTH('grac_practice.organization_committee','effective_to') IS NULL
    ALTER TABLE grac_practice.organization_committee ADD effective_to DATE NULL;
GO
-- 10 Committee Members -> grac_practice.organization_committee_member
IF COL_LENGTH('grac_practice.organization_committee_member','membership_code') IS NULL
    ALTER TABLE grac_practice.organization_committee_member ADD membership_code NVARCHAR(80) NULL;
IF COL_LENGTH('grac_practice.organization_committee_member','member_since') IS NULL
    ALTER TABLE grac_practice.organization_committee_member ADD member_since DATE NULL;
IF COL_LENGTH('grac_practice.organization_committee_member','member_until') IS NULL
    ALTER TABLE grac_practice.organization_committee_member ADD member_until DATE NULL;
IF COL_LENGTH('grac_practice.organization_committee_member','is_voting_member') IS NULL
    ALTER TABLE grac_practice.organization_committee_member ADD is_voting_member NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_committee_member','is_permanent_invitee') IS NULL
    ALTER TABLE grac_practice.organization_committee_member ADD is_permanent_invitee NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_committee_member','participation_requirement') IS NULL
    ALTER TABLE grac_practice.organization_committee_member ADD participation_requirement NVARCHAR(300) NULL;
IF COL_LENGTH('grac_practice.organization_committee_member','remarks') IS NULL
    ALTER TABLE grac_practice.organization_committee_member ADD remarks NVARCHAR(MAX) NULL;
GO
-- 11 Business Processes -> grac_practice.organization_dependency_process
IF COL_LENGTH('grac_practice.organization_dependency_process','process_code') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD process_code NVARCHAR(80) NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','process_level') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD process_level NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','parent_process_id') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD parent_process_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','process_nature') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD process_nature NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','business_function_id') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD business_function_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','owning_department_id') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD owning_department_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','accountable_executive_id') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD accountable_executive_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','description') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD description NVARCHAR(MAX) NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','key_activities') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD key_activities NVARCHAR(MAX) NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','primary_product_id') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD primary_product_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','primary_channel_id') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD primary_channel_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','primary_division_id') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD primary_division_id BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','location_scope') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD location_scope NVARCHAR(300) NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','process_frequency') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD process_frequency NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','annual_volume') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD annual_volume BIGINT NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','customer_impact') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD customer_impact NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','regulatory_impact') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD regulatory_impact NVARCHAR(120) NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','regulatory_references') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD regulatory_references NVARCHAR(MAX) NULL;
IF COL_LENGTH('grac_practice.organization_dependency_process','effective_to') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD effective_to DATE NULL;
GO

-- 4. Bridges for the semicolon lists of sheets 11 and 13.
IF OBJECT_ID('grac_practice.organization_channel_product','U') IS NULL
CREATE TABLE grac_practice.organization_channel_product(
    channel_id         BIGINT NOT NULL,
    product_service_id BIGINT NOT NULL,
    entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_orgreg_chprod_by DEFAULT N'system',
    entered_dt DATETIME2     NOT NULL CONSTRAINT df_orgreg_chprod_dt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_organization_channel_product PRIMARY KEY(channel_id, product_service_id),
    CONSTRAINT fk_orgreg_chprod_channel FOREIGN KEY(channel_id) REFERENCES grac_practice.organization_delivery_channel(channel_id),
    CONSTRAINT fk_orgreg_chprod_product FOREIGN KEY(product_service_id) REFERENCES grac_practice.organization_product_service(product_service_id)
);
GO
IF OBJECT_ID('grac_practice.organization_channel_process','U') IS NULL
CREATE TABLE grac_practice.organization_channel_process(
    channel_id BIGINT NOT NULL,
    process_id BIGINT NOT NULL,
    entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_orgreg_chproc_by DEFAULT N'system',
    entered_dt DATETIME2     NOT NULL CONSTRAINT df_orgreg_chproc_dt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_organization_channel_process PRIMARY KEY(channel_id, process_id),
    CONSTRAINT fk_orgreg_chproc_channel FOREIGN KEY(channel_id) REFERENCES grac_practice.organization_delivery_channel(channel_id),
    CONSTRAINT fk_orgreg_chproc_process FOREIGN KEY(process_id) REFERENCES grac_practice.organization_dependency_process(process_id)
);
GO
IF OBJECT_ID('grac_practice.organization_process_risk_category','U') IS NULL
CREATE TABLE grac_practice.organization_process_risk_category(
    process_id    BIGINT        NOT NULL,
    risk_category NVARCHAR(120) NOT NULL,
    entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_orgreg_procrisk_by DEFAULT N'system',
    entered_dt DATETIME2     NOT NULL CONSTRAINT df_orgreg_procrisk_dt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_organization_process_risk_category PRIMARY KEY(process_id, risk_category),
    CONSTRAINT fk_orgreg_procrisk_process FOREIGN KEY(process_id) REFERENCES grac_practice.organization_dependency_process(process_id)
);
GO

-- 5. Referential integrity for every new reference column.
IF COL_LENGTH('grac_practice.organization','registry_organization_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_organization_registry_organization_id','F') IS NULL
    ALTER TABLE grac_practice.organization ADD CONSTRAINT fk_orgreg_organization_registry_organization_id FOREIGN KEY(registry_organization_id) REFERENCES grac_practice.registry_organization(registry_organization_id);
IF COL_LENGTH('grac_practice.organization','parent_organization_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_organization_parent_organization_id','F') IS NULL
    ALTER TABLE grac_practice.organization ADD CONSTRAINT fk_orgreg_organization_parent_organization_id FOREIGN KEY(parent_organization_id) REFERENCES grac_practice.organization(organization_id);
IF COL_LENGTH('grac_practice.organization','entity_owner_employee_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_organization_entity_owner_employee_id','F') IS NULL
    ALTER TABLE grac_practice.organization ADD CONSTRAINT fk_orgreg_organization_entity_owner_employee_id FOREIGN KEY(entity_owner_employee_id) REFERENCES grac_practice.organization_employee(employee_id);
IF COL_LENGTH('grac_practice.organization_division','parent_division_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_division_parent_division_id','F') IS NULL
    ALTER TABLE grac_practice.organization_division ADD CONSTRAINT fk_orgreg_org_division_parent_division_id FOREIGN KEY(parent_division_id) REFERENCES grac_practice.organization_division(division_id);
IF COL_LENGTH('grac_practice.organization_division','primary_location_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_division_primary_location_id','F') IS NULL
    ALTER TABLE grac_practice.organization_division ADD CONSTRAINT fk_orgreg_org_division_primary_location_id FOREIGN KEY(primary_location_id) REFERENCES grac_practice.organization_location(location_id);
IF COL_LENGTH('grac_practice.organization_location','division_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_location_division_id','F') IS NULL
    ALTER TABLE grac_practice.organization_location ADD CONSTRAINT fk_orgreg_org_location_division_id FOREIGN KEY(division_id) REFERENCES grac_practice.organization_division(division_id);
IF COL_LENGTH('grac_practice.organization_location','parent_location_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_location_parent_location_id','F') IS NULL
    ALTER TABLE grac_practice.organization_location ADD CONSTRAINT fk_orgreg_org_location_parent_location_id FOREIGN KEY(parent_location_id) REFERENCES grac_practice.organization_location(location_id);
IF COL_LENGTH('grac_practice.organization_department','parent_department_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_department_parent_department_id','F') IS NULL
    ALTER TABLE grac_practice.organization_department ADD CONSTRAINT fk_orgreg_org_department_parent_department_id FOREIGN KEY(parent_department_id) REFERENCES grac_practice.organization_department(department_id);
IF COL_LENGTH('grac_practice.organization_department','primary_division_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_department_primary_division_id','F') IS NULL
    ALTER TABLE grac_practice.organization_department ADD CONSTRAINT fk_orgreg_org_department_primary_division_id FOREIGN KEY(primary_division_id) REFERENCES grac_practice.organization_division(division_id);
IF COL_LENGTH('grac_practice.organization_department','primary_business_function_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_department_primary_business_function_id','F') IS NULL
    ALTER TABLE grac_practice.organization_department ADD CONSTRAINT fk_orgreg_org_department_primary_business_function_id FOREIGN KEY(primary_business_function_id) REFERENCES grac_practice.organization_business_function(business_function_id);
IF COL_LENGTH('grac_practice.organization_business_function','parent_function_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_business_function_parent_function_id','F') IS NULL
    ALTER TABLE grac_practice.organization_business_function ADD CONSTRAINT fk_orgreg_org_business_function_parent_function_id FOREIGN KEY(parent_function_id) REFERENCES grac_practice.organization_business_function(business_function_id);
IF COL_LENGTH('grac_practice.organization_business_function','owner_employee_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_business_function_owner_employee_id','F') IS NULL
    ALTER TABLE grac_practice.organization_business_function ADD CONSTRAINT fk_orgreg_org_business_function_owner_employee_id FOREIGN KEY(owner_employee_id) REFERENCES grac_practice.organization_employee(employee_id);
IF COL_LENGTH('grac_practice.organization_business_function','accountable_department_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_business_function_accountable_department_id','F') IS NULL
    ALTER TABLE grac_practice.organization_business_function ADD CONSTRAINT fk_orgreg_org_business_function_accountable_department_id FOREIGN KEY(accountable_department_id) REFERENCES grac_practice.organization_department(department_id);
IF COL_LENGTH('grac_practice.organization_business_function','executive_sponsor_employee_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_business_function_executive_sponsor_employee_id','F') IS NULL
    ALTER TABLE grac_practice.organization_business_function ADD CONSTRAINT fk_orgreg_org_business_function_executive_sponsor_employee_id FOREIGN KEY(executive_sponsor_employee_id) REFERENCES grac_practice.organization_employee(employee_id);
IF COL_LENGTH('grac_practice.organization_team','primary_function_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_team_primary_function_id','F') IS NULL
    ALTER TABLE grac_practice.organization_team ADD CONSTRAINT fk_orgreg_org_team_primary_function_id FOREIGN KEY(primary_function_id) REFERENCES grac_practice.organization_business_function(business_function_id);
IF COL_LENGTH('grac_practice.organization_team','division_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_team_division_id','F') IS NULL
    ALTER TABLE grac_practice.organization_team ADD CONSTRAINT fk_orgreg_org_team_division_id FOREIGN KEY(division_id) REFERENCES grac_practice.organization_division(division_id);
IF COL_LENGTH('grac_practice.organization_employee','primary_team_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_employee_primary_team_id','F') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD CONSTRAINT fk_orgreg_org_employee_primary_team_id FOREIGN KEY(primary_team_id) REFERENCES grac_practice.organization_team(team_id);
IF COL_LENGTH('grac_practice.organization_employee','functional_reporting_to_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_employee_functional_reporting_to_id','F') IS NULL
    ALTER TABLE grac_practice.organization_employee ADD CONSTRAINT fk_orgreg_org_employee_functional_reporting_to_id FOREIGN KEY(functional_reporting_to_id) REFERENCES grac_practice.organization_employee(employee_id);
IF COL_LENGTH('grac_practice.organization_dependency_process','parent_process_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_dependency_process_parent_process_id','F') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD CONSTRAINT fk_orgreg_org_dependency_process_parent_process_id FOREIGN KEY(parent_process_id) REFERENCES grac_practice.organization_dependency_process(process_id);
IF COL_LENGTH('grac_practice.organization_dependency_process','business_function_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_dependency_process_business_function_id','F') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD CONSTRAINT fk_orgreg_org_dependency_process_business_function_id FOREIGN KEY(business_function_id) REFERENCES grac_practice.organization_business_function(business_function_id);
IF COL_LENGTH('grac_practice.organization_dependency_process','owning_department_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_dependency_process_owning_department_id','F') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD CONSTRAINT fk_orgreg_org_dependency_process_owning_department_id FOREIGN KEY(owning_department_id) REFERENCES grac_practice.organization_department(department_id);
IF COL_LENGTH('grac_practice.organization_dependency_process','accountable_executive_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_dependency_process_accountable_executive_id','F') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD CONSTRAINT fk_orgreg_org_dependency_process_accountable_executive_id FOREIGN KEY(accountable_executive_id) REFERENCES grac_practice.organization_employee(employee_id);
IF COL_LENGTH('grac_practice.organization_dependency_process','primary_product_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_dependency_process_primary_product_id','F') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD CONSTRAINT fk_orgreg_org_dependency_process_primary_product_id FOREIGN KEY(primary_product_id) REFERENCES grac_practice.organization_product_service(product_service_id);
IF COL_LENGTH('grac_practice.organization_dependency_process','primary_channel_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_dependency_process_primary_channel_id','F') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD CONSTRAINT fk_orgreg_org_dependency_process_primary_channel_id FOREIGN KEY(primary_channel_id) REFERENCES grac_practice.organization_delivery_channel(channel_id);
IF COL_LENGTH('grac_practice.organization_dependency_process','primary_division_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_dependency_process_primary_division_id','F') IS NULL
    ALTER TABLE grac_practice.organization_dependency_process ADD CONSTRAINT fk_orgreg_org_dependency_process_primary_division_id FOREIGN KEY(primary_division_id) REFERENCES grac_practice.organization_division(division_id);
IF COL_LENGTH('grac_practice.organization_product_service','owning_function_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_product_service_owning_function_id','F') IS NULL
    ALTER TABLE grac_practice.organization_product_service ADD CONSTRAINT fk_orgreg_org_product_service_owning_function_id FOREIGN KEY(owning_function_id) REFERENCES grac_practice.organization_business_function(business_function_id);
IF COL_LENGTH('grac_practice.organization_product_service','owning_department_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_product_service_owning_department_id','F') IS NULL
    ALTER TABLE grac_practice.organization_product_service ADD CONSTRAINT fk_orgreg_org_product_service_owning_department_id FOREIGN KEY(owning_department_id) REFERENCES grac_practice.organization_department(department_id);
IF COL_LENGTH('grac_practice.organization_product_service','product_owner_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_product_service_product_owner_id','F') IS NULL
    ALTER TABLE grac_practice.organization_product_service ADD CONSTRAINT fk_orgreg_org_product_service_product_owner_id FOREIGN KEY(product_owner_id) REFERENCES grac_practice.organization_employee(employee_id);
IF COL_LENGTH('grac_practice.organization_delivery_channel','owning_function_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_delivery_channel_owning_function_id','F') IS NULL
    ALTER TABLE grac_practice.organization_delivery_channel ADD CONSTRAINT fk_orgreg_org_delivery_channel_owning_function_id FOREIGN KEY(owning_function_id) REFERENCES grac_practice.organization_business_function(business_function_id);
IF COL_LENGTH('grac_practice.organization_delivery_channel','channel_owner_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_delivery_channel_channel_owner_id','F') IS NULL
    ALTER TABLE grac_practice.organization_delivery_channel ADD CONSTRAINT fk_orgreg_org_delivery_channel_channel_owner_id FOREIGN KEY(channel_owner_id) REFERENCES grac_practice.organization_employee(employee_id);
IF COL_LENGTH('grac_practice.organization_delivery_channel','primary_division_id') IS NOT NULL AND OBJECT_ID('grac_practice.fk_orgreg_org_delivery_channel_primary_division_id','F') IS NULL
    ALTER TABLE grac_practice.organization_delivery_channel ADD CONSTRAINT fk_orgreg_org_delivery_channel_primary_division_id FOREIGN KEY(primary_division_id) REFERENCES grac_practice.organization_division(division_id);
GO

-- 6. Codes: unique per Legal Entity (filtered: rows created before the registry have none).
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_orgreg_org_location_code' AND object_id = OBJECT_ID('grac_practice.organization_location'))
    EXEC('CREATE UNIQUE INDEX ux_orgreg_org_location_code ON grac_practice.organization_location(organization_id, location_code) WHERE location_code IS NOT NULL');
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_orgreg_org_team_code' AND object_id = OBJECT_ID('grac_practice.organization_team'))
    EXEC('CREATE UNIQUE INDEX ux_orgreg_org_team_code ON grac_practice.organization_team(organization_id, team_code) WHERE team_code IS NOT NULL');
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_orgreg_org_committee_code' AND object_id = OBJECT_ID('grac_practice.organization_committee'))
    EXEC('CREATE UNIQUE INDEX ux_orgreg_org_committee_code ON grac_practice.organization_committee(organization_id, committee_code) WHERE committee_code IS NOT NULL');
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_orgreg_org_committee_member_code' AND object_id = OBJECT_ID('grac_practice.organization_committee_member'))
    EXEC('CREATE UNIQUE INDEX ux_orgreg_org_committee_member_code ON grac_practice.organization_committee_member(organization_id, membership_code) WHERE membership_code IS NOT NULL');
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_orgreg_org_dependency_process_code' AND object_id = OBJECT_ID('grac_practice.organization_dependency_process'))
    EXEC('CREATE UNIQUE INDEX ux_orgreg_org_dependency_process_code ON grac_practice.organization_dependency_process(organization_id, process_code) WHERE process_code IS NOT NULL');
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_orgreg_org_registry_org' AND object_id = OBJECT_ID('grac_practice.organization'))
    EXEC('CREATE INDEX ix_orgreg_org_registry_org ON grac_practice.organization(registry_organization_id)');
GO

-- 7. Existing organizations are GRAC tenants, so they are in GRAC scope.
--    Nothing else is backfilled: the sheet-02 columns stay empty until the
--    Legal Entity is edited, and no Organization is invented for them.
IF COL_LENGTH('grac_practice.organization','in_scope_for_grac') IS NOT NULL
    EXEC('UPDATE grac_practice.organization SET in_scope_for_grac = N''Yes'' WHERE in_scope_for_grac IS NULL');
GO

PRINT '--- 569 verification ---';
SELECT t.name AS table_name, COUNT(c.column_id) AS columns_now
  FROM sys.tables t JOIN sys.columns c ON c.object_id = t.object_id
 WHERE SCHEMA_NAME(t.schema_id) = 'grac_practice'
   AND t.name IN ('registry_organization','organization','organization_division','organization_location',
                  'organization_department','organization_business_function','organization_team',
                  'organization_employee','organization_committee','organization_committee_member',
                  'organization_dependency_process','organization_product_service',
                  'organization_delivery_channel','org_registry_master_value')
 GROUP BY t.name ORDER BY t.name;
GO
SET NOEXEC OFF;
GO
PRINT '569 complete. Next: 570 (masters, menu), 571 (procedures), 572 (sample data).';
GO
