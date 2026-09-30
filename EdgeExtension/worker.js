import {capturePage, scrollOwnPage, safeToClose, selectFollowing} from './capture.js';
import {countFromText, normalizePost, searchURLs, profileCandidates} from './rules.js';

const BASE = 'http://127.0.0.1:18796';
let running = false;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function request(path, body, pairing = false) {
  const {token} = await chrome.storage.local.get('token');
  if (!pairing && !token) throw new Error('先连接素材助手');
  const response = await fetch(BASE + path, {
    method: body === undefined ? 'GET' : 'POST', credentials: 'omit', redirect: 'error', cache: 'no-store',
    headers: {'Content-Type': 'application/json', 'X-XContent-Extension': chrome.runtime.id, ...(pairing ? {} : {Authorization: `Bearer ${token}`})},
    ...(body === undefined ? {} : {body: JSON.stringify(body)}), signal: AbortSignal.timeout(15000)
  });
  const value = await response.json();
  if (!response.ok) throw new Error(value.error || '本地连接失败');
  return value;
}
async function configure() {
  await chrome.storage.local.setAccessLevel({accessLevel: 'TRUSTED_CONTEXTS'});
  await chrome.alarms.create('local-request-check', {periodInMinutes: 0.5});
}
chrome.runtime.onInstalled.addListener(configure);
chrome.runtime.onStartup.addListener(configure);
chrome.alarms.onAlarm.addListener(alarm => { if (alarm.name === 'local-request-check') void checkJob(); });
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  // Only our popup/wake page, never messages from X or a content script.
  if (sender.id !== chrome.runtime.id || !sender.url?.startsWith(chrome.runtime.getURL(''))) return false;
  (async () => {
    if (message.type === 'pair') {
      if (!/^[a-f0-9]{64}$/.test(message.code || '')) throw new Error('请粘贴 App 复制的完整连接码');
      const result = await request('/v1/pair', {code: message.code}, true);
      await chrome.storage.local.set({token: result.token}); await configure(); return {ok: true};
    }
    if (message.type === 'wake') { void checkJob(); return {ok: true}; }
    if (message.type === 'status') { const value = await request('/v1/job'); return {ok: true, message: value.job?.message || '已连接，等待 App 点击获取新帖'}; }
    throw new Error('不支持的请求');
  })().then(respond).catch(error => respond({ok: false, message: error.message === 'Failed to fetch' ? '连接不到 App，请先打开素材助手并检查扩展连接' : error.message}));
  return true;
});

async function checkJob() {
  if (running) return;
  running = true;
  let job;
  try {
    ({job} = await request('/v1/job'));
    if (!job || job.state !== 'queued') return; // No request = no X page access.
    await request('/v1/claim', {jobID: job.id});
    await runJob(job);
  } catch (error) {
    if (job?.id) {
      const message = String(error.message || '读取失败').slice(0, 300);
      try { await request('/v1/fail', {jobID: job.id, message}); } catch { /* App closed; its durable task expires. */ }
    }
  } finally { running = false; }
}

async function runJob(job) {
  const started = Date.now(), owned = new Map(), observed = new Map();
  let account = null;
  const progress = async message => {
    if (Date.now() - started > 260000) throw new Error('读取达到本轮时间上限；请稍后重新获取');
    await request('/v1/progress', {jobID: job.id, message}); // Cancelled jobs reject here.
  };
  async function open(url) {
    if (!url.startsWith('https://x.com/')) throw new Error('仅允许读取 X 公开页面');
    const tab = await chrome.tabs.create({url, active: false}); owned.set(tab.id, url); return tab.id;
  }
  async function capture(id, mode = 'posts', username = '') {
    let latest;
    for (let attempt = 0; attempt < (mode === 'profile' ? 8 : 15); attempt++) {
      await delay(800);
      const tab = await chrome.tabs.get(id);
      if (tab.status === 'loading' && tab.pendingUrl === owned.get(id) && (!tab.url || tab.url === 'about:blank')) continue;
      if (!tab.url?.startsWith('https://x.com/') || /\/i\/flow\//.test(tab.url)) throw new Error('X 需要登录或验证，请在 Edge 手动处理后重试');
      if (tab.url !== owned.get(id)) throw new Error('本次读取页被切换，已停止；不会读取你改开的其他页面');
      const [result] = await chrome.scripting.executeScript({target: {tabId: id}, func: capturePage, args: [mode, username]});
      latest = result.result;
      if (latest?.blocked) throw new Error(latest.blocked);
      if (latest?.account) {
        if (account && account.toLowerCase() !== latest.account.toLowerCase()) throw new Error('读取期间 X 账号发生变化，已停止');
        account = latest.account;
        if (mode === 'profile' ? latest.followersText !== null : latest.posts?.length > 0) return latest;
      }
    }
    if (!latest?.account) throw new Error('未读到登录账号；请确认 X 已登录、页面可正常显示');
    return latest;
  }
  async function close(id) {
    try {
      const tab = await chrome.tabs.get(id);
      if (tab.active || tab.url !== owned.get(id)) return;
      const [safe] = await chrome.scripting.executeScript({target: {tabId: id}, func: safeToClose});
      if (safe.result) { await chrome.tabs.remove(id); owned.delete(id); }
    } catch { /* Never touch tabs not created by this request. */ }
  }
  try {
    const following = job.policy.source === 'following';
    const urls = following ? ['https://x.com/home'] : searchURLs(job.policy.maxAgeHours);
    for (const [index, url] of urls.entries()) {
      await progress(following ? '读取正在关注；不限题材，只看本轮可见内容' : `读取${index === 0 ? 'AI' : '医学'}最新搜索页`);
      const id = await open(url);
      if (following) {
        await capture(id);
        const [selected] = await chrome.scripting.executeScript({target: {tabId: id}, func: selectFollowing});
        if (!selected.result) throw new Error('未找到正在关注标签，未将推荐流冒充关注流');
        await delay(1200);
      }
      const pageCount = following ? 8 : 3;
      for (let page = 0; page < pageCount; page++) {
        const result = await capture(id);
        if (following && !result.followingSelected) throw new Error('页面未确认正在关注，已停止读取');
        for (const raw of result.posts || []) {
          const post = normalizePost(raw);
          if (post && !observed.has(post.id)) observed.set(post.id, post);
        }
        await progress(`已读到 ${observed.size} 条相关原帖；继续检查页面`);
        if (page < pageCount - 1) await chrome.scripting.executeScript({target: {tabId: id}, func: scrollOwnPage});
      }
      await close(id);
    }
    if (!account) throw new Error('未读到当前登录账号');
    const posts = [...observed.values()].filter(p => p.username.toLowerCase() !== account.toLowerCase() && !p.discovery.isReply && !p.discovery.isPromoted);
    // Bounded profile reads. High engagement only decides what to inspect first, not who counts as a large account.
    const authors = [...new Set(profileCandidates(posts, account, job.policy).map(p => p.username))].slice(0, 16);
    for (const [index, author] of authors.entries()) {
      await progress(`核对公开粉丝数 ${index + 1}/${authors.length}；未显示的保持未知`);
      const url = `https://x.com/${author}`, id = await open(url);
      const result = await capture(id, 'profile', author), followers = countFromText(result.followersText);
      if (followers !== null) for (const post of posts) if (post.username === author) {
        post.discovery.followers = followers; post.discovery.followersSourceURL = url;
      }
      await close(id);
    }
    await progress('完成网页读取，交给 App 去重、筛选并生成回复');
    await request('/v1/result', {jobID: job.id, account, posts: posts.slice(0, 200)});
  } finally { for (const id of owned.keys()) await close(id); }
}
