# Static audit: every procedure call in AssetConfigService against the 420-453 definitions.
# Usage: python3 audit_cs_procs.py <repo root>
# Every procedure AssetConfigService calls: exists in a migration (latest
# definition wins), every bound @parameter is declared with a compatible
# size, and every parameter without a default is bound.
import re,sys,glob
sys.path.insert(0,'/home/claude/w454/tools')
from tsql_lex import strip_sql
root=sys.argv[1]
procs={}
for f in sorted(glob.glob(root+'/database/4[2-5]*.sql')):
    if 'rollback' in f: continue
    s=strip_sql(open(f).read())
    for m in re.finditer(r"CREATE\s+(?:OR\s+ALTER\s+)?PROCEDURE\s+grac_practice\.(\w+)\s*(.*?)\bAS\s*\n\s*BEGIN",s,re.S|re.I):
        ps={}
        for p in re.finditer(r"(@\w+)\s+([A-Za-z]+)\s*(?:\(\s*(\w+)\s*(?:,\s*\d+\s*)?\))?\s*(=\s*[^,]+)?(?:\s+OUTPUT|\s+OUT)?\s*(?:,|$)",m.group(2).strip()+','):
            ps[p.group(1).lower()]=(p.group(2).upper(),p.group(3),p.group(4) is not None)
        procs[m.group(1).lower()]=(ps,f.split('/')[-1])
svc=open(root+'/src/PracticeManagement.Api/Services/AssetConfigService.cs').read()
svc=re.sub(r'//[^\n]*','',svc)
calls=list(re.finditer(r'"grac_practice\.(\w+)"',svc))
issues=0;seen=set()
for k,m in enumerate(calls):
    name=m.group(1).lower()
    end=calls[k+1].start() if k+1<len(calls) else len(svc)
    seg=svc[m.end():end]
    stop=[x for x in [seg.find('ExecuteReaderAsync'),seg.find('ExecuteNonQueryAsync'),seg.find('ExecuteScalarAsync'),seg.find('}, ct'),seg.find('\n    public '),seg.find('\n    private ')] if x>=0]
    seg=seg[:min(stop)] if stop else seg
    # A generic helper (e.g. CatalogTransitionAsync("grac_practice.x", "@model_id", ...)) binds inside its own body.
    pre=svc[max(0,m.start()-80):m.start()]
    h=re.search(r'(\w+)\(\s*$',pre)
    if h and h.group(1)!='Proc' and h.group(1)!='ResultRowWriteAsync' and h.group(1)!='WriteAsync':
        body=re.search(r'private\s+[^\n]*\b%s\((.*?)\n\s*\n'%h.group(1),svc,re.S)   # the helper up to the next blank line
        if body:
            idp=re.match(r'\s*"[^"]+"\s*,\s*"(@\w+)"',svc[m.start():m.start()+120])
            seg=body.group(1)+('\nAddParam(command, "%s", DbType.Int64, id);'%idp.group(1) if idp else '')
    if name not in procs:
        print('NOT IN 420-453:',name); continue
    ps,src=procs[name]
    bound={}
    for p in re.finditer(r'AddParam\(\s*\w+\s*,\s*"(@\w+)"\s*,\s*DbType\.(\w+)\s*,(.*?)\);',seg,re.S):
        args=[a.strip() for a in re.split(r',(?![^()]*\))',p.group(3))]
        size=args[-1] if len(args)>1 and re.fullmatch(r'-?\d+',args[-1]) else None
        bound[p.group(1).lower()]=(p.group(2),size)
    for p in re.finditer(r'Output\(\s*\w+\s*,\s*"(@\w+)"',seg): bound[p.group(1).lower()]=('OUT',None)
    for p,(t,size) in bound.items():
        if p not in ps: print(f'{name}: binds {p} which the proc ({src}) does not declare'); issues+=1; continue
        st,sl,_=ps[p]
        if size and sl:
            if sl.upper()=='MAX' and size!='-1': print(f'{name}: {p} size {size} vs MAX'); issues+=1
            elif sl.upper()!='MAX' and int(size)!=int(sl) and int(size)!=-1: print(f'{name}: {p} size {size} vs {st}({sl})'); issues+=1
            elif sl.upper()!='MAX' and int(size)==-1: print(f'{name}: {p} size -1 vs {st}({sl})'); issues+=1
    missing=[p for p,(t,s,hasdef) in ps.items() if not hasdef and p not in bound]
    if missing and (name,tuple(missing)) not in seen:
        seen.add((name,tuple(missing))); print(f'{name}: required parameter(s) not bound: {missing}'); issues+=1
print('calls',len(calls),'procs',len(procs),'issues',issues)
