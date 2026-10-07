# Static audit of T-SQL migrations (no SQL Server here): exact lexer, then
# per batch: parentheses, BEGIN/CASE vs END, END; ELSE, a temp table created
# twice, INSERT ... EXEC (allowed one level deep; flagged for review).
# Usage: python3 audit_sql.py database/4[2-5]*.sql
import re,sys
sys.path.insert(0,'/home/claude/w454/tools')
from tsql_lex import strip_sql,batches
tot=0
for f in sys.argv[1:]:
    raw=open(f,encoding='utf-8',errors='replace').read()
    issues=[];notes=[]
    if any(ord(c)>127 for c in raw): issues.append('non-ascii')
    if '\r' in raw: issues.append('CRLF')
    for bi,b in enumerate(batches(raw)):
        s=strip_sql(b); up=s.upper()
        if s.count('(')!=s.count(')'): issues.append(f'batch {bi}: parentheses {s.count("(")}/{s.count(")")}')
        beg=len(re.findall(r"\bBEGIN\b(?!\s+(TRAN|TRANSACTION|DISTRIBUTED)\b)",up)); case=len(re.findall(r"\bCASE\b",up)); end=len(re.findall(r"\bEND\b(?!\s+(CONVERSATION)\b)",up))
        if beg+case!=end: issues.append(f'batch {bi}: BEGIN+CASE {beg+case} END {end}')
        # END; ELSE ends the IF before its ELSE (a statement; ELSE is legal T-SQL)
        for m in re.finditer(r"\bEND\s*;\s*ELSE\b",up): issues.append(f'batch {bi}: END; before ELSE at offset {m.start()}')
        # nested CREATE TABLE same temp table twice
        temps=re.findall(r"CREATE\s+TABLE\s+(#\w+)",up)
        for t in set(temps):
            if temps.count(t)>1: issues.append(f'batch {bi}: {t} created {temps.count(t)} times')
        if re.search(r"INSERT\s+(INTO\s+)?[#@\w.\[\]]+\s*(\([^)]*\))?\s*EXEC",up): notes.append(f'batch {bi}: INSERT ... EXEC (review: one level only)')
    tot+=len(issues)
    print(f, 'OK' if not issues else ''); [print('   ',x) for x in issues]; [print('    note:',x) for x in notes]
print('findings',tot)
