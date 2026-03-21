'use strict';

const fs = require('fs');
const path = require('path');

function setupWatcher(rootDir, onFileChange, installedDir) {
  if (!rootDir) return null;

  // Normalize installedDir so we can exclude it from change events.
  // The installed extension (msw.mlua-*/) lives inside javascript/ and contains
  // thousands of .d.mlua definition files — we must not react to changes there.
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

    if (filename.endsWith('.mlua') || filename.endsWith('.ent')) {
      onFileChange(eventType, fullPath);
    }
  });

  return watcher;
}


module.exports = { setupWatcher };
