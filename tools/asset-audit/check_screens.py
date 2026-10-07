# Asset screens: every element id a script reads exists in its partial (no
# duplicates), and every asset screen is registered consistently (274 menu
# row and parent, PracticeScreen, Manage.cshtml, partial, PM_ORG_ADMIN in
# both appsettings). Usage: python3 check_screens.py <repo root>
import re,os,glob,json,sys
root=sys.argv[1]; W=root+'/src/PracticeManagement.Web/'
P=W+'Views/Practice/Partials/'
bad=0
for js in sorted(glob.glob(W+'wwwroot/js/AssetConfig/*.js')):
    base=os.path.basename(js)
    parts=[p for p in glob.glob(P+'*.cshtml') if base in open(p).read()]
    if not parts: print('no partial includes',base); bad+=1; continue
    html=''.join(open(p).read() for p in parts); src=open(js).read()
    ids=set(re.findall(r'\bid="([\w-]+)"',html))
    used=set(re.findall(r'getElementById\(\s*"([\w-]+)"\s*\)',src))|set(re.findall(r'hostId:\s*"([\w-]+)"',src))
    miss=sorted(used-ids-set(re.findall(r'\bid="([\w-]+)"',src)))
    dups=sorted(i for i in ids if len(re.findall(r'\bid="%s"'%re.escape(i),html))>1)
    if miss or dups: print(base,'missing',miss,'duplicate',dups); bad+=1
def pm(d):
    if isinstance(d,dict):
        for k,v in d.items():
            if k=='PM_ORG_ADMIN': return v
            r=pm(v)
            if r is not None: return r
    return None
m274=open(root+'/database/274_menu_master_seed.sql').read(); ps=open(W+'Models/PracticeScreen.cs').read(); man=open(W+'Views/Practice/Manage.cshtml').read()
api=pm(json.load(open(root+'/src/PracticeManagement.Api/appsettings.json'))) or []; web=pm(json.load(open(W+'appsettings.json'))) or []
for k in sorted(set(re.findall(r"\(N'((?:asset|business)-[\w-]+)'\s*,\s*N'nav-asset-contract'\)",m274))):
    probs=[]
    if f'new("{k}",' not in ps: probs.append('PracticeScreen')
    if k!='asset-contract-dashboard' and f'"{k}"' not in man: probs.append('Manage.cshtml')
    if k!='asset-contract-dashboard' and not os.path.exists(P+k+'.cshtml'): probs.append('partial')
    if not any(x.startswith(k+':') for x in api): probs.append('API PM_ORG_ADMIN')
    if not any(x.startswith(k+':') for x in web): probs.append('Web PM_ORG_ADMIN')
    if probs: print(k,'missing in',probs); bad+=1
print('screen findings',bad)
