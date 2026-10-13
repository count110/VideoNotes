'use strict';

const crypto = require('node:crypto');

function randomId(prefix) {
  return `${prefix}_${crypto.randomBytes(18).toString('base64url')}`;
}

function randomPairingCode() {
  // Easy to type in a chat, strong enough for its very short lifetime.
  return crypto.randomBytes(12).toString('base64url').toUpperCase();
}

function tokenHash(token) {
  return crypto.createHash('sha256').update(token, 'utf8').digest('base64url');
}

function timingSafeEqualText(left, right) {
  const leftHash = crypto.createHash('sha256').update(String(left), 'utf8').digest();
  const rightHash = crypto.createHash('sha256').update(String(right), 'utf8').digest();
  return crypto.timingSafeEqual(leftHash, rightHash);
}

function encryptJson(value, base64urlKey) {
  const key = Buffer.from(base64urlKey, 'base64url');
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const plaintext = Buffer.from(JSON.stringify(value), 'utf8');
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();
  return {
    version: 1,
    algorithm: 'aes-256-gcm',
    iv: iv.toString('base64url'),
    tag: tag.toString('base64url'),
    ciphertext: ciphertext.toString('base64url'),
  };
}

function decryptJson(envelope, base64urlKey) {
  if (!envelope || envelope.version !== 1 || envelope.algorithm !== 'aes-256-gcm') {
    throw new Error('Invalid encrypted relay state envelope');
  }
  const key = Buffer.from(base64urlKey, 'base64url');
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(envelope.iv, 'base64url'));
  decipher.setAuthTag(Buffer.from(envelope.tag, 'base64url'));
  const plaintext = Buffer.concat([
    decipher.update(Buffer.from(envelope.ciphertext, 'base64url')),
    decipher.final(),
  ]);
  return JSON.parse(plaintext.toString('utf8'));
}

module.exports = {
  decryptJson,
  encryptJson,
  randomId,
  randomPairingCode,
  timingSafeEqualText,
  tokenHash,
};
