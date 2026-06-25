'use strict';

const fs = require('fs');
const path = require('path');
const { isIndexableScriptFile } = require('./indexer.js');

function setupWatcher(rootDir, onFileChange, installedDir) {
  if (!rootDir) return null;

  // Normalize installedDir so we can exclude it from change events.
  const normalizedInstalledDir = installedDir
    ? path.resolve(installedDir).replace(/\\/g, '/') + '/'
    : null;

  // Use recursive watch if supported (Node.js 8+)
  // For entries (*.ent) and scripts (*.mlua)
  const watcher = fs.watch(rootDir, { recursive: true }, (eventType, filename) => {
    if (!filename) return;

    const fullPath = path.join(rootDir, filename).replace(/\\/g, '/');

    // Skip files inside the installed extension directory.
    if (normalizedInstalledDir && fullPath.startsWith(normalizedInstalledDir)) return;

    if ((filename.endsWith('.mlua') && isIndexableScriptFile(fullPath)) || filename.endsWith('.ent')) {
      onFileChange(eventType, fullPath);
    }
  });

  return watcher;
}


module.exports = { setupWatcher };
