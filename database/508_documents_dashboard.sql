-- =====================================================================
-- 508_documents_dashboard.sql
--
-- WHY
-- ---
-- GRAC Dashboard UI / Functional Specification v2 (1 Nov 2026), section 11
-- (Policies & Documents). Policies & Documents was the one module with no
-- dashboard. This adds it on the same framework as the other module
-- dashboards (414 contract, 416 menu rule). Presentation only -- nothing
-- is written to the document, acknowledgement or evidence tables; no
-- column, status or workflow change.
--
-- WHAT
--   1. grac_practice.sp_dashboard_documents (@organization_id,
--      @caller_employee_id, @is_admin) -- the 414 contract: KPIs, ageing
--      (none), distributions, lists. Three sections:
--        documents         Document Library (document_upload, Active records)
--        acknowledgements  Document Acknowledgements (batches + users)
--        docevidence       Evidence Center -- only items the caller may see
--                          (fn_pm_evidence_item_visible, the list's rule)
--   2. Menu: 'documents-dashboard' ("Dashboard", Practice/Index/documents-
--      dashboard, 5) -- first child of 'nav-documents' (416 rule). Also in
--      274_menu_master_seed.sql (authoritative snapshot).
--   3. Grants: VIEW on the new row for every role that can VIEW one of the
--      three child screens (451 / 490 rule). Missing rows only.
--
-- DEFINITIONS (each is the Document Library / Acknowledgements / Evidence
-- Center's own reading)
--   current document  = record Active AND current status code 'Active'
--   draft             = current, stage 'Draft'     (awaiting review)
--   pending approval  = current, stage 'Reviewed'  (awaiting approver)
--   published         = current, stage 'Published' (in force)
--   review overdue    = published, next_review_date < today
--   open batch        = acknowledgement batch status 'Open' (153 sets
--                       'Completed' on the last acknowledgement)
--   evidence validity = 476's rule: Expired < today <= Expiring (30 days)
--
-- Not added (no source -- docs/documents-dashboard-v2.md): policy
-- exceptions / waivers, approval SLA, framework mapping coverage,
-- superseded-but-referenced documents.
--
-- SAFE TO RE-RUN. Requires 146-155, 476-477. ASCII-only.
-- Rollback: 508_documents_dashboard_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.document_upload','U') IS NULL
   OR OBJECT_ID('grac_practice.document_acknowledgement_user','U') IS NULL
   OR OBJECT_ID('grac_practice.evidence_item','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_pm_evidence_item_visible') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-documents')
BEGIN
    PRINT 'ABORT (508): run 146-155 and 476-477 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_dashboard_documents
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_dashboard_documents
    @organization_id    BIGINT,
    @caller_employee_id BIGINT = NULL,
    @is_admin           BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 57920, 'sp_dashboard_documents: organization_id is required.', 1;
    SET @is_admin = ISNULL(@is_admin, 0);
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    -- Documents as the Document Library lists them (record Active).
    SELECT d.document_id, d.document_code, d.document_name,
           d.document_type_id, t.document_type, t.type_code,
           d.current_stage_id, s.stage_code, s.document_stage, s.sort_order AS stage_sort,
           d.current_status_id, st.status_code, st.document_status,
           d.next_review_date, d.owner_id, ow.employee_name AS owner_name,
           d.acknowledgement_required, d.version_number, d.reviewed_on
      INTO #doc
      FROM grac_practice.document_upload d
      JOIN grac_practice.record_status_master rs ON rs.record_status_id = d.record_status_id AND rs.status_code = N'Active'
      JOIN grac_practice.document_type_master   t  ON t.document_type_id    = d.document_type_id
      JOIN grac_practice.document_stage_master  s  ON s.document_stage_id   = d.current_stage_id
      JOIN grac_practice.document_status_master st ON st.document_status_id = d.current_status_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = d.owner_id
     WHERE d.organization_id = @organization_id;

    -- Acknowledgement batches and their user rows, as sp_document_ack_list
    -- reads them (every batch of the organisation; 'Open' until 153 marks
    -- it 'Completed' on the last acknowledgement).
    SELECT a.acknowledgement_id, a.acknowledgement_name, a.due_date, a.status_code
      INTO #ack
      FROM grac_practice.document_acknowledgement a
     WHERE a.organization_id = @organization_id;

    SELECT u.acknowledgement_id, u.status_code, a.due_date, a.status_code AS batch_status
      INTO #acku
      FROM grac_practice.document_acknowledgement_user u
      JOIN #ack a ON a.acknowledgement_id = u.acknowledgement_id;

    -- Evidence Center items the caller may see (476/477 rule).
    SELECT i.evidence_item_id, i.status, i.valid_to,
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                              WHERE l.evidence_item_id = i.evidence_item_id AND l.status = N'Active')
                THEN 1 ELSE 0 END AS is_used
      INTO #ev
      FROM grac_practice.evidence_item i
     CROSS APPLY grac_practice.fn_pm_evidence_item_visible(
                 i.evidence_item_id, i.owner_employee_id, i.created_by_employee_id,
                 i.classification, @caller_employee_id, @is_admin) vis
     WHERE i.organization_id = @organization_id
       AND i.status = N'Active';

    -- ---- 0. KPIs --------------------------------------------------------
    -- SUM over an empty set is NULL: ISNULL keeps zero distinguishable from
    -- 'not configured' (the page treats a missing KPI as not available).
    SELECT k.SectionKey, k.SectionTitle, k.KpiKey, k.Label, ISNULL(k.Value, 0) AS Value,
           CAST(k.IsAlert AS BIT) AS IsAlert, k.SortOrder
      FROM (
        SELECT N'documents' AS SectionKey, N'Controlled documents' AS SectionTitle, N'current' AS KpiKey,
               N'Current documents' AS Label,
               SUM(CASE WHEN status_code = N'Active' THEN 1 ELSE 0 END) AS Value, CAST(0 AS BIT) AS IsAlert, 1 AS SortOrder FROM #doc
        UNION ALL SELECT N'documents', N'Controlled documents', N'draft', N'Draft, awaiting review',
                         SUM(CASE WHEN status_code = N'Active' AND stage_code = N'Draft' THEN 1 ELSE 0 END), 0, 2 FROM #doc
        UNION ALL SELECT N'documents', N'Controlled documents', N'pendingapproval', N'Reviewed, awaiting approval',
                         SUM(CASE WHEN status_code = N'Active' AND stage_code = N'Reviewed' THEN 1 ELSE 0 END), 1, 3 FROM #doc
        UNION ALL SELECT N'documents', N'Controlled documents', N'published', N'Published',
                         SUM(CASE WHEN status_code = N'Active' AND stage_code = N'Published' THEN 1 ELSE 0 END), 0, 4 FROM #doc
        UNION ALL SELECT N'documents', N'Controlled documents', N'reviewoverdue', N'Review overdue',
                         SUM(CASE WHEN status_code = N'Active' AND stage_code = N'Published' AND next_review_date < @today THEN 1 ELSE 0 END), 1, 5 FROM #doc
        UNION ALL SELECT N'documents', N'Controlled documents', N'review30', N'Review due in 30 days',
                         SUM(CASE WHEN status_code = N'Active' AND stage_code = N'Published' AND next_review_date BETWEEN @today AND DATEADD(DAY, 30, @today) THEN 1 ELSE 0 END), 0, 6 FROM #doc
        UNION ALL SELECT N'documents', N'Controlled documents', N'noowner', N'Published, no owner',
                         SUM(CASE WHEN status_code = N'Active' AND stage_code = N'Published' AND owner_id IS NULL THEN 1 ELSE 0 END), 1, 7 FROM #doc
        UNION ALL SELECT N'documents', N'Controlled documents', N'noreview', N'Published, no next review date',
                         SUM(CASE WHEN status_code = N'Active' AND stage_code = N'Published' AND next_review_date IS NULL THEN 1 ELSE 0 END), 1, 8 FROM #doc
        UNION ALL SELECT N'documents', N'Controlled documents', N'retired', N'Retired',
                         SUM(CASE WHEN status_code = N'Retired' THEN 1 ELSE 0 END), 0, 9 FROM #doc
        UNION ALL SELECT N'documents', N'Controlled documents', N'ackrequired', N'Published, acknowledgement required',
                         SUM(CASE WHEN status_code = N'Active' AND stage_code = N'Published' AND acknowledgement_required = 1 THEN 1 ELSE 0 END), 0, 10 FROM #doc

        UNION ALL SELECT N'acknowledgements', N'Acknowledgements', N'openbatches', N'Open batches',
                         (SELECT COUNT(*) FROM #ack WHERE status_code = N'Open'), 0, 20
        UNION ALL SELECT N'acknowledgements', N'Acknowledgements', N'pending', N'Acknowledgements pending',
                         (SELECT COUNT(*) FROM #acku WHERE batch_status = N'Open' AND status_code = N'Pending'), 0, 21
        UNION ALL SELECT N'acknowledgements', N'Acknowledgements', N'acknowledged', N'Acknowledged (open batches)',
                         (SELECT COUNT(*) FROM #acku WHERE batch_status = N'Open' AND status_code = N'Acknowledged'), 0, 22
        UNION ALL SELECT N'acknowledgements', N'Acknowledgements', N'overdue', N'Acknowledgements overdue',
                         (SELECT COUNT(*) FROM #acku WHERE batch_status = N'Open' AND status_code = N'Pending' AND due_date < @today), 1, 23
        -- Published documents waiting to be rolled into a batch -- the
        -- Pending tab's own rule (sp_document_ack_pending_list).
        UNION ALL SELECT N'acknowledgements', N'Acknowledgements', N'awaitingbatch', N'Documents awaiting a batch',
                         (SELECT COUNT(*) FROM grac_practice.document_acknowledgement_pending p
                            JOIN grac_practice.document_upload x ON x.document_id = p.document_id
                           WHERE p.status_code = N'Open' AND x.organization_id = @organization_id), 0, 24

        UNION ALL SELECT N'docevidence', N'Evidence Center', N'active', N'Active evidence items', COUNT(*), 0, 30 FROM #ev
        UNION ALL SELECT N'docevidence', N'Evidence Center', N'expiring', N'Expiring in 30 days',
                         SUM(CASE WHEN valid_to BETWEEN @today AND DATEADD(DAY, 30, @today) THEN 1 ELSE 0 END), 1, 31 FROM #ev
        UNION ALL SELECT N'docevidence', N'Evidence Center', N'expired', N'Expired',
                         SUM(CASE WHEN valid_to < @today THEN 1 ELSE 0 END), 1, 32 FROM #ev
        UNION ALL SELECT N'docevidence', N'Evidence Center', N'unused', N'Not used anywhere',
                         SUM(CASE WHEN is_used = 0 THEN 1 ELSE 0 END), 0, 33 FROM #ev
      ) k
     ORDER BY k.SortOrder;

    -- ---- 1. Ageing: none (documents carry a review date, not an age).
    SELECT CAST(NULL AS NVARCHAR(40)) AS GroupKey, CAST(NULL AS NVARCHAR(200)) AS GroupTitle,
           CAST(NULL AS NVARCHAR(20)) AS BandCode, CAST(NULL AS NVARCHAR(60)) AS BandName,
           CAST(NULL AS INT) AS SortOrder, CAST(NULL AS INT) AS MinDays, CAST(NULL AS INT) AS MaxDays,
           CAST(NULL AS INT) AS ItemCount
     WHERE 1 = 0;

    -- ---- 2. Distributions ------------------------------------------------
    -- documents_stage / _status / _type: ItemKey is the master's code
    -- (stage_code / status_code / type_code) -- the Document Library maps
    -- it to its own filter option on load (?stage= / ?status= / ?type=).
    SELECT d.GroupKey, d.GroupTitle, d.ItemKey, d.ItemLabel, d.ItemCount, d.ColourHex, d.SortOrder
      FROM (
        SELECT N'documents_stage' AS GroupKey, N'Current documents by stage' AS GroupTitle,
               CAST(MAX(stage_code) AS NVARCHAR(40)) AS ItemKey, MAX(document_stage) AS ItemLabel,
               COUNT(*) AS ItemCount, CAST(NULL AS NVARCHAR(20)) AS ColourHex, MIN(stage_sort) AS SortOrder
          FROM #doc WHERE status_code = N'Active' GROUP BY current_stage_id
        UNION ALL
        SELECT N'documents_status', N'Documents by status',
               CAST(MAX(status_code) AS NVARCHAR(40)), MAX(document_status), COUNT(*), NULL,
               CASE MAX(status_code) WHEN N'Active' THEN 1 ELSE 2 END
          FROM #doc GROUP BY current_status_id
        UNION ALL
        SELECT N'documents_type', N'Current documents by type',
               CAST(MAX(type_code) AS NVARCHAR(40)), MAX(document_type), COUNT(*), NULL,
               CAST(ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, MAX(document_type)) AS INT)
          FROM #doc WHERE status_code = N'Active' GROUP BY document_type_id
        UNION ALL
        -- Review calendar (spec 11.3): published documents by next review date.
        SELECT N'documents_review', N'Published documents by next review', NULL, b.Label, COUNT(x.document_id), NULL, b.SortOrder
          FROM (VALUES (N'Overdue', 1), (N'Due in 30 days', 2), (N'Due in 31-60 days', 3),
                       (N'Due in 61-90 days', 4), (N'Later', 5), (N'No review date', 6)) b(Label, SortOrder)
          LEFT JOIN (SELECT document_id,
                            CASE WHEN next_review_date IS NULL THEN N'No review date'
                                 WHEN next_review_date < @today THEN N'Overdue'
                                 WHEN next_review_date <= DATEADD(DAY, 30, @today) THEN N'Due in 30 days'
                                 WHEN next_review_date <= DATEADD(DAY, 60, @today) THEN N'Due in 31-60 days'
                                 WHEN next_review_date <= DATEADD(DAY, 90, @today) THEN N'Due in 61-90 days'
                                 ELSE N'Later' END AS bucket
                       FROM #doc WHERE status_code = N'Active' AND stage_code = N'Published') x
                 ON x.bucket = b.Label
         GROUP BY b.Label, b.SortOrder
        UNION ALL
        SELECT N'docevidence_validity', N'Evidence items by validity', NULL, b.Label, COUNT(x.evidence_item_id), NULL, b.SortOrder
          FROM (VALUES (N'Valid', 1), (N'Expiring in 30 days', 2), (N'Expired', 3), (N'No expiry', 4)) b(Label, SortOrder)
          LEFT JOIN (SELECT evidence_item_id,
                            CASE WHEN valid_to IS NULL THEN N'No expiry'
                                 WHEN valid_to < @today THEN N'Expired'
                                 WHEN valid_to <= DATEADD(DAY, 30, @today) THEN N'Expiring in 30 days'
                                 ELSE N'Valid' END AS bucket
                       FROM #ev) x
                 ON x.bucket = b.Label
         GROUP BY b.Label, b.SortOrder
      ) d
     ORDER BY d.GroupKey, d.SortOrder;

    -- ---- 3. Lists --------------------------------------------------------
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (15) N'documents_reviewoverdue' AS ListKey, N'Review overdue' AS ListTitle,
               document_id AS RecordId, CAST(document_code AS NVARCHAR(100)) AS RefText,
               CAST(document_name AS NVARCHAR(400)) AS Title, CAST(owner_name AS NVARCHAR(300)) AS OwnerName,
               CAST(document_type AS NVARCHAR(100)) AS StatusText, CAST(next_review_date AS DATE) AS DateValue,
               CAST(ROW_NUMBER() OVER (ORDER BY next_review_date, document_id) AS INT) AS SortOrder
          FROM #doc
         WHERE status_code = N'Active' AND stage_code = N'Published' AND next_review_date < @today
         ORDER BY next_review_date, document_id
      ) l
    UNION ALL
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        SELECT TOP (10) N'documents_pendingapproval' AS ListKey, N'Awaiting approval' AS ListTitle,
               document_id AS RecordId, CAST(document_code AS NVARCHAR(100)) AS RefText,
               CAST(document_name AS NVARCHAR(400)) AS Title, CAST(owner_name AS NVARCHAR(300)) AS OwnerName,
               CAST(CONCAT(N'Version ', version_number) AS NVARCHAR(100)) AS StatusText,
               CAST(reviewed_on AS DATE) AS DateValue,
               CAST(ROW_NUMBER() OVER (ORDER BY reviewed_on, document_id) AS INT) AS SortOrder
          FROM #doc
         WHERE status_code = N'Active' AND stage_code = N'Reviewed'
         ORDER BY reviewed_on, document_id
      ) l
    UNION ALL
    SELECT l.ListKey, l.ListTitle, l.RecordId, l.RefText, l.Title, l.OwnerName, l.StatusText, l.DateValue, l.SortOrder
      FROM (
        -- Open batches, earliest due first; StatusText = progress.
        SELECT TOP (10) N'acknowledgements_open' AS ListKey, N'Open acknowledgement batches' AS ListTitle,
               a.acknowledgement_id AS RecordId, CAST(NULL AS NVARCHAR(100)) AS RefText,
               CAST(a.acknowledgement_name AS NVARCHAR(400)) AS Title, CAST(NULL AS NVARCHAR(300)) AS OwnerName,
               CAST(CONCAT(ISNULL(p.done, 0), N' of ', ISNULL(p.total, 0), N' acknowledged') AS NVARCHAR(100)) AS StatusText,
               a.due_date AS DateValue,
               CAST(ROW_NUMBER() OVER (ORDER BY CASE WHEN a.due_date IS NULL THEN 1 ELSE 0 END, a.due_date, a.acknowledgement_id) AS INT) AS SortOrder
          FROM #ack a
          OUTER APPLY (SELECT COUNT(*) AS total,
                              SUM(CASE WHEN u.status_code = N'Acknowledged' THEN 1 ELSE 0 END) AS done
                         FROM #acku u WHERE u.acknowledgement_id = a.acknowledgement_id) p
         WHERE a.status_code = N'Open'
         ORDER BY CASE WHEN a.due_date IS NULL THEN 1 ELSE 0 END, a.due_date, a.acknowledgement_id
      ) l
     ORDER BY 1, 9;
END
GO

-- =====================================================================
-- 2. Menu: Policies & Documents -> Dashboard (first child; also in 274)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'documents-dashboard', N'Dashboard', N'Practice/Index/documents-dashboard', 5, N'chart-pie', N'Policies & Documents')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name
               OR ISNULL(t.menu_url, N'') <> ISNULL(s.menu_url, N'')
               OR t.display_order <> s.display_order
               OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type
               OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order,
    icon_class = s.icon_class, module_type = s.module_type, status = N'Active',
    updated_by = N'seed-508', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-508');
PRINT CONCAT('508: menu row upserted: ', @@ROWCOUNT);

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-508', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-documents'
 WHERE c.menu_key = N'documents-dashboard'
   AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
PRINT '508: menu parent wired.';
GO

-- =====================================================================
-- 3. Grants: VIEW on the Dashboard for every role that can VIEW one of
--    the screens it summarises (451 / 490 rule). Missing rows only, so a
--    re-run never re-grants a right someone removed in Role Master.
-- =====================================================================
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT DISTINCT p.role_id, d.menu_id, 1, 0, 0, 0, 0, N'Active', @active_rs, N'seed-508', SYSUTCDATETIME()
  FROM (VALUES (N'document-uploads'), (N'document-acknowledgements'), (N'evidence-center')) x(child_key)
  JOIN grac_practice.menu_master d ON d.menu_key = N'documents-dashboard'
  JOIN grac_practice.menu_master c ON c.menu_key = x.child_key AND c.status = N'Active'
  JOIN grac_practice.organization_role_menu_permission p ON p.menu_id = c.menu_id AND p.can_view = 1 AND p.status = N'Active'
 WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = p.role_id AND e.menu_id = d.menu_id);
PRINT CONCAT('508: dashboard VIEW grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 4. Verification
-- =====================================================================
SELECT '508-a procedure' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_dashboard_documents','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '508-b Dashboard is the first child of Policies & Documents',
       CASE WHEN (SELECT TOP (1) c.menu_key FROM grac_practice.menu_master c
                    JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-documents'
                   WHERE c.status = N'Active' ORDER BY c.display_order, c.menu_id) = N'documents-dashboard'
            THEN 'PASS' ELSE 'FAIL' END;
DECLARE @org BIGINT = (SELECT TOP (1) organization_id FROM grac_practice.organization WHERE status = N'Active' ORDER BY organization_id);
IF @org IS NOT NULL EXEC grac_practice.sp_dashboard_documents @organization_id = @org, @is_admin = 1;
GO

SET NOEXEC OFF;
GO
PRINT '508 complete. Sign out and in again to see the new Dashboard menu (permissions are read at sign-in).';
GO
