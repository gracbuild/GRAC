-- =====================================================================
-- 560 ROLLBACK  Audit Definition refinements
--
-- Puts sp_org_assurance_definition_save and
-- sp_org_assurance_definition_version_copy_config back to their 551 bodies
-- and sp_org_assurance_definition_get back to its 119 body, and drops
-- sp_org_assurance_approach_list.
-- KEPT: org_assurance_approach_master, org_assurance_mandate_master,
-- org_assurance_definition_framework
-- and the new definition version columns, so nothing saved is lost; the
-- page simply stops showing and saving them. Re-run 560 to bring them back.
-- Deploy with the previous Api / Web build. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_approach_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_approach_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_mandate_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_mandate_list;
GO
