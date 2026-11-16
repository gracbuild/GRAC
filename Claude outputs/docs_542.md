
## Submit for Review and Approve live in Audit Configuration (542, 2026-11-13)

**Request (sir).** Review is possible only once the configuration is done (537), so Submit for Review belongs with the configuration: next to Save, enabled when every step is complete. Submit for Review and Approve are removed from the Audit Definition menus.

### Database -- `542_audit_configuration_review.sql` (+ rollback)
`sp_org_assurance_configuration_list` re-issued from 537 with one change: the list also holds audits **Under Review** (listed first), so they can be approved there. Same parameters and columns. Transitions (070) and the 537 gate unchanged.

### Web
- `_audit-configuration-workspace.cshtml`
  - Configure page: **Submit for Review** next to Save. Shown only on a Draft; enabled only when every step (Scope, Question Sets, Workflow, Scoring, Trigger, Scope Resolution) is Completed -- read from `setup-status` after opening, after Save, when a step's grid changes (Triggers / Scope Resolution save on their own), and on focus; its tooltip names the steps still open. It saves Workflow and Scoring first, asks for an optional reason, then `POST definitions/{id}/submit`, and opens the audit's view.
  - Under Review: Save and Submit are hidden, the bar says the configuration is read-only (the hosted screens are read-only off Draft).
  - List: new **Status** column; a row Under Review has **Approve** on its 3-dot menu (View, Audit Configuration, Approve); the view's Actions shows Approve for it too (`POST definitions/{id}/approve`). After approval the audit leaves this list -- Activate it from Audit Definition.
- `org-assurance-definitions.cshtml`: the **Submit for Review** and **Approve** items are removed from the row 3-dot menu and the audit page's Actions. Activate and Retire stay.
