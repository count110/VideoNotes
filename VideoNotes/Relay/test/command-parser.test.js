'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { HELP_TEXT, parseCommand } = require('../src/command-parser');

test('public commands and legacy aliases resolve to the same allow-list', () => {
  assert.deepEqual(parseCommand('当前视频'), { kind: 'command', type: 'generate_current_video_review' });
  assert.deepEqual(parseCommand('复盘当前视频'), { kind: 'command', type: 'generate_current_video_review' });
  assert.deepEqual(parseCommand('当前视频复盘'), { kind: 'command', type: 'generate_current_video_review' });
  assert.deepEqual(parseCommand('复盘今天'), { kind: 'command', type: 'generate_today_review' });
  assert.deepEqual(parseCommand('今天复盘'), { kind: 'command', type: 'generate_today_review' });
  assert.deepEqual(parseCommand('发送当前复盘'), { kind: 'command', type: 'send_current_video_review' });
  assert.deepEqual(parseCommand('绑定 abCdEFghIjkl'), { kind: 'bind', code: 'ABCDEFGHIJKL' });
});

test('help presents only the intended current vocabulary', () => {
  assert.match(HELP_TEXT, /• 帮助/);
  assert.match(HELP_TEXT, /• 绑定 <配对码>/);
  assert.match(HELP_TEXT, /• 当前视频/);
  assert.match(HELP_TEXT, /• 复盘当前视频/);
  assert.match(HELP_TEXT, /• 复盘今天/);
  assert.doesNotMatch(HELP_TEXT, /当前视频复盘/);
  assert.doesNotMatch(HELP_TEXT, /今天复盘/);
  assert.doesNotMatch(HELP_TEXT, /发送当前复盘/);
});
