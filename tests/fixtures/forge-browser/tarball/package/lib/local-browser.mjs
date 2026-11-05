export async function launch(chromium, dir, b) {
    const base = {
      headless: b.headless,
      viewport: null,
      args: ['--window-size=1280,900', '--no-first-run', '--no-default-browser-check'],
    };
    return chromium.launchPersistentContext(dir, base);
}
