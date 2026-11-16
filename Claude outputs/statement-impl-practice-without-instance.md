## Control statement: a practice with no instances now holds it back (2026-11-10)

> "oru control nu 2 practice oru practice implemented matte practice not updated (no instance
> created) ee case lanu control ne implemented ennu kanikunnathu"

**Cause.** A control statement's Implementation Status is derived from the **practice instances**
of the practices mapped to it. A mapped practice that has **no instance yet** adds nothing to
either count. So a statement with one fully Implemented practice and one practice that was never
configured passed the test `InstanceCount > 0 AND InstanceCount = ImplementedInstanceCount` and
read **Implemented**. The practice level was already right: with no instances it shows Not Updated.

**Rule now (statement level)**

| Condition | Result |
|---|---|
| Applicable, at least one instance, every instance Implemented, **and every mapped practice still to be implemented has at least one active instance** | Implemented |
| Applicable, at least one instance Implemented (otherwise) | Partially Implemented |
| Not Applicable / Deferred / Accepted Risk / Not Implemented / Retired | Not Applicable |
| Applicable, an instance updated | Not Implemented |
| Otherwise | Not Updated |

"Still to be implemented" means a mapped practice whose own applicability is **not** Not Applicable,
Deferred, Accepted Risk, Not Implemented or Retired. Such a practice is deliberately out of scope,
so it never holds the statement back. A practice whose applicability is still Not Updated does
hold it back.

So the reported case, one practice Implemented and one with no instance, now reads **Partially
Implemented**. If neither practice has an Implemented instance, the result is unchanged.

**Changed:** `PracticeRepositoryService.cs` only. No SQL migration was needed: every place that
derives a statement's implementation status lives there.

| Where | What |
|---|---|
| `QuerySubscribedFrameworksAsync`, repository releases (Level 1 summary) | new CTE `statement_pending_practices`; `ImplementedStatementsCount` requires none |
| `QuerySubscribedFrameworksAsync`, custom releases | new scalar `PracticeWithoutInstanceCount` per statement; same condition |
| `QueryReleaseStatementsAsync` (repository Control Statements tree) | new CTE `requirement_has_instance`; `statement_practice_counts.PracticeWithoutInstanceCount`; the Implemented branch of `ImplementationStatus` requires 0 |
| Custom release Control Statements query | the same two additions, keyed on `org_statement_id` |

The Level 1 Implemented count and the drill-down's statement status still follow one rule, so
they cannot disagree. The four changed query texts were extracted and parsed (`sqlfluff`, tsql):
0 unparsable.

**Deploy:** deploy the Api only. No Web or SQL change.
