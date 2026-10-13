'use strict';

const crypto = require('node:crypto');
const test = require('node:test');
const assert = require('node:assert/strict');
const { RelayError, RelayService } = require('../src/relay-service');
const { StateStore } = require('../src/state-store');

function key() {
  return crypto.randomBytes(32).toString('base64url');
}

function token() {
  return crypto.randomBytes(32).toString('base64url');
}

function makeConfig(overrides = {}) {
  return {
    adminToken: key(),
    pairingCodeTtlMs: 900_000,
    unboundClaimTtlMs: 3_600_000,
    commandTtlMs: 600_000,
    commandLeaseMs: 60_000,
    maxPendingCommands: 3,
    revokedTokenRetentionMs: 7 * 24 * 60 * 60 * 1000,
    binderOpenIds: ['ou_admin'],
    bindingRateLimitWindowMs: 600_000,
    bindingRateLimitMax: 5,
    commandRateLimitWindowMs: 60_000,
    commandRateLimitMax: 6,
    rateLimitMaxKeys: 100,
    ...overrides,
  };
}

async function relayFixture({ clock = () => Date.now(), config = makeConfig() } = {}) {
  const path = `${require('node:os').tmpdir()}/videonotes-relay-test-${crypto.randomUUID()}.json`;
  const encryptionKey = key();
  const store = new StateStore({ filePath: path, encryptionKey, clock });
  const relay = new RelayService({ store, config, clock, logger: { warn() {}, info() {}, error() {} } });
  await relay.start();
  return { relay, store, config, path, encryptionKey };
}

async function pair(relay, name = 'VideoNotes Mac') {
  const pairing = await relay.createPairingCode();
  const deviceToken = token();
  const response = await relay.claimPairing({
    code: pairing.code,
    installation_id: `install_${crypto.randomUUID()}`,
    device_name: name,
    device_token: deviceToken,
  });
  return { pairing, deviceToken, response };
}

async function bindAndComplete(relay, device, {
  chatId = 'oc_group',
  messageId = 'om_command',
  replyText = 'private review text',
} = {}) {
  await relay.handleFeishuMessage({
    chatId,
    messageId: `bind_${messageId}`,
    senderOpenId: 'ou_admin',
    text: `绑定 ${device.pairing.code}`,
  });
  await relay.handleFeishuMessage({
    chatId,
    messageId,
    senderOpenId: 'ou_admin',
    text: '复盘今天',
  });
  const command = await relay.nextCommand(device.response.device_id, device.deviceToken, 0);
  await relay.completeCommand(device.response.device_id, device.deviceToken, command.id, {
    status: 'succeeded',
    reply_text: replyText,
  });
  return command;
}

async function waitFor(predicate, timeoutMs = 1_000) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('Timed out waiting for test condition');
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

test('claimed pairing retry remains safe after pairing-code expiry', async () => {
  let now = Date.now();
  const { relay } = await relayFixture({ clock: () => now, config: makeConfig({ pairingCodeTtlMs: 60_000 }) });
  const pairing = await relay.createPairingCode();
  const deviceToken = token();
  const input = {
    code: pairing.code,
    installation_id: `install_${crypto.randomUUID()}`,
    device_name: 'VideoNotes Mac',
    device_token: deviceToken,
  };
  const first = await relay.claimPairing(input);
  now += 61_000;
  const retry = await relay.claimPairing(input);
  assert.equal(retry.device_id, first.device_id);
  assert.equal(retry.binding_command, undefined);
});

test('unbound claimed devices expire after their retry grace period', async () => {
  let now = Date.now();
  const { relay, store } = await relayFixture({
    clock: () => now,
    config: makeConfig({
      pairingCodeTtlMs: 60_000,
      unboundClaimTtlMs: 120_000,
    }),
  });
  const pairing = await relay.createPairingCode();
  const deviceToken = token();
  const input = {
    code: pairing.code,
    installation_id: `install_${crypto.randomUUID()}`,
    device_name: 'VideoNotes Mac',
    device_token: deviceToken,
  };
  const first = await relay.claimPairing(input);

  // The original code may already have expired, but a lost claim response
  // still has a bounded window in which the exact same request can recover.
  now += 61_000;
  assert.equal(
    (await relay.deviceStatus(first.device_id, deviceToken)).binding.status,
    'pairing_expired'
  );
  assert.equal((await relay.claimPairing(input)).device_id, first.device_id);

  now += 60_000;
  await relay.createPairingCode(); // triggers durable state pruning
  const state = store.snapshot();
  assert.equal(state.devices[first.device_id], undefined);
  assert.equal(
    Object.values(state.pairingCodes).some((record) => record.deviceId === first.device_id),
    false
  );
  await assert.rejects(
    relay.claimPairing(input),
    (error) => error instanceof RelayError && error.code === 'pairing_not_found'
  );
});

test('one group can bind only one device and only its binding owner can command', async () => {
  const { relay } = await relayFixture();
  const first = await pair(relay, 'First Mac');
  const second = await pair(relay, 'Second Mac');
  assert.match(await relay.handleFeishuMessage({
    chatId: 'oc_group', messageId: 'om_bind_one', senderOpenId: 'ou_admin', text: `绑定 ${first.pairing.code}`,
  }), /安全绑定/);
  assert.match(await relay.handleFeishuMessage({
    chatId: 'oc_group', messageId: 'om_bind_two', senderOpenId: 'ou_admin', text: `绑定 ${second.pairing.code}`,
  }), /已绑定另一台/);
  assert.match(await relay.handleFeishuMessage({
    chatId: 'oc_group', messageId: 'om_wrong_owner', senderOpenId: 'ou_other', text: '当前视频',
  }), /尚未与 VideoNotes 配对/);
  assert.match(await relay.handleFeishuMessage({
    chatId: 'oc_group', messageId: 'om_command', senderOpenId: 'ou_admin', text: '当前视频',
  }), /已发送/);
  const command = await relay.nextCommand(first.response.device_id, first.deviceToken, 0);
  assert.equal(command.type, 'generate_current_video_review');
});

test('duplicate Feishu message does not consume command quota', async () => {
  const { relay } = await relayFixture({ config: makeConfig({ commandRateLimitMax: 1 }) });
  const device = await pair(relay);
  await relay.handleFeishuMessage({
    chatId: 'oc_group', messageId: 'om_bind', senderOpenId: 'ou_admin', text: `绑定 ${device.pairing.code}`,
  });
  const first = await relay.handleFeishuMessage({
    chatId: 'oc_group', messageId: 'om_same', senderOpenId: 'ou_admin', text: '当前视频',
  });
  const duplicate = await relay.handleFeishuMessage({
    chatId: 'oc_group', messageId: 'om_same', senderOpenId: 'ou_admin', text: '当前视频',
  });
  const tooFast = await relay.handleFeishuMessage({
    chatId: 'oc_group', messageId: 'om_next', senderOpenId: 'ou_admin', text: '当前视频',
  });
  assert.match(first, /已发送/);
  assert.equal(duplicate, null);
  assert.match(tooFast, /过于频繁/);
});

test('binding attempt rate limit and command result idempotency are enforced', async () => {
  const { relay } = await relayFixture({ config: makeConfig({ bindingRateLimitMax: 1 }) });
  const device = await pair(relay);
  assert.match(await relay.handleFeishuMessage({
    chatId: 'oc_group', messageId: 'om_bad_bind', senderOpenId: 'ou_admin', text: '绑定 ABCDEFGHIJKL',
  }), /无法完成绑定/);
  assert.match(await relay.handleFeishuMessage({
    chatId: 'oc_group', messageId: 'om_good_bind', senderOpenId: 'ou_admin', text: `绑定 ${device.pairing.code}`,
  }), /过于频繁/);

  // Use a fresh fixture for result delivery; the prior one deliberately never
  // bound because its quota was exhausted by an invalid attempt.
  const fresh = await relayFixture();
  const paired = await pair(fresh.relay);
  await fresh.relay.handleFeishuMessage({ chatId: 'oc_group', messageId: 'om_bind', senderOpenId: 'ou_admin', text: `绑定 ${paired.pairing.code}` });
  await fresh.relay.handleFeishuMessage({ chatId: 'oc_group', messageId: 'om_cmd', senderOpenId: 'ou_admin', text: '复盘今天' });
  const command = await fresh.relay.nextCommand(paired.response.device_id, paired.deviceToken, 0);
  assert.deepEqual(
    await fresh.relay.completeCommand(paired.response.device_id, paired.deviceToken, command.id, { status: 'succeeded', reply_text: 'done' }),
    { ok: true, already_completed: false }
  );
  assert.deepEqual(
    await fresh.relay.completeCommand(paired.response.device_id, paired.deviceToken, command.id, { status: 'succeeded', reply_text: 'done' }),
    { ok: true, already_completed: true }
  );
  await assert.rejects(
    fresh.relay.completeCommand(paired.response.device_id, paired.deviceToken, command.id, { status: 'succeeded', reply_text: 'different' }),
    (error) => error instanceof RelayError && error.code === 'command_result_conflict'
  );
});

test('completed reply delivery resumes when the bot is attached after a restart', async () => {
  const original = await relayFixture();
  const device = await pair(original.relay);
  const command = await bindAndComplete(original.relay, device, { replyText: 'restored review' });

  const restartedStore = new StateStore({
    filePath: original.path,
    encryptionKey: original.encryptionKey,
  });
  const restartedRelay = new RelayService({
    store: restartedStore,
    config: original.config,
    logger: { warn() {}, info() {}, error() {} },
  });
  await restartedRelay.start();
  const delivered = [];
  restartedRelay.setBot({
    async replyText(payload) { delivered.push(payload); },
  });

  await waitFor(() => delivered.length === 1);
  assert.equal(delivered[0].text, 'restored review');
  assert.equal(delivered[0].idempotencyKey, command.id);
  assert.equal(restartedStore.snapshot().commands[command.id].replyDelivery.state, 'sent');
});

test('revoking a device cancels queued replies, erases review text and claimed pairing metadata', async () => {
  const { relay, store } = await relayFixture();
  const device = await pair(relay);
  const command = await bindAndComplete(relay, device);
  const delivered = [];
  relay.setBot({
    async replyText(payload) { delivered.push(payload); },
  });

  assert.deepEqual(
    await relay.revokeDevice(device.response.device_id, device.deviceToken),
    { revoked: true }
  );
  await relay.recoverPendingDeliveries();
  await new Promise((resolve) => setTimeout(resolve, 150));

  const state = store.snapshot();
  assert.equal(delivered.length, 0);
  assert.equal(state.devices[device.response.device_id], undefined);
  assert.equal(
    Object.values(state.pairingCodes).some((pairing) => pairing.deviceId === device.response.device_id),
    false
  );
  assert.deepEqual(state.commands[command.id].result, { status: 'succeeded' });
  assert.equal(state.commands[command.id].replyDelivery.state, 'cancelled');
});

test('revocation during an in-flight Feishu request keeps delivery cancelled and never retries it', async () => {
  const { relay, store } = await relayFixture();
  const device = await pair(relay);
  const command = await bindAndComplete(relay, device, { replyText: 'in-flight review' });
  let releaseReply;
  const replyStarted = new Promise((resolve) => {
    releaseReply = resolve;
  });
  let replyCalls = 0;
  let markStarted;
  const started = new Promise((resolve) => { markStarted = resolve; });
  relay.setBot({
    async replyText() {
      replyCalls += 1;
      markStarted();
      await replyStarted;
    },
  });

  await started;
  await relay.revokeDevice(device.response.device_id, device.deviceToken);
  releaseReply();
  await waitFor(() => store.snapshot().commands[command.id].replyDelivery.state === 'cancelled');
  await new Promise((resolve) => setTimeout(resolve, 150));

  const stored = store.snapshot().commands[command.id];
  assert.equal(replyCalls, 1, 'an already-issued request cannot be recalled, but must not be retried');
  assert.equal(stored.replyDelivery.state, 'cancelled');
  assert.deepEqual(stored.result, { status: 'succeeded' });
});

test('StateStore continues accepting transactions after a rejected operation', async () => {
  const path = `${require('node:os').tmpdir()}/videonotes-store-test-${crypto.randomUUID()}.json`;
  const store = new StateStore({ filePath: path, encryptionKey: key() });
  await store.load();
  await assert.rejects(store.transaction(() => { throw new Error('expected'); }), /expected/);
  await store.transaction((state) => { state.devices.ok = { id: 'ok' }; });
  assert.equal(store.snapshot().devices.ok.id, 'ok');
});
