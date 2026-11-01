# Review list – items still to verify on screen

Collected from the chapter drafts. Each item was removed from its chapter; where a step depended on it, the chapter now says neutrally that the system shows a message explaining why.

## Dashboard

- A banner on the target screen shows what you drilled into. TO VERIFY: banner wording and its buttons (the design names them **Clear filter** and **Dashboard**).

## Asset Register

- TO VERIFY: exact wording of the serial-number, compatibility and valuation warnings/errors raised on save (they come from the server and are not in the screen).

## Asset Attestation

- The type column can also show **Transfer**, **Return** or **Event**. TO VERIFY: what raises Transfer, Return and Event attestations — none of them can be started from this screen.
- TO VERIFY: whether **Close** is a separate step after an approver's **Approve**, or whether approval closes the exception directly; and which status a **Reject** returns the exception to (expected: **Under review**).
- New rules apply to exceptions opened afterwards. TO VERIFY: whether changed SLA days affect exceptions already open.
- | **Escalated** | — | TO VERIFY: when an occurrence shows Escalated. |

## Contracts

- TO VERIFY: whether the Contract ID must be unique within the organization, and the exact message shown if it is not.
- TO VERIFY: the exact wording of the error messages for each of these checks (the checks made when a contract version is submitted or approved: dates, contract owner, change summary, value with currency, no overlapping versions, active vendor).
- TO VERIFY: the full list of contact roles. The design names Primary Contact as the one mandatory role; others are configured centrally.
- TO VERIFY: the exact condition for **Not started**. It appears as a status label, but the design notes do not define it.
- TO VERIFY: the exact message shown in the Asset Register when activation is blocked.
- TO VERIFY: whether the **Open** filter also includes occurrences that are Pending Approval or Approved (it appears to cover every renewal not yet completed or cancelled).
- **Saving fails because someone else changed the record.** If another user saved the same contract, version, contact or renewal after you opened it, your save is refused. Close and reopen the window to load the latest data, then redo your change. TO VERIFY: the exact wording of this message.

## Asset Notifications

- **Channels:** in-application notices appear on **My Notifications**; reading one marks it delivered (Pending → Sent). Email and Teams / webhook are recorded on every notice for a delivery service; a failed delivery is retried until the third attempt, then stays **Failed**. TO VERIFY: whether email and Teams/webhook delivery is connected in your installation — without a delivery service only in-application notices reach users.
- TO VERIFY: the section heading, the labels of the filter options, the button labels for refresh and mark-all-read, and the grid column headers on My Notifications (the page layout was not available for review). The behaviour below is confirmed.

- (Resolved from seed scripts) Privacy / DPIA review and Retention / deletion review notices ARE raised (open privacy reviews, approved privacy exceptions, open retention reviews); Asset Notifications chapter corrected.

## Asset Relationships

- TO VERIFY: the blank cells (the default cardinality and loop rule for those types). The design implies Many to many and Block, but the screen is the authority.
- TO VERIFY: the exact error messages for the kind, cardinality and loop checks.
- TO VERIFY: the exact message shown in the Asset Register when the retirement gate blocks a lifecycle change.
- If someone else saved the relationship after you opened it, your save is refused. Reopen it and try again. TO VERIFY: the exact wording.

## Business Services

- TO VERIFY: the exact error messages for a duplicate service ID or name and for RTO greater than MTPD.
- TO VERIFY: the exact error messages when activation or retirement is refused.
- TO VERIFY: whether the system also blocks someone other than the requester from using **Withdraw retirement (requester)**. The button is shown to anyone with Edit permission.
- If someone else saved the service after you opened it, your save is refused. Reopen the service and repeat your change. TO VERIFY: the exact wording.

## Asset Discovery

- TO VERIFY: the exact message shown when the thresholds are not in descending order (auto > suggested > manual review).
- Every save and action is checked against the version you opened; if someone else changed the record meanwhile, the save is refused – close and reopen the item and try again. TO VERIFY: the exact wording of this refusal.
- A request that fails with a server error shows the reason in the message line or the window; TO VERIFY: the exact wording of server-side refusals (for example duplicate Source ID, a second golden source for a field, raw retention longer than observation retention, blockers at submit).

## Field Dictionary

- TO VERIFY: the exact wording shown in **Status** (the screen shows the stored status code, for example "ACTIVE" or "RETIRED") and the exact format of **Lookup source** values.
- TO VERIFY: whether retired definitions are listed on this screen or only shown inside existing templates.

## Asset Form Templates

- TO VERIFY: the exact message shown when you try to create a second template for an asset type that already has one.
- TO VERIFY: what the **System** sections contain and where they appear on the asset form.
- TO VERIFY: how **Migrate the value** behaves for users, and where the **Evidence required** and **Help text** settings appear on the asset form.
- TO VERIFY: for **date within N days**, confirm that the value to enter is the number of days.
- TO VERIFY: the complete list of readiness checks and their wording.
- Assets keep the template version they were registered with. TO VERIFY: confirm how existing assets behave after a new version is activated.
- TO VERIFY: whether segregation of duties also applies to the direct **Approve** from **Testing** when **Approval required** is set to No.

## Option Lists

- TO VERIFY: where an organization's locations (sites) are maintained, so the manual can cross-reference that screen.
- TO VERIFY: the exact wording of the refusal messages for a duplicate code and for retiring a value with active children.

## Asset Taxonomy

- TO VERIFY: where these defaults are applied (for example pre-filled when a new asset of this type is registered).
- TO VERIFY: the exact refusal messages for duplicate names and for moving an item that is in use.

## Asset Valuation

- TO VERIFY: when **New Configuration** is used from the list while versions already exist, confirm which version is copied (expected: the current version of the organization).
- TO VERIFY: where outside this screen the **Review every (months)** value is used.
- TO VERIFY: the **Check** column shows an internal check code; confirm the wording users see for each check.
- TO VERIFY: whether the approver must be a different person from the person who submitted the version (the screen relies on the system's segregation-of-duties checks; the exact rule is not shown on screen).

## Technology Catalogue

- TO VERIFY: whether a model can be edited while it is **Pending Approval** (the dialog does not stop it; the system may refuse the save).

## Asset Privacy

- TO VERIFY: the name of the screen where these notification profiles are configured (expected under **Asset & Contract**), and the profile under which exception expiry reminders are sent.  (Partly answered: the profiles are configured on Asset Notifications. Still open: which profile sends privacy exception expiry reminders.)

## Asset Governance

- For a higher-is-better KPI the warning should be below the target; for Reconciliation Backlog Rate (lower is better) the warning should be above the target. TO VERIFY: the exact message shown when the target and warning are in the wrong order.
- Server-side refusals are shown in the message line. TO VERIFY: their exact wording (for example values out of range).

## Asset Reports

- Filter rules (checked by the system): the status must be one of the report's options, the dates must be in order, and days must be 1–3650. TO VERIFY: the exact refusal messages.
- At most 50,000 rows per export; if the result is larger, narrow the filters. TO VERIFY: the exact message.
- Under the **Asset Reports approvers** policy, a user without Asset Reports Approve is refused (for example *Export ... needs Asset Reports APPROVE*). TO VERIFY: the full message.
- Delivery statuses shown include **RUNNING**, **COMPLETED**, **PARTIAL** and **FAILED**. TO VERIFY: the full list of delivery statuses and their exact meaning.
- Server-side refusals appear in the message line. TO VERIFY: the exact wording of refusals such as lowering a classification, an invalid status filter, dates out of order, or too many rows.

## Resolved from seed scripts

- Dashboard: TO VERIFY: the exact section headings shown on screen (they are supplied by the system and are not visible in the page design). The names above are the section keys.
- Dashboard: TO VERIFY: the exact on-screen caption of every tile, bar group and list.
- Asset Register: TO VERIFY: names and order of the steps in each workflow (owner change 7 steps, location transfer 6, breakdown 7, disposal 10 per the design) – these are configuration and shown in the screen's step list.
- Asset Register: TO VERIFY: the grouping of statuses into lifecycle stages (Acquisition, Readiness, Operation, Movement, Exception, Retirement) that drives the chip colour; this comes from configuration and is shown as a tooltip on the chip.
- Asset Activities: TO VERIFY: the exact activity names as they appear in the **All activities** drop-down.
- Asset Notifications: TO VERIFY: the exact activity names as listed in the **Activity** drop-down.
- Asset Notifications: TO VERIFY: the exact recipient labels in the **Add recipient...** drop-down.
- Asset Governance: TO VERIFY: the exact KPI names shown on screen (they come from the system catalogue). The names below are those used in the module design; "Reconciliation Backlog Rate" is confirmed on screen.
- Asset Reports: TO VERIFY: the exact family headings and the complete list of report names as shown in the catalogue (they come from the system catalogue and are not visible in the page design).
- Asset Reports: | Family | Reports (names as used in the design – TO VERIFY on screen) |
