'use strict';

const fs = require('fs');
const path = require('path');

function setupWatcher(rootDir, onFileChange) {
  if (!rootDir) return null;

  console.error('[mlua-watcher] Starting watcher for: ' + rootDir);
  
  // Use recursive watch if supported (Node.js 8+)
  // For entries (*.ent) and scripts (*.mlua)
  const watcher = fs.watch(rootDir, { recursive: true }, (eventType, filename) => {
    if (!filename) return;
    
    const fullPath = path.join(rootDir, filename).replace(/\\/g, '/');
    
    if (filename.endsWith('.mlua') || filename.endsWith('.ent')) {
      onFileChange(eventType, fullPath);
    }
  });

  return watcher;
}

module.exports = { setupWatcher };
