'use strict';

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const indexer = require('./indexer.js');
const { setupWatcher } = require('./watcher.js');

function log(msg) {
  try {
    const logPath = path.join(__dirname, 'mlua-proxy.log');
    fs.appendFileSync(logPath, new Date().toISOString() + ' ' + msg + '\n');
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
  log(`Starting proxy. serverPath=${serverPath}, installedDir=${installedDir}`);

  const child = spawn('node', [serverPath, '--stdio'], {
    stdio: ['pipe', 'pipe', 'pipe'],
    cwd: path.dirname(serverPath),
  });

  child.on('error', (err) => {
    log('Child spawn error: ' + err.message);
    process.stderr.write('[mlua-server] Failed to spawn language server: ' + err.message + '\n');
    process.exit(1);
  });

  child.stderr.on('data', (d) => {
    log('CHILD STDERR: ' + d.toString());
    process.stderr.write(d);
  });

  child.on('exit', (code, signal) => {
    log(`Child exited code=${code} signal=${signal}`);
    process.exit(code ?? 1);
  });

  process.on('uncaughtException', (err) => {
    log('UNCAUGHT EXCEPTION: ' + err.message + '\n' + err.stack);
    process.exit(1);
  });

  let initialized = false;

  // Track open documents: uri -> { languageId, version, previousResultId }
  const openDocs = new Map();

  // URIs for which the editor has issued its own textDocument/diagnostic pull.
  // Proxy-pull results for these are dropped to avoid duplicate diagnostics.
  const editorPulledUris = new Set();

  // Proxy-initiated diagnostic request id tracking: id -> uri
  // We use a string prefix so they never collide with editor-assigned numeric ids.
  let proxyDiagSeq = 0;
  const proxyDiagIds = new Map(); // proxyId -> uri

  function sendProxyDiagnosticRequests() {
    for (const [uri, doc] of openDocs) {
      const proxyId = 'proxy-diag-' + (++proxyDiagSeq);
      const params = { textDocument: { uri } };
      if (doc.previousResultId) params.previousResultId = doc.previousResultId;
      proxyDiagIds.set(proxyId, uri);
      log('Proxy pull textDocument/diagnostic uri=' + uri + ' id=' + proxyId);
      child.stdin.write(encodeLspMessage({ jsonrpc: '2.0', id: proxyId, method: 'textDocument/diagnostic', params }));
    }
  }

  function handleClientMessage(msg) {
    if (!msg) return;
    log('CLIENT MSG: ' + msg.method + ' id: ' + msg.id);

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
      log('Resolved rootDir: ' + rootDir);

      if (rootDir) {
        setupWatcher(rootDir, (eventType, fullPath) => {
          log(`File change detected: ${eventType} ${fullPath}`);
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
              log(`Error parsing entry ${fullPath}: ${e.message}`);
            }
          }
        });
      }

      let initOptions;
      try {
        initOptions = indexer.buildInitOptions(installedDir, rootDir || '');
        log('Successfully built init options. Docs: ' + initOptions.documentItems.length + ' Entries: ' + initOptions.entryItems.length);
      } catch (err) {
        log('indexer.buildInitOptions failed: ' + err.message + '\n' + err.stack);
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
      openDocs.set(td.uri, { languageId: td.languageId, version: td.version, previousResultId: null });
    }
    if (msg.method === 'textDocument/didClose' && msg.params?.textDocument) {
      openDocs.delete(msg.params.textDocument.uri);
    }

    // textDocument/diagnostic: pass through to server.
    // The server registers a pull-based diagnostic provider (Ve class) when
    // diagnosticCapability is present in initializationOptions, so it handles
    // this natively. Do NOT short-circuit with an empty response here.
    // Track which URIs the editor is pulling itself so we don't double-relay.
    if (msg.method === 'textDocument/diagnostic' && msg.params?.textDocument?.uri) {
      editorPulledUris.add(msg.params.textDocument.uri);
    }

    if (msg.method === 'textDocument/inlayHint') {
      log(`Ignoring textDocument/inlayHint to prevent server crash`);
      if (msg.id) {
          process.stdout.write(encodeLspMessage({ jsonrpc: '2.0', id: msg.id, result: null }));
      }
      return;
    }

    // Custom MLua methods
    if (msg.method === 'mlua/reloadWorkspace') {
      log('Got custom mlua/reloadWorkspace request');
      try {
        const rootDir = msg.params?.rootDir || opts.currentRootDir || '';
        const initOptions = indexer.buildInitOptions(installedDir, rootDir);
        for (const doc of initOptions.documentItems) {
          child.stdin.write(encodeLspMessage({ jsonrpc: '2.0', method: 'textDocument/didOpen', params: { textDocument: doc } }));
        }
        for (const entry of initOptions.entryItems) {
          child.stdin.write(encodeLspMessage({ jsonrpc: '2.0', method: 'msw.protocol.entryChanged', params: { entryItem: entry } }));
        }
        child.stdin.write(encodeLspMessage({ jsonrpc: '2.0', method: 'msw.protocol.refreshDiagnostic', params: {} }));
        child.stdin.write(encodeLspMessage({ jsonrpc: '2.0', method: 'msw.protocol.refreshSemanticTokens', params: {} }));
      } catch (err) {
        log('mlua/reloadWorkspace failed: ' + err.message);
      }
      return;
    }

    child.stdin.write(encodeLspMessage(msg));
  }

  function handleServerMessage(msg) {
    if (!msg) return;
    log('SERVER MSG: ' + (msg.method || 'id:' + msg.id));

    // Responses to proxy-initiated diagnostic pulls: relay to editor as a
    // textDocument/publishDiagnostics notification so any editor gets them,
    // and update previousResultId for incremental pulls.
    if (msg.id !== undefined && proxyDiagIds.has(msg.id)) {
      const uri = proxyDiagIds.get(msg.id);
      proxyDiagIds.delete(msg.id);
      const result = msg.result;
      if (result) {
        // Update previousResultId for next incremental pull.
        if (result.resultId && openDocs.has(uri)) {
          openDocs.get(uri).previousResultId = result.resultId;
        }
        // Relay as publishDiagnostics so editors without pull support also benefit.
        // Skip if the editor already issued its own pull for this URI — it will
        // receive the result directly, so relaying would cause duplicates.
        if (result.kind === 'full' && Array.isArray(result.items) && !editorPulledUris.has(uri)) {
          log('Proxy relaying diagnostics for ' + uri + ' (' + result.items.length + ' items)');
          process.stdout.write(encodeLspMessage({
            jsonrpc: '2.0',
            method: 'textDocument/publishDiagnostics',
            params: { uri, diagnostics: result.items },
          }));
        }
      }
      return;
    }

    // workspace/diagnostic/refresh is a server->client REQUEST (has id).
    // Neovim has no handler for it and replies with MethodNotFound, crashing
    // the server. Intercept: ack the server, then proxy-pull diagnostics for
    // all open documents so any editor gets fresh results without needing a
    // custom handler for this request type.
    if (msg.method === 'workspace/diagnostic/refresh' && msg.id !== undefined) {
      log('Intercepting workspace/diagnostic/refresh id:' + msg.id + ', proxy-pulling all open docs');
      child.stdin.write(encodeLspMessage({ jsonrpc: '2.0', id: msg.id, result: null }));
      sendProxyDiagnosticRequests();
      // Also forward as notification so editors with a handler can act on it.
      process.stdout.write(encodeLspMessage({ jsonrpc: '2.0', method: 'workspace/diagnostic/refresh' }));
      return;
    }

    // workspace/semanticTokens/refresh: same issue — Neovim may not handle it as a
    // request. Ack the server and forward as a notification.
    if (msg.method === 'workspace/semanticTokens/refresh' && msg.id !== undefined) {
      log('Intercepting workspace/semanticTokens/refresh request id:' + msg.id + ', acking server and forwarding as notification');
      child.stdin.write(encodeLspMessage({ jsonrpc: '2.0', id: msg.id, result: null }));
      process.stdout.write(encodeLspMessage({ jsonrpc: '2.0', method: 'workspace/semanticTokens/refresh' }));
      return;
    }

    // Server -> Client Translation (dead paths kept for safety)
    if (msg.method === 'msw.protocol.refreshDiagnostic') {
      log('Translating msw.protocol.refreshDiagnostic -> workspace/diagnostic/refresh notification');
      msg.method = 'workspace/diagnostic/refresh';
      delete msg.id;
    } else if (msg.method === 'msw.protocol.refreshSemanticTokens') {
      log('Translating msw.protocol.refreshSemanticTokens -> workspace/semanticTokens/refresh');
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
