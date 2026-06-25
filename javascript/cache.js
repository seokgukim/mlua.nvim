'use strict';

// cache.js — disk cache with snapshot-based invalidation
//
// Cache layout (inside javascript/cache/):
//   <sha256(rootDir)>-entry-items.json   — entry items + snapshot
//   predefines.json                       — predefines (keyed by installedDir hash)
//
// Snapshot key: { fileCount, totalSize, maxMtime }
// If snapshot matches → return cached items without re-reading files.
// If snapshot mismatches → caller re-indexes and calls store().

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const SCHEMA_VERSION = 6;

/**
 * Resolve the shared cache directory under javascript/cache/.
 * The javascript/ dir is two levels up from this file (javascript/cache.js → javascript/).
 * @returns {string}
 */
function getCacheDir() {
  const jsDir = path.dirname(__filename);
  const cacheDir = path.join(jsDir, 'cache');
  fs.mkdirSync(cacheDir, { recursive: true });
  return cacheDir;
}

/**
 * SHA-256 hex digest of a string — used to build per-project cache filenames.
 * @param {string} value
 * @returns {string}
 */
function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

/**
 * Compute a filesystem snapshot over a list of file paths.
 * Returns { fileCount, totalSize, maxMtime } using only fs.statSync —
 * no file content is read.
 *
 * @param {string[]} filePaths
 * @returns {{ fileCount: number, totalSize: number, maxMtime: number }}
 */
function computeSnapshot(filePaths) {
  let totalSize = 0;
  let maxMtime = 0;

  for (const p of filePaths) {
    try {
      const st = fs.statSync(p);
      totalSize += st.size;
      const mtime = Math.floor(st.mtimeMs);
      if (mtime > maxMtime) maxMtime = mtime;
    } catch (_) {
      // file disappeared — treat as changed
      maxMtime = Date.now();
    }
  }

  return { fileCount: filePaths.length, totalSize, maxMtime };
}

/**
 * Check whether two snapshots are identical.
 * @param {{ fileCount: number, totalSize: number, maxMtime: number }} a
 * @param {{ fileCount: number, totalSize: number, maxMtime: number }} b
 * @returns {boolean}
 */
function snapshotEqual(a, b) {
  return (
    a.fileCount === b.fileCount &&
    a.totalSize === b.totalSize &&
    a.maxMtime === b.maxMtime
  );
}

// ---------------------------------------------------------------------------
// Entry-items cache
// ---------------------------------------------------------------------------

/**
 * Load cached entry items for a project root.
 * Returns null when the cache is missing, schema-mismatched, or stale.
 *
 * @param {string} rootDir  — absolute path to project root
 * @param {string[]} currentFiles — current list of entry file paths (for snapshot)
 * @returns {{ items: object[] } | null}
 */
function loadEntryItems(rootDir, currentFiles) {
  const cacheFile = path.join(getCacheDir(), sha256(rootDir) + '-entry-items.json');

  let raw;
  try {
    raw = fs.readFileSync(cacheFile, 'utf8');
  } catch (_) {
    return null;
  }

  let data;
  try {
    data = JSON.parse(raw);
  } catch (_) {
    return null;
  }

  if (data.schemaVersion !== SCHEMA_VERSION) return null;

  const current = computeSnapshot(currentFiles);
  if (!snapshotEqual(current, data.snapshot)) return null;

  return { items: data.items };
}

/**
 * Persist entry items and their snapshot to disk.
 *
 * @param {string} rootDir
 * @param {string[]} filePaths — the entry files that were indexed
 * @param {object[]} items     — parsed EntryItem[]
 */
function storeEntryItems(rootDir, filePaths, items) {
  const cacheFile = path.join(getCacheDir(), sha256(rootDir) + '-entry-items.json');
  const snapshot = computeSnapshot(filePaths);

  const data = {
    schemaVersion: SCHEMA_VERSION,
    snapshot,
    items,
  };

  try {
    fs.writeFileSync(cacheFile, JSON.stringify(data), 'utf8');
  } catch (_) {
    // non-fatal — next run will just re-index
  }
}

// ---------------------------------------------------------------------------
// Predefines cache
// ---------------------------------------------------------------------------

/**
 * Load cached predefines for a given installedDir.
 * Returns null when cache is missing or schema-mismatched.
 * Predefines don't need snapshot validation — they change only when the
 * extension version changes (which changes installedDir).
 *
 * @param {string} installedDir
 * @returns {{ modules: object[], globalVariables: object[], globalFunctions: object[] } | null}
 */
function loadPredefines(installedDir) {
  const cacheFile = path.join(getCacheDir(), sha256(installedDir) + '-predefines.json');

  let raw;
  try {
    raw = fs.readFileSync(cacheFile, 'utf8');
  } catch (_) {
    return null;
  }

  let data;
  try {
    data = JSON.parse(raw);
  } catch (_) {
    return null;
  }

  if (data.schemaVersion !== SCHEMA_VERSION) return null;

  return data.predefines;
}

/**
 * Persist predefines to disk.
 *
 * @param {string} installedDir
 * @param {{ modules: object[], globalVariables: object[], globalFunctions: object[] }} predefines
 */
function storePredefines(installedDir, predefines) {
  const cacheFile = path.join(getCacheDir(), sha256(installedDir) + '-predefines.json');

  const data = {
    schemaVersion: SCHEMA_VERSION,
    predefines,
  };

  try {
    fs.writeFileSync(cacheFile, JSON.stringify(data), 'utf8');
  } catch (_) {
    // non-fatal
  }
}

// ---------------------------------------------------------------------------
// Documents cache
// ---------------------------------------------------------------------------

/**
 * Load cached document items for a project root.
 *
 * @param {string} rootDir
 * @param {string[]} currentFiles
 * @returns {{ items: object[] } | null}
 */
function loadDocuments(rootDir, currentFiles) {
  const cacheFile = path.join(getCacheDir(), sha256(rootDir) + '-documents.json');

  let raw;
  try {
    raw = fs.readFileSync(cacheFile, 'utf8');
  } catch (_) {
    return null;
  }

  let data;
  try {
    data = JSON.parse(raw);
  } catch (_) {
    return null;
  }

  if (data.schemaVersion !== SCHEMA_VERSION) return null;

  const current = computeSnapshot(currentFiles);
  if (!snapshotEqual(current, data.snapshot)) return null;

  return { items: data.items };
}

/**
 * Persist document items to disk.
 *
 * @param {string} rootDir
 * @param {string[]} filePaths
 * @param {object[]} items
 */
function storeDocuments(rootDir, filePaths, items) {
  const cacheFile = path.join(getCacheDir(), sha256(rootDir) + '-documents.json');
  const snapshot = computeSnapshot(filePaths);

  const data = {
    schemaVersion: SCHEMA_VERSION,
    snapshot,
    items,
  };

  try {
    fs.writeFileSync(cacheFile, JSON.stringify(data), 'utf8');
  } catch (_) {
    // non-fatal
  }
}

module.exports = {
  computeSnapshot,
  snapshotEqual,
  loadEntryItems,
  storeEntryItems,
  loadPredefines,
  storePredefines,
  loadDocuments,
  storeDocuments,
};
