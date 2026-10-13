'use strict';

const http = require('node:http');
const { RelayError } = require('./relay-service');
const { SlidingWindowRateLimiter } = require('./rate-limiter');

const JSON_LIMIT_BYTES = 64 * 1024;

function json(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
  });
  response.end(body);
}

function noContent(response) {
  response.writeHead(204, {
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
  });
  response.end();
}

function errorBody(error) {
  if (error instanceof RelayError) {
    return { status: error.status, body: { error: error.code, message: error.message } };
  }
  if (error?.code === 'ENTITY_TOO_LARGE') {
    return { status: 413, body: { error: 'request_too_large', message: 'Request body is too large' } };
  }
  if (error?.code === 'INVALID_JSON') {
    return { status: 400, body: { error: 'invalid_json', message: 'Request body must be valid JSON' } };
  }
  return { status: 500, body: { error: 'internal_error', message: 'Internal server error' } };
}

async function readJson(request) {
  const contentType = request.headers['content-type'] || '';
  if (!contentType.toLowerCase().startsWith('application/json')) {
    throw new RelayError(415, 'unsupported_media_type', 'Content-Type must be application/json');
  }
  let total = 0;
  const chunks = [];
  for await (const chunk of request) {
    total += chunk.length;
    if (total > JSON_LIMIT_BYTES) {
      const error = new Error('too large');
      error.code = 'ENTITY_TOO_LARGE';
      // Stop consuming a potentially unbounded body before returning the
      // error. The caller will turn this into a compact 413 response; Node
      // may then close the keep-alive connection, which is intentional.
      request.destroy();
      throw error;
    }
    chunks.push(chunk);
  }
  try {
    const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('object required');
    }
    return parsed;
  } catch (cause) {
    if (cause.code === 'ENTITY_TOO_LARGE') throw cause;
    const error = new Error('invalid JSON');
    error.code = 'INVALID_JSON';
    throw error;
  }
}

function bearerToken(request) {
  const header = request.headers.authorization;
  if (typeof header !== 'string') return null;
  const match = /^Bearer ([A-Za-z0-9_-]{20,256})$/.exec(header);
  return match?.[1] || null;
}

function requireAdmin(request, relay) {
  const token = bearerToken(request);
  if (!token || !relay.isAdminToken(token)) {
    throw new RelayError(401, 'unauthorized_admin', 'Administrator authentication failed');
  }
}

function requireDeviceToken(request) {
  const token = bearerToken(request);
  if (!token) throw new RelayError(401, 'unauthorized_device', 'Device authentication failed');
  return token;
}

function secondsFromQuery(url) {
  const raw = url.searchParams.get('wait_seconds');
  if (raw === null) return 25;
  if (!/^\d+$/.test(raw)) {
    throw new RelayError(400, 'invalid_request', 'wait_seconds must be an integer from 0 to 25');
  }
  const seconds = Number(raw);
  if (!Number.isInteger(seconds) || seconds < 0 || seconds > 25) {
    throw new RelayError(400, 'invalid_request', 'wait_seconds must be an integer from 0 to 25');
  }
  return seconds;
}

function pathParts(url) {
  try {
    return url.pathname.split('/').filter(Boolean).map((part) => decodeURIComponent(part));
  } catch {
    throw new RelayError(400, 'invalid_path', 'Path contains an invalid percent escape');
  }
}

function clientAddress(request) {
  // This listener is intentionally loopback-only. A public reverse proxy must
  // rate-limit real client IPs itself; accepting X-Forwarded-For here would
  // let an untrusted direct caller forge a limiter key.
  return request.socket.remoteAddress || 'unknown';
}

function methodNotAllowed(response) {
  json(response, 405, { error: 'method_not_allowed', message: 'Method not allowed' });
}

function createHttpServer({ relay, logger = console }) {
  const config = relay.config || {};
  const windowMs = config.httpRateLimitWindowMs || 10 * 60 * 1000;
  const maxKeys = config.rateLimitMaxKeys || 5_000;
  const pairingClaimLimiter = new SlidingWindowRateLimiter({
    windowMs,
    maxEvents: config.httpPairingClaimRateLimitMax || 20,
    maxKeys,
  });
  const adminPairingLimiter = new SlidingWindowRateLimiter({
    windowMs,
    maxEvents: config.httpAdminPairingRateLimitMax || 20,
    maxKeys,
  });
  return http.createServer(async (request, response) => {
    try {
      const url = new URL(request.url, 'http://localhost');
      const parts = pathParts(url);

      if (request.method === 'GET' && url.pathname === '/healthz') {
        json(response, 200, relay.health());
        return;
      }

      if (parts[0] !== 'v1') {
        json(response, 404, { error: 'not_found', message: 'Route not found' });
        return;
      }

      if (parts[1] === 'admin' && parts[2] === 'pairing-codes' && parts.length === 3) {
        if (request.method !== 'POST') return methodNotAllowed(response);
        requireAdmin(request, relay);
        if (!adminPairingLimiter.consume(clientAddress(request))) {
          throw new RelayError(429, 'rate_limited', 'Too many pairing-code requests; try again later');
        }
        const pairing = await relay.createPairingCode(await readJson(request));
        json(response, 201, pairing);
        return;
      }

      if (parts[1] === 'pairing' && parts[2] === 'claim' && parts.length === 3) {
        if (request.method !== 'POST') return methodNotAllowed(response);
        if (!pairingClaimLimiter.consume(clientAddress(request))) {
          throw new RelayError(429, 'rate_limited', 'Too many pairing attempts; try again later');
        }
        const device = await relay.claimPairing(await readJson(request));
        json(response, 201, device);
        return;
      }

      if (parts[1] === 'devices' && parts.length >= 3) {
        const deviceId = parts[2];
        const token = requireDeviceToken(request);
        if (parts.length === 3) {
          if (request.method === 'GET') {
            json(response, 200, await relay.deviceStatus(deviceId, token));
            return;
          }
          if (request.method === 'DELETE') {
            await relay.revokeDevice(deviceId, token);
            noContent(response);
            return;
          }
          return methodNotAllowed(response);
        }
        if (parts[3] === 'heartbeat' && parts.length === 4) {
          if (request.method !== 'POST') return methodNotAllowed(response);
          // Explicitly consume JSON to keep client request semantics uniform.
          await readJson(request);
          json(response, 200, await relay.heartbeat(deviceId, token));
          return;
        }
        if (parts[3] === 'commands' && parts.length === 4) {
          if (request.method !== 'GET') return methodNotAllowed(response);
          const command = await relay.nextCommand(deviceId, token, secondsFromQuery(url) * 1000);
          if (command === null) {
            noContent(response);
          } else {
            json(response, 200, { command });
          }
          return;
        }
        if (parts[3] === 'commands' && parts.length === 5) {
          const commandId = parts[4];
          if (request.method === 'GET') {
            json(response, 200, await relay.commandStatus(deviceId, token, commandId));
            return;
          }
          return methodNotAllowed(response);
        }
        if (parts[3] === 'commands' && parts[5] === 'result' && parts.length === 6) {
          if (request.method !== 'POST') return methodNotAllowed(response);
          const outcome = await relay.completeCommand(deviceId, token, parts[4], await readJson(request));
          json(response, 200, outcome);
          return;
        }
      }

      json(response, 404, { error: 'not_found', message: 'Route not found' });
    } catch (error) {
      const { status, body } = errorBody(error);
      if (status >= 500) {
        // Deliberately omit request bodies, authorization headers, pairing
        // codes, device tokens and review content from the log.
        logger.error?.(`Relay HTTP request failed: ${error.message}`);
      }
      if (!response.headersSent) json(response, status, body);
      else response.destroy();
    }
  });
}

module.exports = {
  createHttpServer,
  pathParts,
  readJson,
};
