/* ================================================================
   Migration 360 -- Location: address fields + Time Zone reference
   ----------------------------------------------------------------
   Change request 2026-09-20 (Location View redesign's follow-up):
   Location gets a proper postal address and a Time Zone selection.

   TIME ZONE, NOT UTC OFFSET
   ----------------------------------------------------------------
   time_zone_id is a nullable FK into GRAC_New.time_zone_master --
   the shared, IANA-anchored Time Zone Master that lives in
   ControlManagement (058/059 there). Per that decision: the actual
   timezone identifier is GRAC_New.time_zone_master.iana_time_zone;
   this module never stores a raw UTC offset against a Location, and
   PracticeManagement does not manage the master itself -- it only
   references it. Nullable and unconstrained-by-default (see the FK
   guard below) so this migration can run in this database before or
   after ControlManagement's 058 has: an unapplied migration should
   degrade a feature (the Time Zone dropdown is empty), not break the
   Location screen, matching 134's precedent for cross-module drift.

   ADDRESS
   ----------------------------------------------------------------
   No existing Country/State/City master was found anywhere in this
   codebase (grep across the SQL migration files under database/ and
   wwwroot/js/practice.js turned up only the "countries" lookup already used by
   Organization's own Country field -- reused here for the same
   reason, not duplicated). City / State-Province / Postal Code have
   no matching master anywhere in the project, so they are plain
   user-entered text, exactly as asked: business-verified information,
   never derived from device/browser geolocation.

   SAFE FOR EXISTING ROWS
   ----------------------------------------------------------------
   Every new column is NULLable with no default -- existing Location
   rows keep working unchanged; the new fields simply read as blank
   ("Not set") on the View page (which already renders any blank
   field that way -- see setupViewFieldMarkup/viewFieldMarkup in
   practice.js) until an admin edits the record.

   Depends on: nothing hard. The time_zone_id FK is added only if
   GRAC_New.time_zone_master already exists in this database; if not,
   the column stays FK-less until a later run of this same migration
   (or a manual follow-up) finds the table.

   Rollback: database/360_location_address_and_timezone_rollback.sql
   ================================================================ */

/* ------------------------------------------------------------------
   1. Columns
   ------------------------------------------------------------------ */
IF COL_LENGTH('grac_practice.organization_location','time_zone_id') IS NULL
    ALTER TABLE grac_practice.organization_location ADD time_zone_id BIGINT NULL;
GO

IF COL_LENGTH('grac_practice.organization_location','address_line1') IS NULL
    ALTER TABLE grac_practice.organization_location ADD address_line1 NVARCHAR(200) NULL;
GO
IF COL_LENGTH('grac_practice.organization_location','address_line2') IS NULL
    ALTER TABLE grac_practice.organization_location ADD address_line2 NVARCHAR(200) NULL;
GO
IF COL_LENGTH('grac_practice.organization_location','city') IS NULL
    ALTER TABLE grac_practice.organization_location ADD city NVARCHAR(120) NULL;
GO
IF COL_LENGTH('grac_practice.organization_location','state_province') IS NULL
    ALTER TABLE grac_practice.organization_location ADD state_province NVARCHAR(120) NULL;
GO
IF COL_LENGTH('grac_practice.organization_location','country') IS NULL
    ALTER TABLE grac_practice.organization_location ADD country NVARCHAR(120) NULL;
GO
IF COL_LENGTH('grac_practice.organization_location','postal_code') IS NULL
    ALTER TABLE grac_practice.organization_location ADD postal_code NVARCHAR(30) NULL;
GO

/* ------------------------------------------------------------------
   2. time_zone_id FK -- only once GRAC_New.time_zone_master exists.
      All existing rows are NULL in the new column, so there is no
      orphan-row check to make first (unlike the evidence_type_master
      precedent this mirrors, which had to check pre-existing data).
   ------------------------------------------------------------------ */
IF OBJECT_ID('grac_practice.organization_location','U') IS NOT NULL
   AND OBJECT_ID('GRAC_New.time_zone_master','U') IS NOT NULL
   AND NOT EXISTS(
     SELECT 1 FROM sys.foreign_keys fk
     WHERE fk.parent_object_id = OBJECT_ID('grac_practice.organization_location')
       AND fk.referenced_object_id = OBJECT_ID('GRAC_New.time_zone_master')
   )
BEGIN
    ALTER TABLE grac_practice.organization_location
    ADD CONSTRAINT fk_pm_location_time_zone FOREIGN KEY(time_zone_id) REFERENCES GRAC_New.time_zone_master(time_zone_id);
END
GO

PRINT 'Migration 360_location_address_and_timezone applied.';
IF OBJECT_ID('GRAC_New.time_zone_master','U') IS NULL
    PRINT 'NOTE: GRAC_New.time_zone_master not found yet -- time_zone_id has no FK until ControlManagement''s 058 runs against this database. Re-run this migration afterwards to add it.';
GO
