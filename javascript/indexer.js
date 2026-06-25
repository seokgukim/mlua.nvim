'use strict';

// indexer.js — collect entries, predefines, and documents
//
// Entry parsing logic mirrors lua/mlua/entries.lua exactly.
// Documents mirror lua/mlua/document.lua (sync read, no batch limit needed here).
// Predefines mirror lua/mlua/predefines.lua (require the extension's index.js).

const fs = require('fs');
const path = require('path');
const cache = require('./cache.js');

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Recursively collect files matching an extension set under a root directory.
 * Uses only fs.readdirSync — no external dependencies.
 *
 * @param {string} dir
 * @param {Set<string>} exts
 * @param {string[]} [results]
 * @returns {string[]}
 */
function globSync(dir, exts, results = []) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (_) {
    return results;
  }

  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      globSync(full, exts, results);
    } else if (entry.isFile() && exts.has(path.extname(entry.name))) {
      results.push(full);
    }
  }

  return results;
}

/**
 * Convert an absolute file path to a file:// URI (cross-platform).
 * @param {string} filePath
 * @returns {string}
 */
function pathToUri(filePath) {
  // Normalise to forward slashes
  const normalized = filePath.replace(/\\/g, '/');
  if (normalized.startsWith('/')) {
    return 'file://' + normalized;
  }
  // Windows drive letter  e.g. C:/foo  →  file:///C:/foo
  return 'file:///' + normalized;
}

// ---------------------------------------------------------------------------
// Project root resolution
// ---------------------------------------------------------------------------

/**
 * Resolve the actual mLua project root from a given directory.
 *
 * Editors send rootUri based on what the user opened, which may be a
 * subdirectory of the project (e.g. RootDesk/MyDesk/).  Walk upward until we
 * find a directory that contains both "RootDesk" and "Environment" siblings —
 * that is the true project root and must be indexed as a whole.
 *
 * If no such ancestor is found the original dir is returned unchanged.
 *
 * @param {string} dir  — starting directory (absolute path)
 * @returns {string}    — resolved project root
 */
function resolveProjectRoot(dir) {
  if (!dir) return dir;

  let current = path.resolve(dir);
  while (true) {
    let hasRootDesk = false;
    let hasEnvironment = false;
    try {
      const entries = fs.readdirSync(current, { withFileTypes: true });
      for (const e of entries) {
        if (!e.isDirectory()) continue;
        if (e.name === 'RootDesk') hasRootDesk = true;
        if (e.name === 'Environment') hasEnvironment = true;
        if (hasRootDesk && hasEnvironment) break;
      }
    } catch (_) {
      // unreadable directory — stop
      break;
    }

    if (hasRootDesk && hasEnvironment) return current;

    const parent = path.dirname(current);
    if (parent === current) break; // filesystem root
    current = parent;
  }

  return dir; // fallback: use what the editor sent
}

// ---------------------------------------------------------------------------
// Entry parsing  (mirrors lua/mlua/entries.lua)
// ---------------------------------------------------------------------------

const ENTRY_EXTS = new Set();

/** @param {object|null} json_components */
function parseComponentItems(json_components) {
  if (!Array.isArray(json_components)) return [];
  const items = [];
  for (const c of json_components) {
    if (c && typeof c === 'object') {
      items.push({ name: c['@type'], enable: c.enable });
    }
  }
  return items;
}

/** @param {object|null} json_entities */
function parseEntityItems(json_entities) {
  if (!Array.isArray(json_entities)) return [];
  const entities = [];
  for (const e of json_entities) {
    if (e && typeof e === 'object') {
      const summary = e.jsonString || {};
      entities.push({
        id: e.id,
        path: e.path,
        name: summary.name,
        enable: summary.enable,
        visible: summary.visible,
        modelId: summary.modelId,
        components: parseComponentItems(summary['@components']),
      });
    }
  }
  return entities;
}

function parseMapContentProto(content) {
  if (!content || typeof content !== 'object') return null;
  return { entities: parseEntityItems(content.Entities) };
}

function parseModelContentProto(content) {
  if (!content || typeof content !== 'object') return null;
  const model = content.Json;
  if (!model || typeof model !== 'object') return null;
  return {
    modelItem: {
      name: model.Name,
      id: model.Id,
      baseModelId: model.BaseModelId,
      components: model.Components,
    },
  };
}

function parseCollisionGroupSetProto(content) {
  if (!content || typeof content !== 'object') return null;
  const json = content.Json;
  if (!json || typeof json !== 'object') return null;
  const groups = [];
  if (Array.isArray(json.Groups)) {
    for (const g of json.Groups) {
      if (g && typeof g === 'object') {
        groups.push({ id: g.Id, name: g.Name });
      }
    }
  }
  return { collisionGroupSet: { groups } };
}

/**
 * Parse a single entry file into an EntryItem.
 * @param {string} filePath
 * @returns {object|null}
 */
function parseEntryFile(filePath) {
  let raw;
  try {
    raw = fs.readFileSync(filePath, 'utf8');
  } catch (_) {
    return null;
  }

  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (_) {
    return null;
  }

  if (!payload || typeof payload !== 'object') return null;

  const entryKey = payload.EntryKey ?? payload.entryKey;
  const contentType = payload.ContentType ?? payload.contentType;
  const contentProto = payload.ContentProto ?? payload.contentProto;

  if (!entryKey || !contentType || !contentProto) return null;

  let parsed;
  if (contentType === 'x-mod/map' || contentType === 'x-mod/ui') {
    parsed = parseMapContentProto(contentProto);
  } else if (contentType === 'x-mod/model') {
    parsed = parseModelContentProto(contentProto);
  } else if (contentType === 'x-mod/collisiongroupset') {
    parsed = parseCollisionGroupSetProto(contentProto);
  } else {
    return null;
  }

  if (!parsed) return null;

  return {
    uri: pathToUri(filePath),
    entryKey,
    contentType,
    contentProto: parsed,
  };
}

/**
 * Collect all entry items for rootDir, using disk cache when valid.
 *
 * @param {string} rootDir
 * @returns {object[]}  EntryItem[]
 */
function collectEntryItems(rootDir) {
  if (ENTRY_EXTS.size === 0) return [];

  const filePaths = globSync(rootDir, ENTRY_EXTS);

  const hit = cache.loadEntryItems(rootDir, filePaths);
  if (hit) return hit.items;

  const items = [];
  for (const p of filePaths) {
    const item = parseEntryFile(p);
    if (item) items.push(item);
  }

  cache.storeEntryItems(rootDir, filePaths, items);
  return items;
}

// ---------------------------------------------------------------------------
// Predefines  (mirrors lua/mlua/predefines.lua)
// ---------------------------------------------------------------------------

/**
 * Load predefines from the extension's index.js.
 * Result is cached to disk keyed by installedDir.
 *
 * @param {string} installedDir  — path to msw.mlua-<version>/ directory
 * @returns {{ modules: object[], globalVariables: object[], globalFunctions: object[] }}
 */
function collectPredefines(installedDir) {
  const hit = cache.loadPredefines(installedDir);
  if (hit) return hit;

  const indexPath = path.join(installedDir, 'extension', 'scripts', 'predefines', 'out', 'index.js');

  let m;
  try {
    m = require(indexPath);
  } catch (err) {
    process.stderr.write('[mlua-server] Failed to require predefines index.js: ' + err.message + '\n');
    return { modules: [], globalVariables: [], globalFunctions: [] };
  }

  const P = m.Predefines;
  const predefines = {
    modules: P && P.modules ? P.modules() : [],
    globalVariables: P && P.globalVariables ? P.globalVariables() : [],
    globalFunctions: P && P.globalFunctions ? P.globalFunctions() : [],
  };

  cache.storePredefines(installedDir, predefines);
  return predefines;
}

// ---------------------------------------------------------------------------
// Documents  (mirrors lua/mlua/document.lua)
// ---------------------------------------------------------------------------

const MLUA_EXTS = new Set(['.mlua']);

/**
 * Determine whether a file should be injected as a workspace document.
 *
 * @param {string} filePath
 * @returns {boolean}
 */
function isIndexableScriptFile(filePath) {
  const normalized = String(filePath || '').replace(/\\/g, '/');
  const base = path.basename(normalized);
  return base.endsWith('.mlua');
}

/**
 * Collect all .mlua document items for rootDir, using disk cache when valid.
 *
 * @param {string} rootDir
 * @returns {object[]}  DocumentItem[]  { uri, languageId, version, text }
 */
function collectDocuments(rootDir) {
  const filePaths = globSync(rootDir, MLUA_EXTS).filter(isIndexableScriptFile);

  const hit = cache.loadDocuments(rootDir, filePaths);
  if (hit) return hit.items;

  const items = [];
  for (const p of filePaths) {
    let text;
    try {
      text = fs.readFileSync(p, 'utf8');
    } catch (_) {
      continue;
    }
    items.push({
      uri: pathToUri(p),
      languageId: 'mlua',
      version: 0,
      text,
    });
  }

  cache.storeDocuments(rootDir, filePaths, items);
  return items;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Build the full initializeOptions payload expected by the mLua language server.
 *
 * @param {string} installedDir  — path to msw.mlua-<version>/
 * @param {string} rootDir       — project root (may be null/empty for no-project mode)
 * @returns {{
 *   documentItems: object[],
 *   entryItems: object[],
 *   modules: object[],
 *   globalVariables: object[],
 *   globalFunctions: object[],
 *   stopwatch: boolean,
 *   profileMode: number,
 *   capabilities: object
 * }}
 */
function buildInitOptions(installedDir, rootDir) {
  const predefines = collectPredefines(installedDir);

  let documentItems = [];
  let entryItems = [];

  if (rootDir) {
    const resolvedRoot = resolveProjectRoot(rootDir);
    documentItems = collectDocuments(resolvedRoot);
    entryItems = collectEntryItems(resolvedRoot);
  }

  return {
    documentItems,
    entryItems,
    modules: predefines.modules,
    globalVariables: predefines.globalVariables,
    globalFunctions: predefines.globalFunctions,
    stopwatch: false,
    profileMode: 0,
    capabilities: {
      completionCapability: {
        codeBlockScriptSnippetCompletion: true,
        codeBlockBTNodeSnippetCompletion: true,
        codeBlockComponentSnippetCompletion: true,
        codeBlockEventSnippetCompletion: true,
        codeBlockMethodSnippetCompletion: true,
        codeBlockHandlerSnippetCompletion: true,
        codeBlockItemSnippetCompletion: true,
        codeBlockLogicSnippetCompletion: true,
        codeBlockPropertySnippetCompletion: true,
        codeBlockStateSnippetCompletion: true,
        codeBlockStructSnippetCompletion: true,
        attributeCompletion: true,
        eventMethodCompletion: true,
        overrideMethodCompletion: true,
        overridePropertyCompletion: true,
        annotationCompletion: true,
        keywordCompletion: true,
        luaCodeCompletion: true,
        commitCharacterSupport: true,
      },
      definitionCapability: {},
      diagnosticCapability: {
        needExtendsDiagnostic: true,
        notEqualsNameDiagnostic: true,
        duplicateLocalDiagnostic: true,
        introduceGlobalVariableDiagnostic: true,
        parseErrorDiagnostic: true,
        annotationParseErrorDiagnostic: true,
        unavailableAttributeDiagnostic: true,
        unavailableTypeDiagnostic: true,
        unresolvedMemberDiagnostic: true,
        unresolvedSymbolDiagnostic: true,
        assignTypeMismatchDiagnostic: true,
        parameterTypeMismatchDiagnostic: true,
        deprecatedDiagnostic: true,
        overrideMemberMismatchDiagnostic: true,
        unavailableOptionalParameterDiagnostic: true,
        unavailableParameterNameDiagnostic: true,
        invalidAttributeArgumentDiagnostic: true,
        notAllowPropertyDefaultValueDiagnostic: true,
        assignToReadonlyDiagnostic: true,
        needPropertyDefaultValueDiagnostic: true,
        notEnoughArgumentDiagnostic: true,
        tooManyArgumentDiagnostic: true,
        duplicateMemberDiagnostic: true,
        cannotOverrideMemberDiagnostic: true,
        tableKeyTypeMismatchDiagnostic: true,
        duplicateAttributeDiagnostic: true,
        invalidEventHandlerParameterDiagnostic: true,
        unavailablePropertyNameDiagnostic: true,
        annotationTypeNotFoundDiagnostic: true,
        annotationParamNotFoundDiagnostic: true,
        unbalancedAssignmentDiagnostic: true,
        unexpectedReturnDiagnostic: true,
        needReturnDiagnostic: true,
        duplicateParamDiagnostic: true,
        returnTypeMismatchDiagnostic: true,
        expectedReturnValueDiagnostic: true,
      },
      documentSymbolCapability: {},
      hoverCapability: {},
      referenceCapability: {},
      semanticTokensCapability: {},
      signatureHelpCapability: {},
      typeDefinitionCapability: {},
      renameCapability: {},
      inlayHintCapability: {},
      documentFormattingCapability: {},
      documentRangeFormattingCapability: {},
    },
  };
}

module.exports = {
  collectEntryItems,
  collectPredefines,
  collectDocuments,
  buildInitOptions,
  isIndexableScriptFile,
  parseEntryFile,
  resolveProjectRoot,
};
