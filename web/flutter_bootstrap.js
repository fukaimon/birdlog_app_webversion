{{flutter_js}}
{{flutter_build_config}}
_flutter.loader.load({
  config: {canvasKitBaseUrl: 'canvaskit/'},
  onEntrypointLoaded: async function(initializer) {
    const app = await initializer.initializeEngine();
    await app.runApp();
    document.getElementById('startup')?.remove();
  }
});
