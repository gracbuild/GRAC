-- =====================================================================
-- 111 rollback -- DESTRUCTIVE: removes every custom_gap row copied
-- from the legacy Assurance module (source_reference_type='OrgAssuranceGap').
-- Also removes the child rows (actions, history, junctions) and
-- restores observation.gap_id pointers back to the legacy IDs.
-- Use only for a redo of the data migration.
-- =====================================================================
SET NOCOUNT ON;
GO

BEGIN TRAN;

IF OBJECT_ID('grac_practice.custom_gap','U') IS NOT NULL
BEGIN
    -- Restore observation.gap_id pointers to the legacy IDs so 105's
    -- accept-hook + downstream readers still work.
    IF OBJECT_ID('grac_practice.org_assurance_observation','U') IS NOT NULL
    BEGIN
        UPDATE o
           SET o.gap_id     = cg.source_reference_id,
               o.updated_by = 'rollback-111',
               o.updated_dt = SYSUTCDATETIME()
        FROM grac_practice.org_assurance_observation o
        JOIN grac_practice.custom_gap cg
             ON cg.custom_gap_id = o.gap_id
        WHERE cg.source_reference_type = N'OrgAssuranceGap'
          AND cg.source_reference_id IS NOT NULL;
    END

    -- Delete child rows tied to migrated gaps.
    IF OBJECT_ID('grac_practice.custom_gap_history','U') IS NOT NULL
        DELETE ch FROM grac_practice.custom_gap_history ch
        JOIN grac_practice.custom_gap cg ON cg.custom_gap_id = ch.custom_gap_id
        WHERE cg.source_reference_type = N'OrgAssuranceGap';

    IF OBJECT_ID('grac_practice.custom_gap_action','U') IS NOT NULL
        DELETE ca FROM grac_practice.custom_gap_action ca
        JOIN grac_practice.custom_gap cg ON cg.custom_gap_id = ca.custom_gap_id
        WHERE cg.source_reference_type = N'OrgAssuranceGap';

    IF OBJECT_ID('grac_practice.custom_gap_observation','U') IS NOT NULL
        DELETE cj FROM grac_practice.custom_gap_observation cj
        JOIN grac_practice.custom_gap cg ON cg.custom_gap_id = cj.custom_gap_id
        WHERE cg.source_reference_type = N'OrgAssuranceGap';

    -- Delete the migrated gap rows themselves.
    DELETE FROM grac_practice.custom_gap
    WHERE source_reference_type = N'OrgAssuranceGap';
END

COMMIT TRAN;
GO

PRINT '111 rollback complete -- migrated Assurance gap rows removed from custom_gap.';
GO
