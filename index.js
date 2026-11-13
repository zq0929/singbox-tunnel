#!/usr/bin/env node
// 修复版入口：用 spawn 启动 start.sh，并正确转发退出信号与退出码。
// 原版 index.js 用 execSync('bash start.sh')，信号不会转发，容器停止时子进程可能残留。
'use strict';

const { spawn } = require('node:child_process');
const path = require('node:path');

const script = path.join(__dirname, 'start.sh');
const child = spawn(process.env.BASH || 'bash', [script], {
  stdio: 'inherit',
  env: process.env,
});

let stopping = false;
for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
  process.on(signal, () => {
    if (stopping) return;
    stopping = true;
    try {
      child.kill(signal);
    } catch {
      /* 子进程已退出 */
    }
  });
}

child.on('error', (err) => {
  console.error(`[index] 启动 ${script} 失败: ${err.message}`);
  process.exit(1);
});

child.on('exit', (code, signal) => {
  if (signal) {
    // 被信号杀死时用 128+signo 作为退出码，方便托管平台判断
    const signals = { SIGTERM: 15, SIGINT: 2, SIGHUP: 1, SIGKILL: 9 };
    process.exit(128 + (signals[signal] || 15));
  }
  process.exit(code === null ? 1 : code);
});
