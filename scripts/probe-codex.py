#!/usr/bin/env python3
"""Sonda del app-server de Codex: habla el protocolo a mano, sin pasar por la app.

Sirve para ver qué contesta una versión nueva de Codex antes de tocar el cliente:
`initialize`, `account/read` y un turno corto. Vivía en `.build/`, que está ignorado,
así que se perdía con cualquier `rm -rf .build` (ver docs/specs/C9-cobertura-pruebas.md).

Uso: python3 scripts/probe-codex.py
Requiere ChatGPT para Mac instalado y una sesión iniciada. No deja nada en disco.
"""
import subprocess,json,selectors,time,os
cli='/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'
p=subprocess.Popen([cli,'app-server','--listen','stdio://'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,bufsize=0,start_new_session=True)
s=selectors.DefaultSelector(); s.register(p.stdout,selectors.EVENT_READ)
def send(i,m,params):
 p.stdin.write((json.dumps({'id':i,'method':m,'params':params})+'\n').encode()); p.stdin.flush()
def wait(i):
 deadline=time.monotonic()+45
 while time.monotonic()<deadline:
  if s.select(1):
   line=p.stdout.readline()
   if not line: raise RuntimeError('closed')
   msg=json.loads(line)
   if msg.get('id')==i and 'method' not in msg: return msg
 raise TimeoutError(i)
try:
 send(1,'initialize',{'clientInfo':{'name':'krabzik_ide','title':'Krabzik IDE','version':'0.3.0'},'capabilities':{}})
 print('initialize:', 'result' in wait(1))
 p.stdin.write(b'{"method":"initialized","params":{}}\n'); p.stdin.flush()
 send(2,'account/read',{'refreshToken':False}); r=wait(2); a=r.get('result',{}).get('account') or {}
 print('account:',a.get('type'),a.get('planType'), 'error:',r.get('error'))
 cwd=os.path.abspath('.build/agent-fixture/api')
 send(3,'thread/start',{'cwd':cwd,'sandbox':'workspace-write','approvalPolicy':'on-request','ephemeral':True,'config':{'sandbox_workspace_write.writable_roots':[os.path.abspath('.build/agent-fixture/client')],'sandbox_workspace_write.network_access':False,'approvals_reviewer':'user','features.multi_agent':False}})
 r=wait(3); print('thread:', {k:v for k,v in r.get('result',{}).items() if k in ['model','sandbox','approvalPolicy','approvalsReviewer']},'error:',r.get('error'))
finally:
 os.killpg(p.pid,15)
 try:p.wait(timeout=3)
 except subprocess.TimeoutExpired: os.killpg(p.pid,9);p.wait()
