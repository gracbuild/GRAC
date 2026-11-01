-- =====================================================================
-- 462_custom_release_blank_end_date_null.sql
--
-- WHY
-- ---
-- On the Standards & Frameworks > Edit Release form for a Custom release,
-- a blank End Date was being saved and then shown back as 01-01-1900.
-- Root cause: SaveCustomReleaseAsync parsed the date as
--     TRY_CONVERT(DATE, JSON_VALUE(@payload,'$.endDate'))
-- and the form posts an empty string "" for a blank field. In SQL Server
-- TRY_CONVERT(DATE,'') SUCCEEDS and returns 1900-01-01 (not NULL), so the
-- sentinel was stored. (The code fix adds NULLIF(...,''), matching every
-- other date parse in the codebase, e.g. the generic repository
-- subscription proc and the organization address/subscription procs.)
--
-- Besides looking wrong on Edit, a stored 1900-01-01 end_dt is also read
-- as a real "ended" date by the event-scope eligibility filter in
-- 124_event_scope_mapping_procs.sql:
--     AND (s.end_dt IS NULL OR s.end_dt >= @effective_date)
-- i.e. an open-ended custom release with end_dt=1900-01-01 would be
-- treated as having ended in 1900 and silently dropped from scope.
--
-- WHAT
--   Clear the 1900-01-01 sentinel to NULL for Custom releases, so "no end
--   date" is stored as NULL -- the form shows it blank and the scope
--   filter treats the release as open-ended again.
--
-- SCOPE
--   Only subscription_type = 'Custom' and only the exact 1900-01-01
--   sentinel. effective_dt is intentionally left untouched: both NULL and
--   1900-01-01 already pass the matching effective_dt filter
--   (s.effective_dt IS NULL OR s.effective_dt <= @effective_date), so it
--   is not part of the reported issue; blank effective dates are stored as
--   NULL going forward by the same NULLIF code fix.
--
-- Idempotent and re-runnable (the WHERE matches nothing after the first
-- run). ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

UPDATE grac_practice.repository_subscription
SET end_dt = NULL
WHERE subscription_type = N'Custom'
  AND end_dt = '1900-01-01';

PRINT CONCAT('462: cleared blank-end-date sentinel on ', @@ROWCOUNT, ' Custom release(s).');
GO
