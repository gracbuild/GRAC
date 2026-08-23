-- =====================================================================
-- TEMPLATE: add missing classification rows to grac_new.sla_master
--
-- WHY THIS FILE LIVES HERE (in PracticeManagement/database)
--   Only as an operator reference -- Practice Management does NOT
--   own grac_new.sla_master. Run against whatever database hosts
--   the grac_new schema (do NOT USE grac_new -- that's a schema,
--   not a database). Do not add to the normal Practice Management
--   migration numbering.
--
-- WORKFLOW
--   1. Run _diag_severity_vs_classification.sql first --
--      Section 4 lists the severities that have no matching
--      classification (e.g. Medium, Low).
--   2. Run _diag_sla_master_writable_columns.sql to confirm which
--      columns are writable in this environment. sla_code is a
--      COMPUTED column in the deployed schema and cannot be INSERTed;
--      it auto-derives from sla_id.
--   3. Copy one INSERT block per missing classification below and
--      fill in the values that match your organisation's SLA policy.
--   4. Run against the DB that hosts grac_new.
--   5. Come back to Practice Management -> SLA Configuration -> new
--      row appears as "Not Configured" -> Configure it -> Active.
--   6. Re-save any affected gap (or the next analysis save) so
--      sp_custom_gap_apply_sla picks up the fresh master.
--
-- COLUMNS to specify (post-diagnostic; adjust if your schema differs):
--   process_code     NVARCHAR(160)  (e.g. 'Gap Analysis')
--   classification   NVARCHAR(40)   (the value apply_sla matches on)
--   duration_value   INT
--   duration_unit    NVARCHAR(20)   (Days / Hours / Weeks / Months)
--   time_basis       NVARCHAR(60)   (Business Days / Calendar Days / ...)
--   warning_pct      DECIMAL(5,2)   (0..100)
--   escalation_pct   DECIMAL(5,2)   (0..100)
--   effective_from   DATE           (nullable)
--   remarks          NVARCHAR(1000) (nullable)
--   status           NVARCHAR(40)   (Active / Inactive / Retired)
--   entered_by       NVARCHAR(200)
--   entered_dt       DATETIME2
--
-- COLUMNS to SKIP (server-generated):
--   sla_id           IDENTITY
--   sla_code         COMPUTED (auto-generated from sla_id)
-- =====================================================================
SET NOCOUNT ON;

-- ---------------------------------------------------------------------
-- EXAMPLE 1: add Medium classification for Gap Analysis process
-- ---------------------------------------------------------------------
INSERT INTO grac_new.sla_master
    (process_code, classification,
     duration_value, duration_unit, time_basis,
     warning_pct, escalation_pct,
     effective_from, remarks, status,
     entered_by, entered_dt)
VALUES
    ('Gap Analysis',        -- process this SLA governs
     'Medium',              -- CLASSIFICATION -- must match a gap severity code
     7, 'Days', 'Business Days',
     75.00, 90.00,          -- warning at 75% elapsed, escalation at 90%
     '2026-01-01', 'Aligns criticality vocabulary with SLA classification.', 'Active',
     'ops', SYSUTCDATETIME());

-- ---------------------------------------------------------------------
-- EXAMPLE 2: add Low classification for Gap Analysis process
-- ---------------------------------------------------------------------
INSERT INTO grac_new.sla_master
    (process_code, classification,
     duration_value, duration_unit, time_basis,
     warning_pct, escalation_pct,
     effective_from, remarks, status,
     entered_by, entered_dt)
VALUES
    ('Gap Analysis',
     'Low',
     15, 'Days', 'Business Days',
     75.00, 90.00,
     '2026-01-01', 'Aligns criticality vocabulary with SLA classification.', 'Active',
     'ops', SYSUTCDATETIME());

-- ---------------------------------------------------------------------
-- OPTIONAL: mirror rows for other process_codes (Gap Remediation,
-- Risk Assessment, Risk Treatment, Continuous Assurance, ...) so the
-- same severity vocabulary matches across every process.
-- ---------------------------------------------------------------------

-- Verify (sla_code will appear -- computed on INSERT):
SELECT sla_id, sla_code, process_code, classification,
       duration_value, duration_unit, warning_pct, escalation_pct, status
FROM grac_new.sla_master
WHERE classification IN ('Medium', 'Low')
ORDER BY classification, process_code;
