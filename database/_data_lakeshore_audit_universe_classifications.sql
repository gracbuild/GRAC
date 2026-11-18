-- =====================================================================
-- Lakeshore -- Audit Universe Audit Classifications (data load, not a migration)
--
-- Source: Lakeshore_Audit_Classifications_Backend_Upload.xlsx (sheet
-- Audit_Classifications), 20 rows. Audit Classification has no parent
-- category; every value is offered for every subject.
--
-- What it does
--   * Finds the organization: set @organization_id, or leave it NULL to
--     use the one organization whose name contains 'Lakeshore'.
--   * Saves each row through sp_org_assurance_universe_master_save (577):
--     a new code is added, an existing CLASSIFICATION code is updated (name,
--     order, active, description). Same validation and Universe history
--     ("MASTER") as Universe Configuration.
--   * One transaction: all rows or none. Safe to run again.
-- After it runs, reload Audit Universe with Ctrl+F5 (the page reads the
-- masters once when it opens).
-- Requires: 577.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @organization_id BIGINT        = NULL;              -- set the id, or NULL = find 'Lakeshore'
DECLARE @actor           NVARCHAR(100) = N'data-load-lakeshore-classifications';

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

DECLARE @src TABLE(rn INT IDENTITY(1,1), code NVARCHAR(40), name NVARCHAR(200), display_order INT, is_active BIT,
                   description NVARCHAR(1000), master_id BIGINT NULL);
INSERT INTO @src (code, name, display_order, is_active, description) VALUES
    (N'CLINICAL', N'Clinical Operations', 10, 1, N'Clinical care delivery, diagnosis, treatment and patient management'),
    (N'PATIENT_SAFETY', N'Patient Safety & Quality', 20, 1, N'Patient safety, clinical quality, adverse events and quality assurance'),
    (N'MEDICAL_GOV', N'Medical Governance', 30, 1, N'Medical staff governance, clinical privileges, credentialing and professional conduct'),
    (N'NURSING', N'Nursing Operations', 40, 1, N'Nursing administration, patient care practices and nursing standards'),
    (N'PHARMACY', N'Pharmacy & Medication Management', 50, 1, N'Drug procurement, storage, dispensing, medication safety and inventory'),
    (N'DIAGNOSTICS', N'Diagnostic Services', 60, 1, N'Laboratory, radiology, imaging and other diagnostic operations'),
    (N'FINANCIAL', N'Finance & Accounts', 70, 1, N'Accounting, financial controls, billing, revenue recognition and expenditure'),
    (N'REVENUE', N'Revenue Cycle Management', 80, 1, N'Patient registration, billing, insurance, claims and collections'),
    (N'REGULATORY', N'Regulatory & Statutory Compliance', 90, 1, N'Compliance with healthcare regulations, statutory requirements and accreditation standards'),
    (N'IT_DIGITAL', N'IT & Digital Systems', 100, 1, N'IT infrastructure, applications, cybersecurity, information systems and data governance'),
    (N'HR_ADMIN', N'Human Resources & Administration', 110, 1, N'Human resources, payroll, employee administration and general administration'),
    (N'PROCUREMENT', N'Procurement & Supply Chain', 120, 1, N'Purchasing, vendor procurement, stores and supply chain management'),
    (N'FACILITIES', N'Facilities & Infrastructure', 130, 1, N'Hospital buildings, utilities, biomedical engineering and facility management'),
    (N'GOVERNANCE', N'Corporate Governance', 140, 1, N'Board governance, management oversight, policies and delegated authority'),
    (N'RISK', N'Enterprise Risk Management', 150, 1, N'Enterprise risk identification, assessment, mitigation and monitoring'),
    (N'SECURITY', N'Safety & Security', 160, 1, N'Physical security, fire safety, emergency preparedness and occupational safety'),
    (N'RESEARCH', N'Research & Academic Activities', 170, 1, N'Clinical research, medical education, training and academic activities'),
    (N'CUSTOMER', N'Patient Experience & Relations', 180, 1, N'Patient grievances, feedback, service quality and patient relationship management'),
    (N'ETHICS', N'Ethics & Professional Conduct', 190, 1, N'Ethical practices, conflicts of interest, confidentiality and professional conduct'),
    (N'BUSINESS_CONTINUITY', N'Business Continuity', 200, 1, N'Disaster preparedness, emergency response and continuity of hospital operations');

UPDATE s SET master_id = m.universe_master_id
  FROM @src s
  JOIN grac_practice.org_assurance_universe_master m
    ON m.organization_id = @organization_id AND m.master_group = N'CLASSIFICATION'
   AND m.code = UPPER(REPLACE(LTRIM(RTRIM(s.code)), N' ', N'_'));

DECLARE @rn INT = 1, @max INT = (SELECT MAX(rn) FROM @src), @added INT = 0, @updated INT = 0;
DECLARE @id BIGINT, @code NVARCHAR(40), @name NVARCHAR(200), @ord INT, @act BIT, @descr NVARCHAR(1000), @out BIGINT,
        @grp NVARCHAR(30) = N'CLASSIFICATION';

BEGIN TRY
    BEGIN TRAN;
    WHILE @rn <= @max
    BEGIN
        SELECT @id = master_id, @code = code, @name = name, @ord = display_order, @act = is_active, @descr = description
          FROM @src WHERE rn = @rn;
        SET @out = NULL;
        EXEC grac_practice.sp_org_assurance_universe_master_save
             @organization_id = @organization_id, @universe_master_id = @id, @master_group = @grp,
             @code = @code, @name = @name, @description = @descr,
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

PRINT 'Audit Classifications added = ' + CAST(@added AS NVARCHAR(10)) + ', updated = ' + CAST(@updated AS NVARCHAR(10));

-- Check: the organization's Audit Classifications.
SELECT code AS Code, name AS Name, display_order AS [Order], CASE WHEN is_active = 1 THEN 'Yes' ELSE 'No' END AS Active
  FROM grac_practice.org_assurance_universe_master
 WHERE organization_id = @organization_id AND master_group = N'CLASSIFICATION'
 ORDER BY display_order, name;
