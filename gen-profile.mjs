// gen-profile.mjs — 预置 profile 生成器
// 用 CDP 驱动真实 Chromium：开启 ScriptCat 的"允许运行用户脚本"开关，并通过正规安装流程安装 OCS 网课助手。
// 生成一个"开箱即用"的 profile 目录（含脚本数据 + userScripts 开关状态），由构建脚本打包为 profile_seed。
//
// 用法: node gen-profile.mjs --chromium <chrome.exe> --ext <scriptcat目录> --profile <输出profile> --ocs <ocs.user.js路径> [--port 9222] [--no-cleanup]
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

// ---------- 参数 ----------
const args = process.argv.slice(2);
const get = (k) => {
  const i = args.indexOf(k);
  return i >= 0 ? args[i + 1] : null;
};
const chromium = get('--chromium');
const extDir = get('--ext');
const profileDir = get('--profile');
const ocsFile = get('--ocs');
const port = Number(get('--port') || '9222');
if (!chromium || !extDir || !profileDir || !ocsFile) {
  console.error('缺少必要参数');
  process.exit(2);
}

// ---------- CDP 客户端 ----------
class CDP {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.id = 0;
    this.pending = new Map();
  }
  async open() {
    await new Promise((res, rej) => { this.ws.onopen = res; this.ws.onerror = rej; });
    this.ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        const p = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        msg.error ? p.reject(new Error(msg.error.message)) : p.resolve(msg.result);
      }
    };
  }
  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const msgId = ++this.id;
      this.pending.set(msgId, { resolve, reject });
      this.ws.send(JSON.stringify({ id: msgId, method, params }));
    });
  }
  close() { try { this.ws.close(); } catch {} }
}

async function newTab(port) {
  const res = await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' });
  return res.json();
}

// 注入页面的 BFS 遍历函数
const BFS_FN = `(root) => {
  const queue = [root]; const seen = new Set(); const all = [];
  while (queue.length) {
    const el = queue.shift();
    if (!el || seen.has(el)) continue;
    seen.add(el); all.push(el);
    if (el.shadowRoot) queue.push(el.shadowRoot);
    if (el.children) queue.push(...el.children);
  }
  return all;
}`;

async function evalIn(cdp, expression) {
  const r = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  return r.result.value;
}

// ---------- 本地 http server（提供 OCS 脚本）----------
const ocsContent = readFileSync(ocsFile);
const server = createServer((req, res) => {
  if (req.url.startsWith('/ocs')) {
    res.writeHead(200, { 'Content-Type': 'text/javascript', 'Content-Length': ocsContent.length });
    res.end(ocsContent);
  } else {
    res.writeHead(404); res.end();
  }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const ocsPort = server.address().port;
const OCS_URL = `http://127.0.0.1:${ocsPort}/ocs.user.js`;

// ---------- 计算扩展 ID ----------
const mf = JSON.parse(readFileSync(path.join(extDir, 'manifest.json'), 'utf8'));
const keyB64 = mf.key || '';
const ALPHA = 'abcdefghijklmnop';
let extId = '';
if (keyB64) {
  const hash = createHash('sha256').update(Buffer.from(keyB64, 'base64')).digest();
  for (let i = 0; i < 16; i++) {
    extId += ALPHA[Math.floor(hash[i] / 16)];
    extId += ALPHA[hash[i] % 16];
  }
} else {
  // 无 key 时无法预知 ID，报错提示
  throw new Error('扩展 manifest 缺少 key 字段，无法计算固定扩展 ID。请在构建脚本中注入 key。');
}
console.log(`[gen-profile] 扩展 ID: ${extId}`);

// ---------- 启动 Chromium ----------
const proc = spawn(chromium, [
  `--user-data-dir=${profileDir}`,
  // 注意：不要加 --disable-extensions-except，否则首次启动会弹"加载扩展程序时候出错"并触发进程重启
  `--load-extension=${extDir}`,
  '--no-first-run',
  '--no-default-browser-check',
  `--remote-debugging-port=${port}`,
  '--window-size=960,720',
  'about:blank',
], { stdio: 'ignore' });

async function waitCdp(port, tries = 20) {
  for (let i = 0; i < tries; i++) {
    try {
      await fetch(`http://127.0.0.1:${port}/json/list`);
      return;
    } catch { await sleep(1000); }
  }
  throw new Error('CDP 未在预期时间内就绪');
}

try {
  await waitCdp(port);
  console.log('[gen-profile] Chromium 已启动，CDP 就绪');

  // 等待扩展 SW 就绪（说明扩展已完成加载），再操作 chrome://extensions 页面
  let swReady = false;
  for (let i = 0; i < 15; i++) {
    const t = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    if (t.some((x) => x.type === 'service_worker' && x.url.includes(extId))) { swReady = true; break; }
    await sleep(2000);
  }
  if (!swReady) console.log('[gen-profile] 警告: 扩展 SW 未在预期时间内就绪，继续尝试');
  await sleep(3000);

  // ---------- 1. 开启 "允许运行用户脚本" 开关 ----------
  const tab = await newTab(port);
  const cdp = new CDP(tab.webSocketDebuggerUrl);
  await cdp.open();
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');
  await cdp.send('Page.navigate', { url: 'chrome://extensions/' });

  // 轮询直到扩展卡片与详情按钮就绪（全新 profile 首次启动较慢）
  let r = null;
  for (let i = 0; i < 15; i++) {
    await sleep(2000);
    r = await evalIn(cdp, `(() => {
      const els = (${BFS_FN})(document.documentElement);
      const cards = els.filter(e => e.tagName === 'EXTENSIONS-ITEM');
      if (!cards.length) return { ok: false, msg: '卡片未就绪(' + els.length + '节点)' };
      let target = null;
      for (const c of cards) {
        const q = (${BFS_FN})(c);
        const nameEl = q.find(e => e.id === 'name' || e.className === 'name');
        if (nameEl && /scriptcat|脚本猫/i.test(nameEl.textContent || '')) { target = c; break; }
      }
      if (!target) return { ok: false, msg: '卡片存在但未找到脚本猫' };
      const q = (${BFS_FN})(target);
      const btn = q.find(e => /详情|details/i.test((e.textContent || '').trim()) && e.tagName === 'CR-BUTTON');
      if (!btn) return { ok: false, msg: '详情按钮未找到' };
      btn.click();
      return { ok: true };
    })()`);
    if (r.ok) break;
  }
  if (!r.ok) throw new Error('打开扩展详情失败: ' + (r.msg || ''));
  console.log('[gen-profile] 已打开扩展详情');

  await sleep(4000);
  r = await evalIn(cdp, `(() => {
    const els = (${BFS_FN})(document.documentElement);
    const row = els.find(e => {
      if (e.tagName !== 'EXTENSIONS-TOGGLE-ROW') return false;
      return /允许运行用户脚本|allow user scripts/i.test((e.textContent || '').trim());
    });
    if (!row) return { ok: false, msg: '允许运行用户脚本开关未找到' };
    const toggles = (${BFS_FN})(row).filter(e => e.tagName === 'CR-TOGGLE');
    if (!toggles.length) return { ok: false, msg: 'cr-toggle 未找到' };
    const t = toggles[0];
    const before = t.checked ?? t.getAttribute('aria-pressed');
    if (before === true || before === 'true') return { ok: true, alreadyOn: true };
    t.click();
    return { ok: true, alreadyOn: false };
  })()`);
  if (!r.ok) throw new Error('开启 userScripts 失败: ' + (r.msg || ''));
  console.log(`[gen-profile] userScripts 开关已开启 ${r.alreadyOn ? '(原本已开)' : ''}`);
  cdp.close();

  // ---------- 2. 安装 OCS 脚本 ----------
  const tab2 = await newTab(port);
  const cdp2 = new CDP(tab2.webSocketDebuggerUrl);
  await cdp2.open();
  await cdp2.send('Page.enable');
  await cdp2.send('Runtime.enable');
  await cdp2.send('Page.navigate', { url: OCS_URL });
  await sleep(8000);

  const findInstallBtn = `(() => {
    const els = (${BFS_FN})(document.documentElement);
    const btn = els.find(e => {
      if (!/BUTTON/.test(e.tagName)) return false;
      const t = (e.textContent || '').trim();
      return /^(安装|立即安装|安装脚本|Install|Install Script)/i.test(t) && t.length < 30;
    });
    return btn ? { found: true } : { found: false };
  })()`;

  let installed = false;
  for (let i = 0; i < 5 && !installed; i++) {
    const st = await evalIn(cdp2, findInstallBtn);
    if (st.found) {
      await evalIn(cdp2, `(() => {
        const els = (${BFS_FN})(document.documentElement);
        const btn = els.find(e => {
          if (!/BUTTON/.test(e.tagName)) return false;
          const t = (e.textContent || '').trim();
          return /^(安装|立即安装|安装脚本|Install|Install Script)/i.test(t) && t.length < 30;
        });
        if (btn) btn.click();
      })()`);
      console.log('[gen-profile] 已点击安装按钮');
      await sleep(5000);
      // 若出现确认弹窗，再点一次
      const st2 = await evalIn(cdp2, findInstallBtn);
      if (st2.found) {
        await evalIn(cdp2, `(() => {
          const els = (${BFS_FN})(document.documentElement);
          const btn = els.find(e => {
            if (!/BUTTON/.test(e.tagName)) return false;
            const t = (e.textContent || '').trim();
            return /^(安装|立即安装|Install)/i.test(t) && t.length < 30;
          });
          if (btn) btn.click();
        })()`);
        console.log('[gen-profile] 已点击确认弹窗的安装');
        await sleep(4000);
      }
      installed = true;
    } else {
      await sleep(3000);
    }
  }
  if (!installed) throw new Error('OCS 脚本安装流程未完成');
  cdp2.close();

  // ---------- 3. 验证安装结果 ----------
  const tab3 = await newTab(port);
  const cdp3 = new CDP(tab3.webSocketDebuggerUrl);
  await cdp3.open();
  await cdp3.send('Page.enable');
  await cdp3.send('Runtime.enable');
  await cdp3.send('Page.navigate', { url: `chrome-extension://${extId}/src/options.html` });
  await sleep(6000);
  const body = await evalIn(cdp3, `(() => {
    const t = document.body ? document.body.textContent : '';
    return { hasOCS: /OCS 网课助手/.test(t), hasScriptCat: /脚本猫|ScriptCat/.test(t) };
  })()`);
  console.log('[gen-profile] 安装验证:', JSON.stringify(body));
  if (!body.hasOCS) throw new Error('验证失败：脚本猫管理面板未找到 OCS 网课助手');
  cdp3.close();

  // 3.5 验证 SW 中 userScripts 已启用（确保 toggle 持久化生效，否则用户首次启动会弹扩展错误）
  await sleep(3000);
  const targets2 = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const sw = targets2.find(t => t.type === 'service_worker' && t.url.includes(extId));
  if (sw) {
    const swCdp = new CDP(sw.webSocketDebuggerUrl);
    await swCdp.open();
    const us = await evalIn(swCdp, `(async () => {
      try {
        const defined = typeof chrome.userScripts !== 'undefined';
        let registered = 0;
        if (defined) { try { registered = (await chrome.userScripts.getScripts()).length; } catch {} }
        return { defined, registered };
      } catch (e) { return { error: String(e) }; }
    })()`);
    console.log('[gen-profile] SW userScripts 检查:', JSON.stringify(us));
    if (!us.defined) throw new Error('userScripts 未启用，预置 profile 无效');
    swCdp.close();
  } else {
    console.log('[gen-profile] 警告: 未找到 SW target（跳过 userScripts 检查）');
  }

  // ---------- 4. 优雅关闭浏览器，确保数据落盘 ----------
  console.log('[gen-profile] 关闭浏览器...');
  try {
    const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
    const bc = new CDP(version.webSocketDebuggerUrl);
    await bc.open();
    await bc.send('Browser.close');
    await sleep(3000);
  } catch {
    // 关闭失败则强杀
    try { proc.kill(); } catch {}
  }

  console.log('[gen-profile] 完成！profile 已生成于:', profileDir);
  process.exit(0);
} catch (err) {
  console.error('[gen-profile] 失败:', err.message);
  try { proc.kill(); } catch {}
  process.exit(1);
}
