path = "database/192_practice_data_reset.sql"
with open(path, "r", encoding="utf-8") as f:
    c = f.read()

old = """/* ------------------------------------------------------------------ */
/* 4. Delete order: children (level 0) first, parents last              */
/*                                                                      */
/*    This schema contains a genuine FK cycle (migration 069):          */
/*      org_assurance_definition.current_version_id -> ..._version      */
/*      org_assurance_definition.active_version_id  -> ..._version      */
/*      org_assurance_definition_version.org_assurance_definition_id    */
/*                                       -> org_assurance_definition    */
/*    No delete order can satisfy both directions, so the cycle is      */
/*    broken the same way the schema intended: the two nullable pointer  */
/*    columns on the parent side are set to NULL first, that FK is then  */
/*    ignored for ordering purposes, and the levelling is recomputed.    */
/*    Detection is generic -- any future nullable-column cycle is        */
/*    handled the same way, and a cycle over NOT NULL columns still      */
/*    aborts the script rather than guessing.                            */
/* ------------------------------------------------------------------ */"""

assert c.count(old) == 1, f"anchor found {c.count(old)} times"

new = """/* ------------------------------------------------------------------ */
/* 4. Delete order: children (level 0) first, parents last              */
/*                                                                      */
/*    This schema contains several genuine, mutual FK cycles -- two      */
/*    tables each pointing back at the other, so no delete order can     */
/*    satisfy both directions:                                          */
/*      org_assurance_definition      <-> org_assurance_definition_version */
/*        (current_version_id / active_version_id, migration 069)       */
/*      practice_task                 <-> task_candidate                */
/*      risk_analysis                 <-> risk_register                 */
/*      risk_candidate                <-> risk_register                 */
/*      risk_register                 <-> risk_residual_analysis        */
/*    Each is broken the same way the schema intended: the nullable      */
/*    pointer column(s) on one or both sides are set to NULL first, that */
/*    FK is then ignored for ordering purposes, and the levelling is     */
/*    recomputed. A cycle over NOT NULL columns still aborts the script  */
/*    rather than guessing.                                              */
/*                                                                        */
/*    Detection only nulls an FK when the OTHER table has a real FK      */
/*    pointing back to THIS one (a genuinely mutual pair) -- not merely  */
/*    when both ends happen to be unresolved. That distinction matters:  */
/*    every table in the five cycles above also carries ordinary FKs      */
/*    into organization_employee (owner/approver/analyst/... columns),   */
/*    so organization_employee cannot level until they do, and would      */
/*    otherwise be swept into this step too even though it has no cycle   */
/*    of its own -- blanket-nulling its role_id/provider_vendor_id would  */
/*    then fail ck_pm_employee_provider_required for any ThirdParty row. */
/*    Requiring the reverse FK to actually exist keeps that kind of       */
/*    innocent, merely-downstream table out of #ignore_fk.                */
/* ------------------------------------------------------------------ */"""

c = c.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(c)
print("header comment updated")
