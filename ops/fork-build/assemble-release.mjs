#!/usr/bin/env node
/**
 * Turn one fork checkout into a desktop-runtime directory.
 *
 * The Electron shell, the bundled Node, the web app and the orchestrator's
 * already-built native modules are copied from an official release of the
 * same upstream version. The daemon itself (dist, bin, presets, scripts,
 * built-in plugins, docs, mission launcher) is compiled from the checkout
 * and signed with this build's Ed25519 key, the way
 * `desktop/scripts/prepare-daemon-release.mjs` seals a release. The key is
 * embedded in `dist/boot.js`, so the package checks its own inventory.
 *
 * Nothing here writes under the Timon home. `npm` is not invoked: the
 * checkout's dependencies are the ones already installed for development,
 * and they are used only to typecheck. The shipped `node_modules` stay the
 * official release's, rebuilt for the bundled Node.
 */
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, lstatSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { basename, isAbsolute, join, relative, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const USAGE = `Usage: node ops/fork-build/assemble-release.mjs --checkout DIR --stage DIR --output DIR --shell DIR --key-dir DIR --version-id ID --commit SHA --modules DIR`;

function args(argv) {
  const out = {};
  const valued = {
    '--checkout': 'checkout', '--stage': 'stage', '--output': 'output', '--shell': 'shell',
    '--key-dir': 'keyDir', '--version-id': 'versionId', '--commit': 'commit', '--modules': 'modules',
  };
  for (let i = 0; i < argv.length; i++) {
    const name = valued[argv[i]];
    if (!name) throw new Error(`unexpected argument ${argv[i]}\n${USAGE}`);
    const value = argv[++i];
    if (!value || value.startsWith('--')) throw new Error(`${argv[i - 1]} needs a value\n${USAGE}`);
    out[name] = value;
  }
  for (const key of Object.values(valued)) if (!out[key]) throw new Error(`missing --${key.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}\n${USAGE}`);
  return out;
}

function real(path) {
  return resolve(path);
}

/** A path must not sit inside the live home: the daemon executes that tree. */
function assertOutside(path, home, what) {
  const child = real(path);
  const parent = real(home);
  const rel = relative(parent, child);
  if (rel === '' || (!rel.startsWith('..') && !isAbsolute(rel))) {
    throw new Error(`${what} is inside ${parent}: refusing to build where the daemon runs`);
  }
}

function run(cmd, cmdArgs, cwd) {
  const result = spawnSync(cmd, cmdArgs, { cwd, stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${cmd} ${cmdArgs[0] ?? ''} failed (${result.status})`);
}

function dependencyMap(packageJson) {
  const body = JSON.parse(readFileSync(packageJson, 'utf8'));
  return body.dependencies ?? {};
}

function sameDependencies(left, right) {
  const keys = [...new Set([...Object.keys(left), ...Object.keys(right)])].sort();
  const differ = keys.filter((key) => left[key] !== right[key]);
  return differ;
}

const opt = args(process.argv.slice(2));
const checkout = resolve(opt.checkout);
const stage = resolve(opt.stage);
const output = resolve(opt.output);
const shell = resolve(opt.shell);
const keyDir = resolve(opt.keyDir);
const modules = resolve(opt.modules);
const home = join(process.env.HOME ?? '', '.timon');
for (const [path, what] of [[stage, 'stage'], [output, 'output'], [checkout, 'checkout']]) assertOutside(path, home, what);
if (existsSync(output)) throw new Error(`output already exists: ${output}`);
if (!existsSync(join(shell, 'resources', 'node', 'node'))) throw new Error(`${shell} is not a desktop-runtime release (no resources/node/node)`);
if (!existsSync(join(modules, 'typescript', 'bin', 'tsc'))) throw new Error(`typescript is missing under ${modules}`);

const differ = sameDependencies(
  dependencyMap(join(checkout, 'orchestrator', 'package.json')),
  dependencyMap(join(shell, 'resources', 'orchestrator', 'package.json')),
);
if (differ.length) {
  throw new Error(`orchestrator dependencies differ from the official shell (${differ.join(', ')}). `
    + 'The shell node_modules cannot be reused; rebuild the natives for the bundled Node before packaging.');
}

const importer = (file) => import(pathToFileURL(join(checkout, file)).href);
const prepare = await importer('desktop/scripts/prepare-daemon-release.mjs');
const buildInfoMod = await importer('desktop/scripts/build-info.mjs');
const integrity = await importer('desktop/scripts/release-integrity.mjs');

rmSync(stage, { recursive: true, force: true });
mkdirSync(stage, { recursive: true });
const tsc = join(modules, 'typescript', 'bin', 'tsc');
run(process.execPath, [
  tsc, '--project', join(checkout, 'orchestrator', 'tsconfig.json'),
  '--outDir', join(stage, 'dist'), '--sourceMap', 'false', '--declaration', 'false',
], checkout);

for (const name of ['bin', 'presets', 'scripts']) {
  cpSync(join(checkout, 'orchestrator', name), join(stage, name), { recursive: true, verbatimSymlinks: true });
}
const pkg = JSON.parse(readFileSync(join(checkout, 'orchestrator', 'package.json'), 'utf8'));
delete pkg.devDependencies;
pkg.scripts = { start: 'node dist/index.js' };
writeFileSync(join(stage, 'package.json'), `${JSON.stringify(pkg, null, 2)}\n`);
rmSync(join(stage, 'dist', 'kernel', 'fixtures'), { recursive: true, force: true });
rmSync(join(stage, 'scripts', 'test-plugin-hot-reload.mjs'), { force: true });

console.log(`[fork-build] ${prepare.copyBuiltinPlugins(stage, join(checkout, 'orchestrator'))} built-in plugin(s)`);
const info = buildInfoMod.createBuildInfo({ channel: 'stable', noExpiry: true });
writeFileSync(join(stage, buildInfoMod.BUILD_INFO_FILE), `${JSON.stringify(info, null, 2)}\n`);
console.log(`[fork-build] ${buildInfoMod.BUILD_INFO_FILE}: channel ${info.channel}, expires ${info.expiresAt ?? 'never'}`);

let changelog = '';
try { changelog = readFileSync(join(checkout, 'CHANGELOG.md'), 'utf8'); }
catch { console.warn('[fork-build] changelog unavailable; release notes will be empty'); }
const fragments = await importer('scripts/changelog-fragments.mjs');
changelog = fragments.withUnreleased(changelog, fragments.readFragments(join(checkout, fragments.FRAGMENTS_DIR)));
const notes = await importer('desktop/scripts/release-notes.mjs');
writeFileSync(join(stage, 'scripts', 'release-notes.json'), `${JSON.stringify(notes.createReleaseNotes(changelog, pkg.version), null, 2)}\n`);
cpSync(join(checkout, 'desktop', 'scripts', 'release-notes.mjs'), join(stage, 'scripts', 'release-notes.mjs'));

await prepare.exportDocs(join(stage, 'public-docs'));
const fence = prepare.stageFence(stage);
if (fence) console.log(`[fork-build] mission launcher: ${fence}`);

const privateKey = join(keyDir, 'fork-release.key.pem');
const publicKey = join(keyDir, 'fork-release.pub.pem');
if (!existsSync(privateKey) || !existsSync(publicKey)) throw new Error(`missing the Ed25519 pair in ${keyDir}`);
process.env.TIMON_RELEASE_PRIVATE_KEY_FILE = privateKey;
process.env.TIMON_RELEASE_PUBLIC_KEY_FILE = publicKey;
const keys = prepare.releaseKeys();
const signed = prepare.sealTree(stage, keys);
console.log(`[fork-build] ${signed} files signed`);

run('cp', ['-a', shell, output]);
const orch = join(output, 'resources', 'orchestrator');
const replaced = ['dist', 'bin', 'presets', 'scripts', 'builtin-plugins', 'builtin-plugins.json', 'package.json', 'build-info.json', 'public-docs', 'native', 'release-manifest.json', 'release-manifest.sig'];
for (const name of replaced) rmSync(join(orch, name), { recursive: true, force: true });
for (const name of replaced) {
  const from = join(stage, name);
  if (!existsSync(from)) continue;
  const dest = join(orch, name);
  cpSync(from, dest, { recursive: true, verbatimSymlinks: true });
}
for (const name of ['dist', 'bin', 'scripts', 'presets', 'package.json', 'native']) {
  const path = join(orch, name);
  if (existsSync(path) && lstatSync(path).isSymbolicLink()) throw new Error(`signed path is a symlink: ${name}`);
}
integrity.verifyRelease(orch, keys.publicKey);
console.log('[fork-build] sealed daemon matches the copied tree');

writeFileSync(join(output, 'fork-build.json'), `${JSON.stringify({
  kind: 'timon-fork-runtime',
  versionId: opt.versionId,
  upstreamVersion: pkg.version,
  commit: opt.commit,
  shellRelease: basename(shell),
  shellPath: shell,
  channel: info.channel,
  builtAt: info.builtAt,
  daemon: 'compiled from the commit and signed with the fork key',
  shell: 'Electron, bundled Node, web app and orchestrator node_modules from the official release',
}, null, 2)}\n`);
console.log(`[fork-build] package: ${output}`);
