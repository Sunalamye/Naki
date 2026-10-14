window.__nakiPlugins.register({
  id: 'com.naki.example.settings-page',
  onReceive(ctx) {
    if (!ctx.settings.enabled) return;
    for (let i = 0; i < ctx.settings.repeat; i++) ctx.log(ctx.settings.note);
  },
});
