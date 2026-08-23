(() => {
  const enableSidePanelAction = async () => {
    try {
      if (chrome.sidePanel?.setPanelBehavior) {
        await chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true });
      }
    } catch {
      // Older Chromium builds may expose MV3 without the sidePanel API.
    }
  };

  // T4: content scripts (core.js) can't read their own tab id, so they ask the service worker, which
  // reads it from the message sender. Returns { tabId } (null when there's no owning tab). We return true
  // to keep the sendResponse channel open for the async-safe reply.
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message && message.type === "recap-tab-id") {
      sendResponse({ tabId: sender.tab?.id ?? null });
      return true;
    }
    return undefined;
  });

  chrome.runtime.onInstalled.addListener(() => {
    void enableSidePanelAction();
  });

  chrome.runtime.onStartup.addListener(() => {
    void enableSidePanelAction();
  });

  void enableSidePanelAction();
})();
