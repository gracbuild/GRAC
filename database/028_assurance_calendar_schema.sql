/*  ============================================================
    028_assurance_calendar_schema.sql
    Assurance Calendar module – schema, seed data, and indexes.

    Design: "Store only overrides" (lazy generation).
    - assurance_schedule_rule   : one row per practice instance → defines the recurring pattern
    - assurance_schedule_override : stores user-moved/skipped/added individual occurrences
    - assurance_calendar_config  : org-level calendar window settings

    Occurrences are computed at query time from the rule + frequency
    and then patched with overrides. No "materialised schedule" table.
    ============================================================ */

-- ==============================
-- 1. Schedule Rule
-- ==============================
IF OBJECT_ID('grac_practice.assurance_schedule_rule','U') IS NULL
CREATE TABLE grac_practice.assurance_schedule_rule(
 schedule_rule_id   BIGINT IDENTITY PRIMARY KEY,
 organization_id    BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 practice_instance_id BIGINT NOT NULL REFERENCES grac_practice.practice_instance(practice_instance_id),
 frequency_id       INT    NOT NULL REFERENCES grac_practice.frequency_master(frequency_id),
 anchor_date        DATE   NOT NULL,                         -- first occurrence date
 end_date           DATE   NULL,                             -- NULL = open-ended
 schedule_owner     NVARCHAR(200) NULL,                      -- who owns the schedule
 notes              NVARCHAR(MAX) NULL,
 is_active          BIT    NOT NULL DEFAULT 1,
 status             NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by         NVARCHAR(100) NOT NULL,
 entered_dt         DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by         NVARCHAR(100) NULL,
 updated_dt         DATETIME2 NULL,
 CONSTRAINT uq_pm_schedule_rule_instance UNIQUE(practice_instance_id)  -- one active rule per instance
);
GO

-- ==============================
-- 2. Schedule Override
-- ==============================
IF OBJECT_ID('grac_practice.assurance_schedule_override','U') IS NULL
CREATE TABLE grac_practice.assurance_schedule_override(
 override_id        BIGINT IDENTITY PRIMARY KEY,
 schedule_rule_id   BIGINT NOT NULL REFERENCES grac_practice.assurance_schedule_rule(schedule_rule_id),
 organization_id    BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 original_date      DATE   NOT NULL,                         -- the computed occurrence date
 override_type      NVARCHAR(30) NOT NULL,                   -- 'Moved', 'Skipped', 'Added'
 new_date           DATE   NULL,                             -- target date for Moved; NULL for Skipped
 reason             NVARCHAR(500) NULL,
 apply_to_future    BIT    NOT NULL DEFAULT 0,               -- recurring change flag
 override_by        NVARCHAR(200) NULL,
 status             NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by         NVARCHAR(100) NOT NULL,
 entered_dt         DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by         NVARCHAR(100) NULL,
 updated_dt         DATETIME2 NULL
);
GO

-- ==============================
-- 3. Calendar Config (per-org)
-- ==============================
IF OBJECT_ID('grac_practice.assurance_calendar_config','U') IS NULL
CREATE TABLE grac_practice.assurance_calendar_config(
 config_id          BIGINT IDENTITY PRIMARY KEY,
 organization_id    BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 look_back_months   INT    NOT NULL DEFAULT 3,
 look_ahead_months  INT    NOT NULL DEFAULT 12,
 default_view       NVARCHAR(20) NOT NULL DEFAULT 'month',   -- month | week | day
 status             NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by         NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt         DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by         NVARCHAR(100) NULL,
 updated_dt         DATETIME2 NULL,
 CONSTRAINT uq_pm_calendar_config_org UNIQUE(organization_id)
);
GO

-- ==============================
-- 4. Indexes
-- ==============================
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_schedule_rule_org_status' AND object_id=OBJECT_ID('grac_practice.assurance_schedule_rule'))
 CREATE INDEX ix_pm_schedule_rule_org_status ON grac_practice.assurance_schedule_rule(organization_id,is_active,status) INCLUDE(practice_instance_id,frequency_id,anchor_date,end_date);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_schedule_override_rule_date' AND object_id=OBJECT_ID('grac_practice.assurance_schedule_override'))
 CREATE INDEX ix_pm_schedule_override_rule_date ON grac_practice.assurance_schedule_override(schedule_rule_id,original_date,status) INCLUDE(override_type,new_date);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_schedule_override_org_status' AND object_id=OBJECT_ID('grac_practice.assurance_schedule_override'))
 CREATE INDEX ix_pm_schedule_override_org_status ON grac_practice.assurance_schedule_override(organization_id,status,entered_dt DESC);
GO

-- ==============================
-- 5. Seed: Override Type Master
-- ==============================
IF OBJECT_ID('grac_practice.schedule_override_type_master','U') IS NULL
CREATE TABLE grac_practice.schedule_override_type_master(
 override_type_id   INT IDENTITY PRIMARY KEY,
 override_type_code NVARCHAR(40) NOT NULL UNIQUE,
 override_type_name NVARCHAR(80) NOT NULL,
 display_order      INT NOT NULL DEFAULT 0,
 is_active          BIT NOT NULL DEFAULT 1,
 entered_by         NVARCHAR(100) NOT NULL DEFAULT 'system',
 entered_dt         DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

IF NOT EXISTS(SELECT 1 FROM grac_practice.schedule_override_type_master WHERE override_type_code='Moved')
INSERT grac_practice.schedule_override_type_master(override_type_code,override_type_name,display_order) VALUES
 ('Moved','Moved to Different Date',1),
 ('Skipped','Skipped / Cancelled',2),
 ('Added','Manually Added Occurrence',3);
GO

-- ── Menu entry for Assurance Calendar ──
IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
 MERGE grac_practice.menu_master AS target
 USING (VALUES
  (N'assurance-calendar',N'Assurance Calendar',N'Practice/Index/assurance-calendar',730,N'calendar-days',N'Assurance Management')
 ) AS source(menu_key,menu_name,menu_url,display_order,icon_class,module_type)
 ON target.menu_key=source.menu_key
 WHEN MATCHED THEN UPDATE SET menu_name=source.menu_name,menu_url=source.menu_url,display_order=source.display_order,icon_class=source.icon_class,module_type=source.module_type,status='Active',updated_by='seed',updated_dt=SYSUTCDATETIME()
 WHEN NOT MATCHED THEN INSERT(menu_key,menu_name,menu_url,display_order,icon_class,module_type,status,entered_by)
 VALUES(source.menu_key,source.menu_name,source.menu_url,source.display_order,source.icon_class,source.module_type,'Active','seed');
END
GO

-- Grant permissions for the new menu item to all existing active roles
IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NOT NULL
BEGIN
 INSERT grac_practice.organization_role_menu_permission(role_id,menu_id,can_view,can_add,can_edit,can_delete,can_approve,status,record_status_id,entered_by)
 SELECT r.role_id,m.menu_id,1,1,1,0,0,'Active',
        (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master WHERE status_code='Active'),
        'seed'
 FROM grac_practice.organization_role r
 JOIN grac_practice.menu_master m ON m.menu_key=N'assurance-calendar' AND m.status='Active'
 WHERE r.status='Active'
   AND NOT EXISTS(
     SELECT 1
     FROM grac_practice.organization_role_menu_permission existing
     WHERE existing.role_id=r.role_id
       AND existing.menu_id=m.menu_id
   );
END
GO

PRINT '028_assurance_calendar_schema.sql completed successfully.';
GO
