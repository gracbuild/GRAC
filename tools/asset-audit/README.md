# Asset & Contract static audit (Phase 9)

No SQL Server or .NET SDK is available where these were written, so the
module is checked statically. Run from the repository root with Python 3:

    python3 tools/asset-audit/audit_sql.py database/4[2-5]*.sql
    python3 tools/asset-audit/audit_cs_procs.py .
    python3 tools/asset-audit/audit_proxy_post.py .
    python3 tools/asset-audit/check_screens.py .

| Script | Checks |
|---|---|
| `tsql_lex.py` | Lexer used by the SQL checks: removes comments (also with apostrophes) and string literals exactly. |
| `audit_sql.py` | Per batch: parentheses, BEGIN / CASE vs END, `END; ELSE`, a temp table created twice, `INSERT ... EXEC` (flagged for review). |
| `audit_cs_procs.py` | Every procedure `AssetConfigService` calls exists in 420-453 (latest definition), every bound parameter is declared with the same size, every parameter without a default is bound. |
| `audit_proxy_post.py` | Every POST route of the API controller reaches a permission rule in the Web proxy (none falls into a refusing catch-all). |
| `check_screens.py` | Script element ids exist in their partials; every asset screen is registered in 274, PracticeScreen, Manage.cshtml, a partial and PM_ORG_ADMIN of both appsettings. |

Runtime checks: `database/deployment/16_UAT_Diagnostics_AssetContract.sql`
(read-only) and `17_Asset_Contract_Regression_Tests.sql` (UAT only).
