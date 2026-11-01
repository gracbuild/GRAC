-- _diag_one_time_evidence_attachments.sql  (READ-ONLY; SSMS against the Practice Management DB)
-- "I attached a one-time evidence file on Operationalize but cannot see it
-- afterwards" -- was it saved, and to which evidence row?
-- Set @practice_instance_id (the id in the Operationalize URL).
SET NOCOUNT ON;
DECLARE @practice_instance_id BIGINT = 0;

-- 1. Every evidence row of the instance, with its cadence and file count.
--    Only rows with EvidenceCadence = OneTime show the attach block.
SELECT N'1 evidence row' AS Step, e.evidence_id, e.source_obligation_id, e.status,
       COALESCE(NULLIF(LTRIM(RTRIM(e.evidence_name)), N''), et.evidence_type_name) AS EvidenceName,
       cad.EvidenceCadence, cad.CadenceSource,
       (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence_attachment a
         WHERE a.practice_instance_id = e.practice_instance_id AND a.evidence_id = e.evidence_id
           AND a.status = N'Active') AS ActiveFiles
FROM   grac_practice.practice_instance_evidence e
LEFT   JOIN grac_practice.evidence_type_master et ON et.evidence_type_id = e.evidence_type_id
LEFT   JOIN grac_practice.vw_pm_instance_evidence_cadence cad ON cad.evidence_id = e.evidence_id
WHERE  e.practice_instance_id = @practice_instance_id
ORDER  BY e.source_obligation_id, e.evidence_id;

-- 2. Every file ever attached on this instance (Active and Removed). No
--    rows here = the upload never reached the database (the API refused it
--    or never received it -- check the message next to "Attach file" and
--    the API log for sp_resolve_evidence_attachment_add).
SELECT N'2 attachment' AS Step, a.evidence_attachment_id, a.evidence_id, a.organization_id,
       a.file_name, a.file_size_bytes, a.status, a.uploaded_by, a.uploaded_dt, a.removed_by, a.removed_dt,
       CASE WHEN e.evidence_id IS NULL THEN N'evidence row missing'
            WHEN e.status <> N'Active' THEN N'evidence row not Active - the screen no longer shows it'
            WHEN a.status <> N'Active' THEN N'file was removed'
            ELSE N'ok - should be listed under that evidence row' END AS Verdict
FROM   grac_practice.practice_instance_evidence_attachment a
LEFT   JOIN grac_practice.practice_instance_evidence e ON e.evidence_id = a.evidence_id
WHERE  a.practice_instance_id = @practice_instance_id
ORDER  BY a.uploaded_dt DESC;

-- 3. The audit trail of uploads / removals for this instance.
SELECT N'3 audit' AS Step, t.entity_id AS evidence_attachment_id, t.action_type, t.after_json, t.entered_by, t.entered_dt
FROM   grac_practice.practice_audit_trace t
WHERE  t.entity_type = N'practice-instance-evidence-attachment'
  AND  JSON_VALUE(t.after_json, '$.practiceInstanceId') = CAST(@practice_instance_id AS NVARCHAR(30))
ORDER  BY t.entered_dt DESC;
