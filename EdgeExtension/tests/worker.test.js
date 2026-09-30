import test from 'node:test';
import assert from 'node:assert/strict';

test('worker simulation: explicit request only, own tabs, following verified, other topics retained, account switch stops', async () => {
  const realFetch = globalThis.fetch, realChrome = globalThis.chrome, realTimeout = globalThis.setTimeout;
  let listener, events = [], tabs = new Map(), nextID = 100, result, fail, mode = 'idle';
  let currentJob = null;
  const id = 'a'.repeat(32), token = 'mock-local-only-not-a-real-secret';
  globalThis.setTimeout = (callback, _ms) => { queueMicrotask(callback); return 1; };
  globalThis.chrome = {
    storage: {local: {get: async () => ({token}), set: async () => {}, setAccessLevel: async () => {}}},
    alarms: {create: async () => {}, onAlarm: {addListener: () => {}}},
    runtime: {id, getURL: path => `chrome-extension://${id}/${path}`, onInstalled: {addListener: () => {}}, onStartup: {addListener: () => {}}, onMessage: {addListener: fn => {listener = fn;}}},
    tabs: {
      create: async ({url, active}) => { assert.equal(active, false); const tab = {id: nextID++, url, active: false}; tabs.set(tab.id, tab); events.push(['create', url]); return tab; },
      get: async id => tabs.get(id), remove: async id => { assert.ok(tabs.has(id)); tabs.delete(id); events.push(['remove', id]); }
    },
    scripting: {executeScript: async ({target, func, args}) => {
      const tab = tabs.get(target.tabId); assert.ok(tab, 'only task-owned tab touched');
      if (func.name === 'selectFollowing' || func.name === 'safeToClose') return [{result: true}];
      if (func.name === 'scrollOwnPage') return [{result: undefined}];
      assert.equal(func.name, 'capturePage');
      if (args[0] === 'profile') return [{result: {account: mode === 'switch' ? 'different_user' : 'me', followersText: '2.5万 Followers'}}];
      return [{result: {account: 'me', followingSelected: mode !== 'wrong-timeline', posts: [{url: 'https://x.com/daily/status/95200', text: '公司几号发工资能看出公司的实力吗？', publishedAt: new Date().toISOString(), textComplete: true, likeText: '12 likes', replyText: '3 replies'}]}}];
    }}
  };
  globalThis.fetch = async (url, options) => {
    assert.equal(new URL(url).origin, 'http://127.0.0.1:18796');
    assert.equal(options.credentials, 'omit'); assert.equal(options.redirect, 'error');
    assert.equal(options.headers.Authorization, `Bearer ${token}`);
    const path = new URL(url).pathname, body = options.body ? JSON.parse(options.body) : null;
    if (path === '/v1/job') return {ok: true, json: async () => ({job: currentJob})};
    events.push([path, body]);
    if (path === '/v1/result') result = body;
    if (path === '/v1/fail') fail = body;
    return {ok: true, json: async () => ({ok: true})};
  };
  const wake = () => new Promise(resolve => listener({type: 'wake'}, {id, url: `chrome-extension://${id}/wake.html`, tab: {id: 1}}, resolve));
  const settle = async () => { for (let i = 0; i < 200; i++) { await Promise.resolve(); await new Promise(resolve => realTimeout(resolve, 0)); if (result || fail) break; } };
  try {
    await import('../worker.js?mock-isolated');
    await wake(); await new Promise(resolve => realTimeout(resolve, 5));
    assert.equal(events.length, 0, 'no request means no X browsing');
    currentJob = {id: 'fixture-1', state: 'queued', policy: {source: 'following', maxAgeHours: 48}}; mode = 'normal';
    await wake(); await settle();
    assert.equal(result.posts.length, 1); assert.equal(result.posts[0].category, '职场');
    assert.equal(result.posts[0].discovery.followers, 25000); assert.equal(result.account, 'me');
    assert.equal(tabs.size, 0); assert.equal(events.filter(x => x[0] === '/v1/claim').length, 1);
    assert.ok(events.some(x => x[0] === 'create' && x[1] === 'https://x.com/home'));
    result = null; fail = null; mode = 'switch'; currentJob.id = 'fixture-2';
    await wake(); await settle();
    assert.equal(result, null); assert.match(fail.message, /账号发生变化/); assert.equal(tabs.size, 0);
    result = null; fail = null; mode = 'wrong-timeline'; currentJob.id = 'fixture-3';
    await wake(); await settle();
    assert.equal(result, null); assert.match(fail.message, /未确认正在关注/);
    result = null; fail = null; mode = 'normal';
    currentJob = {...currentJob, id: 'fixture-hot-materials', hotPreferences: {minimumLikes: 100, minimumReplies: 20, limit: 10}, autoDraft: false};
    await wake(); await settle();
    assert.equal(result.jobID, 'fixture-hot-materials');
    assert.equal(result.posts[0].discovery.likes, 12, 'extension passes actual metrics, never fabricates minimum heat');
    assert.equal(result.posts[0].discovery.replies, 3);
    assert.equal(tabs.size, 0, 'material job retains owned-tab cleanup without publication');
  } finally { globalThis.fetch = realFetch; globalThis.chrome = realChrome; globalThis.setTimeout = realTimeout; }
});
