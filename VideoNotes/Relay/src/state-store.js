'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { decryptJson, encryptJson } = require('./crypto');

function emptyState() {
  return {
    version: 1,
    pairingCodes: {},
    devices: {},
    commands: {},
    messageIndex: {},
    revokedDevices: {},
  };
}

function validateState(state) {
  if (!state || state.version !== 1 || typeof state !== 'object') {
    throw new Error('Unsupported or invalid relay state');
  }
  for (const key of ['pairingCodes', 'devices', 'commands', 'messageIndex', 'revokedDevices']) {
    if (!state[key] || typeof state[key] !== 'object' || Array.isArray(state[key])) {
      throw new Error(`Invalid relay state: ${key}`);
    }
  }
  return state;
}

// An encrypted local persistence boundary. We write using rename so a crash
// cannot leave a partially-written state file. `transaction` serializes all
// read-modify-write changes in this one-process relay.
class StateStore {
  constructor({ filePath, encryptionKey, clock = () => Date.now() }) {
    this.filePath = filePath;
    this.encryptionKey = encryptionKey;
    this.clock = clock;
    this.state = emptyState();
    this.writeChain = Promise.resolve();
  }

  async load() {
    try {
      const raw = await fs.readFile(this.filePath, 'utf8');
      this.state = validateState(decryptJson(JSON.parse(raw), this.encryptionKey));
    } catch (error) {
      if (error && error.code === 'ENOENT') {
        await fs.mkdir(path.dirname(this.filePath), { recursive: true, mode: 0o700 });
        this.state = emptyState();
        await this.persist();
        return;
      }
      throw new Error(`Unable to load encrypted relay state: ${error.message}`);
    }
  }

  snapshot() {
    return structuredClone(this.state);
  }

  async transaction(change) {
    const operation = this.writeChain.then(async () => {
      const result = await change(this.state);
      await this.persist();
      return result;
    });
    // A rejected operation must not poison the queue. The caller still gets
    // its original failure, while later requests can continue safely.
    this.writeChain = operation.catch(() => undefined);
    return operation;
  }

  async persist() {
    const envelope = encryptJson(this.state, this.encryptionKey);
    const temporary = `${this.filePath}.${process.pid}.${Date.now()}.tmp`;
    await fs.mkdir(path.dirname(this.filePath), { recursive: true, mode: 0o700 });
    await fs.writeFile(temporary, `${JSON.stringify(envelope)}\n`, { mode: 0o600 });
    await fs.rename(temporary, this.filePath);
    await fs.chmod(this.filePath, 0o600);
  }
}

module.exports = {
  StateStore,
  emptyState,
};
