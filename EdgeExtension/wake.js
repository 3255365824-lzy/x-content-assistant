const result = await chrome.runtime.sendMessage({type: 'wake'});
if (!result.ok) document.getElementById('message').textContent = result.message;
else window.close();
