'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { FeishuBot, stripBotMentionPlaceholders } = require('../src/feishu-bot');

function sdkStub() {
  class Client {
    constructor() {
      this.im = { v1: { message: { reply: async () => ({ code: 0 }) } } };
    }
    async request() {
      return { code: 0, bot: { open_id: 'ou_bot' } };
    }
  }
  class EventDispatcher {
    constructor() {}
    register(handles) {
      this.handles = handles;
      return this;
    }
  }
  class WSClient {
    constructor() {}
    async start({ eventDispatcher }) { this.dispatcher = eventDispatcher; }
    close() {}
    getConnectionStatus() { return { state: 'connected' }; }
  }
  return {
    Client,
    EventDispatcher,
    WSClient,
    Domain: { Lark: 'lark', Feishu: 'feishu' },
    LoggerLevel: { warn: 'warn' },
  };
}

function event({ appId = 'cli_0123456789abcdef', mentions, content = '{"text":"@_user_1 帮助"}' } = {}) {
  return {
    app_id: appId,
    sender: { sender_type: 'user', sender_id: { open_id: 'ou_sender' } },
    message: {
      chat_type: 'group',
      message_type: 'text',
      chat_id: 'oc_group',
      message_id: 'om_message',
      mentions,
      content,
    },
  };
}

test('strips only bot mention placeholders using opaque mention keys', () => {
  const text = '@_user_1 复盘今天 @_user_2';
  const mentions = [
    { key: '@_user_1', mentioned_type: 'bot', id: { open_id: 'ou_bot' } },
    { key: '@_user_2', mentioned_type: 'user', id: { open_id: 'ou_someone' } },
  ];
  assert.equal(stripBotMentionPlaceholders(text, mentions, 'ou_bot'), '复盘今天 @_user_2');
});

test('receives only current-app group bot mentions and parses placeholder text', async () => {
  const received = [];
  const relay = {
    async handleFeishuMessage(payload) {
      received.push(payload);
      return null;
    },
  };
  const bot = new FeishuBot({
    config: {
      feishuAppId: 'cli_0123456789abcdef',
      feishuAppSecret: 'secret',
      feishuDomain: 'feishu',
    },
    relay,
    sdk: sdkStub(),
    logger: { info() {}, warn() {}, error() {} },
  });
  await bot.start();
  const receive = bot.wsClient.dispatcher.handles['im.message.receive_v1'];

  await receive(event({ mentions: [{ key: '@_user_1', mentioned_type: 'bot', id: {} }] }));
  assert.equal(received.length, 1);
  assert.equal(received[0].text, '帮助');

  await receive(event({ appId: 'cli_fedcba9876543210', mentions: [{ key: '@_user_1', mentioned_type: 'bot' }] }));
  await receive(event({ mentions: [{ key: '@_user_1', mentioned_type: 'user' }] }));
  assert.equal(received.length, 1);
});

test('accepts real bot mentions without mentioned_type only when Open ID belongs to this app bot', async () => {
  const received = [];
  const relay = {
    async handleFeishuMessage(payload) {
      received.push(payload);
      return null;
    },
  };
  const bot = new FeishuBot({
    config: {
      feishuAppId: 'cli_0123456789abcdef',
      feishuAppSecret: 'secret',
      feishuDomain: 'feishu',
    },
    relay,
    sdk: sdkStub(),
    logger: { info() {}, warn() {}, error() {} },
  });
  await bot.start();
  const receive = bot.wsClient.dispatcher.handles['im.message.receive_v1'];

  await receive(event({
    mentions: [{ key: '@_user_1', id: { open_id: 'ou_bot' }, name: 'VideoNotes' }],
  }));
  assert.equal(received.length, 1);
  assert.equal(received[0].text, '帮助');

  await receive(event({
    mentions: [{ key: '@_user_1', id: { open_id: 'ou_someone_else' }, name: 'VideoNotes' }],
  }));
  await receive(event({
    mentions: [{ key: '@_user_1', mentioned_type: 'bot', id: { open_id: 'ou_someone_else' } }],
  }));
  assert.equal(received.length, 1);
});
