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

  chrome.runtime.onInstalled.addListener(() => {
    void enableSidePanelAction();
  });

  chrome.runtime.onStartup.addListener(() => {
    void enableSidePanelAction();
  });

  void enableSidePanelAction();
})();
