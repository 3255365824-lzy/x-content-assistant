import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {countFromText, normalizePost, searchURLs, profileCandidates} from '../rules.js';

test('visible count parser handles local formats, never treats blue checks as counts', () => {
  for (const [raw, count] of [['1,234 Followers', 1234], ['1.2万 位关注者', 12000], ['3.5M Followers', 3500000], ['24 likes. Like', 24], ['Verified', null], ['', null], [null, null]]) assert.equal(countFromText(raw), count);
});
test('source identity, category, dates and completeness retained', () => {
  const raw = {url: 'https://x.com/large/status/95101', text: 'AI 模型演示和实际使用场景并不总是一样。', publishedAt: '2026-09-28T04:00:00.000Z', textComplete: true, likeText: '10 likes'};
  const post = normalizePost(raw, '2026-09-28T05:00:00Z');
  assert.equal(post.username, 'large'); assert.equal(post.discovery.publishedAt, '2026-09-28T04:00:00Z');
  assert.equal(post.discovery.followers, null); assert.equal(post.discovery.likes, 10);
  assert.equal(normalizePost({...raw, url: 'https://x.com.evil.invalid/large/status/95101'}), null);
  assert.equal(normalizePost({...raw, publishedAt: 'unknown'}), null);
  assert.equal(normalizePost({...raw, isRepost: true}), null);
  assert.equal(normalizePost({...raw, text: '今天不知道吃什么晚饭。'}).category, '生活');
  assert.equal(normalizePost({...raw, text: '公司几号发工资能看出公司的实力吗？'}).category, '职场');
  assert.equal(normalizePost({...raw, text: '这碗面在你生活的城市卖多少钱合适？', hasMedia: true}).discovery.visualContextMissing, true);
  assert.equal(normalizePost({...raw, textComplete: false}).discovery.textComplete, false);
});
test('search navigation stays on X latest and has finite dates', () => {
  const urls = searchURLs(48, new Date('2026-09-28T05:00:00Z'));
  assert.equal(urls.length, 2);
  for (const raw of urls) { const url = new URL(raw); assert.equal(url.origin, 'https://x.com'); assert.equal(url.searchParams.get('f'), 'live'); assert.match(url.searchParams.get('q'), /since:2026-09-26/); }
});
test('profile budget excludes stale, incomplete and image-dependent posts without mutating source array', () => {
  const now = Date.parse('2026-09-28T05:00:00Z');
  const post = normalizePost({url: 'https://x.com/author/status/95101', text: '普通生活也有值得接话的具体细节。', publishedAt: new Date(now - 3600000).toISOString(), textComplete: true});
  const stale = structuredClone(post); stale.discovery.publishedAt = '2026-09-20T00:00:00Z';
  const image = structuredClone(post); image.discovery.visualContextMissing = true;
  const short = structuredClone(post); short.discovery.textComplete = false;
  const input = [stale, image, short, post], before = JSON.stringify(input);
  assert.deepEqual(profileCandidates(input, 'me', {maxAgeHours: 48}, now), [post]);
  assert.equal(JSON.stringify(input), before);
});
test('manifest is limited and contains no secret or executable remote content', () => {
  const manifest = JSON.parse(readFileSync(new URL('../manifest.json', import.meta.url)));
  assert.deepEqual(manifest.permissions, ['storage', 'scripting', 'alarms']);
  assert.deepEqual(manifest.host_permissions, ['https://x.com/*', 'http://127.0.0.1/*']);
  assert.equal(manifest.externally_connectable, undefined); assert.equal(manifest.content_scripts, undefined);
  const capture = readFileSync(new URL('../capture.js', import.meta.url), 'utf8');
  assert.doesNotMatch(capture, /fetch\(|document\.cookie|localStorage|sessionStorage|dispatchEvent|execCommand/);
  assert.equal((capture.match(/\.click\(/g) || []).length, 1); // Only the fixed Following navigation tab.
  assert.match(capture, /location\.pathname !== '\/home'/);
});
