#!/usr/bin/env node
/**
 * Print how many missions are running. The daemon token stays in this
 * process: it is read from a file and never written to stdout or stderr.
 *
 *   node missions-running.mjs --token-file PATH --url URL
 *
 * Exit 0 when none are running, 2 when at least one is, 1 when the
 * question could not be answered (fail closed).
 */
import { readFileSync } from 'node:fs';

function arg(name) {
  const index = process.argv.indexOf(name);
  const value = index === -1 ? '' : process.argv[index + 1];
  if (!value || value.startsWith('--')) {
    process.stderr.write(`missing ${name}\n`);
    process.exit(1);
  }
  return value;
}

const token = readFileSync(arg('--token-file'), 'utf8').trim();
if (!token) {
  process.stderr.write('daemon token file is empty\n');
  process.exit(1);
}
const url = arg('--url');
let response;
try {
  response = await fetch(url, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10000), redirect: 'manual' });
} catch (error) {
  process.stderr.write(`mission list failed: ${error.message}\n`);
  process.exit(1);
}
if (!response.ok) {
  process.stderr.write(`mission list answered ${response.status}\n`);
  process.exit(1);
}
const body = await response.json();
const missions = Array.isArray(body) ? body : body.missions;
if (!Array.isArray(missions)) {
  process.stderr.write('mission list has no missions array\n');
  process.exit(1);
}
const running = missions.filter((mission) => mission && mission.status === 'running');
// The route caps a page at 1000. A full page may hide further running missions.
if (running.length >= 1000) {
  process.stderr.write('mission list is truncated at 1000; refusing\n');
  process.exit(1);
}
process.stdout.write(`running ${running.length}\n`);
for (const mission of running) process.stdout.write(`id ${mission.id}\n`);
process.exit(running.length === 0 ? 0 : 2);
