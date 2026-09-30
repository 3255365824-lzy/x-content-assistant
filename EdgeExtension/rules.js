export function countFromText(text) {
  if (typeof text !== 'string' || text.length > 200) return null;
  const m = text.replaceAll(',', '').match(/(?:^|\s)(\d+(?:\.\d+)?)\s*([kKmM万萬亿億]?)/);
  if (!m) return null;
  const multiplier = {k: 1e3, m: 1e6, '万': 1e4, '萬': 1e4, '亿': 1e8, '億': 1e8}[m[2].toLowerCase()] || 1;
  const count = Math.round(Number(m[1]) * multiplier);
  return Number.isSafeInteger(count) && count >= 0 && count <= 1e10 ? count : null;
}
export function normalizePost(raw, observedAt = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')) {
  let url;
  try { url = new URL(raw.url); } catch { return null; }
  const match = url.pathname.match(/^\/([A-Za-z0-9_]{1,15})\/status\/([1-9][0-9]{0,24})$/);
  if (url.origin !== 'https://x.com' || !match || url.username || url.password || raw.isRepost) return null;
  const text = typeof raw.text === 'string' ? raw.text.trim() : '';
  if (text.length < 8 || text.length > 12000 || !Number.isFinite(Date.parse(raw.publishedAt))) return null;
  const medical = /医学|健康|睡眠|运动|药物|临床|患者|疾病|医疗|疫苗|癌症|\b(medical|health|clinical|sleep|vaccine|medicine)\b/i.test(text);
  const ai = /人工智能|大模型|模型|机器学习|提示词|幻觉|\b(ai|llm|gpt|openai|claude|gemini|qwen|ollama|chatgpt|opus|codex|muse)\b/i.test(text);
  let category = medical ? '医学' : ai ? 'AI' :
    /数码|芯片|电脑|手机|软件|网络|路由|\b(wifi|vpn|iphone|mac)\b/i.test(text) ? '科技' :
    /职场|上班|下班|工资|公司|同事|加班|老板|工作/.test(text) ? '职场' :
    /吸血鬼|笑话|段子|搞笑|哈哈|😂|🤣/.test(text) ? '趣味' :
    /吃|饭|面|旅行|现金|红包|生活|周末|咖啡|睡觉/.test(text) ? '生活' :
    /觉得|认为|怎么看|道理|规律|胜负|观点/.test(text) ? '观点' : '其他';
  return {
    id: match[2], username: match[1], text, category,
    origin: 'Edge 可见页面 · 新帖筛选', createdAt: new Date(raw.publishedAt).toISOString().replace(/\.\d{3}Z$/, 'Z'),
    discovery: {observedAt, publishedAt: new Date(raw.publishedAt).toISOString().replace(/\.\d{3}Z$/, 'Z'), postURL: `https://x.com/${match[1]}/status/${match[2]}`,
      followers: null, followersSourceURL: null, likes: countFromText(raw.likeText), replies: countFromText(raw.replyText),
      isReply: !!raw.isReply, isPromoted: !!raw.isPromoted, textComplete: !!raw.textComplete,
      visualContextMissing: !!raw.hasMedia && /这(个|样|张|碗)|看图|视频里|如图|图里|秒懂|建模脸|看.{0,5}视频/.test(text)}
  };
}
export function searchURLs(hours, now = new Date()) {
  const since = new Date(now.getTime() - hours * 3600000).toISOString().slice(0, 10);
  return ['(AI OR 人工智能 OR 大模型 OR ChatGPT OR Claude)', '(医学 OR 医疗 OR 健康 OR 睡眠 OR 临床)'].map(topic => {
    const url = new URL('https://x.com/search');
    url.searchParams.set('q', `${topic} lang:zh -filter:replies -filter:retweets min_faves:5 since:${since}`);
    url.searchParams.set('f', 'live'); return url.href;
  });
}

// Spend the finite profile-reading budget only on posts that could actually be selected.
// Keep excluded posts in the result: the App remains authoritative and explains its skips.
export function profileCandidates(posts, account, policy, now = Date.now()) {
  return posts.filter(post => {
    const e = post.discovery, age = now - Date.parse(e.publishedAt);
    return post.username.toLowerCase() !== account.toLowerCase() && !e.isReply && !e.isPromoted && e.textComplete && !e.visualContextMissing &&
      age >= -300000 && age <= policy.maxAgeHours * 3600000 && !/互关|互fo|回关|邀请码|返佣|刷粉|follow.?back/i.test(post.text);
  }).sort((a, b) => (b.discovery.likes || 0) - (a.discovery.likes || 0));
}
