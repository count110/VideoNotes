'use strict';

const COMMANDS = Object.freeze({
  // Short, natural commands are the public vocabulary shown in the bot help.
  // The older spellings remain aliases so already-paired groups do not break.
  '当前视频': 'generate_current_video_review',
  '复盘当前视频': 'generate_current_video_review',
  '当前视频复盘': 'generate_current_video_review',
  '复盘今天': 'generate_today_review',
  '今天复盘': 'generate_today_review',
  '发送当前复盘': 'send_current_video_review',
});

const HELP_TEXT = [
  'VideoNotes 复盘机器人',
  '',
  '可用指令：',
  '• 帮助',
  '• 绑定 <配对码>',
  '• 当前视频',
  '• 复盘当前视频',
  '• 复盘今天',
  '',
  '首次配对：在目标群 @我后发送「绑定 <配对码>」。',
  '为保护本机笔记，只有完成绑定的发起人可使用上述指令。',
].join('\n');

function normalizeText(value) {
  return String(value || '')
    .replace(/[\u200B-\u200D\uFEFF]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function parseCommand(text) {
  const normalized = normalizeText(text);
  if (/^(帮助|help|\/help)$/i.test(normalized)) return { kind: 'help' };

  const binding = /^绑定\s+([A-Za-z0-9_-]{12,64})$/i.exec(normalized);
  if (binding) return { kind: 'bind', code: binding[1].toUpperCase() };

  const type = COMMANDS[normalized];
  if (type) return { kind: 'command', type };
  return { kind: 'unknown' };
}

module.exports = {
  COMMANDS,
  HELP_TEXT,
  normalizeText,
  parseCommand,
};
