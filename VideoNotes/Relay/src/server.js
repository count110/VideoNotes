'use strict';

const { loadConfig } = require('./config');
const { FeishuBot } = require('./feishu-bot');
const { createHttpServer } = require('./http-server');
const { RelayService } = require('./relay-service');
const { StateStore } = require('./state-store');

async function main() {
  const config = loadConfig();
  const store = new StateStore({
    filePath: config.statePath,
    encryptionKey: config.stateEncryptionKey,
  });
  const relay = new RelayService({ store, config, logger: console });
  await relay.start();

  const bot = new FeishuBot({ config, relay, logger: console });
  const server = createHttpServer({ relay, logger: console });
  server.requestTimeout = 35_000;
  server.headersTimeout = 40_000;
  server.keepAliveTimeout = 5_000;
  server.listen(config.port, config.host, () => {
    console.log(`VideoNotes Relay listening on http://${config.host}:${config.port}`);
  });

  const shutdown = async (signal) => {
    console.log(`Received ${signal}; stopping VideoNotes Relay`);
    await bot.stop();
    await new Promise((resolve) => server.close(resolve));
    process.exit(0);
  };
  process.once('SIGINT', () => void shutdown('SIGINT'));
  process.once('SIGTERM', () => void shutdown('SIGTERM'));

  try {
    await bot.start();
    // Attaching the usable adapter triggers a second durable-delivery scan.
    // The first scan ran before the bot existed and intentionally scheduled
    // nothing.
    relay.setBot(bot);
  } catch (error) {
    // Never start a relay that silently cannot initialize its bot adapter.
    // The official SDK reconnects asynchronously for transient network errors;
    // this branch handles only a synchronous/fatal setup failure.
    console.error(`Failed to start Feishu bot: ${error.message}`);
    server.close(() => process.exitCode = 1);
  }
}

main().catch((error) => {
  console.error(`VideoNotes Relay could not start: ${error.message}`);
  process.exitCode = 1;
});
