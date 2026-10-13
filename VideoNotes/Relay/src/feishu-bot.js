'use strict';

const lark = require('@larksuiteoapi/node-sdk');

const MAX_IMMEDIATE_REPLY_CODEPOINTS = 1_500;

function codePointSlice(value, max) {
  return [...value].slice(0, max).join('');
}

function decodeTextContent(content) {
  try {
    const parsed = JSON.parse(content);
    if (typeof parsed.text === 'string') return parsed.text;
  } catch {
    // Non-text Feishu message types are intentionally ignored below.
  }
  return null;
}

function mentionTargetsBot(mention, botOpenId) {
  if (!mention || typeof mention !== 'object') return false;
  const mentionedOpenId = mention.id?.open_id;
  // Current `im.message.receive_v1` payloads do not consistently include the
  // non-standard `mentioned_type` field. The Open ID returned by bot/v3/info
  // is the stable identity that lets us recognize this app's bot without
  // trusting its mutable display name. If Feishu did provide an Open ID, a
  // mismatching value must fail closed even when `mentioned_type` says bot.
  if (typeof mentionedOpenId === 'string' && mentionedOpenId) {
    return Boolean(botOpenId) && mentionedOpenId === botOpenId;
  }
  // Retain compatibility with older events that explicitly identify a bot
  // but omit its ID. The caller separately validates the event's app_id.
  return mention.mentioned_type === 'bot';
}

// Feishu text-message JSON stores @ mentions as placeholders such as
// `@_user_1`, while the corresponding mention object carries the opaque key
// and bot Open ID. Never infer this from the displayed bot name: names are
// mutable and can be duplicated in a group.
function stripBotMentionPlaceholders(text, mentions, botOpenId = null) {
  let result = text;
  if (!Array.isArray(mentions)) return result;
  for (const mention of mentions) {
    if (!mentionTargetsBot(mention, botOpenId) || typeof mention.key !== 'string' || !mention.key) {
      continue;
    }
    // split/join avoids treating a platform-provided key as a RegExp. Keys
    // are opaque, so regex replacement would be both fragile and unsafe.
    result = result.split(mention.key).join(' ');
  }
  return result.replace(/\s+/g, ' ').trim();
}

// A thin adapter over the official SDK. Its dispatcher gives the platform an
// acknowledgement immediately while durable work is queued locally. It is
// deliberately restricted to group text messages that explicitly mention
// this bot; all authorization is also rechecked in RelayService.
class FeishuBot {
  constructor({ config, relay, logger = console, sdk = lark }) {
    this.config = config;
    this.relay = relay;
    this.logger = logger;
    this.sdk = sdk;
    this.client = null;
    this.wsClient = null;
    this.started = false;
    this.lastError = null;
    this.botOpenId = null;
  }

  async start() {
    if (this.started) return;
    const base = {
      appId: this.config.feishuAppId,
      appSecret: this.config.feishuAppSecret,
      domain: this.config.feishuDomain === 'lark' ? this.sdk.Domain.Lark : this.sdk.Domain.Feishu,
      loggerLevel: this.sdk.LoggerLevel.warn,
      source: 'videonotes-feishu-relay',
    };
    this.client = new this.sdk.Client(base);
    const identity = await this.client.request({
      url: '/open-apis/bot/v3/info',
      method: 'GET',
    });
    this.botOpenId = identity?.bot?.open_id;
    if (identity?.code !== undefined && identity.code !== 0) {
      throw new Error(`Unable to verify Feishu bot identity (code ${identity.code})`);
    }
    if (typeof this.botOpenId !== 'string' || !this.botOpenId) {
      throw new Error('Unable to verify Feishu bot identity: bot/v3/info returned no Open ID');
    }
    const dispatcher = new this.sdk.EventDispatcher({ loggerLevel: this.sdk.LoggerLevel.warn }).register({
      'im.message.receive_v1': async (event) => this.#receive(event),
    });
    this.wsClient = new this.sdk.WSClient({
      ...base,
      handshakeTimeoutMs: 15_000,
      wsConfig: { pingTimeout: 15 },
      onReady: () => {
        this.lastError = null;
        this.logger.info?.('Feishu long connection ready');
      },
      onError: (error) => {
        this.lastError = error?.message || 'Unknown Feishu long-connection error';
        this.logger.error?.(`Feishu long connection failed: ${this.lastError}`);
      },
      onReconnecting: () => this.logger.warn?.('Feishu long connection reconnecting'),
      onReconnected: () => {
        this.lastError = null;
        this.logger.info?.('Feishu long connection reconnected');
      },
    });
    // The SDK manages reconnects; start intentionally resolves quickly.
    await this.wsClient.start({ eventDispatcher: dispatcher });
    this.started = true;
  }

  async stop() {
    this.wsClient?.close({ force: true });
    this.started = false;
  }

  health() {
    return {
      connection: this.wsClient?.getConnectionStatus?.().state || (this.started ? 'starting' : 'not_started'),
      ...(this.lastError ? { last_error: this.lastError } : {}),
    };
  }

  async replyText({ messageId, text, idempotencyKey }) {
    if (!this.client) throw new Error('Feishu bot has not started');
    const response = await this.client.im.v1.message.reply({
      path: { message_id: messageId },
      data: {
        content: JSON.stringify({ text }),
        msg_type: 'text',
        // Feishu's `uuid` makes a retried send idempotent at the API edge.
        uuid: idempotencyKey,
      },
    });
    if (response?.code !== 0) {
      throw new Error(`Feishu reply rejected (code ${response?.code ?? 'unknown'})`);
    }
  }

  async #receive(event) {
    // The event header belongs to the self-built app that received the event.
    // This fail-closed check is independent of permissions and prevents an
    // accidental dispatcher/configuration mix-up from parsing another app's
    // event. SDK versions may expose header fields either flattened or nested.
    const eventAppId = event?.app_id ?? event?.header?.app_id;
    if (eventAppId !== this.config.feishuAppId) return;
    const message = event?.message;
    const sender = event?.sender;
    if (!message || !sender || sender.sender_type !== 'user') return;
    // The Feishu app has only group @-message receive permission. Still reject
    // anything that isn't exactly a group text message with our bot in its
    // mention list, so an accidental permission expansion cannot expose notes.
    if (message.chat_type !== 'group' || message.message_type !== 'text') return;
    if (!this.#isBotMentioned(message.mentions)) return;
    const senderOpenId = sender.sender_id?.open_id;
    const decodedText = decodeTextContent(message.content);
    const text = decodedText === null
      ? null
      : stripBotMentionPlaceholders(decodedText, message.mentions, this.botOpenId);
    if (!senderOpenId || text === null) return;

    try {
      const reply = await this.relay.handleFeishuMessage({
        chatId: message.chat_id,
        messageId: message.message_id,
        senderOpenId,
        text,
      });
      if (reply) {
        await this.replyText({
          messageId: message.message_id,
          text: codePointSlice(reply, MAX_IMMEDIATE_REPLY_CODEPOINTS),
          idempotencyKey: `ack_${message.message_id}`,
        });
      }
    } catch (error) {
      // Never echo review content, pairing codes, or device tokens.
      this.logger.error?.(`Feishu event processing failed for ${message.message_id}: ${error.message}`);
      try {
        await this.replyText({
          messageId: message.message_id,
          text: '处理请求时出现问题，请稍后再试。',
          idempotencyKey: `error_${message.message_id}`,
        });
      } catch {
        // The websocket event must still return promptly even if a reply fails.
      }
    }
  }

  #isBotMentioned(mentions) {
    // `im:message.group_at_msg:readonly` only delivers group messages that
    // mention this bot. Verify the mention against the bot identity belonging
    // to the already-checked event app_id rather than relying on a field that
    // is absent from real-world event payloads.
    return Array.isArray(mentions) && mentions.some((mention) => (
      mentionTargetsBot(mention, this.botOpenId)
    ));
  }
}

module.exports = {
  FeishuBot,
  decodeTextContent,
  mentionTargetsBot,
  stripBotMentionPlaceholders,
};
