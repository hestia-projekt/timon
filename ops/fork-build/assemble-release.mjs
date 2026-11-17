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
 * official release's, rebuilt for the bundled Node. The shell is refused
 * when its upstream version or its resolved dependency tree is not the
 * commit's: a matching `dependencies` map is not enough.
 */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
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

function readJson(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

/** Same id as `packagedReleaseId` in orchestrator/src/host/packaged-service.ts. */
function officialReleaseId(version) {
  const readable = version.trim().replace(/[^A-Za-z0-9._-]+/g, '-').slice(0, 48) || 'unknown';
  const digest = createHash('sha256').update(version).digest('hex').slice(0, 12);
  return `${readable}-${digest}`;
}

/**
 * The shell must be the official release of the commit's upstream version.
 * `release-manifest.json` `version` is the inventory schema, not the product
 * version. The product version is `package.json`, and the manifest seals
 * those bytes. The directory name is the release id of that version.
 */
function assertShellVersion(shell, checkoutVersion) {
  const pkgPath = join(shell, 'resources', 'orchestrator', 'package.json');
  const manifestPath = join(shell, 'resources', 'orchestrator', 'release-manifest.json');
  if (!existsSync(pkgPath)) throw new Error(`${shell} has no orchestrator package.json`);
  if (!existsSync(manifestPath)) throw new Error(`${shell} has no release-manifest.json`);
  const pkg = readJson(pkgPath);
  if (typeof pkg.version !== 'string' || pkg.version === '') throw new Error(`${pkgPath} has no version`);
  if (pkg.version !== checkoutVersion) {
    throw new Error(`official shell version ${pkg.version} differs from the commit version ${checkoutVersion}. `
      + 'Pass --shell pointing at the official release of the same upstream version.');
  }
  const manifest = readJson(manifestPath);
  const sealed = manifest.files?.['package.json'];
  const actual = createHash('sha256').update(readFileSync(pkgPath)).digest('hex');
  if (sealed !== actual) {
    throw new Error(`shell package.json does not match release-manifest.json (${pkgPath}). Refusing this shell.`);
  }
  if (typeof manifest.version === 'string' && manifest.version !== checkoutVersion) {
    throw new Error(`shell release-manifest version ${manifest.version} differs from the commit version ${checkoutVersion}`);
  }
  const expectedId = officialReleaseId(pkg.version);
  const shellName = basename(shell);
  if (shellName !== expectedId) {
    throw new Error(`shell directory ${shellName} is not the official release id ${expectedId} of version ${pkg.version}`);
  }
}

/** Resolved packages of a lockfile v2/v3, keyed by `node_modules/...`. */
function lockIdentities(lock, path) {
  if (!lock || typeof lock.packages !== 'object' || lock.packages === null) {
    throw new Error(`${path} has no resolved packages map (lockfileVersion 2 or 3)`);
  }
  const out = new Map();
  for (const [name, meta] of Object.entries(lock.packages)) {
    if (!name.startsWith('node_modules/')) continue;
    out.set(name, {
      version: typeof meta.version === 'string' ? meta.version : null,
      integrity: typeof meta.integrity === 'string' ? meta.integrity : null,
      optional: meta.optional === true,
      // `dev: true` means the package is reachable only from devDependencies.
      // A missing one is not what the daemon loads. One that is installed
      // still has to match, which the walk comparison checks.
      dev: meta.dev === true,
    });
  }
  if (out.size === 0) throw new Error(`${path} does not pin any dependency`);
  return out;
}

function packageVersion(dir) {
  const file = join(dir, 'package.json');
  if (!existsSync(file)) return null;
  try {
    const body = readJson(file);
    return typeof body.version === 'string' ? body.version : null;
  } catch {
    return null;
  }
}

/** Packages actually present under a node_modules tree. Symlinks are skipped. */
function walkInstalled(nodeModules, rel, out) {
  let entries;
  try { entries = readdirSync(nodeModules, { withFileTypes: true }); }
  catch { return; }
  for (const entry of entries) {
    if (entry.name.startsWith('.') || !entry.isDirectory() || entry.isSymbolicLink()) continue;
    const dir = join(nodeModules, entry.name);
    if (entry.name.startsWith('@')) {
      let scoped;
      try { scoped = readdirSync(dir, { withFileTypes: true }); }
      catch { continue; }
      for (const child of scoped) {
        if (child.name.startsWith('.') || !child.isDirectory() || child.isSymbolicLink()) continue;
        const childDir = join(dir, child.name);
        const childRel = `${rel}/${entry.name}/${child.name}`;
        const version = packageVersion(childDir);
        if (version) out.set(childRel, { version, integrity: null });
        walkInstalled(join(childDir, 'node_modules'), `${childRel}/node_modules`, out);
      }
      continue;
    }
    const pkgRel = `${rel}/${entry.name}`;
    const version = packageVersion(dir);
    if (version) out.set(pkgRel, { version, integrity: null });
    walkInstalled(join(dir, 'node_modules'), `${pkgRel}/node_modules`, out);
  }
}

/**
 * Fingerprint of the shell's installed modules. `node_modules/.package-lock.json`
 * supplies the integrity npm recorded; the walk is what is on disk. An
 * orchestrator/package-lock.json next to those modules, when the shell has
 * one, is the same kind of record and wins for integrity.
 */
function shellIdentities(orch) {
  const nodeModules = join(orch, 'node_modules');
  if (!existsSync(nodeModules)) throw new Error(`${orch} has no node_modules to compare with the commit lock`);
  const installed = new Map();
  walkInstalled(nodeModules, 'node_modules', installed);
  const hidden = existsSync(join(orch, 'package-lock.json'))
    ? join(orch, 'package-lock.json')
    : join(nodeModules, '.package-lock.json');
  if (existsSync(hidden)) {
    const recorded = lockIdentities(readJson(hidden), hidden);
    for (const [name, meta] of recorded) {
      const got = installed.get(name);
      if (!got) continue;
      if (meta.integrity) got.integrity = meta.integrity;
      if (meta.version && meta.version !== got.version) got.recordedVersion = meta.version;
    }
  }
  if (installed.size === 0) throw new Error(`${nodeModules} has no installed packages`);
  return installed;
}

function assertResolvedTree(checkout, shell) {
  const lockPath = join(checkout, 'orchestrator', 'package-lock.json');
  if (!existsSync(lockPath)) throw new Error(`commit has no ${lockPath}`);
  const expected = lockIdentities(readJson(lockPath), lockPath);
  const actual = shellIdentities(join(shell, 'resources', 'orchestrator'));
  const problems = [];
  for (const [name, got] of actual) {
    const want = expected.get(name);
    if (!want) problems.push(`${name}@${got.version} is installed in the shell and is not in the commit lock`);
    else if (got.recordedVersion) problems.push(`${name} package.json is ${got.version} but the shell lock records ${got.recordedVersion}`);
    else if (want.version !== got.version) problems.push(`${name} is ${got.version} in the shell and ${want.version} in the commit lock`);
    else if (want.integrity && got.integrity && want.integrity !== got.integrity) problems.push(`${name}@${got.version} integrity differs from the commit lock`);
  }
  for (const [name, want] of expected) {
    if (want.optional || want.dev) continue;
    if (!actual.has(name)) problems.push(`${name}@${want.version} is pinned by the commit lock and missing from the shell`);
  }
  if (!problems.length) return;
  const shown = problems.slice(0, 12).join('; ');
  throw new Error(`resolved dependency tree differs from the official shell (${problems.length}). ${shown}. `
    + 'The shell node_modules cannot be reused. This build does not reinstall them: native modules have to match the bundled Node.');
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

const checkoutVersion = readJson(join(checkout, 'orchestrator', 'package.json')).version;
if (typeof checkoutVersion !== 'string' || checkoutVersion === '') throw new Error('commit orchestrator/package.json has no version');
assertShellVersion(shell, checkoutVersion);

const differ = sameDependencies(
  dependencyMap(join(checkout, 'orchestrator', 'package.json')),
  dependencyMap(join(shell, 'resources', 'orchestrator', 'package.json')),
);
if (differ.length) {
  throw new Error(`orchestrator dependencies differ from the official shell (${differ.join(', ')}). `
    + 'The shell node_modules cannot be reused; rebuild the natives for the bundled Node before packaging.');
}
assertResolvedTree(checkout, shell);

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
