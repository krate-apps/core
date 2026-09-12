// Load before most plugins (name sorts first) so extension init.js can wrap these stubs.
(function () {
	if (typeof theWebUI === 'undefined') {
		return;
	}
	if (typeof theWebUI.resizeBottom !== 'function') {
		theWebUI.resizeBottom = function () {};
	}
})();
