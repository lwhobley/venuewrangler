{{flutter_js}}
{{flutter_build_config}}

// Serve CanvasKit from this deployment so the operator app does not depend on
// a third-party CDN at startup. The build uses --base-href=/app/.
_flutter.loader.load({
  config: { canvasKitBaseUrl: '/app/canvaskit/' },
});
