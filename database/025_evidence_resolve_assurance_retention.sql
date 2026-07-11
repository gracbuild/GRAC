SET NOCOUNT ON;

IF SCHEMA_ID('grac_practice') IS NOT NULL
   AND OBJECT_ID('grac_practice.assurance_type_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.assurance_type_master(
        assurance_type_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_assurance_type_master PRIMARY KEY,
        assurance_type_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_assurance_type_code UNIQUE,
        assurance_type_name NVARCHAR(120) NOT NULL,
        display_order INT NOT NULL CONSTRAINT df_pm_assurance_type_order DEFAULT 0,
        is_active BIT NOT NULL CONSTRAINT df_pm_assurance_type_active DEFAULT 1,
        entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_assurance_type_entered_by DEFAULT 'system',
        entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_assurance_type_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL
    );
END

IF OBJECT_ID('grac_practice.assurance_type_master','U') IS NOT NULL
BEGIN
    ;WITH seed(assurance_type_code,assurance_type_name,display_order) AS (
        SELECT N'Manual',N'Manual',1 UNION ALL
        SELECT N'Automated',N'Automated',2
    )
    INSERT grac_practice.assurance_type_master(assurance_type_code,assurance_type_name,display_order,entered_by)
    SELECT s.assurance_type_code,s.assurance_type_name,s.display_order,N'system'
    FROM seed s
    WHERE NOT EXISTS(
        SELECT 1
        FROM grac_practice.assurance_type_master existing
        WHERE existing.assurance_type_code=s.assurance_type_code
           OR existing.assurance_type_name=s.assurance_type_name
    );

    UPDATE grac_practice.assurance_type_master
    SET is_active = CASE WHEN assurance_type_code IN (N'Manual',N'Automated') THEN 1 ELSE 0 END,
        updated_by = N'system',
        updated_dt = SYSUTCDATETIME()
    WHERE assurance_type_code IN (N'Manual',N'Automated',N'Semi-Automated',N'Semi Automated',N'Hybrid')
       OR assurance_type_name IN (N'Manual',N'Automated',N'Semi-Automated',N'Semi Automated',N'Hybrid');
END

IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.practice_instance_evidence','assurance_type_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.practice_instance_evidence ADD assurance_type_id INT NULL;
END

IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.practice_instance_evidence','retention_period') IS NULL
BEGIN
    ALTER TABLE grac_practice.practice_instance_evidence ADD retention_period NVARCHAR(120) NULL;
END

IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.assurance_type_master','U') IS NOT NULL
BEGIN
    DECLARE @manual_assurance_type_id INT = (
        SELECT TOP 1 assurance_type_id
        FROM grac_practice.assurance_type_master
        WHERE assurance_type_code=N'Manual'
        ORDER BY display_order,assurance_type_id
    );

    UPDATE grac_practice.practice_instance_evidence
    SET assurance_type_id = @manual_assurance_type_id,
        updated_by = COALESCE(NULLIF(updated_by,N''),N'system'),
        updated_dt = SYSUTCDATETIME()
    WHERE assurance_type_id IS NULL
      AND @manual_assurance_type_id IS NOT NULL;
END

IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.assurance_type_master','U') IS NOT NULL
   AND NOT EXISTS(
        SELECT 1
        FROM sys.foreign_keys
        WHERE name=N'fk_pm_evidence_assurance_type'
          AND parent_object_id=OBJECT_ID('grac_practice.practice_instance_evidence')
   )
BEGIN
    ALTER TABLE grac_practice.practice_instance_evidence
    ADD CONSTRAINT fk_pm_evidence_assurance_type
    FOREIGN KEY(assurance_type_id) REFERENCES grac_practice.assurance_type_master(assurance_type_id);
END
