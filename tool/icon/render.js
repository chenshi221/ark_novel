// 把本目录的 SVG 渲染成 1024px PNG：node tool/icon/render.js（需要 Playwright + Chromium）
// logo.png 直接写到 assets/images/（App 内和旧版图标用），其余给 flutter_launcher_icons / flutter_native_splash 用
const { chromium } = require('playwright'); const fs = require('fs'); const path = require('path');
(async () => {
  const dir = __dirname; const b = await chromium.launch(); const p = await b.newPage({ viewport: { width: 1024, height: 1024 } });
  for (const n of ['logo','logo_foreground','logo_monochrome','logo_transparent','logo_transparent_dark']) {
    const svg = fs.readFileSync(path.join(dir, n + '.svg'), 'utf8');
    await p.setContent(`<html><body style="margin:0;background:transparent">${svg.replace('<svg ', '<svg width="1024" height="1024" ')}</body></html>`);
    await p.screenshot({ path: n === 'logo' ? path.join(dir, '../../assets/images/logo.png') : path.join(dir, n + '.png'), omitBackground: true, clip: { x: 0, y: 0, width: 1024, height: 1024 } });
  }
  await b.close();
})();
