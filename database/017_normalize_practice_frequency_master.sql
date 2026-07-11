/*
  GRAC Part 2 - Practice Intelligence Layer
  Normalize Practice Instance frequency to grac_practice.frequency_master.

  Keeps existing frequency_type / frequency_value / frequency_unit columns as
  compatibility/reporting snapshots, but stores frequency_id as the normalized FK.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRAN;

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 52001, 'Schema grac_practice is missing. Run 001_practice_management_schema.sql first.', 1;

IF OBJECT_ID('grac_practice.practice_instance','U') IS NULL
    THROW 52002, 'Table grac_practice.practice_instance is missing.', 1;

IF OBJECT_ID('grac_practice.frequency_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.frequency_master(
        frequency_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_frequency_master PRIMARY KEY,
        frequency_code NVARCHAR(40) NOT NULL CONSTRAINT uq_pm_frequency_code UNIQUE,
        frequency_name NVARCHAR(80) NOT NULL,
        frequency_value INT NULL,
        frequency_unit NVARCHAR(40) NULL,
        is_custom BIT NOT NULL DEFAULT 0,
        display_order INT NOT NULL DEFAULT 0,
        is_active BIT NOT NULL DEFAULT 1,
        entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
        entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL
    );
END;

;WITH seed(frequency_code,frequency_name,frequency_value,frequency_unit,is_custom,display_order) AS (
    SELECT N'Daily',N'Daily',1,N'Day',0,1 UNION ALL
    SELECT N'Weekly',N'Weekly',1,N'Week',0,2 UNION ALL
    SELECT N'Monthly',N'Monthly',1,N'Month',0,3 UNION ALL
    SELECT N'Quarterly',N'Quarterly',3,N'Month',0,4 UNION ALL
    SELECT N'Half-Yearly',N'Half-Yearly',6,N'Month',0,5 UNION ALL
    SELECT N'Annual',N'Annual',12,N'Month',0,6 UNION ALL
    SELECT N'Event Driven',N'Event Driven',NULL,NULL,0,7 UNION ALL
    SELECT N'Continuous',N'Continuous',NULL,NULL,0,8 UNION ALL
    SELECT N'Custom',N'Custom',NULL,NULL,1,9
)
INSERT grac_practice.frequency_master(frequency_code,frequency_name,frequency_value,frequency_unit,is_custom,display_order,entered_by)
SELECT s.frequency_code,s.frequency_name,s.frequency_value,s.frequency_unit,s.is_custom,s.display_order,N'system'
FROM seed s
WHERE NOT EXISTS(
    SELECT 1
    FROM grac_practice.frequency_master existing
    WHERE existing.frequency_code=s.frequency_code
       OR existing.frequency_name=s.frequency_name
);

IF COL_LENGTH('grac_practice.practice_instance','frequency_id') IS NULL
    ALTER TABLE grac_practice.practice_instance ADD frequency_id INT NULL;

UPDATE pi
SET frequency_id=f.frequency_id
FROM grac_practice.practice_instance pi
JOIN grac_practice.frequency_master f
  ON f.frequency_code=pi.frequency_type
  OR f.frequency_name=pi.frequency_type
WHERE pi.frequency_id IS NULL;

UPDATE pi
SET frequency_id=f.frequency_id
FROM grac_practice.practice_instance pi
CROSS JOIN grac_practice.frequency_master f
WHERE pi.frequency_id IS NULL
  AND NULLIF(pi.frequency_type,'') IS NOT NULL
  AND f.frequency_code=N'Custom';

UPDATE pi
SET frequency_type=f.frequency_code,
    frequency_value=CASE WHEN f.is_custom=1 THEN pi.frequency_value ELSE f.frequency_value END,
    frequency_unit=CASE WHEN f.is_custom=1 THEN pi.frequency_unit ELSE f.frequency_unit END
FROM grac_practice.practice_instance pi
JOIN grac_practice.frequency_master f ON f.frequency_id=pi.frequency_id;

IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_practice_instance_frequency')
    ALTER TABLE grac_practice.practice_instance
    ADD CONSTRAINT fk_pm_practice_instance_frequency
    FOREIGN KEY(frequency_id) REFERENCES grac_practice.frequency_master(frequency_id);

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_practice_instance_frequency' AND object_id=OBJECT_ID('grac_practice.practice_instance'))
    CREATE INDEX ix_pm_practice_instance_frequency
    ON grac_practice.practice_instance(organization_id,frequency_id,status,entered_dt DESC)
    INCLUDE(practice_id,instance_code,instance_name,primary_owner);

COMMIT;

SELECT frequency_id FrequencyId,frequency_code FrequencyCode,frequency_name FrequencyName,frequency_value FrequencyValue,frequency_unit FrequencyUnit,is_custom IsCustom
FROM grac_practice.frequency_master
ORDER BY display_order,frequency_name;
