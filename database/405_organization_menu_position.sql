-- =====================================================================
-- 405 Organization menu position: place it directly above Settings
--
-- Migration 402 promoted 'organization-administration' (displayed as
-- "Organization") to a top-level nav root. It sat at display_order 195,
-- which rendered it high up between Governance (100) and Issues &
-- Actions (200). Sir asked for it to sit immediately above the Settings
-- root (menu_key 'nav-organization', display_order 500).
--
-- The sidebar orders top-level (parent NULL) rows by display_order
-- ascending (PracticeMenuService.BuildChildren / BuildModuleGroups).
-- The active roots are:
--   Home 0, My Notification 50, Governance 100, Organization 195,
--   Issues & Actions 200, Risk Management 280, Audit Assurance 300,
--   Policies & Documents 400, Settings 500, Audit Traceability 900.
-- Nothing active occupies the gap between Policies & Documents (400)
-- and Settings (500), so display_order 490 lands Organization directly
-- above Settings and below Policies & Documents.
--
-- Menu-only change to grac_practice.menu_master.display_order. The 274
-- snapshot is amended to match (Section 1 row for
-- 'organization-administration' now carries 490). Idempotent.
-- ASCII-only. Rollback restores 195.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

UPDATE grac_practice.menu_master
   SET display_order = 490,
       updated_by    = N'migration-405',
       updated_dt    = SYSUTCDATETIME()
 WHERE menu_key = N'organization-administration';
GO

PRINT '405 complete.';
GO
