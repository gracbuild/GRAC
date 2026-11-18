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

# Pilot database (Grac_Pilot) from grac_demo (2026-11-18)

Goal (sir): a pilot database `Grac_Pilot` with every table, procedure, function, trigger and sequence of Practice Management **and** Control Management (schemas `grac_practice`, `GRAC_New`, and the `dbo` procedures / functions / sequences both use), all master data, and the data of **MSP (1)** and **Lakeshore (11)** only; every other table as structure only.

The same two tools, now parameterized (their defaults are the pilot run):

| Step | Script (database/) | Run in | Settings |
|---|---|---|---|
| 1 | `tool_demo_db_01_clone.sql` | `master`, on the grac_demo server | `@Source = 'grac_demo'`, `@Target = 'Grac_Pilot'`. COPY_ONLY backup of grac_demo, restored as Grac_Pilot -- every object exactly as grac_demo has it. Stops if Grac_Pilot exists; grac_demo is only read. |
| 2 | `tool_demo_db_02_keep_orgs.sql` | `Grac_Pilot` | `@KeepOrganizationIds = '1,11'`, `@TargetDatabase = 'Grac_Pilot'`, `@IncludeGracNew = 1`, `@EmptyTables` (below). `@DryRun = 1` first, then `@DryRun = 0` with `@ConfirmDatabase = 'Grac_Pilot'`. |

What step 2 keeps:
- Tables with `organization_id` (all schemas, GRAC_New included): rows of organizations 1 and 11, and global rows (`organization_id` NULL).
- Rows that depended on a removed row are removed through the foreign keys (an organization's history, children, links), so the data of 1 and 11 stays complete.
- Tables without `organization_id` that nothing removed: kept in full -- the masters. The dry run lists them with their row counts ("Tables kept in full").
- `@EmptyTables`: tables to keep as structure only (every row deleted) -- LIKE patterns on `schema.table`, comma separated. Empty by default: pick them from the dry run's "Tables kept in full" list (logs, queues, outboxes ...), add them, dry-run again, then commit.

Notes
- Users, roles and grants of other organizations are removed with their organizations. The GRAC Admin users of migration 220 live in organization 4 -- add `4` to `@KeepOrganizationIds` if they are needed (org 4's data then stays too).
- Point the pilot Api's `ConnectionStrings:PracticeManagement` (and Control Management's connection) at `Grac_Pilot`. Logins are server-level; database users come with the restore.
- Set `Grac_Pilot` to SIMPLE recovery before step 2 if log space is tight. Delete the .bak from step 1 when done. SQL Server 2017+.
