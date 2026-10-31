// DataWheel — 渲染进程：转盘交互 + 任务面板
const FORMATS = [
  { id: 'csv',     label: 'CSV',     color: '#F59E0B', desc: '逗号分隔文本' },
  { id: 'tsv',     label: 'TSV',     color: '#F97316', desc: '制表符文本' },
  { id: 'xlsx',    label: 'XLSX',    color: '#16A34A', desc: 'Excel 工作簿' },
  { id: 'dta',     label: 'DTA',     color: '#0891B2', desc: 'Stata 数据' },
  { id: 'rds',     label: 'RDS',     color: '#3B82F6', desc: 'R 数据文件' },
  { id: 'parquet', label: 'PARQUET', color: '#8B5CF6', desc: 'Parquet 列式' },
  { id: 'feather', label: 'FEATHER', color: '#EC4899', desc: 'Arrow Feather' },
  { id: 'json',    label: 'JSON',    color: '#65A30D', desc: 'JSON 记录' },
];

const SVG_R = 180;          // viewBox 中心
const INNER_R = 80, OUTER_R = 158;
const GAP_DEG = 3.2;

const layer = document.getElementById('donut-layer');
const anchor = document.getElementById('donut-anchor');
const svg = document.getElementById('donut-svg');
const hubCount = document.getElementById('hub-count');
const hubText = document.getElementById('hub-text');
const dropzone = document.getElementById('dropzone');
const jobsBox = document.getElementById('jobs');

// ---------- 转盘构建 ----------

function sectorPath(a0, a1, r0, r1) {
  const rad = (d) => (d * Math.PI) / 180;
  const px = (r, a) => (SVG_R + r * Math.cos(rad(a))).toFixed(2);
  const py = (r, a) => (SVG_R + r * Math.sin(rad(a))).toFixed(2);
  const large = a1 - a0 > 180 ? 1 : 0;
  return `M${px(r1, a0)},${py(r1, a0)} A${r1},${r1} 0 ${large} 1 ${px(r1, a1)},${py(r1, a1)} ` +
         `L${px(r0, a1)},${py(r0, a1)} A${r0},${r0} 0 ${large} 0 ${px(r0, a0)},${py(r0, a0)} Z`;
}

function buildDonut() {
  svg.innerHTML = '';
  const n = FORMATS.length;
  const span = 360 / n;
  FORMATS.forEach((f, i) => {
    const a0 = -90 + i * span + GAP_DEG / 2;
    const a1 = -90 + (i + 1) * span - GAP_DEG / 2;
    const mid = (a0 + a1) / 2;
    const rad = (mid * Math.PI) / 180;
    const lr = (INNER_R + OUTER_R) / 2 + 4;

    const g = document.createElementNS('http://www.w3.org/2000/svg', 'g');
    g.setAttribute('class', 'sector');
    g.dataset.fmt = f.id;
    g.dataset.i = i;

    const hit = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    hit.setAttribute('d', sectorPath(a0, a1, INNER_R, OUTER_R));
    hit.setAttribute('fill', f.color);
    hit.setAttribute('fill-opacity', '0.22');
    hit.setAttribute('stroke', '#ffffff');
    hit.setAttribute('stroke-width', '1.5');
    hit.setAttribute('class', 'sector-hit');

    const t = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    t.setAttribute('x', (SVG_R + lr * Math.cos(rad)).toFixed(1));
    t.setAttribute('y', (SVG_R + lr * Math.sin(rad)).toFixed(1));
    t.setAttribute('text-anchor', 'middle');
    t.setAttribute('dominant-baseline', 'middle');
    t.setAttribute('fill', '#3D4654');
    t.setAttribute('font-size', f.label.length > 5 ? '11.5' : '13');
    t.textContent = f.label;

    g.appendChild(hit);
    g.appendChild(t);
    svg.appendChild(g);
  });
}
buildDonut();

// ---------- 转盘状态 ----------

const donut = {
  visible: false,
  mode: 'drag',            // drag | click
  cx: 0, cy: 0,            // 锚点（转盘中心）位置
  targetX: 0, targetY: 0,  // 轻微漂移目标
  fileCount: 0,
  paths: [],
  hotIdx: -1,
  raf: 0,
};

function showDonut(cx, cy, mode, paths) {
  donut.visible = true;
  donut.mode = mode;
  donut.cx = donut.targetX = cx;
  donut.cy = donut.targetY = cy;
  donut.paths = paths || [];
  donut.fileCount = Math.max(donut.paths.length, donut.fileCount) || 1;
  donut.hotIdx = -1;

  anchor.style.left = cx + 'px';
  anchor.style.top = cy + 'px';
  anchor.classList.remove('leave');
  anchor.classList.remove('enter');
  void anchor.offsetWidth; // 重启动画
  anchor.classList.add('enter');
  layer.classList.remove('hidden');

  hubCount.textContent = donut.paths.length ? donut.paths.length : '·';
  setHubDefault();
  startLerp();
}

function hideDonut(immediate) {
  if (!donut.visible) return;
  donut.visible = false;
  cancelAnimationFrame(donut.raf);
  if (immediate) {
    layer.classList.add('hidden');
    anchor.classList.remove('enter', 'leave');
  } else {
    anchor.classList.remove('enter');
    anchor.classList.add('leave');
    setTimeout(() => {
      if (!donut.visible) {
        layer.classList.add('hidden');
        anchor.classList.remove('leave');
      }
    }, 230);
  }
  setHot(-1);
  donut.fileCount = 0;
}

function setHubDefault() {
  hubCount.textContent = donut.paths.length || '·';
  hubText.innerHTML = donut.mode === 'drag'
    ? (donut.fileCount > 1 ? '个文件<br/>拖到目标格式' : (donut.fileCount === 1 ? '个文件<br/>拖到目标格式' : '拖到目标格式'))
    : '点击扇区选择输出格式';
}

function setHot(idx) {
  if (idx === donut.hotIdx) return;
  donut.hotIdx = idx;
  svg.querySelectorAll('.sector').forEach((g, i) => g.classList.toggle('hot', i === idx));
  if (idx >= 0) {
    const f = FORMATS[idx];
    hubCount.textContent = '';
    hubText.innerHTML = `<b style="color:${f.color}">${f.label}</b>${f.desc} · 松开转换`;
  } else {
    setHubDefault();
  }
}

function pickSector(x, y) {
  const dx = x - donut.cx, dy = y - donut.cy;
  const r = Math.hypot(dx, dy);
  if (r < INNER_R - 6 || r > OUTER_R + 14) return -1;
  let deg = (Math.atan2(dy, dx) * 180) / Math.PI + 90; // 从正上方起算
  if (deg < 0) deg += 360;
  const span = 360 / FORMATS.length;
  const idx = Math.floor(deg / span);
  return idx >= 0 && idx < FORMATS.length ? idx : -1;
}

// 转盘轻微跟随光标漂移（保持锚定，产生"活"的感觉）
function startLerp() {
  cancelAnimationFrame(donut.raf);
  const step = () => {
    if (!donut.visible) return;
    donut.cx += (donut.targetX - donut.cx) * 0.045;
    donut.cy += (donut.targetY - donut.cy) * 0.045;
    anchor.style.left = donut.cx + 'px';
    anchor.style.top = donut.cy + 'px';
    donut.raf = requestAnimationFrame(step);
  };
  donut.raf = requestAnimationFrame(step);
}

// ---------- 拖放交互 ----------

function hasFiles(e) {
  return e.dataTransfer && [...(e.dataTransfer.types || [])].includes('Files');
}

document.addEventListener('dragenter', (e) => {
  if (!hasFiles(e)) return;
  e.preventDefault();
  donut.fileCount = e.dataTransfer.items ? e.dataTransfer.items.length : 1;
  if (!donut.visible) {
    showDonut(e.clientX, e.clientY, 'drag', []);
    donut.fileCount = e.dataTransfer.items ? e.dataTransfer.items.length : 1;
    hubCount.textContent = donut.fileCount;
  }
  dropzone.classList.add('armed');
});

document.addEventListener('dragover', (e) => {
  if (!hasFiles(e)) return;
  e.preventDefault();
  e.dataTransfer.dropEffect = 'copy';
  if (!donut.visible) return;
  // 光标向锚点轻微牵引（不超过 12px），悬停判定以光标相对锚点位置计算
  const pull = 0.05;
  const dx = e.clientX - donut.cx, dy = e.clientY - donut.cy;
  donut.targetX = donut.cx + Math.max(-12, Math.min(12, dx * pull));
  donut.targetY = donut.cy + Math.max(-12, Math.min(12, dy * pull));
  setHot(pickSector(e.clientX, e.clientY));
});

document.addEventListener('dragleave', (e) => {
  if (e.relatedTarget === null && !window.__dropping) {
    dropzone.classList.remove('armed');
    hideDonut(false);
  }
});

document.addEventListener('drop', async (e) => {
  e.preventDefault();
  window.__dropping = true;
  dropzone.classList.remove('armed');
  const files = [...(e.dataTransfer?.files || [])];
  const paths = files.map((f) => window.api.pathForFile(f)).filter(Boolean);
  const hotIdx = pickSector(e.clientX, e.clientY);

  if (!donut.visible) { window.__dropping = false; return; }

  if (hotIdx >= 0 && paths.length) {
    const target = FORMATS[hotIdx].id;
    hideDonut(false);
    await window.api.convert(paths, target);
  } else {
    hideDonut(false); // 未落在扇区上：取消
  }
  setTimeout(() => { window.__dropping = false; }, 60);
});

// ---------- 点按流程 ----------

document.getElementById('btn-pick').addEventListener('click', async () => {
  const paths = await window.api.pickFiles();
  if (!paths.length) return;
  showDonut(window.innerWidth / 2, window.innerHeight / 2 - 20, 'click', paths);
});

svg.addEventListener('click', async (e) => {
  if (donut.mode !== 'click' || !donut.visible) return;
  const idx = pickSector(e.clientX, e.clientY);
  if (idx < 0) return;
  const target = FORMATS[idx].id;
  const paths = donut.paths;
  hideDonut(false);
  await window.api.convert(paths, target);
});

svg.addEventListener('mousemove', (e) => {
  if (donut.visible) setHot(pickSector(e.clientX, e.clientY));
});

// Dock / 打开方式 送来的文件
window.api.onOpenFiles((paths) => {
  if (!paths.length) return;
  showDonut(window.innerWidth / 2, window.innerHeight / 2 - 20, 'click', paths);
});

// ---------- 任务面板 ----------

const formatColor = (id) => (FORMATS.find((f) => f.id === id) || {}).color || '#666';

function timeStr(ts) {
  const d = new Date(ts);
  const p = (x) => String(x).padStart(2, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}`;
}

window.api.onJob(async (j) => {
  if (j.event === 'start') return;
  const base = j.file ? j.file.split('/').pop() : '';
  const target = j.result?.target || j.target || '';

  if (j.event === 'stage') {
    let card = document.getElementById('job-' + jobIdOf(j));
    if (!card) {
      card = makeCard(jobIdOf(j), base, target);
      jobsBox.prepend(card);
    }
    card.querySelector('.job-spin').style.display = '';
    const meta = card.querySelector('.job-meta');
    if (meta) meta.textContent = j.stage === 'reading' ? '读取中…' : '写出中…';
  }

  if (j.event === 'done') {
    const card = makeCard(jobIdOf(j), base, j.result.target);
    card.querySelector('.job-status').innerHTML =
      `<div class="job-ico ok">✓</div>`;
    card.querySelector('.job-meta').textContent =
      `${j.result.rows} 行 × ${j.result.cols} 列 · ${j.result.elapsed}s`;
    if (j.warning) {
      const w = document.createElement('div');
      w.className = 'job-warn';
      w.textContent = '⚠ ' + j.warning;
      card.appendChild(w);
    }
    const acts = document.createElement('div');
    acts.className = 'job-actions';
    acts.innerHTML = `
      <button class="btn-ghost small" data-act="open">打开</button>
      <button class="btn-ghost small" data-act="reveal">在 Finder 中显示</button>`;
    acts.querySelector('[data-act="open"]').onclick = () => window.api.openPath(j.result.output);
    acts.querySelector('[data-act="reveal"]').onclick = () => window.api.reveal(j.result.output);
    card.appendChild(acts);
    const old = document.getElementById('job-' + jobIdOf(j));
    if (old) old.remove();
    jobsBox.prepend(card);
    loadRecents();
    setTimeout(() => dismissCard(card, 400), 12000);
  }

  if (j.event === 'fail') {
    const card = makeCard(jobIdOf(j), base, target);
    card.querySelector('.job-status').innerHTML = `<div class="job-ico bad">✕</div>`;
    const err = document.createElement('div');
    err.className = 'job-err';
    err.textContent = j.error || '转换失败';
    card.appendChild(err);
    const old = document.getElementById('job-' + jobIdOf(j));
    if (old) old.remove();
    jobsBox.prepend(card);
  }
});

let cardSeq = 0;
const cardIds = new Map(); // file -> cardId
function jobIdOf(j) {
  if (!cardIds.has(j.file)) cardIds.set(j.file, 'c' + (++cardSeq));
  return cardIds.get(j.file);
}

function makeCard(id, name, target) {
  let card = document.getElementById('job-' + id);
  if (card) return card;
  card = document.createElement('div');
  card.className = 'job-card';
  card.id = 'job-' + id;
  card.innerHTML = `
    <div class="job-row">
      <div class="job-status"><div class="job-spin"></div></div>
      <div class="job-file">${escapeHtml(name)}</div>
      <span class="rc-badge" style="background:${formatColor(target)}">${(target || '').toUpperCase()}</span>
      <button class="job-x" title="关闭">×</button>
    </div>
    <div class="job-meta">准备中…</div>`;
  card.querySelector('.job-x').onclick = () => card.remove();
  return card;
}

function dismissCard(card, delay) {
  setTimeout(() => {
    card.style.transition = 'opacity .4s, transform .4s';
    card.style.opacity = '0';
    card.style.transform = 'translateY(8px)';
    setTimeout(() => card.remove(), 420);
  }, delay);
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// ---------- 最近转换 ----------

async function loadRecents() {
  const items = await window.api.getRecents();
  const list = document.getElementById('recents-list');
  const empty = document.getElementById('recents-empty');
  list.innerHTML = '';
  empty.style.display = items.length ? 'none' : '';
  items.slice(0, 12).forEach((r) => {
    const li = document.createElement('li');
    const inName = r.input.split('/').pop();
    li.innerHTML = `
      <span class="rc-name" title="${escapeHtml(r.output)}">${escapeHtml(inName)} <span class="rc-arrow">→</span> ${escapeHtml(r.output.split('/').pop())}</span>
      <span class="rc-badge" style="background:${formatColor(r.target)}">${(r.target || '').toUpperCase()}</span>
      <span class="rc-meta">${r.rows}×${r.cols}</span>
      <span class="rc-time">${timeStr(r.time)}</span>
      <button class="rc-open">显示</button>`;
    li.querySelector('.rc-open').onclick = () => window.api.reveal(r.output);
    list.appendChild(li);
  });
}
document.getElementById('btn-clear-recents').onclick = async () => {
  await window.api.clearRecents();
  loadRecents();
};
loadRecents();

// ---------- 设置 ----------

const modal = document.getElementById('settings-modal');
document.getElementById('btn-settings').onclick = async () => {
  const s = await window.api.getSettings();
  document.getElementById('set-python').value = s.pythonPath || '';
  document.querySelector(`input[name="outmode"][value="${s.outputMode}"]`).checked = true;
  document.getElementById('set-outdir').value = s.customOutDir || '';
  modal.classList.remove('hidden');
};
document.getElementById('btn-settings-cancel').onclick = () => modal.classList.add('hidden');
document.getElementById('btn-browse-outdir').onclick = async () => {
  const p = await window.api.pickOutDir ? await window.api.pickOutDir() : null;
  if (p) document.getElementById('set-outdir').value = p;
};
document.getElementById('btn-settings-save').onclick = async () => {
  await window.api.saveSettings({
    pythonPath: document.getElementById('set-python').value.trim(),
    outputMode: document.querySelector('input[name="outmode"]:checked').value,
    customOutDir: document.getElementById('set-outdir').value.trim(),
  });
  modal.classList.add('hidden');
};

// ---------- 截图演示模式（视觉验证用） ----------

if (new URLSearchParams(location.search).get('shot') === '1') {
  setTimeout(() => {
    showDonut(window.innerWidth / 2, window.innerHeight / 2 - 10, 'click', ['/Users/demo/sample.dta']);
    setHot(3);
  }, 700);
}
