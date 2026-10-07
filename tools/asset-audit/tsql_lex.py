# Proper T-SQL lexer for the static audit: removes comments and string
# literals (keeping a placeholder) so keyword counts are exact even when a
# comment holds an apostrophe or a string holds "--".
import re
def strip_sql(s):
    out=[];i=0;n=len(s)
    while i<n:
        c=s[i]
        if c=='-' and s.startswith('--',i):
            j=s.find('\n',i); i=n if j<0 else j; continue
        if c=='/' and s.startswith('/*',i):
            depth=1;i+=2
            while i<n and depth:
                if s.startswith('/*',i): depth+=1;i+=2
                elif s.startswith('*/',i): depth-=1;i+=2
                else: i+=1
            out.append(' ');continue
        if c=="'" :
            i+=1
            while i<n:
                if s[i]=="'":
                    if i+1<n and s[i+1]=="'": i+=2; continue
                    i+=1;break
                i+=1
            out.append("''");continue
        if c=='[':
            j=s.find(']',i); 
            if j>0: out.append('[x]'); i=j+1; continue
        out.append(c);i+=1
    return ''.join(out)
def batches(raw):
    return re.split(r"^\s*GO\s*$",raw,flags=re.M)
