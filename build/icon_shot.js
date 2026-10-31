// 渲染 HTML 为 PNG：electron iconshot2.js <html> <out> <size>
const { app, BrowserWindow } = require('electron');
const fs = require('fs');
// Electron 主进程 argv = [electron, flags..., script, args...]，定位脚本后的真实参数
const si = process.argv.findIndex(a => a.endsWith('.js') && !a.startsWith('-'));
const args = process.argv.slice(si + 1).filter(a => !a.startsWith('--'));
const page = args[0], out = args[1], size = parseInt(args[2] || '1024', 10);
app.whenReady().then(async () => {
  try {
    const win = new BrowserWindow({ width: size, height: size, show: false, frame: false,
                                    transparent: true, backgroundColor: '#00000000' });
    await win.loadFile(page);
    await new Promise(r => setTimeout(r, 800));
    const img = await win.webContents.capturePage({ x: 0, y: 0, width: size, height: size });
    fs.writeFileSync(out, img.toPNG());
    console.log('ICON_SAVED ' + out);
  } catch (e) { console.error('ERR', e); }
  setTimeout(() => app.quit(), 100);
});
