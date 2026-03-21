'use strict';

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const indexer = require('./indexer.js');
const { setupWatcher } = require('./watcher.js');

function logError(msg) {
  try {
    const logPath = path.join(__dirname, 'mlua-proxy.log');
    fs.appendFileSync(logPath, new Date().toISOString() + ' [ERROR] ' + msg + '\n');
  } catch(e) {}
}

function createLspParser(onMessage) {
  let buf = Buffer.alloc(0);
  function push(chunk) {
    buf = Buffer.concat([buf, chunk]);
    while (true) {
      const sep = buf.indexOf('\r\n\r\n');
      if (sep === -1) break;
      const header = buf.slice(0, sep).toString('utf8');
      const lenMatch = header.match(/Content-Length:\s*(\d+)/i);
      if (!lenMatch) {
        buf = buf.slice(sep + 4);
        continue;
      }
      const bodyLen = parseInt(lenMatch[1], 10);
      const bodyStart = sep + 4;
      if (buf.length < bodyStart + bodyLen) break;
      const body = buf.slice(bodyStart, bodyStart + bodyLen).toString('utf8');
      buf = buf.slice(bodyStart + bodyLen);
      let msg;
      try { msg = JSON.parse(body); } catch (_) { continue; }
      onMessage(msg);
    }
  }
  return { push };
}

function encodeLspMessage(msg) {
  const body = JSON.stringify(msg);
  const header = `Content-Length: ${Buffer.byteLength(body, 'utf8')}\r\n\r\n`;
  return Buffer.concat([Buffer.from(header, 'utf8'), Buffer.from(body, 'utf8')]);
}

function start(opts) {
  const { serverPath, installedDir } = opts;

  const child = spawn(process.execPath, [serverPath, '--stdio'], {
    stdio: ['pipe', 'pipe', 'pipe'],
    cwd: path.dirname(serverPath),
  });

  child.on('error', (err) => {
    logError('Child spawn error: ' + err.message);
    process.stderr.write('[mlua-server] Failed to spawn language server: ' + err.message + '\n');
    process.exit(1);
  });

  child.stderr.on('data', (d) => {
    process.stderr.write(d);
  });

  child.on('exit', (code, signal) => {
    logError(`Child exited code=${code} signal=${signal}`);
    process.exit(code ?? 1);
  });

  process.on('uncaughtException', (err) => {
    logError('UNCAUGHT EXCEPTION: ' + err.message + '\n' + err.stack);
    process.exit(1);
  });

  let initialized = false;
  let clientSupportsPull = false;

  // Track open documents: uri -> { languageId, version, previousResultId, text }
  const openDocs = new Map();

  // Diagnostic cache: uri -> { items: [...], resultId: string }
  // Populated by proxy-initiated pulls; served to editor pull requests.
  // resultId is a monotonically increasing string so Zed can detect changes.
  const diagCache = new Map();
  let diagCacheSeq = 0;

  // Proxy-initiated diagnostic request id tracking: id -> uri
  // We use a string prefix so they never collide with editor-assigned numeric ids.
  let proxyDiagSeq = 0;
  const proxyDiagIds = new Map(); // proxyId -> uri
  let diagDebounceTimer = null;

  // Pending editor pull requests waiting for proxy to populate the cache:
  // uri -> [{ id, params }]
  const pendingEditorPulls = new Map();

  function sendProxyDiagnosticRequests() {
    for (const [uri, doc] of openDocs) {
      const proxyId = 'proxy-diag-' + (++proxyDiagSeq);
      const params = { textDocument: { uri } };
      if (doc.previousResultId) params.previousResultId = doc.previousResultId;
      proxyDiagIds.set(proxyId, uri);
      child.stdin.write(encodeLspMessage({ jsonrpc: '2.0', id: proxyId, method: 'textDocument/diagnostic', params }));
    }
  }

  function handleClientMessage(msg) {
    if (!msg) return;

    if (!initialized && msg.method === 'initialize') {
      initialized = true;
      let rootDir = null;
      const rootUri = msg.params && msg.params.rootUri;
      if (rootUri) {
        rootDir = rootUri.replace(/^file:\/\//, '').replace(/^\/([A-Za-z]:)/, '$1');
        if (!rootDir.startsWith('/') && !rootDir.match(/^[A-Za-z]:/)) {
          rootDir = '/' + rootDir;
        }
        rootDir = rootDir.replace(/\\/g, '/');
      } else if (msg.params && msg.params.rootPath) {
        rootDir = msg.params.rootPath;
      }

      opts.currentRootDir = rootDir;

      // Resolve the actual mLua project root (walks up to find RootDesk + Environment).
      const resolvedRootDir = rootDir ? indexer.resolveProjectRoot(rootDir) : rootDir;

      // Detect if the client natively supports pull diagnostics.
      if (msg.params && msg.params.capabilities) {
        clientSupportsPull = !!(
          msg.params.capabilities.textDocument &&
          msg.params.capabilities.textDocument.diagnostic
        );
      }

      // Inject textDocument.diagnostic capability so the server activates its
      // pull diagnostic provider — required for workspace/diagnostic/refresh
      // to fire and for textDocument/diagnostic requests to return results.
      if (msg.params && msg.params.capabilities) {
        msg.params.capabilities.textDocument = msg.params.capabilities.textDocument || {};
        msg.params.capabilities.textDocument.diagnostic = msg.params.capabilities.textDocument.diagnostic || {
          dynamicRegistration: false,
          relatedDocumentSupport: false,
        };
        msg.params.capabilities.workspace = msg.params.capabilities.workspace || {};
        msg.params.capabilities.workspace.diagnostics = msg.params.capabilities.workspace.diagnostics || {
          refreshSupport: true,
        };
      }

      if (resolvedRootDir) {
        setupWatcher(resolvedRootDir, (eventType, fullPath) => {
          if (fullPath.endsWith('.ent')) {
            try {
              const entry = indexer.parseEntryFile(fullPath);
              if (entry) {
                child.stdin.write(encodeLspMessage({
                  jsonrpc: '2.0',
                  method: 'msw.protocol.entryChanged',
                  params: { entryItem: entry }
                }));
              }
            } catch (e) {
              logError(`Error parsing entry ${fullPath}: ${e.message}`);
            }
          }
        }, installedDir);
      }

      let initOptions;
      try {
        initOptions = indexer.buildInitOptions(installedDir, resolvedRootDir || '');
      } catch (err) {
        logError('indexer.buildInitOptions failed: ' + err.message + '\n' + err.stack);
        initOptions = { documentItems: [], entryItems: [], modules: [], globalVariables: [], globalFunctions: [], stopwatch: false, profileMode: 0, capabilities: {} };
      }

      const patched = Object.assign({}, msg, {
        params: Object.assign({}, msg.params, {
          initializationOptions: JSON.stringify(initOptions),
        }),
      });

      child.stdin.write(encodeLspMessage(patched));
      return;
    }

    // Track open documents for proxy-initiated diagnostic pulls.
    if (msg.method === 'textDocument/didOpen' && msg.params?.textDocument) {
      const td = msg.params.textDocument;
      openDocs.set(td.uri, { languageId: td.languageId, version: td.version, previousResultId: null, text: td.text });
    }
    if (msg.method === 'textDocument/didClose' && msg.params?.textDocument) {
      openDocs.delete(msg.params.textDocument.uri);
    }

    // After initialized, wait for workspace/diagnostic/refresh from the server.
    // If it doesn't arrive within 10s, fallback to a direct pull.
    if (msg.method === 'initialized') {
      const fallback = setTimeout(() => {
        sendProxyDiagnosticRequests();
      }, 10000);
      opts._diagFallbackTimer = fallback;
    }

    // Also proxy-pull on didChange (debounced) so diagnostics stay fresh.
    if (msg.method === 'textDocument/didChange') {
      clearTimeout(diagDebounceTimer);
      diagDebounceTimer = setTimeout(() => {
        sendProxyDiagnosticRequests();
      }, 800);
    }

    // Convert full-content didChange → incremental for the server.
    if (msg.method === 'textDocument/didChange' && msg.params?.contentChanges) {
      const uri = msg.params.textDocument?.uri;
      const changes = msg.params.contentChanges;
      const isFullSync = changes.length === 1 && changes[0].range === undefined && changes[0].rangeLength === undefined;
      if (isFullSync && uri) {
        const newText = changes[0].text;
        const prevText = (openDocs.get(uri) || {}).text || '';
        const lines = prevText.split('\n');
        const endLine = lines.length - 1;
        const endChar = lines[endLine].length;
        msg.params.contentChanges = [{
          range: { start: { line: 0, character: 0 }, end: { line: endLine, character: endChar } },
          text: newText,
        }];
        if (openDocs.has(uri)) openDocs.get(uri).text = newText;
      }
    }

    // textDocument/diagnostic: intercept and serve from cache.
    // The server returns "unchanged" for editor pulls because it tracks result IDs
    // per-client. Proxy pulls for itself, caches results, and serves them directly.
    if (msg.method === 'textDocument/diagnostic' && msg.id !== undefined && msg.params?.textDocument?.uri) {
      const uri = msg.params.textDocument.uri;
      const editorPreviousResultId = msg.params.previousResultId || null;
      if (diagCache.has(uri)) {
        const cached = diagCache.get(uri);
        if (editorPreviousResultId && editorPreviousResultId === cached.resultId) {
          process.stdout.write(encodeLspMessage({
            jsonrpc: '2.0',
            id: msg.id,
            result: { kind: 'unchanged', resultId: cached.resultId },
          }));
        } else {
          process.stdout.write(encodeLspMessage({
            jsonrpc: '2.0',
            id: msg.id,
            result: { kind: 'full', items: cached.items, resultId: cached.resultId },
          }));
        }
      } else {
        // No cache yet — queue and wait for proxy pull to populate it.
        if (!pendingEditorPulls.has(uri)) pendingEditorPulls.set(uri, []);
        pendingEditorPulls.get(uri).push({ id: msg.id, params: msg.params });
      }
      return;
    }

    if (msg.method === 'textDocument/inlayHint') {
      if (msg.id) {
        process.stdout.write(encodeLspMessage({ jsonrpc: '2.0', id: msg.id, result: null }));
      }
      return;
    }

    // Custom MLua methods
    if (msg.method === 'mlua/reloadWorkspace') {
      try {
        const rootDir = msg.params?.rootDir || opts.currentRootDir || '';
        const resolvedRootDir = rootDir ? indexer.resolveProjectRoot(rootDir) : rootDir;
        const initOptions = indexer.buildInitOptions(installedDir, resolvedRootDir);
        for (const doc of initOptions.documentItems) {
          child.stdin.write(encodeLspMessage({ jsonrpc: '2.0', method: 'textDocument/didOpen', params: { textDocument: doc } }));
        }
        for (const entry of initOptions.entryItems) {
          child.stdin.write(encodeLspMessage({ jsonrpc: '2.0', method: 'msw.protocol.entryChanged', params: { entryItem: entry } }));
        }
        child.stdin.write(encodeLspMessage({ jsonrpc: '2.0', method: 'msw.protocol.refreshDiagnostic', params: {} }));
        child.stdin.write(encodeLspMessage({ jsonrpc: '2.0', method: 'msw.protocol.refreshSemanticTokens', params: {} }));
      } catch (err) {
        logError('mlua/reloadWorkspace failed: ' + err.message);
      }
      return;
    }

    child.stdin.write(encodeLspMessage(msg));
  }

  function handleServerMessage(msg) {
    if (!msg) return;

    // Responses to proxy-initiated diagnostic pulls: cache and serve.
    if (msg.id !== undefined && proxyDiagIds.has(msg.id)) {
      const uri = proxyDiagIds.get(msg.id);
      proxyDiagIds.delete(msg.id);
      const result = msg.result;
      if (result) {
        // Update previousResultId for next incremental pull.
        if (result.resultId && openDocs.has(uri)) {
          openDocs.get(uri).previousResultId = result.resultId;
        }

        // Update cache on full result.
        if (result.kind === 'full' && Array.isArray(result.items)) {
          const newResultId = 'proxy-' + (++diagCacheSeq);
          diagCache.set(uri, { items: result.items, resultId: newResultId });
        }

        // Flush any pending editor pull requests for this URI.
        if (pendingEditorPulls.has(uri)) {
          const pending = pendingEditorPulls.get(uri);
          pendingEditorPulls.delete(uri);
          const cached = diagCache.has(uri) ? diagCache.get(uri) : { items: [], resultId: 'proxy-' + (++diagCacheSeq) };
          for (const { id } of pending) {
            process.stdout.write(encodeLspMessage({
              jsonrpc: '2.0',
              id,
              result: { kind: 'full', items: cached.items, resultId: cached.resultId },
            }));
          }
        }


        // Relay as publishDiagnostics for push-only editors (pull-capable clients
        // receive diagnostics via textDocument/diagnostic responses above).
        if (!clientSupportsPull && result.kind === 'full' && Array.isArray(result.items)) {
          process.stdout.write(encodeLspMessage({
            jsonrpc: '2.0',
            method: 'textDocument/publishDiagnostics',
            params: { uri, diagnostics: result.items },
          }));
        }
      }
      return;
    }

    // workspace/diagnostic/refresh: ack the server, proxy-pull all open docs.
    if (msg.method === 'workspace/diagnostic/refresh' && msg.id !== undefined) {
      child.stdin.write(encodeLspMessage({ jsonrpc: '2.0', id: msg.id, result: null }));
      if (opts._diagFallbackTimer) { clearTimeout(opts._diagFallbackTimer); opts._diagFallbackTimer = null; }
      for (const doc of openDocs.values()) doc.previousResultId = null;
      sendProxyDiagnosticRequests();
      process.stdout.write(encodeLspMessage({ jsonrpc: '2.0', method: 'workspace/diagnostic/refresh' }));
      return;
    }

    // workspace/semanticTokens/refresh: ack and forward as notification.
    if (msg.method === 'workspace/semanticTokens/refresh' && msg.id !== undefined) {
      child.stdin.write(encodeLspMessage({ jsonrpc: '2.0', id: msg.id, result: null }));
      process.stdout.write(encodeLspMessage({ jsonrpc: '2.0', method: 'workspace/semanticTokens/refresh' }));
      return;
    }

    // Server -> Client protocol translation.
    if (msg.method === 'msw.protocol.refreshDiagnostic') {
      msg.method = 'workspace/diagnostic/refresh';
      delete msg.id;
    } else if (msg.method === 'msw.protocol.refreshSemanticTokens') {
      msg.method = 'workspace/semanticTokens/refresh';
    } else if (msg.method === 'msw.protocol.execSpaceDecorationChanged') {
      msg.method = 'mlua/execSpaceDecorationChanged';
    } else if (msg.method === 'msw.protocol.renameFile') {
      const { uri, newName } = msg.params;
      if (uri && newName) {
        const oldPath = uri.replace(/^file:\/\//, '').replace(/^\/([A-Za-z]:)/, '$1');
        const oldExt = oldPath.endsWith('.d.mlua') ? '.d.mlua' : '.mlua';
        const newPath = path.join(path.dirname(oldPath), newName + oldExt);
        const newUri = 'file://' + (newPath.startsWith('/') ? '' : '/') + newPath.replace(/\\/g, '/');
        msg.method = 'workspace/applyEdit';
        msg.params = {
          edit: {
            documentChanges: [{ kind: 'rename', oldUri: uri, newUri: newUri }]
          }
        };
      }
    }

    process.stdout.write(encodeLspMessage(msg));
  }

  const clientParser = createLspParser(handleClientMessage);
  const serverParser = createLspParser(handleServerMessage);

  process.stdin.on('data', (chunk) => clientParser.push(chunk));
  child.stdout.on('data', (chunk) => serverParser.push(chunk));

  process.stderr.write('[mlua-server] proxy started, server: ' + serverPath + '\n');
}

module.exports = { start };
