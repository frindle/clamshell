// Page side. Answers "collect" with the tab's scroll and media state, and applies "restore" after a tab is opened here.
(function () {
  'use strict';
  const ext = typeof browser !== 'undefined' ? browser : chrome;
  const core = globalThis.DeskTabSend;
  ext.runtime.onMessage.addListener(function (msg, _sender, sendResponse) {
    if (!msg || typeof msg !== 'object') return false;
    if (msg.type === 'desk-collect') {
      sendResponse(core.collectPageState(window, document));
      return false;
    }
    if (msg.type === 'desk-restore' && msg.tab) {
      core.applyPageState(window, document, msg.tab, function (fn, ms) { setTimeout(fn, ms); }).then(sendResponse);
      return true; // answer asynchronously
    }
    return false;
  });
})();
