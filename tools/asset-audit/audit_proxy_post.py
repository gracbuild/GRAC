# Walks the Web proxy POST permission chain for every API POST route and
# reports routes that land on a refusing catch-all (": isX ? false").
import re,sys
root=sys.argv[1]
api=open(root+'/src/PracticeManagement.Api/Controllers/AssetConfigController.cs').read()
web=open(root+'/src/PracticeManagement.Web/Controllers/AssetConfigController.cs').read()
post=re.search(r'public async Task<IActionResult> ProxyPost(.*?)\n    // 424',web,re.S).group(1)
flags=dict(re.findall(r'var (is\w+) = (lower[^;]+);',post))
chain=re.sub(r'//[^\n]*','',re.search(r'var allowed = (.*?);\n',post,re.S).group(1))
toks=re.split(r'(\?|:)',chain); seq=[];cur=''
for t in toks:
    cur+=t
    if t in ('?',':') and cur.count('(')==cur.count(')'): seq.append(cur[:-1].strip()); seq.append(t); cur=''
seq.append(cur.strip())
pairs=[(seq[k],seq[k+2]) for k in range(0,len(seq)-2,4)]; final=seq[-1]
def py(e,p):
    e=' '.join(e.split()).replace('lower','p')
    for n,f in flags.items(): e=re.sub(r'\b%s\b'%n,'('+' '.join(f.split()).replace('lower','p')+')',e)
    e=re.sub(r'p\.StartsWith\(("[^"]*")\)',r'p.startswith(\1)',e); e=re.sub(r'p\.EndsWith\(("[^"]*")\)',r'p.endswith(\1)',e)
    e=re.sub(r'p\.Contains\(("[^"]*")\)',r'(\1 in p)',e)
    e=re.sub(r'\b(exceptionAction|decision|outcome|toStatus)\s+is\s+[^()]*?(?=\)|\?|$)','True',e)
    e=re.sub(r'\b(exceptionAction|decision|outcome|toStatus)\s*==\s*"[A-Z_]+"','True',e)
    e=e.replace('&&',' and ').replace('||',' or ').replace('!p.','not p.')
    return eval(e,{'True':True},{'p':p})
routes=[t for v,t in re.findall(r'\[Http(Get|Post)\("([^"]+)"\)\]',api) if v=='Post']
bad=0
for t in routes:
    p=re.sub(r'\{[^}]+\}','1',t).lower()
    if p.startswith('taxonomy/') or p.startswith('notifications/mine/'): continue
    hit=final
    for c,r in pairs:
        if py(c,p): hit=r; break
    if hit.strip()=='false': print('REFUSED BY CATCH-ALL:',t); bad+=1
print('POST routes',len(routes),'refused',bad)
