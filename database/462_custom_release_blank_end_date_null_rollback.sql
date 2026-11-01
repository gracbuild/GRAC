-- =====================================================================
-- 462_custom_release_blank_end_date_null_rollback.sql
--
-- 462 cleared the 1900-01-01 "blank end date" sentinel to NULL on Custom
-- releases. This cannot be truthfully reversed: once set to NULL, a row
-- that was a sentinel is indistinguishable from a release that genuinely
-- never had an end date, so restoring 1900-01-01 would corrupt the latter.
-- Intentionally a no-op. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO
PRINT '462 rollback: no-op by design (NULL end dates are not restored to the 1900-01-01 sentinel).';
GO
