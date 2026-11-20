(function () {
  'use strict';
  const ext = typeof browser !== 'undefined' ? browser : chrome;
  const core = globalThis.DeskTabSend;
  const ids = ['port', 'token', 'targetName'];
  ext.storage.local.get(ids).then(function (raw) {
    const s = core.normalizeSettings(raw);
    ids.forEach(function (id) { document.getElementById(id).value = s[id]; });
  });
  ids.forEach(function (id) {
    document.getElementById(id).addEventListener('change', function () {
      const raw = {};
      ids.forEach(function (k) { raw[k] = document.getElementById(k).value; });
      raw.port = parseInt(raw.port, 10);
      const s = core.normalizeSettings(raw);
      ext.storage.local.set(s).then(function () { document.getElementById('saved').textContent = 'Saved.'; });
    });
  });
  // Permission requests must come from a click.
  function grant(id, origins) {
    document.getElementById(id).addEventListener('click', function () {
      ext.permissions.request({ origins: origins }).then(function (ok) {
        document.getElementById('saved').textContent = ok ? 'Access allowed.' : 'Access not allowed.';
      });
    });
  }
  grant('grantLocal', ['http://127.0.0.1/*']);
  grant('grantPages', ['http://*/*', 'https://*/*']);
})();
