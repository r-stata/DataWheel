// DataWheel — 预加载脚本
const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('api', {
  // 拖放得到的 File 对象 -> 本地绝对路径（必须在 preload 侧用 webUtils）
  pathForFile: (file) => {
    try { return webUtils.getPathForFile(file); } catch { return null; }
  },
  convert: (paths, target, outDir) => ipcRenderer.invoke('convert', paths, target, outDir || null),
  pickFiles: () => ipcRenderer.invoke('pick-files'),
  pickOutDir: () => ipcRenderer.invoke('pick-outdir'),
  reveal: (p) => ipcRenderer.invoke('reveal', p),
  openPath: (p) => ipcRenderer.invoke('open-path', p),
  getSettings: () => ipcRenderer.invoke('get-settings'),
  saveSettings: (s) => ipcRenderer.invoke('save-settings', s),
  getRecents: () => ipcRenderer.invoke('get-recents'),
  clearRecents: () => ipcRenderer.invoke('clear-recents'),
  onJob: (cb) => ipcRenderer.on('job', (_e, data) => cb(data)),
  onOpenFiles: (cb) => ipcRenderer.on('open-files', (_e, paths) => cb(paths)),
});
