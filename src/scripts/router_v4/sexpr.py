import re
TOK = re.compile(r'\(|\)|"(?:[^"\\]|\\.)*"|[^\s()"]+')
def parse(s):
    stack=[[]]
    for m in TOK.finditer(s):
        t=m.group()
        if t=='(':
            stack.append([])
        elif t==')':
            x=stack.pop(); stack[-1].append(x)
        else:
            if t[0]=='"': t=t[1:-1].replace('\\"','"').replace('\\\\','\\')
            stack[-1].append(t)
    return stack[0][0]
def find(node,key):
    return [c for c in node if isinstance(c,list) and c and c[0]==key]
def one(node,key):
    r=find(node,key); return r[0] if r else None
