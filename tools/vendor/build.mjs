import { value as option } from '../arguments.mjs';
// Explicit, offline developer/release bootstrap. Never invoked by foo build/test.
import { cpSync as copy, mkdirSync as mkdir, readFileSync as read, writeFileSync as write, readdirSync as entries, existsSync as exists } from 'node:fs';
import { resolve, join, dirname, relative } from 'node:path';
import { fileURLToPath as filename } from 'node:url';
import { spawnSync as invoke } from 'node:child_process';
import { createHash as hasher } from 'node:crypto';
import * as artifacts from '../artifacts.mjs';
const root = resolve(dirname(filename(import.meta.url)), '../..');
const target = option('--target');
const host = `linux-${process.arch === 'x64' ? 'x64' : process.arch === 'arm64' ? 'arm64' : process.arch}`;
const musl = target === 'linux-musl-x64' || target === 'linux-musl-arm64';
const foreign = target === 'linux-arm64' && host === 'linux-x64';
const cross = musl || foreign;
if (process.platform !== 'linux' || (!cross && target !== host) || (cross && host !== 'linux-x64'))
  throw Error('Native Linux x64/arm64 or explicit Zig cross Linux ARM64/musl from Linux x64 only. No other cross/WASI/freestanding artifacts.');
const compiler = option('--compiler') || (cross ? 'zig' : 'cc');
const suffix = target === 'linux-musl-x64' ? 'x86_64-linux-musl' : 'aarch64-linux-musl';
const destination = foreign ? 'aarch64-linux-gnu.2.27' : suffix;
const options = cross ? ['cc','-target',destination] : [];
function run(command,args,cwd=root,env={}) {
  const result=invoke(command,args,{cwd,env:{...process.env,LC_ALL:'C',TZ:'UTC',SOURCE_DATE_EPOCH:'0',...env},encoding:'utf8',windowsHide:true});
  if(result.status!==0) throw Error(`${command} ${args.join(' ')} failed: ${result.error?.message || result.stderr || result.stdout}`);
  return result.stdout.trim();
}
run(process.execPath,[join(root,'tools/vendor/audit.mjs')]);
const versions = Object.fromEntries([[compiler,cross?['version']:['--version']],['make',['--version']],['ar',['--version']],['nm',['--version']],['readelf',['--version']]].map(([tool,args])=>[tool,run(tool,args).split('\n')[0]]));
if (cross && versions[compiler] !== '0.11.0') throw Error(`Cross native dependencies require Zig 0.11.0; selected ${versions[compiler]}`);
const lock=read(join(root,'vendor/manifest.json'));
const identity=hasher('sha256').update(lock).digest('hex');
const output=join(root,'.artifacts/vendor',target);
const staging=join(resolve(option('--workdir') || artifacts.create('tools')),target,identity.slice(0,16));
mkdir(output,{recursive:true});
const flags=`-O2 -fPIC -ffile-prefix-map=${staging}=vendor-build`;
const triple=run(compiler,[...options,'-dumpmachine']);
if (cross && (!triple.startsWith(`${destination.split('-')[0]}-`) ||
    !triple.includes(foreign ? '-linux-gnu' : '-linux-musl')))
  throw Error(`Cross compiler target mismatch: ${triple}`);
const recipes=[];
for(const [dep,symbol,archive] of [['libsodium','sodium_init','libsodium.a'],['zlib','deflateInit_','libz.a']]) {
  console.log(`Building ${dep} offline for ${target}...`);
  const source=join(staging,dep);
  if(exists(source)) throw Error(`Build staging exists; choose a fresh checkout or explicitly remove ${source} before rebuilding.`);
  copy(join(root,'vendor',dep,'source'),source,{recursive:true});
  const prefix=join(output,dep);
  const args=dep==='libsodium'?[...(cross?[`--host=${foreign ? 'aarch64-linux-gnu' : suffix}`]:[]),'--disable-shared','--enable-static','--disable-dependency-tracking',`--prefix=${prefix}`]:['--static',`--prefix=${prefix}`];
  const env={CC:cross?`${compiler} ${options.join(' ')}`:compiler,AR:'ar',RANLIB:'ranlib',CFLAGS:flags};
  run('sh',['configure',...args],source,env);
  // Use upstream install so generated target configuration headers match ABI.
  run('make',dep==='zlib'?['-j2','libz.a']:['-j2'],source,env);
  run('make',['install'],source,env);
  const library=join(prefix,'lib',archive);
  const symbols=run('nm',['--defined-only',library]);
  const architecture=run('readelf',['-h',library]);
  if(!symbols.includes(symbol)) throw Error(`Missing ABI symbol ${symbol}`);
  const machine=target.endsWith('x64')?'Advanced Micro Devices X86-64':'AArch64';
  if(!architecture.includes(machine) || architecture.split('\n').filter(l=>l.includes('Machine:')).some(l=>!l.includes(machine))) throw Error(`Wrong architecture for ${dep}`);
  const settings=read(join(source,'Makefile'),'utf8').split('\n').filter(line=>/^(?:CFLAGS|CPPFLAGS|LDFLAGS|ARFLAGS)\s*=/.test(line));
  recipes.push({dependency:dep,configure:args,cflags:flags,effectiveMakeFlags:settings,symbol,architecture:machine});
}
const files={};
function collect(directory) {
 for(const item of entries(directory,{withFileTypes:true})) {
  const path=join(directory,item.name);
  if(item.isSymbolicLink()) continue;
  if(item.isDirectory()) collect(path);
  else if(item.name!=='provenance.json') files[relative(output,path).replaceAll('\\','/')]=hasher('sha256').update(read(path)).digest('hex');
 }
}
collect(output);
write(join(output,'provenance.json'),JSON.stringify({format:'foo.native',version:1,target,vendorIdentity: identity,compilerTarget: triple,tools:versions,recipes,files},null,2)+'\n');
console.log(`Built controlled static dependencies: ${output}`);
