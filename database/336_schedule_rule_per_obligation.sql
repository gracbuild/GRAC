-- =====================================================================
-- 336 Schedule rule becomes per-obligation, and carries its kind
--
-- WHY
-- ---
-- assurance_schedule_rule (028) was one row per practice instance:
-- UNIQUE(practice_instance_id), a single frequency_id, a single
-- anchor_date. That fit the old model where an instance had one
-- instance-wide assurance cadence (retired in 235-237).
--
-- The cadence now belongs to each obligation. An instance can hold an
-- Execution obligation that runs weekly AND an Assurance obligation that
-- verifies monthly -- two genuinely different recurring streams that the
-- one-row-per-instance rule cannot represent, and that the Assurance-only
-- collapse in 237 (shortest cadence, ignoring Execution entirely) could
-- not even see.
--
-- This migration widens the rule so one instance can own several streams,
-- each tied to the obligation that defines its cadence and tagged with
-- which kind of cadence it is.
--
-- WHAT IT DOES
-- ------------
--   1. adds practice_instance_obligation_id -- the schedulable obligation
--      this stream belongs to (NULL = a legacy instance-wide row seeded
--      before this change; kept working until reconciled).
--   2. adds schedule_kind -- 'Execution' or 'Assurance', the cadence this
--      stream represents. Legacy rows are stamped 'Assurance', which is
--      exactly what the 237 view fed them.
--   3. drops UNIQUE(practice_instance_id) -- an instance may now own more
--      than one active rule.
--   4. adds a filtered UNIQUE index so an obligation still owns at most
--      ONE active stream (the NULL legacy rows are excluded from it, so
--      they do not collide with each other).
--   5. adds a plain index on the obligation id for the calendar read
--      join (QueryCalendarEventsAsync).
--
-- WHAT IT DELIBERATELY DOES NOT DO
-- --------------------------------
--   * No row is deleted or re-pointed. Existing rules keep their
--     schedule_rule_id, frequency_id, anchor_date and every override that
--     references them -- overrides are keyed on schedule_rule_id, so
--     ALTERing in place (not recreating) preserves them.
--   * frequency_id / anchor_date stay per-row and untouched. Populating a
--     stream from an obligation's own frequency is the save-hook's job
--     (later migration / API), not this schema step.
--   * No proc or view is changed here. The read query and the
--     schedulable-obligations view ship in their own steps.
--
-- SAFE TO RE-RUN: every add/drop is guarded on catalog state.
-- Rollback: database/336_schedule_rule_per_obligation_rollback.sql
-- DEPENDS ON: 028 (assurance_schedule_rule), 140 (practice_instance_obligation).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

-- ---------------------------------------------------------------------
-- Prerequisites
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.assurance_schedule_rule','U') IS NULL
BEGIN PRINT 'ABORT (336): grac_practice.assurance_schedule_rule missing. Run 028 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NULL
BEGIN PRINT 'ABORT (336): practice_instance_obligation missing. Run 140 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('336_schedule_rule_per_obligation: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. practice_instance_obligation_id -- the obligation that owns this
--    stream. NULL for the legacy instance-wide rows seeded before 336.
-- ---------------------------------------------------------------------
IF COL_LENGTH('grac_practice.assurance_schedule_rule','practice_instance_obligation_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.assurance_schedule_rule
        ADD practice_instance_obligation_id BIGINT NULL;
    PRINT '336: added assurance_schedule_rule.practice_instance_obligation_id';
END
ELSE PRINT '336: practice_instance_obligation_id already present -- skipped';
GO

-- FK added in its own batch so the column is guaranteed committed first.
IF COL_LENGTH('grac_practice.assurance_schedule_rule','practice_instance_obligation_id') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_schedule_rule_pio')
BEGIN
    ALTER TABLE grac_practice.assurance_schedule_rule
        ADD CONSTRAINT fk_pm_schedule_rule_pio
        FOREIGN KEY (practice_instance_obligation_id)
        REFERENCES grac_practice.practice_instance_obligation(practice_instance_obligation_id);
    PRINT '336: added FK fk_pm_schedule_rule_pio';
END
ELSE PRINT '336: FK fk_pm_schedule_rule_pio already present or column missing -- skipped';
GO

-- ---------------------------------------------------------------------
-- 2. schedule_kind -- 'Execution' | 'Assurance'.
-- ---------------------------------------------------------------------
IF COL_LENGTH('grac_practice.assurance_schedule_rule','schedule_kind') IS NULL
BEGIN
    ALTER TABLE grac_practice.assurance_schedule_rule
        ADD schedule_kind NVARCHAR(20) NULL;
    PRINT '336: added assurance_schedule_rule.schedule_kind';
END
ELSE PRINT '336: schedule_kind already present -- skipped';
GO

-- ---------------------------------------------------------------------
-- 3. Stamp legacy rows. Everything that exists before 336 was seeded
--    from the Assurance-only 237 view, so its kind is 'Assurance'. Only
--    rows still NULL are touched, so a second run changes nothing.
-- ---------------------------------------------------------------------
IF COL_LENGTH('grac_practice.assurance_schedule_rule','schedule_kind') IS NOT NULL
BEGIN
    UPDATE grac_practice.assurance_schedule_rule
       SET schedule_kind = N'Assurance'
     WHERE schedule_kind IS NULL;
    PRINT '336: legacy rows stamped schedule_kind=Assurance = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END
GO

-- ---------------------------------------------------------------------
-- 4. Drop the one-rule-per-instance UNIQUE. An instance may now own an
--    Execution stream and an Assurance stream at once.
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.key_constraints
            WHERE name = 'uq_pm_schedule_rule_instance'
              AND parent_object_id = OBJECT_ID('grac_practice.assurance_schedule_rule'))
BEGIN
    ALTER TABLE grac_practice.assurance_schedule_rule
        DROP CONSTRAINT uq_pm_schedule_rule_instance;
    PRINT '336: dropped UNIQUE uq_pm_schedule_rule_instance';
END
ELSE PRINT '336: uq_pm_schedule_rule_instance already gone -- skipped';
GO

-- ---------------------------------------------------------------------
-- 5. One ACTIVE stream per obligation. Filtered so the legacy NULL rows
--    (which have no obligation id yet) are outside the rule and never
--    collide with one another. Reconcile/backfill later maps them.
-- ---------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'uq_pm_schedule_rule_obligation_active'
                  AND object_id = OBJECT_ID('grac_practice.assurance_schedule_rule'))
BEGIN
    CREATE UNIQUE INDEX uq_pm_schedule_rule_obligation_active
        ON grac_practice.assurance_schedule_rule(practice_instance_obligation_id)
        WHERE practice_instance_obligation_id IS NOT NULL
          AND is_active = 1
          AND status = N'Active';
    PRINT '336: created filtered UNIQUE uq_pm_schedule_rule_obligation_active';
END
ELSE PRINT '336: uq_pm_schedule_rule_obligation_active already present -- skipped';
GO

-- ---------------------------------------------------------------------
-- 6. Read-join helper index (calendar occurrence query joins the rule to
--    its obligation).
-- ---------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_schedule_rule_pio'
                  AND object_id = OBJECT_ID('grac_practice.assurance_schedule_rule'))
BEGIN
    CREATE INDEX ix_pm_schedule_rule_pio
        ON grac_practice.assurance_schedule_rule(practice_instance_obligation_id)
        INCLUDE(practice_instance_id, frequency_id, anchor_date, schedule_kind);
    PRINT '336: created index ix_pm_schedule_rule_pio';
END
ELSE PRINT '336: ix_pm_schedule_rule_pio already present -- skipped';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 336 verification ===';

SELECT 'columns added' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.assurance_schedule_rule','practice_instance_obligation_id') IS NOT NULL
             AND COL_LENGTH('grac_practice.assurance_schedule_rule','schedule_kind') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'per-instance UNIQUE dropped',
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.key_constraints
                              WHERE name = 'uq_pm_schedule_rule_instance'
                                AND parent_object_id = OBJECT_ID('grac_practice.assurance_schedule_rule'))
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'per-obligation UNIQUE present',
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                          WHERE name = 'uq_pm_schedule_rule_obligation_active'
                            AND object_id = OBJECT_ID('grac_practice.assurance_schedule_rule'))
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'no legacy row left without a kind',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.assurance_schedule_rule WHERE schedule_kind IS NULL)
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '336 schedule_rule per-obligation schema change complete.';
GO
SET NOEXEC OFF;
GO
