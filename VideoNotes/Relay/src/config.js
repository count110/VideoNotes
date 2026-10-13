'use strict';

const path = require('node:path');

const BASE64URL_32_BYTE_PATTERN = /^[A-Za-z0-9_-]{43}$/;

function required(name, env = process.env) {
  const value = env[name]?.trim();
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function integer(name, fallback, { min, max }, env = process.env) {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  if (!/^\d+$/.test(raw)) {
    throw new Error(`${name} must be an integer`);
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new Error(`${name} must be between ${min} and ${max}`);
  }
  return value;
}

function parseOpenIds(value) {
  const ids = value
    .split(',')
    .map((id) => id.trim())
    .filter(Boolean);

  if (ids.length === 0) {
    throw new Error('FEISHU_BINDER_OPEN_IDS must contain at least one Open ID');
  }
  return [...new Set(ids)];
}

function assertKeyMaterial(name, value) {
  if (!BASE64URL_32_BYTE_PATTERN.test(value)) {
    throw new Error(`${name} must be a 32-byte base64url value (43 characters)`);
  }
  const bytes = Buffer.from(value, 'base64url');
  if (bytes.length !== 32) {
    throw new Error(`${name} must decode to exactly 32 bytes`);
  }
}

function loadConfig(env = process.env, cwd = process.cwd()) {
  const feishuAppId = required('FEISHU_APP_ID', env);
  if (!/^cli_[0-9a-fA-F]{16}$/.test(feishuAppId)) {
    throw new Error('FEISHU_APP_ID must look like cli_ followed by 16 hexadecimal characters');
  }

  const stateEncryptionKey = required('RELAY_STATE_ENCRYPTION_KEY', env);
  const adminToken = required('RELAY_ADMIN_TOKEN', env);
  assertKeyMaterial('RELAY_STATE_ENCRYPTION_KEY', stateEncryptionKey);
  assertKeyMaterial('RELAY_ADMIN_TOKEN', adminToken);

  const host = (env.RELAY_HOST || '127.0.0.1').trim();
  if (!['127.0.0.1', '::1', 'localhost'].includes(host)) {
    throw new Error('RELAY_HOST must be loopback. Put TLS/authenticated ingress in front of the relay.');
  }

  const domain = (env.FEISHU_DOMAIN || 'feishu').trim().toLowerCase();
  if (!['feishu', 'lark'].includes(domain)) {
    throw new Error('FEISHU_DOMAIN must be either feishu or lark');
  }

  const statePath = env.RELAY_STATE_FILE
    ? path.resolve(cwd, env.RELAY_STATE_FILE)
    : path.resolve(cwd, 'data/relay-state.enc.json');

  const pairingCodeTtlMs = integer(
    'RELAY_PAIRING_CODE_TTL_SECONDS',
    900,
    { min: 60, max: 3600 },
    env
  ) * 1000;
  const unboundClaimTtlMs = integer(
    'RELAY_UNBOUND_CLAIM_TTL_SECONDS',
    3600,
    { min: 60, max: 86_400 },
    env
  ) * 1000;
  if (unboundClaimTtlMs < pairingCodeTtlMs) {
    throw new Error(
      'RELAY_UNBOUND_CLAIM_TTL_SECONDS must be at least RELAY_PAIRING_CODE_TTL_SECONDS'
    );
  }

  return Object.freeze({
    host,
    port: integer('PORT', 8787, { min: 1, max: 65535 }, env),
    feishuAppId,
    feishuAppSecret: required('FEISHU_APP_SECRET', env),
    feishuDomain: domain,
    binderOpenIds: parseOpenIds(required('FEISHU_BINDER_OPEN_IDS', env)),
    stateEncryptionKey,
    adminToken,
    statePath,
    pairingCodeTtlMs,
    // A claim response can be lost, so a claimed code must survive briefly
    // for an idempotent client retry. It must not, however, leave a device
    // with no group binding in the encrypted state forever.
    unboundClaimTtlMs,
    commandTtlMs: integer('RELAY_COMMAND_TTL_SECONDS', 600, { min: 60, max: 3600 }, env) * 1000,
    commandLeaseMs: integer('RELAY_COMMAND_LEASE_SECONDS', 60, { min: 10, max: 300 }, env) * 1000,
    maxPendingCommands: integer('RELAY_MAX_PENDING_COMMANDS', 3, { min: 1, max: 10 }, env),
    bindingRateLimitWindowMs: integer(
      'RELAY_BIND_RATE_WINDOW_SECONDS',
      600,
      { min: 60, max: 3_600 },
      env
    ) * 1000,
    bindingRateLimitMax: integer('RELAY_BIND_ATTEMPTS_PER_WINDOW', 5, { min: 1, max: 30 }, env),
    commandRateLimitWindowMs: integer(
      'RELAY_COMMAND_RATE_WINDOW_SECONDS',
      60,
      { min: 10, max: 3_600 },
      env
    ) * 1000,
    commandRateLimitMax: integer('RELAY_COMMANDS_PER_WINDOW', 6, { min: 1, max: 60 }, env),
    httpRateLimitWindowMs: integer(
      'RELAY_HTTP_RATE_WINDOW_SECONDS',
      600,
      { min: 60, max: 3_600 },
      env
    ) * 1000,
    httpPairingClaimRateLimitMax: integer(
      'RELAY_HTTP_PAIRING_CLAIMS_PER_WINDOW',
      20,
      { min: 1, max: 200 },
      env
    ),
    httpAdminPairingRateLimitMax: integer(
      'RELAY_HTTP_ADMIN_PAIRINGS_PER_WINDOW',
      20,
      { min: 1, max: 200 },
      env
    ),
    rateLimitMaxKeys: integer('RELAY_RATE_LIMIT_MAX_KEYS', 5_000, { min: 100, max: 50_000 }, env),
    revokedTokenRetentionMs: 7 * 24 * 60 * 60 * 1000,
  });
}

module.exports = {
  BASE64URL_32_BYTE_PATTERN,
  loadConfig,
};
