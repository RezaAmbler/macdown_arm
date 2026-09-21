(function () {

MathJax.Hub.Config({
	'showProcessingMessages': false,
	'messageStyle': 'none'
});

// Tell MacDown when typesetting has finished, so it can zoom and scroll-sync
// the preview against its final layout. Guarded because this same file is
// embedded into exported HTML, where there is no message handler to post to.
if (window.webkit && window.webkit.messageHandlers
		&& window.webkit.messageHandlers.MathJaxListener) {
	MathJax.Hub.Register.StartupHook('End', function () {
		window.webkit.messageHandlers.MathJaxListener.postMessage('End');
	});
}

})();
