// gen-profile.mjs — 预置 profile 生成器
// 用 CDP 驱动真实 Chromium：开启 ScriptCat 的"允许运行用户脚本"开关，并通过正规安装流程安装 OCS 网课助手。
// 生成一个"开箱即用"的 profile 目录（含脚本数据 + userScripts 开关状态），由构建脚本打包为 profile_seed。
//
// 用法: node gen-profile.mjs --chromium <chrome.exe> --ext <scriptcat目录> --profile <输出profile> --ocs <ocs.user.js路径> [--port 9222]
// OCS 是 ScriptCat 的油猴脚本：本脚本直接把它写入 ScriptCat 的 chrome.storage.local
// （script:<uuid> 元数据 + scriptCode:<uuid> 代码），status=1 默认启用，无需任何服务器或 UI 点击。
import { readFileSync, rmSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

// ---------- 参数 ----------
const args = process.argv.slice(2);
const get = (k) => {
  const i = args.indexOf(k);
  return i >= 0 ? args[i + 1] : null;
};
// 参数支持相对路径（相对当前工作目录），内部统一解析为绝对路径，
// 避免在不同机器/目录下因路径解析不一致而出错。
const resolveArg = (p) => (p ? (path.isAbsolute(p) ? p : path.resolve(p)) : p);
const chromium = resolveArg(get('--chromium'));
const extDir = resolveArg(get('--ext'));
const profileDir = resolveArg(get('--profile'));
const ocsFile = resolveArg(get('--ocs'));
const port = Number(get('--port') || '9222');
if (!chromium || !extDir || !profileDir || !ocsFile) {
  console.error('缺少必要参数');
  process.exit(2);
}

// ---------- CDP 客户端 ----------
// CDP 是基于 WebSocket 的调试协议客户端：send() 发送带自增 id 的请求，
// 响应按 id 回到对应 pending Promise（简化版 JSON-RPC）。
class CDP {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.id = 0;
    this.pending = new Map();
  }
  // open 等待 WebSocket 握手完成，并注册 onmessage 分发器（按 msg.id 回调 pending）。
  async open() {
    await new Promise((res, rej) => {
      this.ws.onopen = res;
      this.ws.onerror = () => rej(new Error('CDP WebSocket 连接失败'));
    });
    this.ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        const p = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        msg.error ? p.reject(new Error(msg.error.message)) : p.resolve(msg.result);
      }
    };
    // 连接中途断开（页面崩溃/浏览器退出）时，把所有未决请求全部拒绝，
    // 避免 send() 的 Promise 永不 settle 导致脚本永久挂起。
    const failAll = (reason) => {
      for (const p of this.pending.values()) p.reject(new Error(reason));
      this.pending.clear();
    };
    this.ws.onclose = () => failAll('CDP WebSocket 连接已关闭');
    this.ws.onerror = () => failAll('CDP WebSocket 连接出错');
  }
  // send 发送一条 CDP 方法调用，返回结果 Promise（错误时 reject）。
  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const msgId = ++this.id;
      this.pending.set(msgId, { resolve, reject });
      this.ws.send(JSON.stringify({ id: msgId, method, params }));
    });
  }
  // close 关闭连接（忽略关闭过程中的异常）。
  close() { try { this.ws.close(); } catch {} }
}

// newTab 通过 CDP HTTP 接口新建一个 about:blank 标签页，返回其描述对象。
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

// evalIn 在目标（页面/扩展 SW）上下文执行一段 JS 表达式并返回其求值结果。
// awaitPromise: true 让 await 的 Promise 也能同步等到结果；returnByValue 把对象序列化为可读值。
// 注意：awaitPromise 下 Promise reject 时 CDP 不报错，而是把异常放在
// exceptionDetails 字段返回、result.value 为 undefined。这里显式抛出，
// 否则 waitFor 的 try/catch 与 waitForRetry 的重试逻辑都会静默失效。
async function evalIn(cdp, expression) {
  const r = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) {
    const ex = r.exceptionDetails.exception;
    const msg = ex?.description || ex?.value || r.exceptionDetails.text || '页面脚本异常';
    throw new Error(String(msg).split('\n')[0]); // 只取首行，避免把完整堆栈塞进错误信息
  }
  return r.result.value;
}

// ---------- 真实信号等待工具（替代"盲等 N 秒"）----------
// 页面端：等待真实 DOM 状态成立（MutationObserver + 200ms 轮询双保险），
// 条件一旦成立立即 resolve；超时或页面脚本异常则 reject。
// timeoutMs 只是安全上限，不是对耗时的猜测。
const WAIT_JS = `(bfs, cond, timeoutMs, label) => new Promise((resolve, reject) => {
  let settled = false;
  const cleanup = () => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    clearInterval(iv);
    try { obs.disconnect(); } catch {}
  };
  const check = () => {
    if (!document.documentElement) return;
    let r;
    try { r = cond(bfs); } catch (e) { cleanup(); reject(new Error(label + ': 页面脚本异常 ' + e.message)); return; }
    if (r) { cleanup(); resolve(r); }
  };
  const timer = setTimeout(() => { cleanup(); reject(new Error(label + ': 等待超时 ' + timeoutMs + 'ms')); }, timeoutMs);
  const iv = setInterval(check, 200);
  let obs;
  try {
    obs = new MutationObserver(check);
    obs.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
  } catch {}
  check();
})`;

// 宿主侧：注入等待函数并阻塞直到条件成立（awaitPromise）
async function waitFor(cdp, condBody, timeoutMs, label, optional = false) {
  try {
    const expr = `(${WAIT_JS})(${BFS_FN}, (bfs) => ${condBody}, ${timeoutMs}, ${JSON.stringify(label)})`;
    return await evalIn(cdp, expr);
  } catch (e) {
    if (optional) return null;
    throw e;
  }
}

// 页面执行上下文可能因首屏加载被重建，等待类操作失败时有限重试
async function waitForRetry(cdp, condBody, timeoutMs, label, tries = 3) {
  let lastErr;
  for (let i = 0; i < tries; i++) {
    try {
      return await waitFor(cdp, condBody, timeoutMs, label);
    } catch (e) {
      lastErr = e;
      console.log(`[gen-profile] ${label} 第 ${i + 1} 次等待失败: ${e.message}，重试`);
      await sleep(1000);
    }
  }
  throw lastErr;
}

// ---------- OCS 脚本解析与存储条目构造 ----------
const ocsCode = readFileSync(ocsFile, 'utf8');

// 解析 UserScript 元数据头（// ==UserScript== ... ==/UserScript==）
function parseUserscriptMeta(code) {
  const block = code.match(/\/\/ ==UserScript==([\s\S]*?)\/\/ ==\/UserScript==/);
  if (!block) throw new Error('OCS 文件缺少 UserScript 元数据头');
  const meta = {};
  // 兼容 CRLF 行尾：git 检出（core.autocrlf）会把仓库里的 LF 转成 CRLF，
  // 行尾 \r 会卡住 `(.*)$` 使整行匹配失败，导致全部元数据解析为空（曾致
  // OCS 在 ScriptCat 中显示版本 0.0、脚本无法注入）。先统一去掉 \r。
  for (const line of block[1].replace(/\r/g, '').split('\n')) {
    const m = line.match(/^\s*\/\/\s+@([\w-]+)\s*(.*)$/);
    if (!m) continue;
    const key = m[1].toLowerCase();
    const val = (m[2] || '').trim();
    if (val) (meta[key] = meta[key] || []).push(val);
  }
  return meta;
}

// 构造 ScriptCat storage 条目（schema 取自已知可用种子）
function buildOcsEntry(code) {
  const raw = parseUserscriptMeta(code);
  const dedupe = (arr) => [...new Set(arr || [])];
  const metadata = {
    ...(raw.antifeature?.length ? { antifeature: dedupe(raw.antifeature) } : {}),
    ...(raw.author?.length ? { author: dedupe(raw.author) } : {}),
    ...(raw.connect?.length ? { connect: dedupe(raw.connect) } : {}),
    ...(raw.description?.length ? { description: dedupe(raw.description) } : {}),
    ...(raw.grant?.length ? { grant: dedupe(raw.grant) } : {}),
    ...(raw.homepage?.length ? { homepage: dedupe(raw.homepage) } : {}),
    ...(raw.icon?.length ? { icon: dedupe(raw.icon) } : {}),
    ...(raw.license?.length ? { license: dedupe(raw.license) } : {}),
    ...(raw.match?.length ? { match: dedupe(raw.match) } : {}),
    ...(raw.name?.length ? { name: dedupe(raw.name) } : {}),
    ...(raw.namespace?.length ? { namespace: dedupe(raw.namespace) } : {}),
    ...(raw['run-at']?.length ? { 'run-at': dedupe(raw['run-at']) } : {}),
    ...(raw.source?.length ? { source: dedupe(raw.source) } : {}),
    ...(raw.version?.length ? { version: dedupe(raw.version) } : {}),
  };
  const name = metadata.name?.[0] || 'OCS 网课助手';
  const uuid = randomUUID();
  const now = Date.now();
  // ScriptCat 自动更新源：GitHub 最新 Release 资产（稳定 URL，始终指向最新版本）
  const origin = 'https://github.com/ocsjs/ocsjs/releases/latest/download/ocs.user.js';
  return {
    uuid,
    script: {
      author: metadata.author?.[0] || '',
      checkUpdate: true, // 开启 ScriptCat 自动更新检查（对比 @version，发现新版自动提示）
      checkUpdateUrl: origin,
      checktime: now,
      createtime: now,
      downloadUrl: origin,
      metadata,
      name,
      namespace: metadata.namespace?.[0] || '',
      origin,
      originDomain: 'github.com',
      runStatus: 'complete',
      selfMetadata: {},
      sort: 0,
      status: 1, // 1 = 默认启用
      type: 1,
      updatetime: now,
      uuid,
    },
    code: { code },
    temp: {
      key: uuid,
      savedAt: now,
      type: 1,
      value: [false, { code: '', metadata, source: 'user', url: origin, userSubscribe: false, uuid }, {}],
    },
  };
}
const ocsEntry = buildOcsEntry(ocsCode);
console.log(`[gen-profile] OCS 条目已构造: ${ocsEntry.script.name}@${ocsEntry.script.metadata.version?.[0] || ''} uuid=${ocsEntry.uuid}`);

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
// launch 用预置参数（独立 user-data-dir + 加载扩展 + 开调试端口）拉起 Chromium。
// stdio 丢弃（本脚本只通过 CDP 交互），返回子进程句柄。
function launch() {
  return spawn(chromium, [
    `--user-data-dir=${profileDir}`,
    // 注意：不要加 --disable-extensions-except，否则首次启动会弹"加载扩展程序时候出错"并触发进程重启
    `--load-extension=${extDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    // 指定中文，让 seed 的 intl.accept_languages 初始化为 zh-CN，
    // 避免超星等网课平台按 en-US 返回英文界面（运行时由启动器 --lang 兜底）
    '--lang=zh-CN',
    `--remote-debugging-port=${port}`,
    '--window-size=960,720',
    'about:blank',
  ], { stdio: 'ignore' });
}

// 优雅关闭：发送 Browser.close 并等待进程真正退出（确保数据完整落盘）
async function closeGracefully(proc, port) {
  const exited = new Promise((resolve) => {
    proc.once('exit', resolve);
    setTimeout(resolve, 10000);
  });
  try {
    const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
    const bc = new CDP(version.webSocketDebuggerUrl);
    await bc.open();
    await bc.send('Browser.close');
  } catch {
    try { proc.kill(); } catch {}
  }
  await exited;
}

// waitCdp 轮询 CDP HTTP 接口直到 Chromium 的调试服务就绪（首启启动较慢，需等待）。
// 默认最多尝试 20 次、每次间隔 1 秒；超时则抛错终止脚本。
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
  let proc = launch();
  await waitCdp(port);
  console.log('[gen-profile] Chromium 已启动，CDP 就绪');

  // ---------- 1. 开启 "允许运行用户脚本" 开关 ----------
  // 全程等待真实 DOM 状态：扩展卡片 → 详情按钮 → 开关行，不再固定 sleep。
  const tab = await newTab(port);
  const cdp = new CDP(tab.webSocketDebuggerUrl);
  await cdp.open();
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');
  await cdp.send('Page.navigate', { url: 'chrome://extensions/' });

  // 1.0 开发者模式：写死默认开启，避免 unpacked 扩展信任弹窗（端用户首启也不弹）
  const devModeState = await waitForRetry(cdp, `{
    const els = bfs(document.documentElement);
    const toggle = els.find(e => e.id === 'devMode');
    if (!toggle) return false;
    const checked = toggle.checked ?? toggle.getAttribute('aria-pressed');
    if (checked === true || checked === 'true') return 'already-on';
    toggle.click();
    return 'clicked';
  }`, 30000, '开启开发者模式');
  await waitForRetry(cdp, `{
    const els = bfs(document.documentElement);
    const toggle = els.find(e => e.id === 'devMode');
    const checked = toggle ? (toggle.checked ?? toggle.getAttribute('aria-pressed')) : null;
    return checked === true || checked === 'true';
  }`, 15000, '确认开发者模式已开启');
  console.log(`[gen-profile] 开发者模式 ${devModeState === 'already-on' ? '原本已开启' : '已开启并持久化'}`);

  await waitForRetry(cdp, `{
    const els = bfs(document.documentElement);
    const cards = els.filter(e => e.tagName === 'EXTENSIONS-ITEM');
    if (!cards.length) return false;
    let target = null;
    for (const c of cards) {
      const q = bfs(c);
      const nameEl = q.find(e => e.id === 'name' || e.className === 'name');
      if (nameEl && /scriptcat|脚本猫/i.test(nameEl.textContent || '')) { target = c; break; }
    }
    if (!target) return false;
    const q = bfs(target);
    const btn = q.find(e => /详情|details/i.test((e.textContent || '').trim()) && e.tagName === 'CR-BUTTON');
    if (!btn) return false;
    btn.click();
    return true;
  }`, 60000, '打开扩展详情');
  console.log('[gen-profile] 已打开扩展详情');

  const toggleState = await waitForRetry(cdp, `{
    const els = bfs(document.documentElement);
    const row = els.find(e => e.tagName === 'EXTENSIONS-TOGGLE-ROW' && /允许运行用户脚本|allow user scripts/i.test((e.textContent || '').trim()));
    if (!row) return false;
    const toggles = bfs(row).filter(e => e.tagName === 'CR-TOGGLE');
    if (!toggles.length) return false;
    const t = toggles[0];
    const before = t.checked ?? t.getAttribute('aria-pressed');
    if (before === true || before === 'true') return 'already-on';
    t.click();
    return 'toggled';
  }`, 30000, '拨动 userScripts 开关');
  console.log(`[gen-profile] userScripts 开关已开启 ${toggleState === 'already-on' ? '(原本已开)' : ''}`);
  cdp.close();

  // ---------- 2. 直接预置 OCS 到 ScriptCat 存储（默认启用） ----------
  // 不再模拟点击安装：把 OCS 条目写入 chrome.storage.local，
  // 写入后等待落盘，再优雅关闭/重启让 ScriptCat 重新扫描存储。
  const sw = await (async () => {
    for (let i = 0; i < 20; i++) {
      const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      const t = targets.find((x) => x.type === 'service_worker' && x.url.includes(extId));
      if (t) return t;
      await sleep(1000);
    }
    throw new Error('未找到 ScriptCat SW target');
  })();
  const swCdp = new CDP(sw.webSocketDebuggerUrl);
  await swCdp.open();
  try {
    const payload = JSON.stringify(ocsEntry);
    const injectResult = await evalIn(swCdp, `(async () => {
      const entry = ${payload};
      await chrome.storage.local.set({
        ['script:' + entry.uuid]: entry.script,
        ['scriptCode:' + entry.uuid]: entry.code,
        ['tempStorage:' + entry.uuid]: entry.temp,
      });
      return { ok: true, uuid: entry.uuid, name: entry.name };
    })()`);
    console.log('[gen-profile] OCS 已写入 ScriptCat 存储:', JSON.stringify(injectResult));
  } finally {
    try { swCdp.close(); } catch {}
  }
  // chrome.storage.local 是异步落盘，给足时间再关闭，避免数据丢失
  console.log('[gen-profile] 等待存储落盘...');
  await sleep(2000);

  // ---------- 3. 优雅关闭后重启（模拟端用户首次启动，让 ScriptCat 读取存储） ----------
  console.log('[gen-profile] 关闭浏览器并重启以注册 OCS...');
  await closeGracefully(proc, port);
  proc = launch();
  await waitCdp(port);
  console.log('[gen-profile] 浏览器已重启');

  // ---------- 4. 验证安装结果（重启后的真实状态） ----------
  const tab3 = await newTab(port);
  const cdp3 = new CDP(tab3.webSocketDebuggerUrl);
  await cdp3.open();
  await cdp3.send('Page.enable');
  await cdp3.send('Runtime.enable');
  await cdp3.send('Page.navigate', { url: `chrome-extension://${extId}/src/options.html` });
  // 等待管理面板真实渲染出 OCS 条目（替代固定 6 秒）
  const body = await waitForRetry(cdp3, `{
    const t = document.body ? document.body.textContent : '';
    if (!/OCS 网课助手/.test(t)) return false;
    return { hasOCS: true, hasScriptCat: /脚本猫|ScriptCat/.test(t) };
  }`, 30000, '等待 OCS 出现在管理面板');
  console.log('[gen-profile] 安装验证:', JSON.stringify(body));
  if (!body.hasOCS) {
    const dump = await evalIn(cdp3, `(() => ({ url: location.href, title: document.title, text: (document.body ? document.body.textContent : '').slice(0, 400) }))()`);
    console.log('[gen-profile] 验证失败时页面状态:', JSON.stringify(dump));
    throw new Error('验证失败：脚本猫管理面板未找到 OCS 网课助手');
  }
  // 面板出现名字只证明条目存在——名字失败时会回退默认值，metadata 解析失败
  // （如 CRLF 行尾问题）同样能通过。必须再从 storage 校验 @version/@match 完整。
  const stCheck = await evalIn(cdp3, `(async () => {
    const key = 'script:${ocsEntry.uuid}';
    const got = await chrome.storage.local.get(key);
    const s = got[key] || {};
    const md = s.metadata || {};
    return {
      name: s.name || '',
      version: (md.version && md.version[0]) || null,
      matchCount: (md.match && md.match.length) || 0,
    };
  })()`);
  console.log('[gen-profile] storage 校验:', JSON.stringify(stCheck));
  if (!stCheck.version || stCheck.matchCount < 1) {
    throw new Error('验证失败：OCS 条目 metadata 未解析出 @version/@match，脚本无法被 ScriptCat 正确加载');
  }
  cdp3.close();

  // 4.5 验证 SW 中 userScripts 已启用（确保 toggle 持久化生效，否则用户首次启动会弹扩展错误）
  // 等待 SW target 出现并实测 userScripts API（真实状态，1s 轮询）
  let swChecked = false;
  for (let i = 0; i < 20 && !swChecked; i++) {
    const targets2 = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    const sw = targets2.find(t => t.type === 'service_worker' && t.url.includes(extId));
    if (sw) {
      const swCdp = new CDP(sw.webSocketDebuggerUrl);
      await swCdp.open();
      try {
        const us = await evalIn(swCdp, `(async () => {
          try {
            const defined = typeof chrome.userScripts !== 'undefined';
            let registered = 0;
            if (defined) { try { registered = (await chrome.userScripts.getScripts()).length; } catch {} }
            return { defined, registered };
          } catch (e) { return { error: String(e) }; }
        })()`);
        console.log('[gen-profile] SW userScripts 检查:', JSON.stringify(us));
        if (us.defined) swChecked = true;
      } finally {
        swCdp.close();
      }
    }
    if (!swChecked) await sleep(1000);
  }
  if (!swChecked) throw new Error('userScripts 未启用，预置 profile 无效');
  console.log('[gen-profile] userScripts 已启用（SW 实测确认）');

  // ---------- 5. 优雅关闭浏览器，确保数据落盘 ----------
  console.log('[gen-profile] 关闭浏览器...');
  await closeGracefully(proc, port);

  // ---------- 6. 清理会话恢复数据 ----------
  // 生成过程中打开的标签/窗口会写入 Sessions，若不清理，端用户首次启动
  // 会恢复出这些窗口（options 页、扩展详情页、脚本猫引导页等，且可能重复）。
  for (const d of ['Sessions', 'Sessions_Encrypted']) {
    try { rmSync(path.join(profileDir, 'Default', d), { recursive: true, force: true }); } catch {}
  }
  console.log('[gen-profile] 已清理会话恢复数据（Sessions）');

  console.log('[gen-profile] 完成！profile 已生成于:', profileDir);
  process.exit(0);
} catch (err) {
  console.error('[gen-profile] 失败:', err.message);
  try { proc.kill(); } catch {}
  process.exit(1);
}
