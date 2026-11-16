# Policies & Documents dashboard v2 (migration 508)

Source: Dashboard UI / Functional Specification v2, section 11. Policies &
Documents had no dashboard; 508 adds one on the same framework as the other
module dashboards (414 contract, 416 menu rule, v2 layout). Presentation only:
nothing is written to the document, acknowledgement or evidence tables; no
table, column, status or workflow change.

## Files

| Layer | File | Change |
|---|---|---|
| DB | `database/508_documents_dashboard.sql` | New `sp_dashboard_documents(@organization_id, @caller_employee_id, @is_admin)` (414 contract: KPIs, ageing (none), distributions, lists). Menu row `documents-dashboard` ("Dashboard", `Practice/Index/documents-dashboard`, 5, `chart-pie`) under `nav-documents`. VIEW granted to every role that can VIEW Document Library, Document Acknowledgements or Evidence Center (missing rows only). Rollback: `508_documents_dashboard_rollback.sql`. |
| DB | `database/274_menu_master_seed.sql` | Snapshot: the new menu row and its parent link. |
| API | `Services/ManagementDashboardService.cs` | `documents` -> `sp_dashboard_documents`; caller parameters now passed for `governance` and `documents` (`CallerScoped`). |
| Web | `Models/PracticeScreen.cs` | Screen `documents-dashboard` (Policies & Documents group). |
| Web | `Models/ManagementDashboards.cs` | Sections `documents` -> document-uploads, `acknowledgements` -> document-acknowledgements, `docevidence` -> evidence-center; Home snapshot card "Policies & Documents". |
| Web | `wwwroot/js/ManagementDashboard/management-dashboard.js` | `loadDocuments` / `renderDocuments`; TARGET / KPI_DRILL / DIST_DRILL entries; `watchTable` gains `hideRef`, `hideOwner`, `titleLabel`, `footer`. |
| Web | `wwwroot/js/practice-dashboard.js` | Home snapshot figures for the module. |
| Web | `wwwroot/js/Shared/dashboard-drill.js` | Reads `stage`, `type`, `validity`, `usage` (and clears them). |
| Web | `wwwroot/js/DocumentUpload/document-uploads.js`, `Partials/document-uploads.cshtml` | On load: the drill's organisation and type / stage / status codes, mapped to the page's own filter options through its lookups; banner `#docDrillBanner`. |
| Web | `wwwroot/js/EvidenceCenter/evidence-center.js`, `Partials/evidence-center.cshtml` | On load: the drill's Validity / Used-in filter values; banner `#ecDrillBanner`. |

## Page

1. KPIs: Current documents (published, retired) / Awaiting review (Draft) / Awaiting approval (Reviewed) / Review overdue (due in 30 days, % of published, meter) / Acknowledgement completion % (acknowledged of users in open batches, overdue) / Evidence expiring (expired, active items).
2. Needs attention (left): acknowledgements overdue, reviews overdue, evidence expired, published without owner (High); evidence expiring, awaiting approval, published without review date, documents awaiting a batch (Medium); evidence not used, drafts (Info).
   Right: **Review calendar** (published documents by next review: overdue / 30 / 31-60 / 61-90 / later / not set), then Current documents by stage and Documents by status.
3. Current documents by type, Acknowledgement progress (acknowledged / pending not due / pending overdue, open batches, awaiting batch), Evidence items by validity.
4. Watchlists (balanced two columns): Document reviews overdue (oldest first, 15) | Open acknowledgement batches (earliest due) + Documents awaiting approval.

## KPI dictionary

| Key | Definition | Drill |
|---|---|---|
| documents.current | Record Active, status Active (any stage) | Library `status=Active` |
| documents.draft / pendingapproval / published | Current, stage Draft / Reviewed / Published | Library `stage=..&status=Active` |
| documents.retired | Status Retired | Library `status=Retired` |
| documents.reviewoverdue / review30 | Published, next_review_date < today / within 30 days | none (not a Library filter) |
| documents.noowner / noreview | Published, owner_id / next_review_date NULL | none |
| documents.ackrequired | Published, acknowledgement_required | none |
| acknowledgements.openbatches | Batches status Open (sp_document_ack_list's set) | none |
| acknowledgements.pending / acknowledged | User rows Pending / Acknowledged in Open batches | none |
| acknowledgements.overdue | Pending users in Open batches past due_date | none |
| acknowledgements.awaitingbatch | `document_acknowledgement_pending` Open (the Pending tab's rule) | none |
| docevidence.active | Active items the caller may see (Evidence Center rule) | Evidence Center |
| docevidence.expiring / expired | valid_to within 30 days / before today | `validity=Expiring` / `Expired` |
| docevidence.unused | No Active link | `usage=Unused` |

Distributions: `documents_stage`, `documents_status`, `documents_type` (item key = master code, drill), `documents_review` (no drill), `docevidence_validity` (Expiring / Expired drill; Valid and No expiry are not links because the Evidence Center's "Valid" includes no-expiry items).

Document Acknowledgements has no URL filter, so no figure drills into it; the progress card links to the page itself.

## Out-of-scope register

| Item | Why |
|---|---|
| Policy exceptions / waivers per document | Exceptions & Waivers records are not linked to documents. |
| Approval SLA / time in review | No review/approval due date; only reviewed_on / approved_on. |
| Framework or control mapping coverage | Documents carry no framework / statement mapping. |
| Acknowledgement by business unit / department | Per-user rows only; a department roll-up is not defined. |
| Superseded versions still referenced | No supersedes link between versions. |
| Distribution reach (who received a document) | Distribution lists are configuration, not a delivery record. |

## Deploy

`508_documents_dashboard.sql` (after 146-155 and 476-477) -> Api -> Web. Users sign out and in again to see the new menu (permissions are read at sign-in).
