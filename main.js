// DataWheel — 主进程
const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { spawn } = require('child_process');

app.setName('DataWheel');

const DEFAULTS = {
  pythonPath: '',            // 空 = 自动探测
  outputMode: 'source',      // source | ask | custom
  customOutDir: '',
};

let win = null;
let pendingOpenFiles = [];

function settingsPath() {
  return path.join(app.getPath('userData'), 'settings.json');
}
function recentsPath() {
  return path.join(app.getPath('userData'), 'recents.json');
}

function loadJSON(p, fallback) {
  try { return { ...fallback, ...JSON.parse(fs.readFileSync(p, 'utf8')) }; }
  catch { return { ...fallback }; }
}

function getSettings() {
  const s = loadJSON(settingsPath(), DEFAULTS);
  if (!s.pythonPath) s.pythonPath = autoPython();
  return s;
}

// 自动探测 Python：应用内置 venv -> 项目 venv -> 系统 python3
function autoPython() {
  const candidates = [
    path.join(__dirname, '.venv', 'bin', 'python'),
    path.join(__dirname, '..', '.venv', 'bin', 'python'),
    '/opt/homebrew/bin/python3',
    '/usr/local/bin/python3',
  ];
  for (const c of candidates) {
    try { if (fs.existsSync(c)) return c; } catch {}
  }
  return 'python3';
}

// ---------- 转换任务 ----------

const jobs = new Map();
let jobSeq = 0;

function runEngine(args, onLine) {
  return new Promise((resolve) => {
    const settings = getSettings();
    const enginePath = path.join(__dirname, 'engine', 'engine.py');
    const proc = spawn(settings.pythonPath, [enginePath, ...args], {
      cwd: __dirname,
      env: { ...process.env, PYTHONUNBUFFERED: '1' },
    });
    let buf = '';
    proc.stdout.on('data', (d) => {
      buf += d.toString();
      let idx;
      while ((idx = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, idx).trim();
        buf = buf.slice(idx + 1);
        if (line) onLine(line);
      }
    });
    let stderr = '';
    proc.stderr.on('data', (d) => { stderr += d.toString(); });
    proc.on('error', (err) => resolve({ ok: false, error: '无法启动 Python: ' + err.message }));
    proc.on('close', () => resolve(null));
    // 超时保护：15 分钟
    setTimeout(() => { try { proc.kill(); } catch {} }, 15 * 60 * 1000).unref();
  });
}

ipcMain.handle('convert', async (_e, filePaths, target, outDirOverride) => {
  const settings = getSettings();
  const jobId = ++jobSeq;
  const fileList = [...filePaths];

  jobs.set(jobId, { target, total: fileList.length });
  win?.webContents.send('job', {
    jobId, event: 'start', target, files: fileList, total: fileList.length,
  });

  for (const fp of fileList) {
    // 输出目录
    let outDir = path.dirname(fp);
    if (outDirOverride) outDir = outDirOverride;
    else if (settings.outputMode === 'custom' && settings.customOutDir) outDir = settings.customOutDir;
    else if (settings.outputMode === 'ask') {
      const r = await dialog.showMessageBox(win, {
        type: 'question',
        message: '选择输出目录',
        detail: path.basename(fp) + ' → ' + target.toUpperCase(),
        buttons: ['选择目录…', '保存到源文件目录', '取消'],
        defaultId: 0,
      });
      if (r.response === 2) {
        win?.webContents.send('job', { jobId, event: 'skip', file: fp });
        continue;
      }
      if (r.response === 0) {
        const d = await dialog.showOpenDialog(win, { properties: ['openDirectory', 'createDirectory'] });
        if (d.canceled || !d.filePaths[0]) {
          win?.webContents.send('job', { jobId, event: 'skip', file: fp });
          continue;
        }
        outDir = d.filePaths[0];
      }
    }

    const base = path.basename(fp);
    win?.webContents.send('job', { jobId, event: 'stage', file: fp, stage: 'reading' });

    const lines = [];
    const result = await runEngine(
      ['convert', '--input', fp, '--to', target, '--out', outDir],
      (line) => {
        lines.push(line);
        try {
          const j = JSON.parse(line);
          if (j.event === 'stage') {
            win?.webContents.send('job', { jobId, event: 'stage', file: fp, stage: j.stage });
          }
        } catch {}
      }
    );

    let out = null;
    for (let i = lines.length - 1; i >= 0; i--) {
      try { const j = JSON.parse(lines[i]); if (j.event === undefined) { out = j; break; } } catch {}
    }

    if (out && out.ok) {
      const rec = {
        time: Date.now(), input: fp, output: out.output, target,
        rows: out.rows, cols: out.cols, elapsed: out.elapsed,
      };
      addRecent(rec);
      win?.webContents.send('job', { jobId, event: 'done', file: fp, result: rec, warning: out.warning || null });
    } else if (out && !out.ok) {
      win?.webContents.send('job', { jobId, event: 'fail', file: fp, error: out.error });
    } else {
      win?.webContents.send('job', { jobId, event: 'fail', file: fp, error: '转换进程异常退出' + (stderr ? '：' + stderr.slice(-300) : '') });
    }
  }

  win?.webContents.send('job', { jobId, event: 'end' });
  jobs.delete(jobId);
  return true;
});

function addRecent(rec) {
  const list = loadJSON(recentsPath(), { items: [] }).items;
  list.unshift(rec);
  try { fs.writeFileSync(recentsPath(), JSON.stringify({ items: list.slice(0, 30) })); } catch {}
}

// ---------- 其他 IPC ----------

ipcMain.handle('pick-files', async () => {
  const r = await dialog.showOpenDialog(win, {
    properties: ['openFile', 'multiSelections'],
    filters: [
      { name: '数据文件', extensions: ['csv', 'tsv', 'txt', 'xlsx', 'xls', 'dta', 'rds', 'rdata', 'parquet', 'pq', 'feather', 'arrow', 'json', 'jsonl', 'ndjson'] },
      { name: '所有文件', extensions: ['*'] },
    ],
  });
  return r.canceled ? [] : r.filePaths;
});

ipcMain.handle('pick-outdir', async () => {
  const r = await dialog.showOpenDialog(win, { properties: ['openDirectory', 'createDirectory'] });
  return r.canceled ? null : r.filePaths[0];
});

ipcMain.handle('reveal', (_e, p) => { shell.showItemInFolder(p); });
ipcMain.handle('open-path', (_e, p) => { shell.openPath(p); });
ipcMain.handle('get-settings', () => getSettings());
ipcMain.handle('save-settings', (_e, s) => {
  const cur = getSettings();
  const next = { ...cur, ...s };
  fs.mkdirSync(path.dirname(settingsPath()), { recursive: true });
  fs.writeFileSync(settingsPath(), JSON.stringify(next, null, 2));
  return true;
});
ipcMain.handle('get-recents', () => loadJSON(recentsPath(), { items: [] }).items);
ipcMain.handle('clear-recents', () => { try { fs.writeFileSync(recentsPath(), JSON.stringify({ items: [] })); } catch {} return true; });

// ---------- 窗口 ----------

function createWindow() {
  win = new BrowserWindow({
    width: 980, height: 660,
    minWidth: 780, minHeight: 560,
    show: false,
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 18, y: 17 },
    backgroundColor: '#F6F7F9',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'), {
    query: process.env.DATAWHEEL_SHOT ? { shot: '1' } : {},
  });
  win.once('ready-to-show', () => win.show());

  // 截图调试模式：加载后截屏并退出
  if (process.env.DATAWHEEL_SHOT) {
    win.webContents.once('did-finish-load', async () => {
      setTimeout(async () => {
        try {
          const img = await win.webContents.capturePage();
          const out = process.env.DATAWHEEL_SHOT;
          fs.writeFileSync(out, img.toPNG());
          console.log('SHOT_SAVED ' + out);
        } catch (e) { console.error('shot fail', e); }
        app.quit();
      }, Number(process.env.DATAWHEEL_SHOT_DELAY || 2600));
    });
  }
}

// Finder 拖到 Dock 图标 / 双击打开
app.on('open-file', (event, filePath) => {
  event.preventDefault();
  pendingOpenFiles.push(filePath);
  if (win) {
    win.webContents.send('open-files', pendingOpenFiles);
    pendingOpenFiles = [];
  }
});

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});

app.on('window-all-closed', () => { app.quit(); });
