/*
  GRAC Part 2 - Practice Management
  Normalize status values into master tables and StatusID foreign keys.

  Notes:
  - Legacy text columns are retained for backward compatibility during transition.
  - New application/procedure logic should read/write the *_status_id columns.
  - Run in GRAC_NewPhase database.
*/

SET NOCOUNT ON;

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 51300, 'Schema grac_practice is missing. Run 001_practice_management_schema.sql first.', 1;

IF OBJECT_ID('grac_practice.record_status_master','U') IS NULL
CREATE TABLE grac_practice.record_status_master(
    record_status_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_record_status_master PRIMARY KEY,
    status_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_record_status_code UNIQUE,
    status_name NVARCHAR(100) NOT NULL,
    display_order INT NOT NULL DEFAULT 0,
    is_active BIT NOT NULL DEFAULT 1,
    entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
    entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL
);

IF OBJECT_ID('grac_practice.applicability_status_master','U') IS NULL
CREATE TABLE grac_practice.applicability_status_master(
    applicability_status_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_applicability_status_master PRIMARY KEY,
    status_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_applicability_status_code UNIQUE,
    status_name NVARCHAR(100) NOT NULL,
    display_order INT NOT NULL DEFAULT 0,
    is_active BIT NOT NULL DEFAULT 1,
    entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
    entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL
);

IF OBJECT_ID('grac_practice.subscription_status_master','U') IS NULL
CREATE TABLE grac_practice.subscription_status_master(
    subscription_status_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_subscription_status_master PRIMARY KEY,
    status_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_subscription_status_code UNIQUE,
    status_name NVARCHAR(100) NOT NULL,
    display_order INT NOT NULL DEFAULT 0,
    is_active BIT NOT NULL DEFAULT 1,
    entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
    entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL
);

IF OBJECT_ID('grac_practice.implementation_status_master','U') IS NULL
CREATE TABLE grac_practice.implementation_status_master(
    implementation_status_id INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_implementation_status_master PRIMARY KEY,
    status_code NVARCHAR(60) NOT NULL CONSTRAINT uq_pm_implementation_status_code UNIQUE,
    status_name NVARCHAR(100) NOT NULL,
    display_order INT NOT NULL DEFAULT 0,
    is_active BIT NOT NULL DEFAULT 1,
    entered_by NVARCHAR(100) NOT NULL DEFAULT 'system',
    entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_by NVARCHAR(100) NULL,
    updated_dt DATETIME2 NULL
);

IF NOT EXISTS(SELECT 1 FROM grac_practice.record_status_master WHERE status_code='Active')
INSERT grac_practice.record_status_master(status_code,status_name,display_order)
VALUES('Active','Active',1),('Inactive','Inactive',2),('Retired','Retired',3),('Draft','Draft',4);

IF NOT EXISTS(SELECT 1 FROM grac_practice.applicability_status_master WHERE status_code='Not Updated')
INSERT grac_practice.applicability_status_master(status_code,status_name,display_order)
VALUES('Not Updated','Not Updated',1),('Applicable','Applicable',2),('Not Applicable','Not Applicable',3),('Deferred','Deferred',4),('Accepted Risk','Accepted Risk',5);

IF NOT EXISTS(SELECT 1 FROM grac_practice.applicability_status_master WHERE status_code='Not Implemented')
INSERT grac_practice.applicability_status_master(status_code,status_name,display_order)
VALUES('Not Implemented','Not Implemented',6);

IF NOT EXISTS(SELECT 1 FROM grac_practice.applicability_status_master WHERE status_code='Retired')
INSERT grac_practice.applicability_status_master(status_code,status_name,display_order)
VALUES('Retired','Retired',7);

IF NOT EXISTS(SELECT 1 FROM grac_practice.subscription_status_master WHERE status_code='Active')
INSERT grac_practice.subscription_status_master(status_code,status_name,display_order)
VALUES('Active','Active',1),('Disabled','Disabled',2),('Superseded','Superseded',3),('Pending Review','Pending Review',4);

IF NOT EXISTS(SELECT 1 FROM grac_practice.implementation_status_master WHERE status_code='Not Started')
INSERT grac_practice.implementation_status_master(status_code,status_name,display_order)
VALUES('Not Started','Not Started',1),('In Progress','In Progress',2),('Implemented','Implemented',3),('Active','Active',4),('Inactive','Inactive',5);

DECLARE @ActiveRecordStatusId INT=(SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code='Active');
DECLARE @NotUpdatedApplicabilityStatusId INT=(SELECT applicability_status_id FROM grac_practice.applicability_status_master WHERE status_code='Not Updated');
DECLARE @ActiveSubscriptionStatusId INT=(SELECT subscription_status_id FROM grac_practice.subscription_status_master WHERE status_code='Active');
DECLARE @NotStartedImplementationStatusId INT=(SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code='Not Started');

DECLARE @ColumnAdds TABLE(table_name SYSNAME,column_name SYSNAME,definition NVARCHAR(MAX));
INSERT @ColumnAdds(table_name,column_name,definition)
VALUES
('organization','record_status_id',N'INT NULL'),
('organization_metadata_definition','record_status_id',N'INT NULL'),
('reference_option','record_status_id',N'INT NULL'),
('organization_metadata_value','record_status_id',N'INT NULL'),
('organization_business_function','record_status_id',N'INT NULL'),
('repository_subscription','record_status_id',N'INT NULL'),
('repository_subscription','subscription_status_id',N'INT NULL'),
('subscription_recommendation_history','record_status_id',N'INT NULL'),
('organization_control','record_status_id',N'INT NULL'),
('organization_control','applicability_status_id',N'INT NULL'),
('organization_requirement','record_status_id',N'INT NULL'),
('organization_requirement','applicability_status_id',N'INT NULL'),
('organization_requirement','implementation_status_id',N'INT NULL'),
('practice','record_status_id',N'INT NULL'),
('practice_instance','record_status_id',N'INT NULL'),
('practice_instance','implementation_status_id',N'INT NULL'),
('practice_instance_dependency','record_status_id',N'INT NULL');

DECLARE @TableName SYSNAME,@ColumnName SYSNAME,@Definition NVARCHAR(MAX),@Sql NVARCHAR(MAX);
DECLARE add_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT table_name,column_name,definition FROM @ColumnAdds;
OPEN add_cursor;
FETCH NEXT FROM add_cursor INTO @TableName,@ColumnName,@Definition;
WHILE @@FETCH_STATUS=0
BEGIN
    IF OBJECT_ID(N'grac_practice.'+QUOTENAME(@TableName),'U') IS NOT NULL
       AND COL_LENGTH(N'grac_practice.'+@TableName,@ColumnName) IS NULL
    BEGIN
        SET @Sql=N'ALTER TABLE grac_practice.'+QUOTENAME(@TableName)+N' ADD '+QUOTENAME(@ColumnName)+N' '+@Definition+N';';
        EXEC sys.sp_executesql @Sql;
    END;
    FETCH NEXT FROM add_cursor INTO @TableName,@ColumnName,@Definition;
END;
CLOSE add_cursor;
DEALLOCATE add_cursor;

UPDATE o SET record_status_id=COALESCE(r.record_status_id,@ActiveRecordStatusId)
FROM grac_practice.organization o
LEFT JOIN grac_practice.record_status_master r ON r.status_code=o.status
WHERE o.record_status_id IS NULL;

UPDATE d SET record_status_id=COALESCE(r.record_status_id,@ActiveRecordStatusId)
FROM grac_practice.organization_metadata_definition d
LEFT JOIN grac_practice.record_status_master r ON r.status_code=d.status
WHERE d.record_status_id IS NULL;

UPDATE ro SET record_status_id=COALESCE(r.record_status_id,@ActiveRecordStatusId)
FROM grac_practice.reference_option ro
LEFT JOIN grac_practice.record_status_master r ON r.status_code=ro.status
WHERE ro.record_status_id IS NULL;

UPDATE v SET record_status_id=COALESCE(r.record_status_id,@ActiveRecordStatusId)
FROM grac_practice.organization_metadata_value v
LEFT JOIN grac_practice.record_status_master r ON r.status_code=v.status
WHERE v.record_status_id IS NULL;

UPDATE bf SET record_status_id=COALESCE(r.record_status_id,@ActiveRecordStatusId)
FROM grac_practice.organization_business_function bf
LEFT JOIN grac_practice.record_status_master r ON r.status_code=bf.status
WHERE bf.record_status_id IS NULL;

UPDATE s SET record_status_id=COALESCE(r.record_status_id,@ActiveRecordStatusId),
             subscription_status_id=COALESCE(ss.subscription_status_id,@ActiveSubscriptionStatusId)
FROM grac_practice.repository_subscription s
LEFT JOIN grac_practice.record_status_master r ON r.status_code=s.status
LEFT JOIN grac_practice.subscription_status_master ss ON ss.status_code=s.subscription_status
WHERE s.record_status_id IS NULL OR s.subscription_status_id IS NULL;

UPDATE h SET record_status_id=COALESCE(r.record_status_id,@ActiveRecordStatusId)
FROM grac_practice.subscription_recommendation_history h
LEFT JOIN grac_practice.record_status_master r ON r.status_code=h.status
WHERE h.record_status_id IS NULL;

UPDATE oc SET record_status_id=COALESCE(r.record_status_id,@ActiveRecordStatusId),
              applicability_status_id=COALESCE(a.applicability_status_id,@NotUpdatedApplicabilityStatusId)
FROM grac_practice.organization_control oc
LEFT JOIN grac_practice.record_status_master r ON r.status_code=oc.status
LEFT JOIN grac_practice.applicability_status_master a ON a.status_code=oc.applicability_status
WHERE oc.record_status_id IS NULL OR oc.applicability_status_id IS NULL;

UPDATE q SET record_status_id=COALESCE(r.record_status_id,@ActiveRecordStatusId),
             applicability_status_id=COALESCE(a.applicability_status_id,@NotUpdatedApplicabilityStatusId),
             implementation_status_id=COALESCE(i.implementation_status_id,@NotStartedImplementationStatusId)
FROM grac_practice.organization_requirement q
LEFT JOIN grac_practice.record_status_master r ON r.status_code=q.status
LEFT JOIN grac_practice.applicability_status_master a ON a.status_code=q.applicability_status
LEFT JOIN grac_practice.implementation_status_master i ON i.status_code=q.implementation_status
WHERE q.record_status_id IS NULL OR q.applicability_status_id IS NULL OR q.implementation_status_id IS NULL;

UPDATE p SET record_status_id=COALESCE(r.record_status_id,@ActiveRecordStatusId)
FROM grac_practice.practice p
LEFT JOIN grac_practice.record_status_master r ON r.status_code=p.status
WHERE p.record_status_id IS NULL;

UPDATE pi SET record_status_id=COALESCE(r.record_status_id,@ActiveRecordStatusId),
              implementation_status_id=COALESCE(i.implementation_status_id,@NotStartedImplementationStatusId)
FROM grac_practice.practice_instance pi
LEFT JOIN grac_practice.record_status_master r ON r.status_code=pi.status
LEFT JOIN grac_practice.implementation_status_master i ON i.status_code=pi.implementation_status
WHERE pi.record_status_id IS NULL OR pi.implementation_status_id IS NULL;

UPDATE d SET record_status_id=COALESCE(r.record_status_id,@ActiveRecordStatusId)
FROM grac_practice.practice_instance_dependency d
LEFT JOIN grac_practice.record_status_master r ON r.status_code=d.status
WHERE d.record_status_id IS NULL;

ALTER TABLE grac_practice.organization ALTER COLUMN record_status_id INT NOT NULL;
ALTER TABLE grac_practice.repository_subscription ALTER COLUMN record_status_id INT NOT NULL;
ALTER TABLE grac_practice.repository_subscription ALTER COLUMN subscription_status_id INT NOT NULL;
ALTER TABLE grac_practice.organization_control ALTER COLUMN record_status_id INT NOT NULL;
ALTER TABLE grac_practice.organization_control ALTER COLUMN applicability_status_id INT NOT NULL;
ALTER TABLE grac_practice.organization_requirement ALTER COLUMN record_status_id INT NOT NULL;
ALTER TABLE grac_practice.organization_requirement ALTER COLUMN applicability_status_id INT NOT NULL;
ALTER TABLE grac_practice.organization_requirement ALTER COLUMN implementation_status_id INT NOT NULL;
ALTER TABLE grac_practice.practice ALTER COLUMN record_status_id INT NOT NULL;
ALTER TABLE grac_practice.practice_instance ALTER COLUMN record_status_id INT NOT NULL;
ALTER TABLE grac_practice.practice_instance ALTER COLUMN implementation_status_id INT NOT NULL;
ALTER TABLE grac_practice.practice_instance_dependency ALTER COLUMN record_status_id INT NOT NULL;

IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_org_record_status')
 ALTER TABLE grac_practice.organization ADD CONSTRAINT fk_pm_org_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id);
IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_subscription_record_status')
 ALTER TABLE grac_practice.repository_subscription ADD CONSTRAINT fk_pm_subscription_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id);
IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_subscription_subscription_status')
 ALTER TABLE grac_practice.repository_subscription ADD CONSTRAINT fk_pm_subscription_subscription_status FOREIGN KEY(subscription_status_id) REFERENCES grac_practice.subscription_status_master(subscription_status_id);
IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_org_control_record_status')
 ALTER TABLE grac_practice.organization_control ADD CONSTRAINT fk_pm_org_control_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id);
IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_org_control_applicability_status')
 ALTER TABLE grac_practice.organization_control ADD CONSTRAINT fk_pm_org_control_applicability_status FOREIGN KEY(applicability_status_id) REFERENCES grac_practice.applicability_status_master(applicability_status_id);
IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_org_requirement_record_status')
 ALTER TABLE grac_practice.organization_requirement ADD CONSTRAINT fk_pm_org_requirement_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id);
IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_org_requirement_applicability_status')
 ALTER TABLE grac_practice.organization_requirement ADD CONSTRAINT fk_pm_org_requirement_applicability_status FOREIGN KEY(applicability_status_id) REFERENCES grac_practice.applicability_status_master(applicability_status_id);
IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_org_requirement_implementation_status')
 ALTER TABLE grac_practice.organization_requirement ADD CONSTRAINT fk_pm_org_requirement_implementation_status FOREIGN KEY(implementation_status_id) REFERENCES grac_practice.implementation_status_master(implementation_status_id);
IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_practice_record_status')
 ALTER TABLE grac_practice.practice ADD CONSTRAINT fk_pm_practice_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id);
IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_practice_instance_record_status')
 ALTER TABLE grac_practice.practice_instance ADD CONSTRAINT fk_pm_practice_instance_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id);
IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_practice_instance_implementation_status')
 ALTER TABLE grac_practice.practice_instance ADD CONSTRAINT fk_pm_practice_instance_implementation_status FOREIGN KEY(implementation_status_id) REFERENCES grac_practice.implementation_status_master(implementation_status_id);
IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name='fk_pm_dependency_record_status')
 ALTER TABLE grac_practice.practice_instance_dependency ADD CONSTRAINT fk_pm_dependency_record_status FOREIGN KEY(record_status_id) REFERENCES grac_practice.record_status_master(record_status_id);

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_control_status_ids' AND object_id=OBJECT_ID('grac_practice.organization_control'))
 CREATE INDEX ix_pm_org_control_status_ids ON grac_practice.organization_control(organization_id,record_status_id,applicability_status_id,entered_dt DESC);
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_org_requirement_status_ids' AND object_id=OBJECT_ID('grac_practice.organization_requirement'))
 CREATE INDEX ix_pm_org_requirement_status_ids ON grac_practice.organization_requirement(organization_id,record_status_id,applicability_status_id,implementation_status_id,entered_dt DESC);
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_subscription_status_ids' AND object_id=OBJECT_ID('grac_practice.repository_subscription'))
 CREATE INDEX ix_pm_subscription_status_ids ON grac_practice.repository_subscription(organization_id,record_status_id,subscription_status_id,release_id,entered_dt DESC);

SELECT 'Practice status normalization complete. Status names are now resolved through master IDs.' AS Message;
