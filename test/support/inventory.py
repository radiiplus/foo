"""Explicitly refresh the reviewable test inventory; never run automatically in CI."""
from pathlib import Path
import json,re,hashlib,subprocess
roots=['test','benchmark','tools','.github','bin','installers']
exts={'.nim','.iv','.ivc','.ivl','.cap','.mjs','.ps1','.py','.sh','.c','.h','.cpp','.zig','.rs','.yml','.yaml','.json','.cjs','.golden','.ld','.ir','.txt','.md'}
entries=[]
sources=subprocess.run(['rg','--files','--no-ignore-parent',*roots],check=True,capture_output=True,text=True).stdout.splitlines()
for root in roots:
 for p in sorted(Path(name) for name in sources if name.replace('\\','/').startswith(root+'/')):
  if not p.is_file() or p.suffix not in exts or p.name=='inventory.json':continue
  path=p.as_posix();text=p.read_text(encoding='utf8',errors='replace');tags=[]
  if any(x in path for x in ['crash','failure','fault','error','harness']) or re.search(r'FOO_\w*(?:CRASH|FAIL|INJECT)',text):tags.append('failure injection/crash behavior')
  if any(x in path for x in ['wasi','targets','presets','linking','/fixtures/arm.','/fixtures/riscv.','/gates.mjs']):cat='cross-target'
  elif path.startswith('benchmark/') or '/benchmark/' in path or 'benchmark' in p.name:cat='benchmarks'
  elif p.suffix=='.md' or any(x in path for x in ['/editor/','/docs/','/registry/']) or p.name in ['highlight.mjs','catalog.mjs']:cat='documentation/editor/registry'
  elif any(x in path for x in ['release','sign','binaries','installer','key.mjs']):cat='release/signing'
  elif '/backend/qbe/' in path and p.suffix!='.iv':cat='QBE IR'
  elif path.startswith(('test/types/','test/ir/','test/lex/','test/parse/','test/sema/','test/ast/')):cat='compiler frontend/type checker'
  elif path.startswith(('test/cli/','test/pkg/','test/build/','tools/')):cat='package/CLI'
  elif any(x in path for x in ['service','tls','socket','crypto','compress','native','concurrency','gpu','vulkan','thread']):cat='runtime/service'
  else:cat='language semantics'
  reference=False
  entries.append({'path':path,'category':cat,'tags':sorted(set([cat]+tags)),
   'role':'fixture' if p.suffix in {'.iv','.ivc','.ivl','.cap','.json','.c','.h','.cpp','.zig','.rs','.golden','.ld','.ir','.txt'} else 'runner' if p.suffix in {'.mjs','.cjs','.ps1','.py','.sh','.yml','.yaml'} else 'test',
   'status':'reference-only' if reference else 'retained','sha256':hashlib.sha256(p.read_bytes().replace(b'\r\n',b'\n')).hexdigest(),
   'assertionsInSource':len(re.findall(r'\bdoAssert\b|\bassert(?:\.\w+)?\s*\(|\bcheck\.(?:expect|same)\s*\(',text)),
   'fooTestsInSource':len(re.findall(r'^\s*test\s+"',text,re.M))})
output=Path('test/inventory.json')
lock={'format':'foo.test-inventory','version':1,'hashEncoding':'utf8-lf',
 'defaultPromotion':{'backend':'qbe','status':'pending-full-coverage','gate':'.github/workflows/tests.yml'},
 'testBackendPolicy':{'active':['qbe'],'change':'QBE/WASM execution qualification'},
 'entries':entries}
output.write_text(json.dumps(lock,indent=2)+'\n')
print(f'{len(entries)} inventory entries')
