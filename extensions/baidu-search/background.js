// Course-Thru 内置「新标签页 → 百度」逻辑
//
// 原则：不接管任何浏览器设置（不用 chrome_url_overrides，因此不会弹
// 「更改此网页是您的本意吗？」确认框），只监听新建标签页：如果它是
// chrome://newtab（新标签页页），就导航到百度。
//
// 注意：不能用 openerTabId 区分「用户新建」与「从链接新开」。
// Chrome 152 起，通过 UI（Ctrl+T / 点击加号）新建的标签页
// openerTabId 也非空（指向当前活动标签页），旧版 `!tab.openerTabId`
// 判断会把这类真实用户操作误拦截，导致点击加号不跳转百度。
// 因此只按 URL 判断：从链接/脚本新开的标签页地址是具体链接
// （非 newtab），不会被误伤。

const BAIDU_URL = "https://www.baidu.com/";

// isNewTabPage 判断地址是否属于「新标签页页」。
// 默认搜索被扩展接管后，部分版本的新标签页地址会变成
// chrome://new-tab-page-third-party，一并匹配。
function isNewTabPage(url) {
  if (!url) return false;
  return (
    url.startsWith("chrome://newtab") ||
    url.startsWith("chrome://new-tab-page-third-party")
  );
}

function redirectToBaidu(tabId) {
  chrome.tabs.update(tabId, { url: BAIDU_URL });
}

// 新建标签页：地址已是新标签页页，跳转到百度。
// onCreated 时地址常为空（未提交），此时不判断，交给下方 onUpdated 兜底。
chrome.tabs.onCreated.addListener((tab) => {
  if (isNewTabPage(tab.url)) {
    redirectToBaidu(tab.id);
  }
});

// 兜底：新建标签页在 onCreated 时地址为空，加载完成才变成 chrome://newtab，
// 这里在地址变化时再判断一次（同样只按 URL，不检查 opener）。
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (isNewTabPage(changeInfo.url)) {
    redirectToBaidu(tabId);
  }
});
