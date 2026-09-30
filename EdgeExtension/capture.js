// Serialized into the isolated world of a tab created for this job. Only rendered DOM is read.
// No credential access, fetch, page messages, form entry or publication actions.
export function capturePage(mode = "posts", expectedHandle = "") {
  const main = document.querySelector('main');
  const profile = document.querySelector('a[data-testid="AppTabBar_Profile_Link"]');
  const account = profile?.getAttribute('href')?.match(/^\/([A-Za-z0-9_]{1,15})$/)?.[1];
  if (!main || !account) return {account: null, pending: true, posts: []};
  if (document.querySelector('iframe[src*="captcha"],input[autocomplete="one-time-code"]')) return {blocked: 'X 需要验证，请自行处理后重新获取', account, posts: []};
  const headings = [...main.querySelectorAll('h1,h2,[role="alert"]')].map(n => n.innerText).join(' ');
  if (/rate limit|请求过多|达到.*上限|temporarily limited|暂时受限/i.test(headings)) return {blocked: 'X 暂时限制读取，请稍后手动重试', account, posts: []};
  if (mode === 'profile') {
    const link = [...main.querySelectorAll('a[href]')].find(a => [
      `/${expectedHandle}/followers`, `/${expectedHandle}/verified_followers`
    ].some(p => a.getAttribute('href')?.toLowerCase() === p.toLowerCase()));
    return {account, followersText: link?.innerText || null};
  }
  const posts = [...main.querySelectorAll('article[data-testid="tweet"]')].slice(0, 40).map(article => {
    const time = article.querySelector('a[href*="/status/"] time');
    const link = time?.closest('a');
    const textNode = article.querySelector('[data-testid="tweetText"]');
    const context = article.querySelector('[data-testid="socialContext"]')?.innerText || '';
    const like = article.querySelector('[data-testid="like"],[data-testid="unlike"]');
    const reply = article.querySelector('[data-testid="reply"]');
    const labels = [...article.querySelectorAll('[data-testid="placementTracking"], [data-testid="promotedIndicator"]')];
    const visible = article.innerText;
    return {
      url: link?.href, publishedAt: time?.getAttribute('datetime'), text: textNode?.innerText || '',
      likeText: like?.getAttribute('aria-label') || like?.innerText || '',
      replyText: reply?.getAttribute('aria-label') || reply?.innerText || '',
      isReply: /^(Replying to|回复给|回覆給)/m.test(visible),
      isPromoted: labels.length > 0 || /^(Ad|Promoted|广告|廣告|推广)$/m.test(visible),
      isRepost: /reposted|转帖了|轉發了|转发了/i.test(context),
      textComplete: !!textNode && !article.querySelector('[data-testid="tweet-text-show-more-link"]'),
      hasMedia: !!article.querySelector('[data-testid="tweetPhoto"],[data-testid="videoPlayer"]')
    };
  });
  const followingSelected = [...main.querySelectorAll('[role="tab"][aria-selected="true"]')].some(n => /^(正在关注|正在關注|Following|跟隨中)$/.test(n.innerText.trim()));
  return {account, posts, followingSelected};
}

// Read-only navigation on a task-owned home tab. No generic click target is accepted.
export function selectFollowing() {
  if (location.origin !== 'https://x.com' || location.pathname !== '/home') return false;
  const tab = [...document.querySelectorAll('main [role="tab"]')].find(n => /^(正在关注|正在關注|Following|跟隨中)$/.test(n.innerText.trim()));
  if (!tab) return false;
  if (tab.getAttribute('aria-selected') !== 'true') tab.click();
  return true;
}

export function scrollOwnPage() { window.scrollBy(0, Math.min(window.innerHeight * 1.1, 1000)); }

export function safeToClose() {
  return ![...document.querySelectorAll('[contenteditable="true"],textarea')].some(n => (n.innerText || n.value || '').trim());
}
