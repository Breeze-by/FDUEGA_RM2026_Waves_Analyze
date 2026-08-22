const channels = ["A", "B"];
const histories = { A: [], B: [] };
const waterfalls = { A: [], B: [] };
const lastIterations = { A: -1, B: -1 };
const lastSpectrumTimes = { A: 0, B: 0 };
const decodedCache = { A: {}, B: {} };

function byId(id) { return document.getElementById(id); }
function fmt(value, digits = 1) { return Number.isFinite(value) ? Number(value).toFixed(digits) : "—"; }
function pct(value) { return Number.isFinite(value) ? `${(value * 100).toFixed(1)}%` : "—"; }

async function api(path, options = {}) {
  const response = await fetch(path, { headers: { "Content-Type": "application/json" }, ...options });
  const contentType = response.headers.get("content-type") || "";
  let body;
  if (contentType.includes("application/json")) {
    body = await response.json();
  } else {
    const text = await response.text();
    throw new Error(`Web 后端接口不匹配或服务版本过旧（HTTP ${response.status}）：${text.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim().slice(0, 180)}`);
  }
  if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`);
  return body;
}

function resizeCanvas(canvas) {
  const ratio = window.devicePixelRatio || 1;
  const width = Math.max(100, Math.floor(canvas.clientWidth * ratio));
  const height = Math.max(80, Math.floor(canvas.clientHeight * ratio));
  if (canvas.width !== width || canvas.height !== height) { canvas.width = width; canvas.height = height; }
  return { ctx: canvas.getContext("2d"), width, height, ratio };
}

function drawGrid(ctx, width, height, pad) {
  ctx.strokeStyle = "#1d2a3b"; ctx.lineWidth = 1;
  for (let i = 0; i <= 5; i++) {
    const x = pad.left + (width - pad.left - pad.right) * i / 5;
    const y = pad.top + (height - pad.top - pad.bottom) * i / 5;
    ctx.beginPath(); ctx.moveTo(x, pad.top); ctx.lineTo(x, height - pad.bottom); ctx.stroke();
    ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(width - pad.right, y); ctx.stroke();
  }
}

function drawLineChart(canvas, x, series, options = {}) {
  const { ctx, width, height, ratio } = resizeCanvas(canvas);
  ctx.clearRect(0, 0, width, height);
  if (!x?.length || !series.some(item => item.values?.length)) return;
  const pad = { left: 48 * ratio, right: 12 * ratio, top: 12 * ratio, bottom: 26 * ratio };
  drawGrid(ctx, width, height, pad);
  const allY = series.flatMap(item => item.values.filter(Number.isFinite));
  let xMin = Math.min(...x), xMax = Math.max(...x); if (xMax === xMin) xMax = xMin + 1;
  let yMin = options.yMin ?? Math.min(...allY), yMax = options.yMax ?? Math.max(...allY);
  if (!Number.isFinite(yMin) || !Number.isFinite(yMax)) return;
  if (yMax === yMin) { yMax += 1; yMin -= 1; }
  const sx = value => pad.left + (value - xMin) / (xMax - xMin) * (width - pad.left - pad.right);
  const sy = value => height - pad.bottom - (value - yMin) / (yMax - yMin) * (height - pad.top - pad.bottom);
  for (const marker of options.verticalLines || []) {
    const px = sx(marker.value);
    ctx.save(); ctx.strokeStyle = marker.color || "#ffad4d"; ctx.setLineDash([5 * ratio, 4 * ratio]);
    ctx.beginPath(); ctx.moveTo(px, pad.top); ctx.lineTo(px, height - pad.bottom); ctx.stroke(); ctx.restore();
  }
  for (const item of series) {
    ctx.strokeStyle = item.color; ctx.lineWidth = 1.5 * ratio; ctx.beginPath();
    item.values.forEach((value, index) => { const px = sx(x[index]), py = sy(value); index ? ctx.lineTo(px, py) : ctx.moveTo(px, py); });
    ctx.stroke();
  }
  ctx.fillStyle = "#8394ab"; ctx.font = `${10 * ratio}px sans-serif`;
  ctx.fillText(options.xLabel || fmt(xMin, 2), pad.left, height - 7 * ratio);
  ctx.textAlign = "right"; ctx.fillText(options.xRightLabel || fmt(xMax, 2), width - pad.right, height - 7 * ratio);
  ctx.textAlign = "left"; ctx.fillText(fmt(yMax, options.yDigits ?? 1), 3 * ratio, pad.top + 8 * ratio);
  ctx.fillText(fmt(yMin, options.yDigits ?? 1), 3 * ratio, height - pad.bottom);
}

function heatColor(db) {
  const t = Math.max(0, Math.min(1, (db + 75) / 75));
  if (t < .33) return [5, Math.round(80 * t / .33), Math.round(170 * t / .33)];
  if (t < .66) return [Math.round(255 * (t - .33) / .33), 80 + Math.round(150 * (t - .33) / .33), 170 - Math.round(120 * (t - .33) / .33)];
  return [255, 230 - Math.round(150 * (t - .66) / .34), 50 - Math.round(50 * (t - .66) / .34)];
}

function drawWaterfall(canvas, rows) {
  const { ctx, width, height } = resizeCanvas(canvas); ctx.clearRect(0, 0, width, height);
  if (!rows.length) return;
  const image = ctx.createImageData(width, height);
  for (let y = 0; y < height; y++) {
    const row = rows[Math.min(rows.length - 1, Math.floor(y / height * rows.length))];
    for (let x = 0; x < width; x++) {
      const value = row[Math.min(row.length - 1, Math.floor(x / width * row.length))];
      const [r, g, b] = heatColor(value); const offset = (y * width + x) * 4;
      image.data[offset] = r; image.data[offset + 1] = g; image.data[offset + 2] = b; image.data[offset + 3] = 255;
    }
  }
  ctx.putImageData(image, 0, 0);
}

function renderMetrics(channel, snapshot) {
  const m = snapshot.metrics;
  const items = [
    ["协议解析帧率", `${fmt(m.validFrameHz, 1)} 帧/s`, true],
    ["平均解析帧率", `${fmt(m.averageValidFrameHz, 1)} 帧/s`, true],
    ["当前 OTA", `${m.validPackets}/${m.expectedPackets} · ${pct(m.packetSuccessRate)}`],
    ["当前协议帧", `${m.validFrames}/${m.expectedFrames} · ${pct(m.frameSuccessRate)}`],
    ["OTA 解析频率", `${fmt(m.validPacketHz)} 包/s`],
    ["累计成功率", `${pct(m.aggregatePacketSuccessRate)} / ${pct(m.aggregateFrameSuccessRate)}`],
    ["输入强度", `${fmt(m.rmsDbfs, 2)} dBFS`],
    ["实际 RX 增益", `${fmt(m.actualGainDb, 1)} dB`],
    ["SNR 估计", `${fmt(m.snrEstimateDb, 1)} dB`],
    ["谱峰频偏", `${fmt(m.peakOffsetKHz, 1)} kHz`],
    ["99% 占用带宽", `${fmt(m.occupiedBandwidthKHz, 1)} kHz`],
    ["正式带宽", `${fmt(m.formalBandwidthKHz, 1)} kHz`],
    ["带内功率占比", pct(m.inBandFraction)],
    ["ADC 削顶", pct(m.clipFraction)],
  ];
  byId(`metrics${channel}`).innerHTML = items.map(([label, value, primary]) => `<div class="metric ${primary ? "primary-metric" : ""}"><span>${label}</span><strong>${value}</strong></div>`).join("");
}

function renderInfoRates(channel, snapshot) {
  const target = byId(`infoRates${channel}`);
  if (snapshot.waveType !== "broadcast") { target.hidden = true; target.innerHTML = ""; return; }
  target.hidden = false;
  const rates = snapshot.infoCommandRatesHz || {};
  const totals = snapshot.infoCommandTotalCounts || {};
  const commands = [
    ["0x0A01", "坐标"], ["0x0A02", "血量"], ["0x0A03", "弹量"],
    ["0x0A04", "经济"], ["0x0A05", "增益/状态"],
  ];
  target.innerHTML = commands.map(([cmd, label]) => {
    const key = `cmd${cmd.slice(2)}`;
    return `<div class="info-rate-card"><span class="cmd">${cmd}</span><strong>${fmt(Number(rates[key] ?? 0), 2)} 帧/s</strong><small>${label} · 累计 ${Number(totals[key] ?? 0)} 帧</small></div>`;
  }).join("");
}

function renderFrames(channel, snapshot) {
  const counts = snapshot.cmdCounts || {};
  byId(`commands${channel}`).innerHTML = Object.entries(counts).map(([key, value]) => `<span class="cmd-badge">${key.replace("cmd", "0x")} · ${value}</span>`).join("");
  const box = byId(`frames${channel}`); const frames = snapshot.frames || [];
  for (const frame of frames) {
    if (frame.fields && Object.keys(frame.fields).length) decodedCache[channel][frame.cmdId] = frame;
  }
  renderDecoded(channel, snapshot);
  if (!frames.length) { box.className = "frames empty"; box.textContent = "本窗口未解析到完整协议帧"; return; }
  box.className = "frames";
  box.innerHTML = frames.slice().reverse().map(frame => `<div class="frame"><span class="seq">#${frame.seq}</span><span class="cmd">${frame.cmdId}</span><span>${escapeHtml(frame.summary)}</span></div>`).join("");
}

const robotNames = { hero: "英雄", engineer: "工程", infantry3: "3号", infantry4: "4号", aerial: "空中", sentry: "哨兵" };

function fieldCell(label, value, unit = "") {
  return `<div class="decoded-field"><span>${label}</span><strong>${escapeHtml(String(value ?? "—"))}${unit}</strong></div>`;
}

function robotTable(fields, columns) {
  const rows = columns.robots.map(robot => `<tr><td>${robotNames[robot]}</td>${columns.values.map(([suffix, unit]) => `<td>${escapeHtml(String(fields[robot + suffix] ?? "—"))}${unit || ""}</td>`).join("")}</tr>`).join("");
  return `<table class="robot-table"><thead><tr><th>机器人</th>${columns.values.map(item => `<th>${item[2]}</th>`).join("")}</tr></thead><tbody>${rows}</tbody></table>`;
}

function renderDecodedCard(frame, rateHz, totalCount) {
  const f = frame.fields || {}; let body = ""; let title = frame.cmdId;
  if (frame.cmdId === "0x0A01") {
    title += " 对方机器人坐标";
    body = robotTable(f, { robots: ["hero", "engineer", "infantry3", "infantry4", "aerial", "sentry"], values: [["X", " cm", "X"], ["Y", " cm", "Y"]] });
  } else if (frame.cmdId === "0x0A02") {
    title += " 对方机器人血量";
    body = `<div class="decoded-grid">${["hero","engineer","infantry3","infantry4","sentry"].map(r => fieldCell(robotNames[r], f[r + "Hp"])).join("")}</div>`;
  } else if (frame.cmdId === "0x0A03") {
    title += " 对方允许发弹量";
    body = `<div class="decoded-grid">${["hero","infantry3","infantry4","aerial","sentry"].map(r => fieldCell(robotNames[r], f[r + "Ammo"], " 发")).join("")}</div>`;
  } else if (frame.cmdId === "0x0A04") {
    title += " 经济与增益点";
    body = `<div class="decoded-grid">${fieldCell("剩余金币", f.remainCoins)}${fieldCell("总金币", f.totalCoins)}${fieldCell("增益点状态", f.buffStatusBits)}</div>`;
  } else if (frame.cmdId === "0x0A05") {
    title += " 机器人增益与状态";
    body = robotTable(f, { robots: ["hero","engineer","infantry3","infantry4","sentry"], values: [["Regen","","恢复"],["Cooling","","冷却"],["Defense","","防御"],["NegDefense","","负防御"],["Attack","","攻击"],["MainStatus","","主状态"]] });
    body += `<div class="decoded-grid">${fieldCell("哨兵姿态", f.sentryPose)}</div>`;
  } else if (frame.cmdId === "0x0A06") {
    title += " 干扰波密钥";
    body = `<div class="key-display">${escapeHtml(String(f.jammerKey || "未解析"))}</div>`;
  }
  const rateText = Number.isFinite(rateHz) ? `${fmt(rateHz, 2)} 帧/s · 累计 ${totalCount ?? 0} 帧` : `seq ${frame.seq}`;
  return `<section class="decoded-card"><div class="decoded-card-head"><span>${title}</span><span>${rateText}</span></div>${body}</section>`;
}

function renderDecoded(channel, snapshot) {
  const target = byId(`decoded${channel}`);
  const isJammer = snapshot.waveType === "jammer";
  byId(`decodedTitle${channel}`).textContent = isJammer ? "当前干扰波密钥" : "信息波各命令独立解析结果与帧率";
  byId(`recentBlock${channel}`).hidden = isJammer;
  const order = isJammer ? ["0x0A06"] : ["0x0A01", "0x0A02", "0x0A03", "0x0A04", "0x0A05"];
  const frames = order.map(cmd => decodedCache[channel][cmd]).filter(Boolean);
  if (!frames.length) { target.className = "decoded-details empty"; target.textContent = "尚未解析到业务字段"; return; }
  const rates = snapshot.infoCommandRatesHz || {};
  const totals = snapshot.infoCommandTotalCounts || {};
  target.className = "decoded-details";
  target.innerHTML = frames.map(frame => {
    const key = `cmd${frame.cmdId.slice(2)}`;
    const rate = isJammer ? snapshot.metrics.validFrameHz : rates[key];
    const total = isJammer ? snapshot.metrics.cumulativeValidFrames : totals[key];
    return renderDecodedCard(frame, rate, total);
  }).join("");
}

function renderSpectrumSnapshot(channel, snapshot) {
  if (!snapshot.spectrumMHz?.length || !snapshot.spectrumDb?.length) return;
  const centerMHz = snapshot.metrics?.hardwareCenterMHz ?? snapshot.hardwareCenterMHz;
  const bandwidthKHz = snapshot.metrics?.formalBandwidthKHz ?? snapshot.formalBandwidthKHz;
  const peakIndex = snapshot.spectrumDb.indexOf(Math.max(...snapshot.spectrumDb));
  const peakMHz = snapshot.spectrumMHz[Math.max(0, peakIndex)];
  const halfBandMHz = bandwidthKHz / 2000;
  drawLineChart(byId(`spectrum${channel}`), snapshot.spectrumMHz, [{ values: snapshot.spectrumDb, color: "#3dd9ff" }], {
    yMin: -80, yMax: 5,
    xLabel: `${fmt(snapshot.spectrumMHz[0], 3)} MHz`, xRightLabel: `${fmt(snapshot.spectrumMHz.at(-1), 3)} MHz`,
    verticalLines: [
      { value: centerMHz - halfBandMHz, color: "#ffad4d" },
      { value: centerMHz + halfBandMHz, color: "#ffad4d" },
      { value: peakMHz, color: "#ff667f" },
    ],
  });
  if (snapshot.updatedUnixSec !== lastSpectrumTimes[channel]) {
    lastSpectrumTimes[channel] = snapshot.updatedUnixSec;
    waterfalls[channel].unshift(snapshot.spectrumDb);
    if (waterfalls[channel].length > 70) waterfalls[channel].pop();
  }
  drawWaterfall(byId(`waterfall${channel}`), waterfalls[channel]);
}

function escapeHtml(value) { const node = document.createElement("span"); node.textContent = value ?? ""; return node.innerHTML; }

function renderSnapshot(channel, snapshot) {
  byId(`title${channel}`).textContent = `${snapshot.radioID} · ${snapshot.sourceDisplayName || snapshot.sourceName}`;
  renderSpectrumSnapshot(channel, snapshot);
  byId(`state${channel}`).textContent = snapshot.state === "running" ? `实时 · 第 ${snapshot.iteration} 窗口` : snapshot.state;
  if (snapshot.state !== "running" || !snapshot.metrics) return;
  renderMetrics(channel, snapshot); renderInfoRates(channel, snapshot); renderFrames(channel, snapshot);
  if (lastIterations[channel] !== snapshot.iteration) {
    lastIterations[channel] = snapshot.iteration;
    histories[channel].push({ t: snapshot.elapsedSec, packet: snapshot.metrics.packetSuccessRate * 100, frame: snapshot.metrics.frameSuccessRate * 100 });
    if (histories[channel].length > 120) histories[channel].shift();
  }
  const history = histories[channel];
  drawLineChart(byId(`history${channel}`), history.map(item => item.t), [{ values: history.map(item => item.packet), color: "#3dd9ff" }, { values: history.map(item => item.frame), color: "#ffad4d" }], { yMin: 0, yMax: 100, xLabel: "运行时间", xRightLabel: history.length ? `${fmt(history.at(-1).t, 1)} s` : "" });
}

async function pollState() {
  try {
    const state = await api("/api/state");
    byId("connectionDot").className = `dot ${state.running ? "running" : "idle"}`;
    const runningCount = channels.filter(channel => state.channels[channel].processRunning).length;
    byId("globalStatus").textContent = runningCount ? `${runningCount} 路诊断运行中` : "尚未启动";
    for (const channel of channels) {
      const info = state.channels[channel];
      byId(`start${channel}`).disabled = info.processRunning;
      byId(`stop${channel}`).disabled = !info.processRunning;
      if (info.snapshot) renderSnapshot(channel, info.snapshot);
      else if (info.processRunning) byId(`state${channel}`).textContent = info.spectrumSnapshot ? "正式窗口采集中" : "MATLAB 初始化中";
      else if (info.workerError) {
        byId(`state${channel}`).textContent = "worker 启动失败";
        byId(`message${channel}`).textContent = info.workerError.split("\n").filter(Boolean).slice(-2).join(" · ");
      } else byId(`state${channel}`).textContent = "未运行";
      // 完整解析快照更新指标/密钥后，再用更新的高频快照覆盖图表。
      if (info.spectrumSnapshot) renderSpectrumSnapshot(channel, info.spectrumSnapshot);
    }
  } catch (error) {
    byId("connectionDot").className = "dot error"; byId("globalStatus").textContent = `连接失败：${error.message}`;
  }
}

async function pollLoop() {
  await pollState();
  window.setTimeout(pollLoop, 150);
}

async function startChannel(channel) {
  byId(`message${channel}`).textContent = "正在进行 Pluto IIO 硬件预检…";
  histories[channel] = []; waterfalls[channel] = []; lastIterations[channel] = -1;
  lastSpectrumTimes[channel] = 0;
  decodedCache[channel] = {};
  try {
    await api(`/api/channels/${channel}/start`, { method: "POST", body: JSON.stringify({ radioID: byId(`radio${channel}`).value.trim(), sourceName: byId(`source${channel}`).value }) });
    byId(`message${channel}`).textContent = "硬件预检通过，等待正式接收链路初始化。"; await pollState();
  } catch (error) { byId(`message${channel}`).textContent = error.message; }
}

async function stopChannel(channel) {
  byId(`message${channel}`).textContent = "正在停止并释放 Pluto…";
  try { await api(`/api/channels/${channel}/stop`, { method: "POST", body: "{}" }); byId(`message${channel}`).textContent = "已停止，本路 Pluto 已释放。"; await pollState(); }
  catch (error) { byId(`message${channel}`).textContent = error.message; }
}

async function init() {
  const config = await api("/api/config");
  for (const channel of channels) {
    const select = byId(`source${channel}`);
    select.innerHTML = config.sources.map(item => `<option value="${item.value}">${item.label}</option>`).join("");
  }
  byId("sourceA").value = "red_broadcast"; byId("sourceB").value = "red_l1_jammer";
  for (const channel of channels) {
    byId(`start${channel}`).addEventListener("click", () => startChannel(channel));
    byId(`stop${channel}`).addEventListener("click", () => stopChannel(channel));
  }
  // 只提高网页读取正式链路快照的频率，不改变 MATLAB 采集与解码参数。
  // 150 ms 对应最高约 6.7 FPS，足够让频谱/瀑布更连贯，同时避免本机
  // JSON 轮询和 Canvas 重绘挤占正式 MATLAB worker 的 CPU。
  await pollState(); window.setTimeout(pollLoop, 150); window.addEventListener("resize", pollState);
}

init().catch(error => { byId("globalStatus").textContent = error.message; });
