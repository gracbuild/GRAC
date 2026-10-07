# Demo database (grac_new_demo) from UAT (2026-10-06)

Goal: a demo copy of UAT (`grac_newphase_uat`) with every schema object, all
of GRAC_New and every master table, but organization data for **MSP (1)**
and **SD (9)** only.

| Step | Script (database/) | Run in | What it does |
|---|---|---|---|
| 1 | `tool_demo_db_01_clone.sql` | `master`, on the UAT server | COPY_ONLY backup of UAT, restored as `grac_new_demo` (files to the server's default folders). Stops if `grac_new_demo` exists. UAT is only read. |
| 2 | `tool_demo_db_02_keep_orgs.sql` | `grac_new_demo` | Deletes every other organization's rows; GRAC_New and global rows untouched. `@DryRun = 1` first (rolls back, prints per-table counts), then `@DryRun = 0`, `@ConfirmDatabase = 'grac_new_demo'`. Refuses to run in any other database. |

Step 2 is generic (no table list): tables outside GRAC_New with an
`organization_id` lose rows of other organizations; then rows that pointed
at a deleted row are removed FK by FK (only enabled, trusted FKs, so every
orphan is one this run created). FKs and the tables' triggers are switched
off for the run and back on WITH CHECK at the end, in one transaction --
an inconsistent result rolls everything back. Rows with
`organization_id` NULL (global masters) stay.

Notes
- Sign-in accounts belong to an organization: only users of orgs 1 and 9
  remain. The GRAC Admin users of migration 220 live in organization 4 and
  are removed; org 1's `admin@grac.local` DB login (322) stays. Add `4` to
  `@KeepOrganizationIds` if those accounts are needed (org 4's data then
  stays too).
- Point the demo Api's `ConnectionStrings:PracticeManagement` at
  `grac_new_demo`. SQL logins are server-level and already exist; the
  database users came with the restore.
- Requires SQL Server 2017+. Delete the .bak from step 1 when done.
