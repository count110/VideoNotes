'use strict';

const crypto = require('node:crypto');
const http = require('node:http');
const test = require('node:test');
const assert = require('node:assert/strict');
const { createHttpServer } = require('../src/http-server');
const { RelayService } = require('../src/relay-service');
const { StateStore } = require('../src/state-store');

function key() { return crypto.randomBytes(32).toString('base64url'); }

async function fixture() {
  const config = {
    adminToken: key(), pairingCodeTtlMs: 900_000, commandTtlMs: 600_000,
    commandLeaseMs: 60_000, maxPendingCommands: 3, binderOpenIds: ['ou_admin'],
    revokedTokenRetentionMs: 604_800_000, bindingRateLimitWindowMs: 600_000,
    bindingRateLimitMax: 5, commandRateLimitWindowMs: 60_000, commandRateLimitMax: 6,
    rateLimitMaxKeys: 100, httpRateLimitWindowMs: 600_000,
    httpPairingClaimRateLimitMax: 20, httpAdminPairingRateLimitMax: 20,
  };
  const statePath = `${require('node:os').tmpdir()}/videonotes-http-test-${crypto.randomUUID()}.json`;
  const store = new StateStore({ filePath: statePath, encryptionKey: key() });
  const relay = new RelayService({ store, config, logger: { error() {}, warn() {}, info() {} } });
  await relay.start();
  const server = createHttpServer({ relay, logger: { error() {} } });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { config, server, baseURL: `http://127.0.0.1:${server.address().port}` };
}

function request(baseURL, path, { method = 'GET', headers = {}, body } = {}) {
  const url = new URL(path, baseURL);
  return new Promise((resolve, reject) => {
    const req = http.request(url, { method, headers }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

test('HTTP returns safe errors for unauthorized, bad-path and malformed JSON requests', async (t) => {
  const { server, baseURL } = await fixture();
  t.after(() => new Promise((resolve) => server.close(resolve)));
  let response = await request(baseURL, '/v1/admin/pairing-codes', { method: 'POST' });
  assert.equal(response.status, 401);
  response = await request(baseURL, '/v1/%ZZ');
  assert.equal(response.status, 400);
  assert.match(response.body, /invalid_path/);
  response = await request(baseURL, '/v1/pairing/claim', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{bad',
  });
  assert.equal(response.status, 400);
  assert.match(response.body, /invalid_json/);
});

test('HTTP emits 204 for an empty command poll and handles 413 without poisoning later requests', async (t) => {
  const { config, server, baseURL } = await fixture();
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const adminHeaders = { Authorization: `Bearer ${config.adminToken}`, 'Content-Type': 'application/json' };
  const pairingResponse = await request(baseURL, '/v1/admin/pairing-codes', { method: 'POST', headers: adminHeaders, body: '{}' });
  assert.equal(pairingResponse.status, 201);
  const code = JSON.parse(pairingResponse.body).code;
  const deviceToken = key();
  const claim = await request(baseURL, '/v1/pairing/claim', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ code, installation_id: `install_${crypto.randomUUID()}`, device_name: 'Mac', device_token: deviceToken }),
  });
  assert.equal(claim.status, 201);
  const deviceID = JSON.parse(claim.body).device_id;
  const poll = await request(baseURL, `/v1/devices/${deviceID}/commands?wait_seconds=0`, {
    headers: { Authorization: `Bearer ${deviceToken}` },
  });
  assert.equal(poll.status, 204);

  // A declared oversized body is rejected before allocating it. The next
  // normal request proves the relay remains healthy after the 413 boundary.
  const oversized = await request(baseURL, '/v1/pairing/claim', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: 'x'.repeat(65 * 1024),
  }).catch((error) => ({ error }));
  // Node may reset the connection after request.destroy(); both outcomes are
  // safe. The subsequent status request is the observable server invariant.
  if (!oversized.error) assert.equal(oversized.status, 413);
  const status = await request(baseURL, `/v1/devices/${deviceID}`, { headers: { Authorization: `Bearer ${deviceToken}` } });
  assert.equal(status.status, 200);
});
