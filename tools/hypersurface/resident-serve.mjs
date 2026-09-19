// Trusted experiment bootstrap for the RESIDENT checked-host: the guardian starts this once and it stays.
//   node resident-serve.mjs <resident.mjs> <socket path>
// The two positional arguments are the guardian's `host` and `input` slots (never a Super command payload); the
// socket path lives in the executor's private scratch directory, which the guardian removes on exit. Wire: 4-byte
// big-endian length + UTF-8 JSON, exactly residentd.mjs's (TRVM/runtime/wasm/resident): {id, term} → {id, ...result},
// {id, cancel: true} aborts job id of THIS connection, closing a connection aborts its in-flight jobs. Pool and queue
// come from the environment (RESIDENT_POOL, RESIDENT_MAX_QUEUE), not from any request.
import { createServer } from 'node:net';
import { unlinkSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { performance } from 'node:perf_hooks';

const { createResidentHost } = await import(pathToFileURL(process.argv[2]));
const sockPath = process.argv[3];
const pool = Number(process.env.RESIDENT_POOL ?? 4), maxQueue = Number(process.env.RESIDENT_MAX_QUEUE ?? 16);
const host = createResidentHost({ pool, maxQueue });
const MAX_FRAME = 1048576 + 4096;

const server = createServer(sock => {
  let buf = Buffer.alloc(0), draining = false;
  const inflight = new Map();
  const send = obj => { const out = Buffer.from(JSON.stringify(obj)); const len = Buffer.alloc(4); len.writeUInt32BE(out.length); sock.write(Buffer.concat([len, out])); };
  const handle = async req => {
    if (req?.op === 'stats') return send({ op: 'stats', ...host.stats(), module_sha256: host.digest });
    if (req?.cancel === true) { inflight.get(req.id)?.abort(); return; }
    if (typeof req?.term !== 'string' || req.id === undefined) return send({ id: req?.id ?? null, status: 'refused', reason: 'request-shape' });
    if (inflight.has(req.id)) return send({ id: req.id, status: 'refused', reason: 'duplicate-id' });
    const ac = new AbortController(); inflight.set(req.id, ac);
    const t0 = performance.now();
    let result;
    try { result = await host.reduce(req.term, { signal: ac.signal }); }
    finally { inflight.delete(req.id); }
    if (!sock.destroyed) send({ id: req.id, ...result, serverMs: +(performance.now() - t0).toFixed(3) });
  };
  const drain = () => {
    if (draining) return; draining = true;
    try {
      while (buf.length >= 4) {
        const n = buf.readUInt32BE(0);
        if (n > MAX_FRAME) { sock.destroy(); return; }
        if (buf.length < 4 + n) break;
        let req; try { req = JSON.parse(buf.subarray(4, 4 + n).toString('utf8')); } catch { req = null; }
        buf = buf.subarray(4 + n);
        handle(req).catch(() => {});
      }
    } finally { draining = false; }
  };
  sock.on('data', chunk => { buf = Buffer.concat([buf, chunk]); drain(); });
  sock.on('close', () => { for (const ac of inflight.values()) ac.abort(); inflight.clear(); });
  sock.on('error', () => {});
});

await host.ready();
try { unlinkSync(sockPath); } catch {}
server.listen(sockPath);
// stdout is collected by the guardian until exit; the executor learns readiness by connecting, not by reading this
const stop = async () => { server.close(); await host.close(); process.exit(0); };
process.on('SIGTERM', stop); process.on('SIGINT', stop);
