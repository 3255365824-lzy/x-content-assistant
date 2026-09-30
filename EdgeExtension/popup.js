const message = document.getElementById('message');
document.getElementById('pair').onclick = async () => {
  const input = document.getElementById('code'), code = input.value.trim(); input.value = '';
  const result = await chrome.runtime.sendMessage({type: 'pair', code});
  message.textContent = result.ok ? '连接成功。回到 App，点击“获取新帖”。' : result.message;
};
document.getElementById('status').onclick = async () => {
  const result = await chrome.runtime.sendMessage({type: 'status'}); message.textContent = result.message;
};
