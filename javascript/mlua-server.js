'use strict';

// mlua-server.js — entry point
//
// Usage: node mlua-server.js --stdio
//
// Optional environment variable:
//   MLUA_INSTALL_DIR  — absolute path to the msw.mlua-<version>/ directory.
//                       If not set, the server auto-discovers the first
//                       msw.mlua-*/ directory sitting next to this file.
//
// Startup sequence:
//   1. Validate --stdio flag.
//   2. Resolve install dir (env var or auto-discovery).
//   3. Locate languageServer.js inside the installed extension.
//   4. Delegate to proxy.js which handles the stdio bridge and
//      injects indexed workspace data into the initialize request.

const path = require('path');
const fs = require('fs');

// ---------------------------------------------------------------------------
// CLI validation
// ---------------------------------------------------------------------------

if (!process.argv.includes('--stdio')) {
  process.stderr.write('Usage: node mlua-server.js --stdio\n');
  process.exit(1);
}

// ---------------------------------------------------------------------------
// installed_dir resolution
// ---------------------------------------------------------------------------

function findInstalledDir() {
  // 1. Explicit env var takes priority.
  if (process.env.MLUA_INSTALL_DIR) {
    return path.resolve(process.env.MLUA_INSTALL_DIR);
  }
  // 2. Auto-discover: look for msw.mlua-*/ next to this file.
  let entries;
  try { entries = fs.readdirSync(__dirname); } catch (_) { return null; }
  const match = entries
    .filter(e => e.startsWith('msw.mlua-'))
    .map(e => path.join(__dirname, e))
    .find(p => { try { return fs.statSync(p).isDirectory(); } catch (_) { return false; } });
  return match || null;
}

const resolvedInstallDir = findInstalledDir();

if (!resolvedInstallDir) {
  process.stderr.write(
    '[mlua-server] Error: could not find msw.mlua-*/ directory.\n' +
    '  Set MLUA_INSTALL_DIR, or place the extracted vsix next to mlua-server.js.\n'
  );
  process.exit(1);
}

if (!fs.existsSync(resolvedInstallDir)) {
  process.stderr.write('[mlua-server] Error: install dir does not exist: ' + resolvedInstallDir + '\n');
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Locate languageServer.js
// ---------------------------------------------------------------------------

const serverPath = path.join(resolvedInstallDir, 'extension', 'scripts', 'server', 'out', 'languageServer.js');

if (!fs.existsSync(serverPath)) {
  process.stderr.write('[mlua-server] Error: languageServer.js not found at: ' + serverPath + '\n');
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Start proxy
// ---------------------------------------------------------------------------

const proxy = require('./proxy.js');

proxy.start({
  serverPath,
  installedDir: resolvedInstallDir,
});
