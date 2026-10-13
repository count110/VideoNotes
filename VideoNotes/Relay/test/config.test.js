'use strict';

const crypto = require('node:crypto');
const test = require('node:test');
const assert = require('node:assert/strict');
const { loadConfig } = require('../src/config');

function key() {
  return crypto.randomBytes(32).toString('base64url');
}

function environment(overrides = {}) {
  return {
    FEISHU_APP_ID: 'cli_0123456789abcdef',
    FEISHU_APP_SECRET: 'test-only-secret',
    FEISHU_BINDER_OPEN_IDS: 'ou_admin',
    RELAY_STATE_ENCRYPTION_KEY: key(),
    RELAY_ADMIN_TOKEN: key(),
    ...overrides,
  };
}

test('unbound claim retention has a safe default', () => {
  const config = loadConfig(environment(), '/tmp/videonotes-relay-config-test');
  assert.equal(config.pairingCodeTtlMs, 900_000);
  assert.equal(config.unboundClaimTtlMs, 3_600_000);
});

test('unbound claim retention cannot be shorter than the pairing code lifetime', () => {
  assert.throws(
    () => loadConfig(environment({
      RELAY_PAIRING_CODE_TTL_SECONDS: '900',
      RELAY_UNBOUND_CLAIM_TTL_SECONDS: '600',
    }), '/tmp/videonotes-relay-config-test'),
    /RELAY_UNBOUND_CLAIM_TTL_SECONDS must be at least RELAY_PAIRING_CODE_TTL_SECONDS/
  );
});
