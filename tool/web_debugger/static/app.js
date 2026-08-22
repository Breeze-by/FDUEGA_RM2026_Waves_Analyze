const state = {
  config: null,
  activeTab: "sim",
  currentJobByTask: { sim: null, tx: null, rx: null, auto_rx: null },
  pollTimer: null,
  autoMatch: {
    wasStarted: false,
    matchId: 0,
    parsed: {},
  },
};

const TASK_NAME = {
  sim: "仿真",
  tx: "发射",
  rx: "接收",
  auto_rx: "自动解析",
};

const TASK_NAME_EN = {
  sim: "Simulation",
  tx: "Transmit / waveform generation",
  rx: "Receive",
  auto_rx: "Automatic jammer-key decode",
};

const STATUS_NAME = {
  queued: "排队中",
  running: "运行中",
  stopping: "停止中",
  completed: "已完成",
  failed: "失败",
  unknown: "未知",
};

const METRIC_NAME = {
  sourceName: "波源名称",
  displayName: "波源",
  waveType: "波形类型",
  centerFrequencyHz: "中心频点",
  rfBandwidthHz: "射频带宽",
  powerDbm: "额定功率",
  sampleRateHz: "采样率",
  symbolRateHz: "符号率",
  sps: "每符号采样点",
  bt: "BT",
  deltaFHz: "频偏",
  sensitivity: "灵敏度",
  captureDurationSec: "采集时长",
  bwLpfHz: "解调低通",
  referenceMode: "参考模式",
  maxFrameSuccessRate: "最高协议帧成功率",
  maxPacketSuccessRate: "最高 OTA 成功率",
  minBer: "最低误码率",
  points: "仿真点数",
  expectedOtaPacketCount: "期望 OTA 包数",
  validOtaPacketCount: "有效 OTA 包数",
  packetSuccessRate: "OTA 成功率",
  packetLossCount: "OTA 丢包数",
  expectedProtocolFrameCount: "期望协议帧数",
  validProtocolFrameCount: "有效协议帧数",
  frameSuccessRate: "协议帧成功率",
  frameLossCount: "协议帧丢失数",
  bestPhase: "最优采样相位",
  bestBitShift: "最优比特移位",
  enablePlutoTx: "启用 Pluto 发射",
  radioId: "发射设备地址",
  txGainDb: "发射增益",
  txTimeSec: "发射时长",
  txReleased: "发射设备已释放",
  sampleCount: "样本数",
  bufferDurationSec: "缓存时长",
  bitCount: "比特数",
  protocolFrameCountPerCycle: "每周期协议帧数",
  otaPacketCountPerCycle: "每周期 OTA 包数",
  payloadBytesPerCycle: "每周期有效字节",
  cycleDurationSec: "单周期时长",
  gameStarted: "比赛状态",
  teamColor: "己方颜色",
  jammerLevel: "干扰等级",
  actionReason: "自动逻辑",
  attemptCount: "尝试次数",
  success: "解析成功",
  key: "干扰密钥",
};

const FRAME_TYPE_NAME = {
  broadcast_positions: "位置信息",
  broadcast_hp: "血量信息",
  broadcast_projectiles: "弹量信息",
  broadcast_economy: "经济与增益点状态",
  broadcast_buffs: "机器人增益",
  jammer_key: "干扰密钥",
};

const FRAME_TYPE_NAME_EN = {
  broadcast_positions: "positions",
  broadcast_hp: "hp",
  broadcast_projectiles: "projectiles",
  broadcast_economy: "economy",
  broadcast_buffs: "buffs",
  jammer_key: "jammer_key",
};

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(text || `${res.status} ${res.statusText}`);
  }
  return res.json();
}

function setActiveTab(tab) {
  state.activeTab = tab;
  $$(".tab").forEach((btn) => btn.classList.toggle("active", btn.dataset.tab === tab));
  $$("[data-panel]").forEach((panel) => panel.classList.toggle("active", panel.dataset.panel === tab));
  $$("[data-result-panel]").forEach((panel) => panel.classList.toggle("active", panel.dataset.resultPanel === tab));
}

function fillSources() {
  const options = state.config.sources
    .map((s) => `<option value="${s.value}">${s.label} · ${s.type}</option>`)
    .join("");
  $$("select[data-source]").forEach((select) => {
    select.innerHTML = options;
  });
  $("#simForm [name=SourceName]").value = state.config.sim.SourceName;
  $("#txForm [name=SourceName]").value = state.config.tx.SourceName;
  $("#rxForm [name=SourceName]").value = state.config.rx.SourceName;
  $("#autoForm [name=TeamColor]").value = state.config.auto_rx.TeamColor;
  $("#autoForm [name=JammerLevel]").value = String(state.config.auto_rx.JammerLevel);
}

function formData(form) {
  const data = {};
  Array.from(form.elements).forEach((el) => {
    if (!el.name) return;
    if (el.type === "checkbox") {
      data[el.name] = el.checked;
    } else if (el.type === "number") {
      data[el.name] = el.value === "" ? "" : Number(el.value);
    } else {
      data[el.name] = el.value;
    }
  });
  return data;
}

async function submitJob(task, form) {
  const payload = { task, params: formData(form) };
  const data = await api("/api/jobs", { method: "POST", body: JSON.stringify(payload) });
  state.currentJobByTask[task] = data.job.id;
  renderJob(task, data.job);
  startPolling();
  await refreshJobs();
}

async function handleAutoStatus(form) {
  const params = formData(form);
  const level = Number(params.JammerLevel);
  const started = Boolean(params.GameStarted);
  const autoBox = $("#autoStateBox");

  if (!started) {
    if (state.autoMatch.wasStarted) {
      state.autoMatch.matchId += 1;
      state.autoMatch.parsed = {};
    }
    state.autoMatch.wasStarted = false;
    if (autoBox) autoBox.textContent = "比赛未开始或已结束，已等待下一局开始。";
    return;
  }

  if (!state.autoMatch.wasStarted) {
    state.autoMatch.wasStarted = true;
    state.autoMatch.matchId += 1;
    state.autoMatch.parsed = {};
  }

  if (![1, 2, 3].includes(level)) {
    if (autoBox) autoBox.textContent = "当前干扰等级为无，不需要解析。";
    return;
  }

  const dedupeKey = `${state.autoMatch.matchId}:${params.TeamColor}:${level}`;
  const parsed = state.autoMatch.parsed[dedupeKey];
  if (parsed) {
    if (autoBox) autoBox.textContent = `本局比赛该等级已经解析过：${parsed.sourceName}，密钥 ${parsed.key}。等级不变时不会重复接收。`;
    return;
  }

  if (autoBox) autoBox.textContent = "状态需要解析，正在启动自动接收。";
  await submitJob("auto_rx", form);
}

function startPolling() {
  if (state.pollTimer) return;
  state.pollTimer = setInterval(async () => {
    await refreshRunningJobs();
  }, 1500);
}

async function refreshRunningJobs() {
  const tasks = Object.keys(state.currentJobByTask);
  let hasRunning = false;
  for (const task of tasks) {
    const jobId = state.currentJobByTask[task];
    if (!jobId) continue;
    const data = await api(`/api/jobs/${jobId}`);
    renderJob(task, data.job);
    const jobState = data.job.status?.state || "unknown";
    if (["queued", "running", "stopping"].includes(jobState)) {
      hasRunning = true;
    }
  }
  if (!hasRunning && state.pollTimer) {
    clearInterval(state.pollTimer);
    state.pollTimer = null;
    await refreshJobs();
  }
}

async function refreshLog(task, jobId) {
  const box = $(`[data-log="${task}"]`);
  if (!box) return;
  try {
    const res = await fetch(`/api/jobs/${jobId}/log?t=${Date.now()}`, { cache: "no-store" });
    box.textContent = res.ok ? await res.text() : "";
  } catch {
    box.textContent = "";
  }
}

function renderJob(task, job) {
  if (!job) return;
  const status = job.status || {};
  const result = job.result || {};
  const stateText = status.state || "unknown";
  const meta = $(`[data-job-meta="${task}"]`);
  if (meta) {
    meta.textContent = `${TASK_NAME[task] || job.taskLabel || job.task} · ${job.id} · ${STATUS_NAME[stateText] || stateText}`;
  }
  const stopBtn = $(`[data-stop-task="${task}"]`);
  if (stopBtn) {
    stopBtn.disabled = !["queued", "running", "stopping"].includes(stateText);
  }
  renderMetrics(task, result);
  renderFrames(task, result);
  renderImages(task, job.artifacts || []);
  rememberAutoResult(task, result);
  refreshLog(task, job.id);
}

function buildEnglishDebugLog(task, job) {
  const status = job.status || {};
  const result = job.result || null;
  const params = job.params || {};
  const lines = [];

  lines.push(`Task: ${TASK_NAME_EN[task] || job.taskLabel || task}`);
  lines.push(`Job ID: ${job.id || ""}`);
  lines.push(`State: ${status.state || "unknown"}`);
  if (job.createdAt) lines.push(`Created: ${job.createdAt}`);
  if (status.startedAt) lines.push(`Started: ${status.startedAt}`);
  if (status.finishedAt) lines.push(`Finished: ${status.finishedAt}`);
  if (status.durationSec !== undefined) lines.push(`Duration: ${status.durationSec} s`);
  if (status.exitCode !== undefined && status.exitCode !== null) lines.push(`Exit code: ${status.exitCode}`);
  lines.push("");

  lines.push("Parameters:");
  Object.entries(params).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== "") {
      lines.push(`  ${key}: ${formatDebugValue(value)}`);
    }
  });
  lines.push("");

  if (!result) {
    lines.push("MATLAB job is running or no result has been written yet.");
    lines.push("Raw MATLAB stdout is intentionally hidden here to avoid Windows console encoding issues.");
    return lines.join("\n");
  }

  if (result.ok === false) {
    lines.push("Result: FAILED");
    if (result.identifier) lines.push(`Identifier: ${result.identifier}`);
    if (result.message) lines.push(`Message: ${stripMojibake(String(result.message))}`);
    lines.push("");
    lines.push("The raw MATLAB log is not shown in this panel because it may use a non-UTF-8 Windows code page.");
    return lines.join("\n");
  }

  lines.push("Result: OK");
  appendDebugSection(lines, "Summary", result.summary);
  appendDebugSection(lines, "Auto", result.auto);
  appendDebugSection(lines, "Metrics", result.metrics);
  appendDebugSection(lines, "TX", result.tx);
  appendDebugSection(lines, "Cycle", result.cycle);

  const frames = asArray(result.frames || result.protocolFrames);
  if (frames.length) {
    lines.push("");
    lines.push(`Frames (${frames.length}, first ${Math.min(frames.length, 20)} shown):`);
    frames.slice(0, 20).forEach((frame) => {
      const cmd = frame.cmdId === undefined ? "" : `0x${Number(frame.cmdId).toString(16).toUpperCase().padStart(4, "0")}`;
      const typeName = FRAME_TYPE_NAME_EN[frame.type] || frame.type || "";
      const text = frame.text || frame.summary || "";
      lines.push(`  #${frame.index ?? ""} seq=${frame.seq ?? ""} cmd=${cmd} type=${typeName} ${stripMojibake(text)}`);
    });
  }

  lines.push("");
  lines.push("Raw MATLAB stdout is hidden here. Use result JSON, artifacts, and tables above for debugging.");
  return lines.join("\n");
}

function appendDebugSection(lines, title, obj) {
  if (!obj || typeof obj !== "object") return;
  const entries = Object.entries(obj).filter(([, value]) => value !== undefined && value !== null && value !== "");
  if (!entries.length) return;
  lines.push("");
  lines.push(`${title}:`);
  entries.forEach(([key, value]) => lines.push(`  ${key}: ${formatDebugValue(value)}`));
}

function formatDebugValue(value) {
  if (Array.isArray(value)) return `[${value.map(formatDebugValue).join(", ")}]`;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return "N/A";
    return String(Number(value.toPrecision(8)));
  }
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "object") return JSON.stringify(value);
  return stripMojibake(String(value));
}

function stripMojibake(text) {
  return String(text)
    .replace(/[\uFFFD\x08]/g, "")
    .replace(/[^\x09\x0A\x0D\x20-\x7E]/g, "")
    .trim();
}

function rememberAutoResult(task, result) {
  if (task !== "auto_rx" || !result?.auto?.success) return;
  const summary = result.summary || {};
  const key = `${state.autoMatch.matchId}:${summary.teamColor}:${summary.jammerLevel}`;
  state.autoMatch.parsed[key] = {
    key: result.auto.key,
    sourceName: result.auto.sourceName,
  };
  const autoBox = $("#autoStateBox");
  if (autoBox) {
    autoBox.textContent = `解析成功：${result.auto.sourceName}，干扰密钥 ${result.auto.key}。本局同等级不会重复解析，等级变化会自动开始下一轮。`;
  }
}

function flattenMetrics(result) {
  if (!result || result.ok === false) {
    return result?.message ? [["错误", result.message]] : [];
  }
  const rows = [];
  const add = (key, value) => {
    if (value === undefined || value === null || value === "") return;
    rows.push([METRIC_NAME[key] || key, formatValue(key, value)]);
  };
  Object.entries(result.summary || {}).forEach(([key, value]) => add(key, value));
  Object.entries(result.auto || {}).forEach(([key, value]) => add(key, value));
  Object.entries(result.metrics || {}).forEach(([key, value]) => add(key, value));
  Object.entries(result.tx || {}).forEach(([key, value]) => add(key, value));
  Object.entries(result.cycle || {}).forEach(([key, value]) => add(key, value));
  return rows.slice(0, 28);
}

function formatValue(key, value) {
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return "无";
    if (key.endsWith("FrequencyHz") || key === "rfBandwidthHz" || key === "sampleRateHz" || key === "symbolRateHz" || key === "deltaFHz" || key === "bwLpfHz") {
      return `${(value / 1e3).toFixed(3)} kHz`;
    }
    if (key.endsWith("DurationSec") || key === "captureDurationSec" || key === "txTimeSec" || key === "bufferDurationSec" || key === "cycleDurationSec") {
      return `${value.toFixed(4).replace(/\.?0+$/, "")} s`;
    }
    if (key.toLowerCase().includes("rate") || key.toLowerCase().includes("success")) {
      return value.toFixed(4).replace(/\.?0+$/, "");
    }
    if (Math.abs(value) >= 1000) return value.toFixed(3).replace(/\.?0+$/, "");
    return value.toPrecision(5).replace(/\.?0+$/, "");
  }
  if (typeof value === "boolean") return value ? "是" : "否";
  if (value === "broadcast") return "信息波";
  if (value === "jammer") return "干扰波";
  if (value === "static_source_config") return "静态波源配置";
  if (value === "red") return "红方";
  if (value === "blue") return "蓝方";
  return String(value);
}

function renderMetrics(task, result) {
  const rows = flattenMetrics(result);
  const target = $(`[data-metrics="${task}"]`);
  if (!target) return;
  target.innerHTML = rows
    .map(([name, value]) => `<div class="metric"><div class="name">${escapeHtml(name)}</div><div class="value">${escapeHtml(value)}</div></div>`)
    .join("");
}

function renderImages(task, artifacts) {
  const target = $(`[data-artifacts="${task}"]`);
  if (!target) return;
  target.innerHTML = artifacts
    .filter((item) => item.name.endsWith(".png"))
    .map((item) => {
      const title = imageTitle(item.name);
      return `<div class="artifact">
        <div class="image-title">${escapeHtml(title)}</div>
        <button class="image-open" type="button" data-image-url="${escapeHtml(item.url)}" data-image-title="${escapeHtml(title)}">
          <img src="${item.url}" alt="${escapeHtml(title)}">
        </button>
      </div>`;
    })
    .join("");
  target.querySelectorAll(".image-open").forEach((button) => {
    button.addEventListener("click", () => openImageViewer(button.dataset.imageUrl, button.dataset.imageTitle));
  });
}

function imageTitle(name) {
  const titles = {
    "sim_summary.png": "仿真统计图",
    "tx_waveform.png": "发射波形图",
    "tx_spectrum.png": "发射频谱与星座图",
    "rx_iq.png": "接收 IQ 图",
    "rx_process.png": "接收处理过程图",
    "rx_decode.png": "接收解码结果图",
  };
  return titles[name] || name;
}

function openImageViewer(url, title) {
  const viewer = $("#imageViewer");
  $("#imageViewerImg").src = url;
  $("#imageViewerImg").alt = title || "结果图";
  $("#imageViewerTitle").textContent = title || "结果图";
  viewer.hidden = false;
}

function closeImageViewer() {
  const viewer = $("#imageViewer");
  viewer.hidden = true;
  $("#imageViewerImg").src = "";
}

function asArray(value) {
  if (!value) return [];
  return Array.isArray(value) ? value : [value];
}

function renderFrames(task, result) {
  const target = $(`[data-frames="${task}"]`);
  if (!target) return;
  const frames = asArray(result?.frames || result?.protocolFrames);
  if (!frames.length) {
    target.innerHTML = "";
    return;
  }
  const rows = frames.slice(0, 50).map((frame) => {
    const cmdId = frame.cmdId === undefined ? "" : `0x${Number(frame.cmdId).toString(16).toUpperCase().padStart(4, "0")}`;
    const text = frame.text || frame.summary || "";
    const typeName = FRAME_TYPE_NAME[frame.type] || frame.type || "";
    return `<tr>
      <td>${escapeHtml(frame.index ?? "")}</td>
      <td>${escapeHtml(frame.seq ?? "")}</td>
      <td>${escapeHtml(cmdId)}</td>
      <td>${escapeHtml(typeName)}</td>
      <td>${escapeHtml(text)}</td>
    </tr>`;
  }).join("");
  target.innerHTML = `<table>
    <thead><tr><th>序号</th><th>帧序号</th><th>命令码</th><th>类型</th><th>内容</th></tr></thead>
    <tbody>${rows}</tbody>
  </table>`;
}

async function refreshJobs() {
  const data = await api("/api/jobs");
  const jobs = data.jobs || [];
  jobs.forEach((job) => {
    const task = job.task;
    if (["sim", "tx", "rx", "auto_rx"].includes(task) && !state.currentJobByTask[task]) {
      state.currentJobByTask[task] = job.id;
      renderJob(task, job);
    }
  });
  $("#jobsList").innerHTML = jobs.map(jobRow).join("") || "<p>暂无记录。</p>";
  $$(".open-job").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const jobId = btn.dataset.jobId;
      const task = btn.dataset.task;
      const data = await api(`/api/jobs/${jobId}`);
      state.currentJobByTask[task] = jobId;
      renderJob(task, data.job);
      setActiveTab(task);
    });
  });
}

function jobRow(job) {
  const status = job.status || {};
  const stateText = status.state || "unknown";
  const task = job.task || "";
  return `<div class="job-row">
    <div><strong>${escapeHtml(TASK_NAME[task] || job.taskLabel || task)}</strong><br><span class="job-meta">${escapeHtml(job.id)} · ${escapeHtml(job.createdAt || "")}</span></div>
    <span class="badge ${escapeHtml(stateText)}">${escapeHtml(STATUS_NAME[stateText] || stateText)}</span>
    <button class="secondary open-job" type="button" data-task="${escapeHtml(task)}" data-job-id="${escapeHtml(job.id)}">查看</button>
  </div>`;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

async function stopTask(task) {
  const jobId = state.currentJobByTask[task];
  if (!jobId) return;
  await api(`/api/jobs/${jobId}/stop`, { method: "POST", body: "{}" });
  const data = await api(`/api/jobs/${jobId}`);
  renderJob(task, data.job);
}

async function init() {
  state.config = await api("/api/config");
  $("#projectRoot").textContent = state.config.projectRoot;
  fillSources();

  $$(".tab").forEach((btn) => btn.addEventListener("click", () => setActiveTab(btn.dataset.tab)));
  $("#simForm").addEventListener("submit", (e) => { e.preventDefault(); submitJob("sim", e.currentTarget); });
  $("#txForm").addEventListener("submit", (e) => { e.preventDefault(); submitJob("tx", e.currentTarget); });
  $("#rxForm").addEventListener("submit", (e) => { e.preventDefault(); submitJob("rx", e.currentTarget); });
  $("#autoForm").addEventListener("submit", (e) => { e.preventDefault(); handleAutoStatus(e.currentTarget); });
  $("#refreshJobs").addEventListener("click", refreshJobs);
  $("#refreshJobs2").addEventListener("click", refreshJobs);
  $("#closeImageViewer").addEventListener("click", closeImageViewer);
  $("#imageViewer").addEventListener("click", (event) => {
    if (event.target.id === "imageViewer") closeImageViewer();
  });
  window.addEventListener("keydown", (event) => {
    if (event.key === "Escape") closeImageViewer();
  });
  $$(".stop-job").forEach((btn) => btn.addEventListener("click", () => stopTask(btn.dataset.stopTask)));
  await refreshJobs();
}

init().catch((err) => {
  const meta = $(`[data-job-meta="${state.activeTab}"]`);
  if (meta) meta.textContent = err.message;
});
