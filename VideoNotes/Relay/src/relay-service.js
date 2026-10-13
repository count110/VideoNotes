'use strict';

const { EventEmitter } = require('node:events');
const {
  randomId,
  randomPairingCode,
  timingSafeEqualText,
  tokenHash,
} = require('./crypto');
const { COMMANDS, HELP_TEXT, parseCommand } = require('./command-parser');
const { SlidingWindowRateLimiter } = require('./rate-limiter');

const DEVICE_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const INSTALLATION_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/;
const NAME_MAX_LENGTH = 120;
const REPLY_MAX_CODEPOINTS = 12_000;

class RelayError extends Error {
  constructor(status, code, message) {
    super(message || code);
    this.name = 'RelayError';
    this.status = status;
    this.code = code;
  }
}

function iso(ms) {
  return new Date(ms).toISOString();
}

function shortText(value, field, { min = 1, max = NAME_MAX_LENGTH } = {}) {
  if (typeof value !== 'string') throw new RelayError(400, 'invalid_request', `${field} must be a string`);
  const normalized = value.trim();
  if ([...normalized].length < min || [...normalized].length > max) {
    throw new RelayError(400, 'invalid_request', `${field} length is invalid`);
  }
  return normalized;
}

function optionalShortText(value, field, max = NAME_MAX_LENGTH) {
  if (value === undefined || value === null || value === '') return undefined;
  return shortText(value, field, { max });
}

function assertDeviceToken(token) {
  if (typeof token !== 'string' || !DEVICE_TOKEN_PATTERN.test(token)) {
    throw new RelayError(400, 'invalid_device_token', 'device_token must be a 32-byte base64url token');
  }
  return token;
}

function safeCommand(command) {
  return {
    id: command.id,
    type: command.type,
    requested_at: iso(command.requestedAt),
    expires_at: iso(command.expiresAt),
  };
}

function safeCommandStatus(command) {
  const state = command.state === 'completed'
    ? 'completed'
    : command.state === 'expired'
      ? 'expired'
      : command.state === 'revoked'
        ? 'revoked'
        : command.state === 'leased'
          ? 'leased'
          : 'pending';
  const response = {
    id: command.id,
    type: command.type,
    state,
    requested_at: iso(command.requestedAt),
    expires_at: iso(command.expiresAt),
  };
  if (command.completedAt) {
    response.completed_at = iso(command.completedAt);
    response.result = { status: command.result.status };
  }
  return response;
}

class RelayService {
  constructor({ store, config, clock = () => Date.now(), logger = console }) {
    this.store = store;
    this.config = config;
    this.clock = clock;
    this.logger = logger;
    this.events = new EventEmitter();
    this.events.setMaxListeners(100);
    this.commandEpoch = 0;
    this.bot = null;
    this.deliveryTimers = new Map();
    this.bindingAttemptLimiter = new SlidingWindowRateLimiter({
      windowMs: config.bindingRateLimitWindowMs || 10 * 60 * 1000,
      maxEvents: config.bindingRateLimitMax || 5,
      maxKeys: config.rateLimitMaxKeys || 5_000,
    });
    this.commandLimiter = new SlidingWindowRateLimiter({
      windowMs: config.commandRateLimitWindowMs || 60 * 1000,
      maxEvents: config.commandRateLimitMax || 6,
      maxKeys: config.rateLimitMaxKeys || 5_000,
    });
  }

  setBot(bot) {
    this.bot = bot;
    // `start()` deliberately works without a bot so the durable HTTP queue can
    // be initialized independently. A restarted process therefore has to scan
    // again when the usable bot adapter is finally attached; the startup scan
    // may have happened while `this.bot` was still null.
    if (bot) void this.recoverPendingDeliveries();
  }

  async start() {
    await this.store.load();
    await this.store.transaction((state) => this.#prune(state, this.clock()));
    await this.recoverPendingDeliveries();
  }

  health() {
    return {
      ok: true,
      service: 'videonotes-feishu-relay',
      bot: this.bot?.health?.() || { connection: 'not_started' },
    };
  }

  isAdminToken(token) {
    return typeof token === 'string' && timingSafeEqualText(token, this.config.adminToken);
  }

  async createPairingCode(input = {}) {
    const deviceLabel = optionalShortText(input.device_label, 'device_label');
    let ttlMs = this.config.pairingCodeTtlMs;
    if (input.expires_in_seconds !== undefined) {
      const seconds = input.expires_in_seconds;
      if (!Number.isInteger(seconds) || seconds < 60 || seconds > 3600) {
        throw new RelayError(400, 'invalid_request', 'expires_in_seconds must be an integer from 60 to 3600');
      }
      ttlMs = seconds * 1000;
    }

    const now = this.clock();
    const code = randomPairingCode();
    const codeHash = tokenHash(code);
    const record = {
      id: randomId('pair'),
      codeHash,
      createdAt: now,
      expiresAt: now + ttlMs,
      deviceLabel: deviceLabel || null,
      claimedAt: null,
      deviceId: null,
    };
    await this.store.transaction((state) => {
      this.#prune(state, now);
      state.pairingCodes[codeHash] = record;
    });
    return {
      code,
      expires_at: iso(record.expiresAt),
      bind_command: `绑定 ${code}`,
    };
  }

  async claimPairing(input) {
    if (!input || typeof input !== 'object') {
      throw new RelayError(400, 'invalid_request', 'A JSON object is required');
    }
    const code = shortText(input.code, 'code', { min: 12, max: 64 }).toUpperCase();
    const installationId = shortText(input.installation_id, 'installation_id', { min: 8, max: 128 });
    if (!INSTALLATION_ID_PATTERN.test(installationId)) {
      throw new RelayError(400, 'invalid_request', 'installation_id has an invalid format');
    }
    const deviceName = shortText(input.device_name, 'device_name');
    const deviceToken = assertDeviceToken(input.device_token);
    const codeHash = tokenHash(code);
    const deviceTokenHash = tokenHash(deviceToken);
    const now = this.clock();

    return this.store.transaction((state) => {
      this.#prune(state, now);
      const pairing = state.pairingCodes[codeHash];
      if (!pairing) {
        throw new RelayError(404, 'pairing_not_found', 'Pairing code is invalid or expired');
      }

      if (pairing.deviceId) {
        const device = state.devices[pairing.deviceId];
        if (
          device
          && device.installationId === installationId
          && timingSafeEqualText(device.deviceTokenHash, deviceTokenHash)
        ) {
          return this.#claimedResponse(device);
        }
        throw new RelayError(409, 'pairing_already_claimed', 'Pairing code is already claimed');
      }
      if (pairing.expiresAt <= now) {
        throw new RelayError(404, 'pairing_not_found', 'Pairing code is invalid or expired');
      }

      const device = {
        id: randomId('dev'),
        installationId,
        name: deviceName,
        deviceTokenHash,
        createdAt: now,
        lastSeenAt: now,
        boundChatId: null,
        boundByOpenId: null,
        boundAt: null,
      };
      pairing.claimedAt = now;
      pairing.deviceId = device.id;
      state.devices[device.id] = device;
      return this.#claimedResponse(device);
    });
  }

  async deviceStatus(deviceId, deviceToken) {
    const device = await this.#authenticateDevice(deviceId, deviceToken, {
      touch: true,
      includeBindingStatus: true,
    });
    return {
      device_id: device.id,
      binding: { status: device.relayBindingStatus },
      last_seen_at: iso(device.lastSeenAt),
    };
  }

  async heartbeat(deviceId, deviceToken) {
    const device = await this.#authenticateDevice(deviceId, deviceToken, {
      touch: true,
      includeBindingStatus: true,
    });
    return {
      ok: true,
      device_id: device.id,
      binding: { status: device.relayBindingStatus },
    };
  }

  async revokeDevice(deviceId, deviceToken) {
    const validToken = assertDeviceToken(deviceToken);
    const hashedToken = tokenHash(validToken);
    const now = this.clock();
    const cancelledDeliveryIds = [];
    const result = await this.store.transaction((state) => {
      this.#prune(state, now);
      const device = state.devices[deviceId];
      if (device && timingSafeEqualText(device.deviceTokenHash, hashedToken)) {
        const revocation = {
          deviceTokenHash: device.deviceTokenHash,
          revokedAt: now,
          expiresAt: now + this.config.revokedTokenRetentionMs,
        };
        state.revokedDevices[deviceId] = revocation;
        delete state.devices[deviceId];
        for (const [codeHash, pairing] of Object.entries(state.pairingCodes)) {
          if (pairing.deviceId === deviceId) delete state.pairingCodes[codeHash];
        }
        for (const command of Object.values(state.commands)) {
          if (command.deviceId !== deviceId) continue;
          if (command.state !== 'completed') {
            command.state = 'revoked';
            command.leaseUntil = null;
            continue;
          }

          // A completed result may still contain private review text while it
          // waits for Feishu. Revocation is the authority boundary: cancel any
          // delivery that has not reached `sent`, and retain only non-content
          // status metadata for auditing. A request already handed to Feishu
          // cannot be retracted, but the delivery state guards below ensure it
          // is never retried after revocation.
          if (command.replyDelivery?.state !== 'sent') {
            command.replyDelivery = {
              ...(command.replyDelivery || {
                attempts: 0,
                lastAttemptAt: null,
                sentAt: null,
              }),
              state: 'cancelled',
              cancelledAt: now,
            };
            cancelledDeliveryIds.push(command.id);
          }
          if (command.result) {
            command.result = { status: command.result.status };
          }
        }
        return { revoked: true };
      }
      const revoked = state.revokedDevices[deviceId];
      if (revoked && timingSafeEqualText(revoked.deviceTokenHash, hashedToken)) {
        return { revoked: true, already: true };
      }
      throw new RelayError(401, 'unauthorized_device', 'Device authentication failed');
    });
    for (const commandId of cancelledDeliveryIds) {
      this.#cancelScheduledDelivery(commandId);
    }
    this.#wakeDevice(deviceId);
    return result;
  }

  async nextCommand(deviceId, deviceToken, waitMs) {
    await this.#authenticateDevice(deviceId, deviceToken, { touch: true });
    const deadline = this.clock() + waitMs;
    while (true) {
      const observedEpoch = this.commandEpoch;
      const command = await this.#claimNextCommand(deviceId);
      if (command) return safeCommand(command);
      const remaining = deadline - this.clock();
      if (remaining <= 0) return null;
      await this.#waitForDeviceWake(deviceId, observedEpoch, remaining);
      // The device may have been revoked while the request was waiting.
      await this.#authenticateDevice(deviceId, deviceToken, { touch: true });
    }
  }

  async commandStatus(deviceId, deviceToken, commandId) {
    await this.#authenticateDevice(deviceId, deviceToken, { touch: true });
    const now = this.clock();
    return this.store.transaction((state) => {
      this.#prune(state, now);
      const command = state.commands[commandId];
      if (!command || command.deviceId !== deviceId) {
        throw new RelayError(404, 'command_not_found', 'Command not found');
      }
      return { command: safeCommandStatus(command) };
    });
  }

  async completeCommand(deviceId, deviceToken, commandId, input) {
    if (!input || typeof input !== 'object') {
      throw new RelayError(400, 'invalid_request', 'A JSON object is required');
    }
    const status = input.status;
    if (status !== 'succeeded' && status !== 'failed') {
      throw new RelayError(400, 'invalid_request', 'status must be succeeded or failed');
    }
    if (typeof input.reply_text !== 'string' || [...input.reply_text].length > REPLY_MAX_CODEPOINTS) {
      throw new RelayError(400, 'invalid_request', `reply_text must contain at most ${REPLY_MAX_CODEPOINTS} characters`);
    }
    await this.#authenticateDevice(deviceId, deviceToken, { touch: true });
    const now = this.clock();
    const result = await this.store.transaction((state) => {
      this.#prune(state, now);
      const command = state.commands[commandId];
      if (!command || command.deviceId !== deviceId) {
        throw new RelayError(404, 'command_not_found', 'Command not found');
      }
      if (command.state === 'revoked' || command.state === 'expired') {
        throw new RelayError(409, 'command_inactive', 'Command is no longer active');
      }
      if (command.state === 'completed') {
        if (command.result.status === status && command.result.replyText === input.reply_text) {
          return { alreadyCompleted: true, command: structuredClone(command) };
        }
        throw new RelayError(409, 'command_result_conflict', 'A different result was already submitted');
      }
      command.state = 'completed';
      command.completedAt = now;
      command.leaseUntil = null;
      command.result = { status, replyText: input.reply_text };
      command.replyDelivery = {
        state: 'pending',
        attempts: 0,
        lastAttemptAt: null,
        sentAt: null,
      };
      return { alreadyCompleted: false, command: structuredClone(command) };
    });
    this.scheduleDelivery(commandId, 0);
    return { ok: true, already_completed: result.alreadyCompleted };
  }

  async handleFeishuMessage({ chatId, messageId, senderOpenId, text }) {
    const parsed = parseCommand(text);
    if (parsed.kind === 'help') return HELP_TEXT;
    if (parsed.kind === 'unknown') {
      return '暂不支持这条指令。发送「帮助」查看可用指令。';
    }

    if (parsed.kind === 'bind') {
      return this.#bindFromFeishu({ chatId, senderOpenId, code: parsed.code });
    }

    return this.#enqueueFromFeishu({ chatId, messageId, senderOpenId, type: parsed.type });
  }

  async recoverPendingDeliveries() {
    const state = this.store.snapshot();
    for (const command of Object.values(state.commands)) {
      if (
        command.state === 'completed'
        && ['pending', 'sending'].includes(command.replyDelivery?.state)
      ) {
        this.scheduleDelivery(command.id, 100);
      }
    }
  }

  scheduleDelivery(commandId, delayMs) {
    if (!this.bot || this.deliveryTimers.has(commandId)) return;
    const state = this.store.snapshot();
    const command = state.commands[commandId];
    const device = command ? state.devices[command.deviceId] : null;
    if (
      !command
      || command.state !== 'completed'
      || !['pending', 'sending'].includes(command.replyDelivery?.state)
      || !device
      || device.boundChatId !== command.sourceChatId
    ) {
      return;
    }
    const timer = setTimeout(() => {
      this.deliveryTimers.delete(commandId);
      void this.#deliverCompletedCommand(commandId);
    }, delayMs);
    timer.unref?.();
    this.deliveryTimers.set(commandId, timer);
  }

  async #deliverCompletedCommand(commandId) {
    if (!this.bot) return;
    const now = this.clock();
    const claim = await this.store.transaction((state) => {
      this.#prune(state, now);
      const stored = state.commands[commandId];
      if (
        !stored
        || stored.state !== 'completed'
        || !['pending', 'sending'].includes(stored.replyDelivery?.state)
      ) {
        return { command: null, retryAfterMs: null };
      }
      const device = state.devices[stored.deviceId];
      if (!device || device.boundChatId !== stored.sourceChatId) {
        stored.replyDelivery.state = 'cancelled';
        stored.replyDelivery.cancelledAt = now;
        if (stored.result) stored.result = { status: stored.result.status };
        return { command: null, retryAfterMs: null };
      }
      if (stored.replyDelivery.state === 'sending' && stored.replyDelivery.lastAttemptAt > now - 30_000) {
        return {
          command: null,
          retryAfterMs: Math.max(100, stored.replyDelivery.lastAttemptAt + 30_000 - now),
        };
      }
      stored.replyDelivery.state = 'sending';
      stored.replyDelivery.attempts += 1;
      stored.replyDelivery.lastAttemptAt = now;
      return { command: structuredClone(stored), retryAfterMs: null };
    });
    if (claim.retryAfterMs !== null) {
      this.scheduleDelivery(commandId, claim.retryAfterMs);
      return;
    }
    const command = claim.command;
    if (!command) return;

    try {
      await this.bot.replyText({
        messageId: command.sourceMessageId,
        text: command.result.replyText,
        idempotencyKey: command.id,
      });
      await this.store.transaction((state) => {
        const stored = state.commands[commandId];
        // Revocation can run while the outbound HTTP request is in flight. It
        // cannot recall that request, but it changes the state to `cancelled`;
        // preserve that terminal state here so no retry can leak the result.
        if (stored?.replyDelivery?.state === 'sending' && state.devices[stored.deviceId]) {
          stored.replyDelivery.state = 'sent';
          stored.replyDelivery.sentAt = this.clock();
        }
      });
    } catch (error) {
      // Do not include review text or token material in logs.
      this.logger.warn?.(`Feishu reply delivery failed for command ${commandId}: ${error.message}`);
      const shouldRetry = await this.store.transaction((state) => {
        const stored = state.commands[commandId];
        if (stored?.replyDelivery && stored.replyDelivery.state === 'sending') {
          stored.replyDelivery.state = 'pending';
          return Boolean(state.devices[stored.deviceId]);
        }
        return false;
      });
      const delay = Math.min(60_000, 2_000 * (2 ** Math.min(command.replyDelivery.attempts, 5)));
      if (shouldRetry) this.scheduleDelivery(commandId, delay);
    }
  }

  #cancelScheduledDelivery(commandId) {
    const timer = this.deliveryTimers.get(commandId);
    if (!timer) return;
    clearTimeout(timer);
    this.deliveryTimers.delete(commandId);
  }

  async #bindFromFeishu({ chatId, senderOpenId, code }) {
    if (!this.config.binderOpenIds.includes(senderOpenId)) {
      return '无法完成绑定。请由 VideoNotes 管理员在目标群中操作。';
    }
    const now = this.clock();
    const rateKey = `${chatId}:${senderOpenId}`;
    if (!this.bindingAttemptLimiter.consume(rateKey, now)) {
      return '绑定尝试过于频繁，请在稍后再试。';
    }
    const codeHash = tokenHash(code);
    const result = await this.store.transaction((state) => {
      this.#prune(state, now);
      const pairing = state.pairingCodes[codeHash];
      const device = pairing?.deviceId ? state.devices[pairing.deviceId] : null;
      if (!pairing || !device || pairing.expiresAt <= now) {
        return { ok: false };
      }
      if (device.boundChatId) {
        if (device.boundChatId === chatId && device.boundByOpenId === senderOpenId) {
          return { ok: true, already: true, name: device.name };
        }
        return { ok: false };
      }
      // A group is a one-device endpoint. Allow only the same device's
      // idempotent re-bind above; otherwise a `.find()` later could route a
      // review to an arbitrary Mac with the same group ID.
      const boundElsewhere = Object.values(state.devices).find((candidate) => (
        candidate.id !== device.id && candidate.boundChatId === chatId
      ));
      if (boundElsewhere) {
        return { ok: false, groupOccupied: true };
      }
      device.boundChatId = chatId;
      device.boundByOpenId = senderOpenId;
      device.boundAt = now;
      device.lastSeenAt = now;
      pairing.boundAt = now;
      return { ok: true, already: false, name: device.name };
    });
    if (!result.ok) {
      if (result.groupOccupied) {
        return '此群已绑定另一台 VideoNotes。请先在旧设备的设置中安全断开，再为这台设备重新配对。';
      }
      return '无法完成绑定。请确认配对码未过期、此设备尚未绑定，并由授权管理员在目标群中操作。';
    }
    this.#wakeDeviceForBoundChat(chatId);
    return result.already
      ? `VideoNotes「${result.name}」已绑定到此群。`
      : `已将 VideoNotes「${result.name}」安全绑定到此群。以后请 @我后使用「帮助」。`;
  }

  async #enqueueFromFeishu({ chatId, messageId, senderOpenId, type }) {
    if (!Object.values(COMMANDS).includes(type)) {
      throw new Error('Internal command whitelist violation');
    }
    const now = this.clock();
    const result = await this.store.transaction((state) => {
      this.#prune(state, now);
      const device = Object.values(state.devices).find((candidate) => (
        candidate.boundChatId === chatId && candidate.boundByOpenId === senderOpenId
      ));
      if (!device) return { ok: false };

      const duplicateId = state.messageIndex[messageId];
      if (duplicateId && state.commands[duplicateId]?.deviceId === device.id) {
        return { ok: true, duplicate: true, deviceId: device.id };
      }
      // Deduplication occurs before the rate check because a duplicated
      // Feishu delivery must never consume a user's command quota.
      if (!this.commandLimiter.consume(device.id, now)) {
        return { ok: false, rateLimited: true };
      }
      const pendingCount = Object.values(state.commands).filter((command) => (
        command.deviceId === device.id && ['pending', 'leased'].includes(command.state) && command.expiresAt > now
      )).length;
      if (pendingCount >= this.config.maxPendingCommands) {
        return { ok: false, busy: true };
      }
      const command = {
        id: randomId('cmd'),
        deviceId: device.id,
        type,
        sourceMessageId: messageId,
        sourceChatId: chatId,
        requestedAt: now,
        expiresAt: now + this.config.commandTtlMs,
        leaseUntil: null,
        deliveryCount: 0,
        state: 'pending',
        result: null,
        completedAt: null,
        replyDelivery: null,
      };
      state.commands[command.id] = command;
      state.messageIndex[messageId] = command.id;
      device.lastSeenAt = now;
      return { ok: true, duplicate: false, deviceId: device.id, commandId: command.id };
    });
    if (!result.ok) {
      if (result.rateLimited) {
        return '复盘指令过于频繁，请稍后再试。';
      }
      return result.busy
        ? '本机正在处理较多请求，请等待已有复盘完成后再试。'
        : '此群尚未与 VideoNotes 配对，或你不是完成绑定的管理员。';
    }
    if (result.duplicate) return null;
    this.#wakeDevice(result.deviceId);
    return '已发送到已配对的 VideoNotes。本机完成后会在这条消息下回复。';
  }

  async #claimNextCommand(deviceId) {
    const now = this.clock();
    return this.store.transaction((state) => {
      this.#prune(state, now);
      const candidates = Object.values(state.commands)
        .filter((command) => {
          if (command.deviceId !== deviceId || command.expiresAt <= now) return false;
          return command.state === 'pending' || (command.state === 'leased' && command.leaseUntil <= now);
        })
        .sort((left, right) => left.requestedAt - right.requestedAt);
      const command = candidates[0];
      if (!command) return null;
      command.state = 'leased';
      command.leaseUntil = now + this.config.commandLeaseMs;
      command.deliveryCount += 1;
      return structuredClone(command);
    });
  }

  async #authenticateDevice(deviceId, deviceToken, { touch, includeBindingStatus = false }) {
    const validToken = assertDeviceToken(deviceToken);
    const hashedToken = tokenHash(validToken);
    const now = this.clock();
    return this.store.transaction((state) => {
      this.#prune(state, now);
      const device = state.devices[deviceId];
      if (!device || !timingSafeEqualText(device.deviceTokenHash, hashedToken)) {
        const revoked = state.revokedDevices[deviceId];
        if (revoked && timingSafeEqualText(revoked.deviceTokenHash, hashedToken)) {
          throw new RelayError(401, 'device_revoked', 'Device has been revoked');
        }
        throw new RelayError(401, 'unauthorized_device', 'Device authentication failed');
      }
      if (touch) device.lastSeenAt = now;
      const authenticated = structuredClone(device);
      if (includeBindingStatus) {
        authenticated.relayBindingStatus = this.#bindingStatusForDevice(state, device, now);
      }
      return authenticated;
    });
  }

  #bindingStatusForDevice(state, device, now) {
    if (device.boundChatId) return 'bound';
    const pairing = Object.values(state.pairingCodes).find((candidate) => (
      candidate.deviceId === device.id
    ));
    // A claimed code is intentionally still retryable after expiry if its
    // HTTP response was lost. It can no longer be used to bind a Feishu group,
    // though, so tell the already-paired client to request a fresh code
    // instead of indefinitely showing “awaiting group binding”.
    if (!pairing || pairing.expiresAt <= now) return 'pairing_expired';
    return 'awaiting_group_binding';
  }

  #claimedResponse(device) {
    return {
      device_id: device.id,
      binding_status: device.boundChatId ? 'bound' : 'awaiting_group_binding',
    };
  }

  #waitForDeviceWake(deviceId, observedEpoch, timeoutMs) {
    return new Promise((resolve) => {
      if (this.commandEpoch !== observedEpoch) {
        resolve();
        return;
      }
      const event = `device:${deviceId}`;
      const timer = setTimeout(finish, timeoutMs);
      timer.unref?.();
      const listener = finish;
      const globalListener = finish;
      const cleanup = () => {
        clearTimeout(timer);
        this.events.off(event, listener);
        this.events.off('all-devices', globalListener);
      };
      function finish() {
        cleanup();
        resolve();
      }
      this.events.once(event, listener);
      this.events.once('all-devices', globalListener);
      if (this.commandEpoch !== observedEpoch) finish();
    });
  }

  #wakeDevice(deviceId) {
    this.commandEpoch += 1;
    this.events.emit(`device:${deviceId}`);
  }

  #wakeDeviceForBoundChat(chatId) {
    const state = this.store.snapshot();
    for (const device of Object.values(state.devices)) {
      if (device.boundChatId === chatId) this.#wakeDevice(device.id);
    }
  }

  #prune(state, now) {
    // `loadConfig` always supplies this setting. Keep a safe default here too
    // so an older embedding/test configuration cannot accidentally turn an
    // orphan-cleanup guarantee into infinite retention.
    const configuredUnboundClaimTtlMs = this.config.unboundClaimTtlMs;
    const unboundClaimTtlMs = Math.max(
      this.config.pairingCodeTtlMs,
      Number.isSafeInteger(configuredUnboundClaimTtlMs) && configuredUnboundClaimTtlMs > 0
        ? configuredUnboundClaimTtlMs
        : 60 * 60 * 1000
    );
    for (const [hash, pairing] of Object.entries(state.pairingCodes)) {
      // Keep a claimed pairing long enough for an idempotent app retry after
      // a lost HTTP response. A client can also discard that local retry
      // tuple, however, so an unbound device must have a finite lifetime.
      if (!pairing.deviceId) {
        if (pairing.expiresAt <= now) delete state.pairingCodes[hash];
        continue;
      }

      const device = state.devices[pairing.deviceId];
      if (!device) {
        // Do not keep a dangling pairing record if an older state file was
        // interrupted between deleting a device and deleting its pairing.
        delete state.pairingCodes[hash];
        continue;
      }

      if (device.boundChatId) continue;

      // `claimedAt` was introduced with claimed pairings. For a malformed or
      // older state file, `expiresAt` is the conservative fallback: it never
      // removes a record before its original pairing code became invalid.
      const claimedAt = Number.isFinite(pairing.claimedAt)
        ? pairing.claimedAt
        : pairing.expiresAt;
      if (claimedAt + unboundClaimTtlMs <= now) {
        delete state.devices[device.id];
        delete state.pairingCodes[hash];
      }
    }
    for (const [id, revoked] of Object.entries(state.revokedDevices)) {
      if (revoked.expiresAt <= now) delete state.revokedDevices[id];
    }
    for (const [id, command] of Object.entries(state.commands)) {
      if (['pending', 'leased'].includes(command.state) && command.expiresAt <= now) {
        command.state = 'expired';
        command.leaseUntil = null;
      }
      const retentionMs = command.state === 'completed' ? 7 * 24 * 60 * 60 * 1000 : 24 * 60 * 60 * 1000;
      if (command.expiresAt + retentionMs <= now) {
        if (command.sourceMessageId) delete state.messageIndex[command.sourceMessageId];
        delete state.commands[id];
      }
    }
  }
}

module.exports = {
  DEVICE_TOKEN_PATTERN,
  RelayError,
  RelayService,
  REPLY_MAX_CODEPOINTS,
  safeCommand,
};
