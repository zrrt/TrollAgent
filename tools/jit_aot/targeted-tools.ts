#!/usr/bin/env bun
/** Record musl + busybox for TrollAgent (customized from rcarmo targeted.ts).
 * Usage: bun tools/jit_aot/targeted-tools.ts ISH FAKEFS OUTPUT [elf|macho]
 * Records ONLY musl (libc) and busybox — python/zlib are excluded because rcarmo's
 * measured AOT results for python were slower (0.87x) with 3x RSS; busybox short
 * commands get high coverage from a single recording workload.
 * Workload exercises busybox applets (ls/echo/printf/cat/pwd/expr/dirname/basename)
 * plus a shell loop, so the recorded translations cover the common tool paths.
 */
import { resolve, join, dirname } from 'node:path';
import { existsSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';

const [ishArg, rootArg, outArg, format = 'elf'] = process.argv.slice(2);
if (!ishArg || !rootArg || !outArg || !['elf', 'macho'].includes(format))
    throw new Error('usage: targeted-tools.ts ISH FAKEFS OUTPUT [elf|macho]');
const ish = resolve(ishArg), root = resolve(rootArg), out = resolve(outArg);
if (existsSync(out)) throw new Error(`refusing existing output: ${out}`);
mkdirSync(out, { recursive: true });
const timeout = Number(process.env.AOT_TIMEOUT_S || 300);
if (!Number.isFinite(timeout) || timeout <= 0) throw new Error('invalid AOT_TIMEOUT_S');
// Do not inherit tuning/image/recording knobs into the recorder.
const env = Object.fromEntries(Object.entries(process.env).filter(([k, v]) =>
    v !== undefined && !k.startsWith('ISH_JIT') && !k.startsWith('ISH_AOT'))) as Record<string, string>;
function run(argv: string[], extra: Record<string, string> = {}) {
    const r = Bun.spawnSync(argv, {
        env: { ...env, ...extra }, stdout: 'pipe', stderr: 'pipe', maxBuffer: 64 * 1024 * 1024,
        timeout: Math.ceil(timeout * 1000), killSignal: 'SIGKILL',
    });
    return { status: r.exitCode, stdout: r.stdout.toString(), stderr: r.stderr.toString() };
}
function requireOK(r: ReturnType<typeof run>, label: string) {
    if (r.status !== 0) throw new Error(`${label}: exit ${r.status}\n${r.stderr.slice(-2000)}`);
}
const discover = run([ish, '-f', root, '/bin/sh', '-ec', `
cat /etc/alpine-release
apk list --installed musl busybox 2>/dev/null || true
for p in /lib/ld-musl-aarch64.so.1 /bin/busybox; do readlink -f "$p"; done
`], { ISH_JIT: '0' });
await Bun.write(join(out, 'inventory.log'), discover.stdout + discover.stderr);
requireOK(discover, 'inventory');
const paths = discover.stdout.split('\n').filter(s => s.startsWith('/'));
if (paths.length !== 2) throw new Error(`invalid module inventory: ${paths.join(',')}`);
const modules = { musl: paths[0], busybox: paths[1] };
for (const module of Object.values(modules)) {
    if (!await Bun.file(join(root, 'data', module)).exists()) throw new Error(`missing module: ${module}`);
}
// busybox 常用命令全覆盖热路径：文件操作/文本处理/系统查询/shell 特性（管道重定向通配符函数）。
// 全部在 fakefs /tmp 临时目录操作，结束 rm -rf 清理——不污染 App 打包用的 fakefs（模块 sha256 不变）。
const workload = `set -eu
T=$(mktemp -d /tmp/aot.XXXXXX)
cd "$T"
touch f1 f2 f3
mkdir d1 d2/d3 2>/dev/null || true
cp f1 f2.bak
mv f2.bak f2.new
ln -s f1 link1
printf 'alpha beta gamma\\n' > text.txt
printf 'line1\\nline2\\nline3\\n' >> text.txt
cat text.txt
head -2 text.txt
tail -1 text.txt
wc -l text.txt
grep beta text.txt
sed 's/beta/delta/' text.txt
awk '{print $1}' text.txt
tr 'a-z' 'A-Z' < text.txt | head -1
sort -r text.txt
uniq text.txt
cut -d' ' -f2 text.txt
wc -c text.txt
md5sum text.txt
sha256sum text.txt
base64 text.txt
stat text.txt
du -sh .
df -h / 2>/dev/null || true
ls -la / /bin /usr/bin 2>/dev/null || true
uname -a
arch
date +%s 2>/dev/null || true
uptime 2>/dev/null || true
which ls
id
dirname /a/b/c
basename /a/b/c
realpath /bin/busybox 2>/dev/null || true
readlink -f /bin/busybox
ps 2>/dev/null || true
pidof sh 2>/dev/null || true
i=0; while [ "$i" -lt 1000 ]; do i=$((i+1)); done
test "$i" = 1000
for f in f1 f2 f3; do test -f "$f"; done
case "$(uname -s)" in Linux) : ;; *) exit 1;; esac
f() { echo "$# args"; }; f a b c
[ -f f1 ] && echo yes || echo no
cd / && rm -rf "$T"
printf 'AOT_TRAIN_OK\\n'
`;
await Bun.write(join(out, 'workload.sh'), workload);
const sha = async (path: string) => createHash('sha256').update(new Uint8Array(await Bun.file(path).arrayBuffer())).digest('hex');
const images = [];
let abi: number | undefined;
for (const [name, module] of Object.entries(modules)) {
    const file = join(root, 'data', module), before = await sha(file);
    const recording = join(out, `${name}.jsonl`), image = join(out, `aot_${name}.S`);
    console.log(`recording ${name}: ${module}`);
    const r = run([ish, '-f', root, '/bin/sh', '-ec', workload], {
        ISH_JIT: '1', ISH_JIT_PIC: '1', ISH_JIT_RECORD: recording,
        ISH_JIT_RECORD_MOD: module, ISH_JIT_STATS: '1', ISH_AOT_FAMILY: '0',
    });
    await Bun.write(join(out, `${name}.log`), r.stdout + r.stderr);
    requireOK(r, name);
    if (!r.stdout.split('\n').includes('AOT_TRAIN_OK')) throw new Error(`${name}: missing completion marker`);
    const rows = (await Bun.file(recording).text()).trim().split('\n').map(line => JSON.parse(line));
    const header = rows.shift()?.header;
    if (!header?.abi || !rows.length || rows.some(t => t.mod !== module) || !rows.some(t => t.segs?.length))
        throw new Error(`${name}: invalid/empty recording`);
    if (abi !== undefined && abi !== header.abi) throw new Error('recording ABI mismatch');
    abi = header.abi;
    if (await sha(file) !== before) throw new Error(`${module}: changed during recording`);
    const gen = run(['python3', join(dirname(import.meta.path), 'gen.py'), recording, ish,
        join(root, 'data'), image, '--name', name, '--format', format, '--family', '']);
    await Bun.write(join(out, `${name}-generate.log`), gen.stdout + gen.stderr);
    requireOK(gen, `${name} generator`);
    images.push({ name, module, sha256: before, translations: rows.length,
        image, imageSha256: await sha(image), recordingSha256: await sha(recording) });
}
await Bun.write(join(out, 'manifest.json'), JSON.stringify({
    format, abi: abi!.toString(16).padStart(8, '0'), ish, ishSha256: await sha(ish), root,
    inventory: discover.stdout, workloadSha256: await sha(join(out, 'workload.sh')), images,
    limits: 'Host recording only. musl+busybox. No family matching.',
}, null, 2) + '\n');
console.log(`complete: ${join(out, 'manifest.json')}`);
