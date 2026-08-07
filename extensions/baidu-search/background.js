// Course-Thru 内置「新标签页 → 百度」逻辑
//
// 原则：不接管任何浏览器设置（不用 chrome_url_overrides，因此不会弹
// 「更改此网页是您的本意吗？」确认框），只监听新建标签页：如果它是
// chrome://newtab（新标签页页），就导航到百度；从链接/脚本新开的标签页
// （带 openerTabId）一律不碰。

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

// 新建标签页：地址尚未提交（为空）或已是新标签页页，且没有 opener
// （不是从链接新开的），跳转到百度。
chrome.tabs.onCreated.addListener((tab) => {
  if (!tab.openerTabId && (isNewTabPage(tab.url) || !tab.url)) {
    redirectToBaidu(tab.id);
  }
});

// 兜底：部分版本在 onCreated 时地址为空、加载完成才变成 chrome://newtab，
// 这里在地址变化时再判断一次。
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (isNewTabPage(changeInfo.url) && !tab.openerTabId) {
    redirectToBaidu(tabId);
  }
});
