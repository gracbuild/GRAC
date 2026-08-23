-- =====================================================================
-- TEMPLATE: widen the sla_master.classification CHECK constraint
--
-- The schema constraint ck_sla_master_classification restricts what
-- values classification can take (currently something like
-- IN ('Critical','High','Standard')). To align with gap severity
-- vocabulary (Critical / High / Medium / Low), the constraint must
-- be dropped and re-added with the widened value set.
--
-- STEPS
--   1. Run _diag_sla_master_classification_check.sql first -- confirm
--      the current definition and any existing classification values.
--   2. Adjust the IN(...) list below to match the FULL target
--      vocabulary (keep everything already allowed + add the new
--      values so no existing row is rejected).
--   3. Run against the DB that hosts grac_new (GRAC_NewPhase in the
--      current environment).
--   4. Then run _template_add_missing_sla_classifications.sql for the
--      actual INSERTs.
--
-- SAFETY
--   ALTER TABLE ... ADD CONSTRAINT ... CHECK runs a full-table scan.
--   If any existing classification value is not in the new IN(...)
--   list, the ADD will fail -- the diag SELECT above surfaces that
--   before you attempt the rewrite.
-- =====================================================================
SET NOCOUNT ON;

-- 1. Drop the existing constraint (idempotent).
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_sla_master_classification')
    ALTER TABLE grac_new.sla_master DROP CONSTRAINT ck_sla_master_classification;
GO

-- 2. Re-add with the widened value set.
--    Adjust the IN(...) list to the full target vocabulary.
ALTER TABLE grac_new.sla_master
    ADD CONSTRAINT ck_sla_master_classification
        CHECK (classification IN
            (N'Critical', N'High', N'Medium', N'Standard', N'Low'));
GO

-- 3. Verify.
SELECT name AS ConstraintName, definition AS NewDefinition
FROM sys.check_constraints
WHERE name = 'ck_sla_master_classification';
