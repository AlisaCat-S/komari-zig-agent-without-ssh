"use strict";
const $ = id => document.getElementById(id);
let revision = "", loaded = false, dirty = false, saving = false, polling = false;

function sessionToken() {
  // Read only a same-origin DSM opener/parent. Never ask for or store the DSM password.
  for (const context of [window.opener, window.parent, window]) {
    try {
      if (!context || context.location.origin !== location.origin) continue;
      const token = context.SYNO?.SDS?.Session?.SynoToken || (typeof context._S === "function" && context._S("SynoToken"));
      if (typeof token === "string" && token) return token;
    } catch (_) { /* A closed or cross-origin DSM window is not a session source. */ }
  }
  return "";
}

function notice(message, error = false) {
  $("notice").textContent = message;
  $("notice").className = error ? "error" : "";
  $("notice").hidden = !message;
}

async function request(body) {
  const token = sessionToken();
  if (!token) throw new Error("请先登录 DSM，再从主菜单打开 Komari Monitor，并保持 DSM 窗口打开。");
  const headers = { "X-SYNO-TOKEN": token, "X-Komari-Request": "1" };
  const options = { headers, cache: "no-store", credentials: "same-origin" };
  if (body) {
    Object.assign(options, { method: "POST", body: JSON.stringify(body) });
    headers["Content-Type"] = "application/json";
  }
  const response = await fetch("api.cgi", options);
  let data;
  try { data = await response.json(); } catch (_) { throw new Error("无法读取套件 API，请检查套件是否已启动及 DSM CGI 权限。"); }
  if (!response.ok || !data.ok) throw new Error(data.message || "请求失败，请重新打开应用。");
  return data;
}

function date(seconds) { return seconds ? new Date(seconds * 1000).toLocaleString() : "尚无记录"; }
function relative(seconds) {
  if (!seconds) return "—";
  const delta = Math.max(0, Math.floor(Date.now() / 1000 - seconds));
  if (delta < 5) return "刚刚";
  if (delta < 60) return `${delta} 秒前`;
  if (delta < 3600) return `${Math.floor(delta / 60)} 分钟前`;
  return `${Math.floor(delta / 3600)} 小时前`;
}

function render(data) {
  const t = data.telemetry || {};
  const activityAt = t.connection === "connected" && t.last_report_sent_at ? t.last_report_sent_at : t.updated_at;
  const stale = data.running && activityAt && Date.now() / 1000 - activityAt > Math.max(60, Number(data.config.interval || 3) * 3);
  const states = {
    stopped: ["Agent 已停止", "可在套件中心启动；下方保留最近一次运行的统计。", "neutral"],
    starting: ["等待首条上报", "Agent 正在启动，尚未建立上报连接。", "warn"],
    connecting: ["正在连接面板", "正在尝试建立监控数据连接。", "warn"],
    reconnecting: ["正在重新连接", "连接中断，Agent 正在按配置重试。", "warn"],
    connected: ["上报连接已建立", "监控报告正在通过当前连接发送。", "good"],
    stale: ["状态暂未更新", "进程仍在运行，但最近未更新上报状态，请检查套件日志。", "warn"],
    unknown: ["上报状态未知", "进程仍在运行，尚未读取到本次运行的状态。", "neutral"]
  };
  const key = !data.running ? "stopped" : stale ? "stale" : (t.connection || "unknown");
  const [title, description, color] = states[key] || states.unknown;
  $("status-title").textContent = title;
  $("status-description").textContent = description;
  $("state-dot").className = `dot ${color}`;
  $("process").textContent = data.running ? "运行中" : "已停止";
  $("transport").textContent = t.transport === "websocket" ? `WebSocket · V${t.protocol_version}` : t.transport === "http" ? "HTTP 回退 · V2" : "尚未连接";
  $("last-sent").textContent = relative(t.last_report_sent_at);
  $("sent-date").textContent = date(t.last_report_sent_at);
  $("sent-count").textContent = Number(t.reports_sent || 0).toLocaleString();
  $("basic-confirmed").textContent = date(t.basic_info_confirmed_at);
  $("http-confirmed").textContent = t.last_http_confirmed_at ? `${date(t.last_http_confirmed_at)} · ${t.http_reports_confirmed} 条` : "尚无 HTTP 确认";
  $("started").textContent = date(t.started_at);
  $("last-error-box").hidden = !t.last_error;
  $("last-error").textContent = t.last_error || "";
  $("poll-state").textContent = `更新于 ${new Date().toLocaleTimeString()}`;
  $("save-hint").textContent = data.running ? "运行中保存会重启 Agent，短暂中断上报。" : "保存后仍保持停止，可在套件中心启动。";
  if (!loaded || !dirty) {
    const config = data.config;
    $("endpoint").value = config.endpoint || "";
    $("interval").value = config.interval ?? 3;
    $("protocol").value = String(config.protocol_version || 2);
    $("include-nics").value = config.include_nics || "";
    $("exclude-nics").value = config.exclude_nics || "";
    $("mountpoints").value = config.include_mountpoints || "";
    $("token").placeholder = data.token_configured ? "已配置 · 留空不修改" : "请输入 Agent Token";
    revision = data.revision;
    loaded = true;
  }
  $("fields").disabled = saving;
}

async function refresh(manual = false) {
  if (polling || saving) return;
  polling = true;
  try { render(await request()); if (manual) notice("状态已刷新。"); }
  catch (error) {
    $("poll-state").textContent = "刷新失败";
    $("status-title").textContent = "状态暂不可用";
    $("status-description").textContent = "请恢复 DSM 会话后刷新；下方数据可能已过期。";
    $("state-dot").className = "dot warn";
    $("fields").disabled = true;
    notice(error.message, true);
  } finally { polling = false; }
}

$("settings").addEventListener("input", () => {
  dirty = true; $("save").disabled = false; $("discard").disabled = false; $("edit-state").textContent = "有未保存更改";
});
$("settings").addEventListener("submit", async event => {
  event.preventDefault();
  if (saving || !loaded) return;
  saving = true; $("fields").disabled = true; $("save").textContent = "正在应用…";
  const payload = { revision, endpoint: $("endpoint").value.trim(), token: $("token").value,
    interval: Number($("interval").value), protocol_version: Number($("protocol").value),
    include_nics: $("include-nics").value, exclude_nics: $("exclude-nics").value, include_mountpoints: $("mountpoints").value };
  try {
    const data = await request(payload);
    revision = data.revision; dirty = false; $("token").value = "";
    $("edit-state").textContent = "已保存";
    notice(data.restarted ? "配置已保存，Agent 已重新启动。" : "配置已保存，Agent 保持停止。");
  } catch (error) { notice(error.message, true); }
  finally { saving = false; $("fields").disabled = false; $("save").disabled = !dirty; $("discard").disabled = !dirty; $("save").textContent = "保存并应用"; }
  await refresh();
});
$("refresh").addEventListener("click", () => refresh(true));
$("discard").addEventListener("click", async () => {
  dirty = false; $("token").value = ""; $("save").disabled = true; $("discard").disabled = true;
  $("edit-state").textContent = "未修改";
  await refresh(true);
});
window.addEventListener("beforeunload", event => { if (dirty) { event.preventDefault(); event.returnValue = ""; } });
refresh();
setInterval(() => { if (!document.hidden) refresh(); }, 3000);
