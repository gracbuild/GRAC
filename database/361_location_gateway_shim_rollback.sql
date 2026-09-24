/* ================================================================
   Rollback for 361_location_gateway_shim.sql
   Drops the shim/save/list/lookup procedures. Locations then fall
   straight back onto dbo.pm_manage_practice_repository /
   dbo.pm_get_practice_repository for every action, same as before
   this migration -- the new Time Zone + address columns (360) simply
   go unread/unwritten by the monolith's older 'locations' branch.
   ================================================================ */

IF OBJECT_ID('grac_practice.sp_get_time_zone_lookup','P')           IS NOT NULL DROP PROCEDURE grac_practice.sp_get_time_zone_lookup;
GO
IF OBJECT_ID('grac_practice.sp_org_location_repository_get','P')    IS NOT NULL DROP PROCEDURE grac_practice.sp_org_location_repository_get;
GO
IF OBJECT_ID('grac_practice.sp_org_location_repository_manage','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_location_repository_manage;
GO
IF OBJECT_ID('grac_practice.sp_org_location_list','P')              IS NOT NULL DROP PROCEDURE grac_practice.sp_org_location_list;
GO
IF OBJECT_ID('grac_practice.sp_org_location_save','P')              IS NOT NULL DROP PROCEDURE grac_practice.sp_org_location_save;
GO

PRINT 'Migration 361_location_gateway_shim rolled back.';
GO
