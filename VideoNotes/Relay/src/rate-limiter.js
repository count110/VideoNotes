'use strict';

// Small bounded in-memory sliding-window limiter. It is intentionally local:
// persistent storage is reserved for pairing/device state, while rate limits
// are a best-effort abuse control that safely resets after a relay restart.
class SlidingWindowRateLimiter {
  constructor({ windowMs, maxEvents, maxKeys = 5_000 }) {
    if (!Number.isSafeInteger(windowMs) || windowMs < 1) {
      throw new Error('windowMs must be a positive integer');
    }
    if (!Number.isSafeInteger(maxEvents) || maxEvents < 1) {
      throw new Error('maxEvents must be a positive integer');
    }
    if (!Number.isSafeInteger(maxKeys) || maxKeys < 1) {
      throw new Error('maxKeys must be a positive integer');
    }
    this.windowMs = windowMs;
    this.maxEvents = maxEvents;
    this.maxKeys = maxKeys;
    this.entries = new Map();
  }

  // Returns false without recording an event when the caller is over quota.
  consume(rawKey, now = Date.now()) {
    const key = String(rawKey);
    const cutoff = now - this.windowMs;
    const previous = this.entries.get(key) || [];
    const timestamps = previous.filter((timestamp) => timestamp > cutoff);

    if (timestamps.length >= this.maxEvents) return false;

    timestamps.push(now);
    // Moving an active key to the back gives this map a compact LRU eviction
    // policy when untrusted callers try to create many distinct keys.
    this.entries.delete(key);
    this.entries.set(key, timestamps);
    while (this.entries.size > this.maxKeys) {
      const oldestKey = this.entries.keys().next().value;
      this.entries.delete(oldestKey);
    }
    return true;
  }

  clear() {
    this.entries.clear();
  }
}

module.exports = {
  SlidingWindowRateLimiter,
};
