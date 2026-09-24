/* ================================================================
   Rollback for 360_location_address_and_timezone.sql
   Drops the FK (if it was created) and the new columns.
   ================================================================ */

IF EXISTS (
    SELECT 1 FROM sys.foreign_keys fk
    WHERE fk.parent_object_id = OBJECT_ID('grac_practice.organization_location')
      AND fk.name = 'fk_pm_location_time_zone'
)
    ALTER TABLE grac_practice.organization_location DROP CONSTRAINT fk_pm_location_time_zone;
GO

IF COL_LENGTH('grac_practice.organization_location','time_zone_id')   IS NOT NULL ALTER TABLE grac_practice.organization_location DROP COLUMN time_zone_id;
GO
IF COL_LENGTH('grac_practice.organization_location','address_line1') IS NOT NULL ALTER TABLE grac_practice.organization_location DROP COLUMN address_line1;
GO
IF COL_LENGTH('grac_practice.organization_location','address_line2') IS NOT NULL ALTER TABLE grac_practice.organization_location DROP COLUMN address_line2;
GO
IF COL_LENGTH('grac_practice.organization_location','city')          IS NOT NULL ALTER TABLE grac_practice.organization_location DROP COLUMN city;
GO
IF COL_LENGTH('grac_practice.organization_location','state_province') IS NOT NULL ALTER TABLE grac_practice.organization_location DROP COLUMN state_province;
GO
IF COL_LENGTH('grac_practice.organization_location','country')       IS NOT NULL ALTER TABLE grac_practice.organization_location DROP COLUMN country;
GO
IF COL_LENGTH('grac_practice.organization_location','postal_code')   IS NOT NULL ALTER TABLE grac_practice.organization_location DROP COLUMN postal_code;
GO

PRINT 'Migration 360_location_address_and_timezone rolled back.';
GO
