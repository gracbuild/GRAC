-- =====================================================================
-- Lakeshore -- Audit Universe subcategories (data load, not a migration)
--
-- Source: Lakeshore_Audit_Universe_Subcategories_C_to_L.xlsx (sheet
-- Subcategories_Upload), 102 rows, categories C to L:
--   Department, Business Function, Business Process, Region, Branch /
--   Location, Technology Function, Regulatory Activity, Management-defined,
--   Clinical Service Line, Committee / Governing Body.
-- Legal Entity and Business Unit (A, B) are not in the sheet (already entered).
--
-- What it does
--   * Finds the organization: set @organization_id, or leave it NULL to
--     use the one organization whose name contains 'Lakeshore'.
--   * Matches each row's Category by the category NAME of that organization
--     (Universe Configuration -> Category). A name that is not there stops the
--     script and lists it; nothing is written. Add the missing category in
--     Universe Configuration first (e.g. Clinical Service Line, Committee /
--     Governing Body are not among the default categories).
--   * Saves each row through sp_org_assurance_universe_master_save (577):
--     a new code is added, an existing SUBCATEGORY code is updated (name,
--     category, order, active, description). Same validation and Universe
--     history ("MASTER") as the screen.
--   * One transaction: all rows or none. Safe to run again.
-- Requires: 577.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @organization_id BIGINT       = NULL;               -- set the id, or NULL = find 'Lakeshore'
DECLARE @actor           NVARCHAR(100) = N'data-load-lakeshore-subcategories';

IF OBJECT_ID('grac_practice.sp_org_assurance_universe_master_save', 'P') IS NULL
    THROW 50001, 'Run 577_audit_universe.sql first.', 1;

IF @organization_id IS NULL
BEGIN
    IF (SELECT COUNT(*) FROM grac_practice.organization WHERE organization_name LIKE N'%Lakeshore%') <> 1
        THROW 50002, 'Not exactly one organization named like ''Lakeshore''. Set @organization_id.', 1;
    SELECT @organization_id = organization_id FROM grac_practice.organization WHERE organization_name LIKE N'%Lakeshore%';
END
IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
    THROW 50003, 'The organization was not found.', 1;
DECLARE @org_name NVARCHAR(250) = (SELECT organization_name FROM grac_practice.organization WHERE organization_id = @organization_id);
PRINT 'Organization: ' + CAST(@organization_id AS NVARCHAR(20)) + ' - ' + @org_name;

-- The default masters, if the organization never opened Universe Configuration
-- (adds only what is missing).
EXEC grac_practice.sp_org_assurance_universe_master_seed @organization_id = @organization_id, @actor = @actor;

DECLARE @src TABLE(rn INT IDENTITY(1,1), code NVARCHAR(40), name NVARCHAR(200), category_name NVARCHAR(200),
                   display_order INT, is_active BIT, description NVARCHAR(1000), category_id BIGINT NULL, master_id BIGINT NULL);
INSERT INTO @src (code, name, category_name, display_order, is_active, description) VALUES
    (N'CLINICAL_DEPT', N'Clinical Department', N'Department', 10, 1, N'Medical departments providing direct patient care.'),
    (N'NURSING', N'Nursing Department', N'Department', 20, 1, N'Nursing administration and patient care services.'),
    (N'MEDICAL_ADMIN', N'Medical Administration', N'Department', 30, 1, N'Medical administration and doctor coordination.'),
    (N'PATIENT_ADMIN', N'Patient Administration', N'Department', 40, 1, N'Patient registration, admission, discharge and patient records.'),
    (N'PHARMACY', N'Pharmacy', N'Department', 50, 1, N'Pharmacy and medication dispensing operations.'),
    (N'LABORATORY', N'Laboratory', N'Department', 60, 1, N'Laboratory and pathology operations.'),
    (N'RADIOLOGY', N'Radiology', N'Department', 70, 1, N'Radiology and imaging operations.'),
    (N'FINANCE', N'Finance & Accounts', N'Department', 80, 1, N'Financial accounting, treasury and financial reporting.'),
    (N'HR', N'Human Resources', N'Department', 90, 1, N'Human resources and employee administration.'),
    (N'PROCUREMENT', N'Procurement & Stores', N'Department', 100, 1, N'Procurement, inventory and stores management.'),
    (N'IT', N'Information Technology', N'Department', 110, 1, N'IT operations and technology administration.'),
    (N'QUALITY', N'Quality & Patient Safety', N'Department', 120, 1, N'Quality assurance, accreditation and patient safety.'),
    (N'FACILITIES', N'Facilities & Engineering', N'Department', 130, 1, N'Building, utilities and engineering maintenance.'),
    (N'HOUSEKEEPING', N'Housekeeping', N'Department', 140, 1, N'Housekeeping and environmental services.'),
    (N'SECURITY', N'Security', N'Department', 150, 1, N'Physical security and access control.'),
    (N'PATIENT_CARE', N'Patient Care Delivery', N'Business Function', 10, 1, N'Delivery of clinical and medical care.'),
    (N'CLINICAL_SUPPORT', N'Clinical Support', N'Business Function', 20, 1, N'Functions supporting clinical service delivery.'),
    (N'PATIENT_ADMINISTRATION', N'Patient Administration', N'Business Function', 30, 1, N'Patient registration, admission and discharge management.'),
    (N'REVENUE_CYCLE', N'Revenue Cycle Management', N'Business Function', 40, 1, N'Billing, collections, insurance and revenue realisation.'),
    (N'FINANCIAL_MANAGEMENT', N'Financial Management', N'Business Function', 50, 1, N'Financial planning, accounting and treasury.'),
    (N'PEOPLE_MANAGEMENT', N'People Management', N'Business Function', 60, 1, N'Recruitment, employee management and development.'),
    (N'SUPPLY_CHAIN', N'Supply Chain Management', N'Business Function', 70, 1, N'Procurement, inventory and materials management.'),
    (N'QUALITY_SAFETY', N'Quality & Patient Safety', N'Business Function', 80, 1, N'Clinical quality, patient safety and accreditation.'),
    (N'REGULATORY_COMPLIANCE', N'Regulatory Compliance', N'Business Function', 90, 1, N'Regulatory monitoring and statutory compliance.'),
    (N'TECHNOLOGY_MANAGEMENT', N'Technology Management', N'Business Function', 100, 1, N'Technology strategy, operations and security.'),
    (N'FACILITY_MANAGEMENT', N'Facility Management', N'Business Function', 110, 1, N'Infrastructure, utilities and facility maintenance.'),
    (N'GOVERNANCE', N'Corporate Governance', N'Business Function', 120, 1, N'Governance, oversight and organisational accountability.'),
    (N'PATIENT_REGISTRATION', N'Patient Registration', N'Business Process', 10, 1, N'Patient registration and demographic capture.'),
    (N'APPOINTMENT', N'Appointment Management', N'Business Process', 20, 1, N'Appointment scheduling and management.'),
    (N'ADMISSION', N'Patient Admission', N'Business Process', 30, 1, N'Inpatient admission and bed allocation.'),
    (N'CLINICAL_ASSESSMENT', N'Clinical Assessment', N'Business Process', 40, 1, N'Patient assessment, diagnosis and treatment planning.'),
    (N'MEDICATION', N'Medication Management', N'Business Process', 50, 1, N'Prescription, dispensing and administration of medication.'),
    (N'DIAGNOSTICS', N'Diagnostic Management', N'Business Process', 60, 1, N'Ordering, performing and reporting diagnostic tests.'),
    (N'OT_MANAGEMENT', N'Operation Theatre Management', N'Business Process', 70, 1, N'Surgical scheduling and perioperative management.'),
    (N'ICU_MANAGEMENT', N'Critical Care Management', N'Business Process', 80, 1, N'Intensive and critical care management.'),
    (N'INFECTION_CONTROL', N'Infection Prevention & Control', N'Business Process', 90, 1, N'Infection surveillance and prevention.'),
    (N'DISCHARGE', N'Patient Discharge', N'Business Process', 100, 1, N'Discharge planning, documentation and settlement.'),
    (N'BILLING', N'Patient Billing', N'Business Process', 110, 1, N'Billing, tariff application and charge capture.'),
    (N'INSURANCE', N'Insurance & TPA Claims', N'Business Process', 120, 1, N'Insurance authorisation and claims processing.'),
    (N'PROCUREMENT_PROCESS', N'Procurement Management', N'Business Process', 130, 1, N'Purchase requisition, ordering and vendor payments.'),
    (N'INVENTORY', N'Inventory Management', N'Business Process', 140, 1, N'Inventory receipt, storage and issue.'),
    (N'PAYROLL', N'Payroll Processing', N'Business Process', 150, 1, N'Salary computation and payroll disbursement.'),
    (N'COMPLAINTS', N'Patient Grievance Management', N'Business Process', 160, 1, N'Patient complaints and grievance resolution.'),
    (N'STATE', N'State', N'Region', 10, 1, N'Geographical grouping at state level.'),
    (N'ZONE', N'Zone', N'Region', 20, 1, N'Geographical grouping at zonal level.'),
    (N'DISTRICT', N'District', N'Region', 30, 1, N'Geographical grouping at district level.'),
    (N'CLUSTER', N'Cluster', N'Region', 40, 1, N'Group of operating locations.'),
    (N'MAIN_HOSPITAL', N'Main Hospital', N'Branch / Location', 10, 1, N'Primary hospital facility.'),
    (N'SATELLITE_HOSPITAL', N'Satellite Hospital', N'Branch / Location', 20, 1, N'Additional hospital facility.'),
    (N'CLINIC', N'Clinic', N'Branch / Location', 30, 1, N'Outpatient clinic or consultation facility.'),
    (N'DIAGNOSTIC_CENTRE', N'Diagnostic Centre', N'Branch / Location', 40, 1, N'Independent diagnostic facility.'),
    (N'CORPORATE_OFFICE', N'Corporate Office', N'Branch / Location', 50, 1, N'Central administrative office.'),
    (N'WAREHOUSE', N'Warehouse / Central Store', N'Branch / Location', 60, 1, N'Centralised storage and inventory facility.'),
    (N'IT_INFRA', N'IT Infrastructure', N'Technology Function', 10, 1, N'Servers, storage, endpoints and infrastructure.'),
    (N'NETWORK', N'Network & Connectivity', N'Technology Function', 20, 1, N'Network, internet and communication infrastructure.'),
    (N'APPLICATIONS', N'Application Management', N'Technology Function', 30, 1, N'Business and clinical application systems.'),
    (N'CYBERSECURITY', N'Cybersecurity', N'Technology Function', 40, 1, N'Cybersecurity operations and information protection.'),
    (N'DATA_MANAGEMENT', N'Data Management', N'Technology Function', 50, 1, N'Data governance, databases and reporting.'),
    (N'IT_SERVICE', N'IT Service Management', N'Technology Function', 60, 1, N'IT service desk, incident and change management.'),
    (N'DR_BCP', N'Disaster Recovery & BCP', N'Technology Function', 70, 1, N'IT disaster recovery and business continuity.'),
    (N'CLINICAL_ESTABLISHMENT', N'Clinical Establishment Compliance', N'Regulatory Activity', 10, 1, N'Compliance with applicable clinical establishment requirements.'),
    (N'NABH', N'NABH Accreditation', N'Regulatory Activity', 20, 1, N'Compliance with applicable NABH accreditation standards.'),
    (N'FIRE_SAFETY', N'Fire & Life Safety', N'Regulatory Activity', 30, 1, N'Statutory fire and life safety compliance.'),
    (N'BIOMEDICAL_WASTE', N'Biomedical Waste Management', N'Regulatory Activity', 40, 1, N'Biomedical waste handling and disposal compliance.'),
    (N'PHARMACY_REGULATION', N'Pharmacy & Drug Regulation', N'Regulatory Activity', 50, 1, N'Applicable pharmacy and drug regulatory compliance.'),
    (N'AERB', N'AERB Compliance', N'Regulatory Activity', 60, 1, N'Radiation safety and applicable AERB requirements.'),
    (N'PCPNDT', N'PCPNDT Compliance', N'Regulatory Activity', 70, 1, N'Compliance with applicable PCPNDT requirements.'),
    (N'BLOOD_BANK', N'Blood Bank Regulation', N'Regulatory Activity', 80, 1, N'Blood bank licensing and regulatory compliance.'),
    (N'ENVIRONMENT', N'Environmental Compliance', N'Regulatory Activity', 90, 1, N'Environmental and pollution control requirements.'),
    (N'STRATEGIC_PRIORITY', N'Strategic Priority', N'Management-defined', 10, 1, N'Subject identified as strategically important by management.'),
    (N'HIGH_RISK_AREA', N'High Risk Area', N'Management-defined', 20, 1, N'Subject identified as having elevated organisational risk.'),
    (N'SPECIAL_FOCUS', N'Special Audit Focus', N'Management-defined', 30, 1, N'Subject identified for specific management or audit attention.'),
    (N'EMERGING_RISK', N'Emerging Risk Area', N'Management-defined', 40, 1, N'Subject associated with emerging or changing risks.'),
    (N'INCIDENT_DRIVEN', N'Incident Driven', N'Management-defined', 50, 1, N'Subject identified following an incident or significant event.'),
    (N'CARDIOLOGY', N'Cardiology', N'Clinical Service Line', 10, 1, N'Cardiac care and cardiovascular services.'),
    (N'NEUROLOGY', N'Neurology', N'Clinical Service Line', 20, 1, N'Neurological diagnosis and treatment.'),
    (N'NEUROSURGERY', N'Neurosurgery', N'Clinical Service Line', 30, 1, N'Surgical treatment of neurological conditions.'),
    (N'ONCOLOGY', N'Oncology', N'Clinical Service Line', 40, 1, N'Cancer diagnosis and treatment.'),
    (N'ORTHOPAEDICS', N'Orthopaedics', N'Clinical Service Line', 50, 1, N'Musculoskeletal and orthopaedic care.'),
    (N'GASTROENTEROLOGY', N'Gastroenterology', N'Clinical Service Line', 60, 1, N'Gastrointestinal and digestive health services.'),
    (N'NEPHROLOGY', N'Nephrology', N'Clinical Service Line', 70, 1, N'Kidney care and renal services.'),
    (N'UROLOGY', N'Urology', N'Clinical Service Line', 80, 1, N'Urinary and male reproductive health services.'),
    (N'PULMONOLOGY', N'Pulmonology', N'Clinical Service Line', 90, 1, N'Respiratory and pulmonary care.'),
    (N'GYNAECOLOGY', N'Obstetrics & Gynaecology', N'Clinical Service Line', 100, 1, N'Women''s health and maternity services.'),
    (N'PAEDIATRICS', N'Paediatrics', N'Clinical Service Line', 110, 1, N'Child healthcare services.'),
    (N'GENERAL_MEDICINE', N'General Medicine', N'Clinical Service Line', 120, 1, N'General medical diagnosis and treatment.'),
    (N'GENERAL_SURGERY', N'General Surgery', N'Clinical Service Line', 130, 1, N'General surgical services.'),
    (N'EMERGENCY_MEDICINE', N'Emergency Medicine', N'Clinical Service Line', 140, 1, N'Emergency medical care.'),
    (N'CRITICAL_CARE', N'Critical Care', N'Clinical Service Line', 150, 1, N'Intensive and critical care services.'),
    (N'DERMATOLOGY', N'Dermatology', N'Clinical Service Line', 160, 1, N'Skin and related medical services.'),
    (N'ENT', N'ENT', N'Clinical Service Line', 170, 1, N'Ear, nose and throat services.'),
    (N'OPHTHALMOLOGY', N'Ophthalmology', N'Clinical Service Line', 180, 1, N'Eye care services.'),
    (N'DENTISTRY', N'Dentistry', N'Clinical Service Line', 190, 1, N'Dental care services.'),
    (N'ANAESTHESIOLOGY', N'Anaesthesiology', N'Clinical Service Line', 200, 1, N'Anaesthesia and perioperative medical services.'),
    (N'BOARD_COMMITTEE', N'Board Committee', N'Committee / Governing Body', 10, 1, N'Committee constituted by the Board.'),
    (N'MEDICAL_ADVISORY', N'Medical Advisory Committee', N'Committee / Governing Body', 20, 1, N'Medical governance and clinical oversight.'),
    (N'QUALITY_COMMITTEE', N'Quality Committee', N'Committee / Governing Body', 30, 1, N'Quality management and improvement oversight.'),
    (N'INFECTION_CONTROL_COMMITTEE', N'Infection Control Committee', N'Committee / Governing Body', 40, 1, N'Infection prevention and control oversight.'),
    (N'PHARMACY_COMMITTEE', N'Pharmacy & Therapeutics Committee', N'Committee / Governing Body', 50, 1, N'Medication management and formulary oversight.'),
    (N'ETHICS_COMMITTEE', N'Ethics Committee', N'Committee / Governing Body', 60, 1, N'Clinical and research ethics oversight.'),
    (N'BIOMEDICAL_WASTE_COMMITTEE', N'Biomedical Waste Committee', N'Committee / Governing Body', 70, 1, N'Biomedical waste governance.'),
    (N'PATIENT_SAFETY_COMMITTEE', N'Patient Safety Committee', N'Committee / Governing Body', 80, 1, N'Patient safety monitoring and improvement.');

UPDATE s SET category_id = m.universe_master_id
  FROM @src s
  JOIN grac_practice.org_assurance_universe_master m
    ON m.organization_id = @organization_id AND m.master_group = N'CATEGORY'
   AND LTRIM(RTRIM(m.name)) = LTRIM(RTRIM(s.category_name));

IF EXISTS (SELECT 1 FROM @src WHERE category_id IS NULL)
BEGIN
    DECLARE @missing NVARCHAR(MAX) = (SELECT STRING_AGG(category_name, N', ')
                                        FROM (SELECT DISTINCT category_name FROM @src WHERE category_id IS NULL) x);
    DECLARE @msg NVARCHAR(2048) = N'Categories not found for this organization (add them in Universe Configuration first): ' + @missing;
    THROW 50004, @msg, 1;
END

UPDATE s SET master_id = m.universe_master_id
  FROM @src s
  JOIN grac_practice.org_assurance_universe_master m
    ON m.organization_id = @organization_id AND m.master_group = N'SUBCATEGORY'
   AND m.code = UPPER(REPLACE(LTRIM(RTRIM(s.code)), N' ', N'_'));

DECLARE @rn INT = 1, @max INT = (SELECT MAX(rn) FROM @src), @added INT = 0, @updated INT = 0;
DECLARE @id BIGINT, @code NVARCHAR(40), @name NVARCHAR(200), @cat BIGINT, @ord INT, @act BIT, @descr NVARCHAR(1000), @out BIGINT,
        @grp NVARCHAR(30) = N'SUBCATEGORY';

BEGIN TRY
    BEGIN TRAN;
    WHILE @rn <= @max
    BEGIN
        SELECT @id = master_id, @code = code, @name = name, @cat = category_id, @ord = display_order,
               @act = is_active, @descr = description
          FROM @src WHERE rn = @rn;
        SET @out = NULL;
        EXEC grac_practice.sp_org_assurance_universe_master_save
             @organization_id = @organization_id, @universe_master_id = @id, @master_group = @grp,
             @code = @code, @name = @name, @description = @descr, @parent_master_id = @cat,
             @display_order = @ord, @is_active = @act, @actor = @actor, @universe_master_id_out = @out OUTPUT;
        IF @id IS NULL SET @added += 1; ELSE SET @updated += 1;
        SET @rn += 1;
    END
    COMMIT;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    DECLARE @err NVARCHAR(2048) = N'Row ' + CAST(@rn AS NVARCHAR(10)) + N' (' + ISNULL(@code, N'?') + N'): ' + ERROR_MESSAGE()
                                + N' -- nothing was saved.';
    THROW 50005, @err, 1;
END CATCH

PRINT 'Subcategories added = ' + CAST(@added AS NVARCHAR(10)) + ', updated = ' + CAST(@updated AS NVARCHAR(10));

-- Check: subcategories per category.
SELECT c.name AS Category, COUNT(s.universe_master_id) AS Subcategories
  FROM grac_practice.org_assurance_universe_master c
  LEFT JOIN grac_practice.org_assurance_universe_master s
    ON s.parent_master_id = c.universe_master_id AND s.master_group = N'SUBCATEGORY'
 WHERE c.organization_id = @organization_id AND c.master_group = N'CATEGORY'
 GROUP BY c.name, c.display_order
 ORDER BY c.display_order;
