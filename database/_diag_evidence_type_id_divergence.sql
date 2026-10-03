-- =====================================================================
-- READ-ONLY diagnostic: evidence_type_id divergence between the shared
-- (GRAC_New) and local (grac_practice) evidence_type_master tables, and
-- its impact on grac_practice.practice_instance_evidence.
--
-- Explains "The INSERT statement conflicted with the FOREIGN KEY
-- constraint fk_pm_evidence_shared_type" on obligation-evidence save in
-- Operationalize. Nothing is written. Safe to run on any environment.
-- Run against the affected DB (e.g. Grac_newphase_uat).
-- =====================================================================
SET NOCOUNT ON;

PRINT '===== 1. Same name, DIFFERENT id (the divergence that breaks saves) =====';
SELECT  pet.evidence_type_name              AS EvidenceType,
        pet.evidence_type_id                AS GracPractice_Id,
        get.evidence_type_id                AS GracNew_Id,
        CASE WHEN pet.evidence_type_id = get.evidence_type_id
             THEN 'aligned' ELSE '*** DIVERGED ***' END AS State
FROM    grac_practice.evidence_type_master pet
JOIN    GRAC_New.evidence_type_master      get
        ON get.evidence_type_name = pet.evidence_type_name
ORDER BY State DESC, pet.evidence_type_name;

PRINT '===== 2. Local types with NO shared counterpart by name (org-defined only) =====';
SELECT  pet.evidence_type_id, pet.evidence_type_name, pet.is_active
FROM    grac_practice.evidence_type_master pet
WHERE   NOT EXISTS (SELECT 1 FROM GRAC_New.evidence_type_master get
                    WHERE get.evidence_type_name = pet.evidence_type_name);

PRINT '===== 3. Existing practice_instance_evidence rows and which master their id resolves in =====';
SELECT
   COUNT(*)                                                                   AS TotalRows,
   SUM(CASE WHEN gn.evidence_type_id IS NOT NULL THEN 1 ELSE 0 END)           AS ResolveInGracNew,
   SUM(CASE WHEN gp.evidence_type_id IS NOT NULL THEN 1 ELSE 0 END)           AS ResolveInGracPractice,
   SUM(CASE WHEN gn.evidence_type_id IS NULL THEN 1 ELSE 0 END)               AS Orphan_vs_GracNew_FK,
   SUM(CASE WHEN gp.evidence_type_id IS NULL THEN 1 ELSE 0 END)               AS Orphan_vs_GracPractice
FROM   grac_practice.practice_instance_evidence pie
LEFT   JOIN GRAC_New.evidence_type_master      gn ON gn.evidence_type_id = pie.evidence_type_id
LEFT   JOIN grac_practice.evidence_type_master gp ON gp.evidence_type_id = pie.evidence_type_id;

PRINT '===== 4. Is the FK currently present? =====';
SELECT  fk.name AS ForeignKey, OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.' +
        OBJECT_NAME(fk.referenced_object_id) AS ReferencesTable
FROM    sys.foreign_keys fk
WHERE   fk.name = 'fk_pm_evidence_shared_type';
