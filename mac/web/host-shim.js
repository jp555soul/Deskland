// Injected by the macOS host into the top frame of every page before the page's own scripts run.
// The upstream pages talk to their Windows host through WebView2's window.chrome.webview; this
// provides the same object on top of WKWebView so the pages run unmodified.
(function () {
  'use strict';
  if (window.chrome && window.chrome.webview) return;
  var handlers = window.webkit && window.webkit.messageHandlers;
  if (!handlers || !handlers.host) return;

  var listeners = [];
  window.chrome = window.chrome || {};
  window.chrome.webview = {
    postMessage: function (m) { handlers.host.postMessage(typeof m === 'string' ? m : JSON.stringify(m)); },
    addEventListener: function (type, fn) { if (type === 'message' && listeners.indexOf(fn) < 0) listeners.push(fn); },
    removeEventListener: function (type, fn) { var i = listeners.indexOf(fn); if (type === 'message' && i >= 0) listeners.splice(i, 1); }
  };
  // The host calls this with the same string WebView2's PostWebMessageAsString would deliver.
  window.__hostDispatch = function (data) {
    listeners.slice().forEach(function (fn) {
      try { fn({ data: data }); } catch (e) { console.error(e); }
    });
  };

  // WKWebView drops alert() unless the host shows it.
  window.alert = function (msg) { if (handlers.hostAlert) handlers.hostAlert.postMessage(String(msg)); };

  // share.js squeezes colours into 16–235 and patches the MP4 header to work around how Chromium
  // tags H.264. WebKit's recorder tags its output correctly, so record full range and skip both.
  window.__recFullRange = true;

  window.addEventListener('contextmenu', function (e) { e.preventDefault(); });

  // Upstream asks modified builds to carry their own name.
  document.addEventListener('DOMContentLoaded', function () {
    var brand = document.querySelector('.brand');
    if (brand) { brand.textContent = '__APP_NAME__'; document.title = '__APP_NAME__'; }
    var dl = document.getElementById('shareDownload');
    if (dl) dl.setAttribute('download', '__APP_NAME__.png');
  });
})();
