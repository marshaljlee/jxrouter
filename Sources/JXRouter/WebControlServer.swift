import Foundation
import Network

/// Remote web-control server that lets the iOS/Android web-wrapper apps (and
/// any browser on the LAN) monitor and control JXProxy.
///
/// Serves a self-contained single-file web app at `/` plus a small JSON API:
///   GET  /api/status    — proxy state, active provider/model, counters
///   GET  /api/providers — provider presets + key presence + backend URLs
///   GET  /api/logs      — recent traffic entries (with serving provider)
///   POST /api/action    — {"action":"start"|"stop"|"restart"|"setProvider","provider":"…"}
///
/// Every /api/* request must present the proxy auth token (x-api-key or
/// Bearer). The static page contains no data, so it is served without auth.
/// The listener binds ALL interfaces, so it only starts when the user enables
/// it in Settings → System → Remote Web Control (off by default).
@MainActor
final class WebControlServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.jxproxy.webcontrol", qos: .userInitiated)
    private(set) var isRunning = false

    // MARK: - Lifecycle

    func start(port: UInt16) {
        guard listener == nil else { return }
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                print("[WebControl] Invalid port \(port)")
                return
            }
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        print("[WebControl] Listening on port \(port)")
                    case .failed(let error):
                        self.isRunning = false
                        print("[WebControl] Listener failed: \(error.localizedDescription)")
                        self.listener = nil
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                // Dedicated queue per connection so one slow/hung client can
                // never wedge the listener's accept loop or another connection.
                let connQueue = DispatchQueue(label: "com.jxproxy.webcontrol.conn", qos: .userInitiated)
                connection.start(queue: connQueue)
                self.receiveRequest(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("[WebControl] Failed to start on port \(port): \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        print("[WebControl] Stopped")
    }

    // MARK: - Request Handling

    nonisolated private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                print("[WebControl] receive error: \(error)")
                connection.cancel()
                return
            }
            guard let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                self.route(request: request, connection: connection)
            }
        }
    }

    private func route(request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { connection.cancel(); return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let method = parts[0].uppercased()
        let target = parts[1]
        let path = target.components(separatedBy: "?").first ?? target

        // Static page — no auth (it contains no data). API calls are authed.
        if path == "/" || path == "/index.html" {
            send(connection, status: 200, contentType: "text/html; charset=utf-8", body: Self.pageHTML)
            return
        }

        guard validateAuth(request) else {
            send(connection, status: 401, contentType: "application/json", body: #"{"error":"unauthorized"}"#)
            return
        }

        switch path {
        case "/api/status":
            send(connection, status: 200, contentType: "application/json", body: statusJSON())
        case "/api/providers":
            send(connection, status: 200, contentType: "application/json", body: providersJSON())
        case "/api/logs":
            send(connection, status: 200, contentType: "application/json", body: logsJSON())
        case "/api/action":
            guard method == "POST" else {
                send(connection, status: 405, contentType: "application/json", body: #"{"error":"method not allowed"}"#)
                return
            }
            handleAction(request: request, connection: connection)
        default:
            send(connection, status: 404, contentType: "application/json", body: #"{"error":"not found"}"#)
        }
    }

    // MARK: - Auth

    private func validateAuth(_ request: String) -> Bool {
        let headers = HTTPUtils.parseHeaders(from: request)
        let xApiKey = headers["x-api-key"]
        let authHeader = headers["authorization"]
        let bearerToken = authHeader.flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        let provided = xApiKey ?? bearerToken
        guard let provided, !provided.isEmpty else { return false }
        return constantTimeEquals(provided, ConfigManager.shared.authToken)
    }

    /// Constant-time string comparison (mirrors ProxyServer).
    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        let length = max(aBytes.count, bBytes.count)
        var diff = UInt8(aBytes.count ^ bBytes.count)
        for i in 0..<length {
            let aByte = i < aBytes.count ? aBytes[i] : 0
            let bByte = i < bBytes.count ? bBytes[i] : 0
            diff |= aByte ^ bByte
        }
        return diff == 0
    }

    // MARK: - JSON API

    private func statusJSON() -> String {
        let mgr = ProxyManager.shared
        let cfg = ConfigManager.shared
        let localModel: String
        switch LocalModelManager.shared.status {
        case .stopped: localModel = "stopped"
        case .starting: localModel = "starting"
        case .running: localModel = "running"
        case .failed: localModel = "failed"
        }
        let dict: [String: Any] = [
            "ok": true,
            "proxyRunning": mgr.isRunning,
            "provider": cfg.provider,
            "providerName": ProviderPreset.preset(for: cfg.provider)?.name ?? cfg.provider,
            "model": cfg.model,
            "port": cfg.port,
            "uptime": mgr.uptime,
            "aiRouted": mgr.proxyServer.stats.aiRouted,
            "passthrough": mgr.proxyServer.stats.passthrough,
            "blocked": mgr.proxyServer.stats.blocked,
            "systemProxy": mgr.systemProxyEnabled,
            "localModel": localModel,
            "fallbacks": cfg.fallbackProviders
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            "webPort": cfg.webControlPort,
        ]
        return json(dict)
    }

    private func providersJSON() -> String {
        let cfg = ConfigManager.shared
        let active = cfg.provider
        let providers: [[String: Any]] = ProviderPreset.all.map { preset in
            [
                "id": preset.id,
                "name": preset.name,
                "requiresKey": preset.requiresKey,
                "hasKey": !cfg.apiKey(for: preset.id).isEmpty,
                "active": preset.id == active,
                "models": preset.models,
            ]
        }
        return json(["providers": providers, "backendUrls": cfg.providerBackendUrls])
    }

    private func logsJSON() -> String {
        let entries = ProxyManager.shared.trafficLog.entries.suffix(100)
        let logs: [[String: Any]] = entries.map { entry in
            var dict: [String: Any] = [
                "time": entry.timestamp.ISO8601Format(),
                "host": entry.host,
                "action": entry.action.rawValue,
                "method": entry.method,
                "url": entry.url,
            ]
            if let app = entry.appProcessName { dict["app"] = app }
            if let duration = entry.duration { dict["duration"] = duration }
            if let servedBy = entry.servedBy { dict["servedBy"] = servedBy }
            dict["usedFallback"] = entry.usedFallback
            return dict
        }
        // Array(...) is required: JSONSerialization only accepts bridged
        // Foundation types, and a ReversedCollection is neither — passing it
        // straight through wedges the MainActor inside JSONSerialization and
        // hangs every subsequent web-control request.
        return json(["logs": Array(logs.reversed())])
    }

    private func handleAction(request: String, connection: NWConnection) {
        guard let body = requestBody(from: request),
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            send(connection, status: 400, contentType: "application/json", body: #"{"error":"bad request"}"#)
            return
        }
        switch action {
        case "start":
            Task { await ProxyManager.shared.startProxy() }
            send(connection, status: 200, contentType: "application/json", body: #"{"ok":true}"#)
        case "stop":
            ProxyManager.shared.stopProxy()
            send(connection, status: 200, contentType: "application/json", body: #"{"ok":true}"#)
        case "restart":
            Task { await ProxyManager.shared.restartProxy() }
            send(connection, status: 200, contentType: "application/json", body: #"{"ok":true}"#)
        case "setProvider":
            guard let pid = json["provider"] as? String, ProviderPreset.preset(for: pid) != nil else {
                send(connection, status: 400, contentType: "application/json", body: #"{"error":"unknown provider"}"#)
                return
            }
            ConfigManager.shared.provider = pid
            send(connection, status: 200, contentType: "application/json", body: #"{"ok":true}"#)
        default:
            send(connection, status: 400, contentType: "application/json", body: #"{"error":"unknown action"}"#)
        }
    }

    // MARK: - Helpers

    private func requestBody(from request: String) -> String? {
        guard let range = request.range(of: "\r\n\r\n") else { return nil }
        return String(request[range.upperBound...])
    }

    private func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func send(_ connection: NWConnection, status: Int, contentType: String, body: String) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Error"
        }
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\nProxy-Agent: JXProxy\r\n\r\n\(body)"
        guard let data = response.data(using: .utf8) else {
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Embedded Web App

    /// The single-file mobile web app (dark, touch-friendly). Served at `/`.
    /// Talks to the /api/* endpoints above using the proxy auth token, which
    /// the user enters once and is kept in localStorage.
    private static let pageHTML = """
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="theme-color" content="#0f1115">
<title>JXProxy Remote</title>
<style>
:root{--bg:#0f1115;--card:#161a22;--card2:#1b202b;--border:#262d3a;--text:#e6e9ef;--dim:#8b93a3;--accent:#4f8cff;--green:#34d399;--red:#f87171;--amber:#fbbf24}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;padding:16px;padding-bottom:56px;-webkit-font-smoothing:antialiased;max-width:640px;margin:0 auto}
h1{font-size:20px;font-weight:700}
h2{font-size:13px;font-weight:600;color:var(--dim);text-transform:uppercase;letter-spacing:.06em;margin:22px 0 8px}
.card{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:14px;margin-bottom:10px}
.row{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:8px 0}
.row+.row{border-top:1px solid var(--border)}
.lbl{color:var(--dim);font-size:13px}
.val{font-size:13px;font-weight:600;text-align:right;word-break:break-all}
.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:600}
.badge.on{background:rgba(52,211,153,.15);color:var(--green)}
.badge.off{background:rgba(139,147,163,.15);color:var(--dim)}
.badge.fb{background:rgba(251,191,36,.15);color:var(--amber)}
.badge.route{background:rgba(79,140,255,.15);color:var(--accent)}
.badge.pass{background:rgba(52,211,153,.15);color:var(--green)}
.badge.block{background:rgba(248,113,113,.15);color:var(--red)}
button{border:none;border-radius:10px;padding:12px 16px;font-size:15px;font-weight:600;cursor:pointer}
.btn-primary{background:var(--accent);color:#fff;width:100%}
.btn-danger{background:rgba(248,113,113,.15);color:var(--red);width:100%}
.btn-mini{background:var(--card2);color:var(--text);border:1px solid var(--border);padding:8px 12px;font-size:13px}
.provider{display:flex;align-items:center;gap:10px;padding:12px 14px;border:1px solid var(--border);border-radius:12px;margin-bottom:8px;background:var(--card);cursor:pointer}
.provider.active{border-color:var(--accent)}
.provider .name{font-size:14px;font-weight:600;flex:1}
.provider .sub{font-size:11px;color:var(--dim);margin-top:2px}
.check{color:var(--accent);font-weight:700;font-size:16px}
.log{font-size:12px;padding:9px 0;border-bottom:1px solid var(--border)}
.log:last-child{border-bottom:none}
.log .t{color:var(--dim);font-size:11px}
.log .line{display:flex;align-items:center;gap:6px;flex-wrap:wrap;margin-top:3px}
.log .host{font-weight:600}
input{background:var(--card2);border:1px solid var(--border);border-radius:10px;color:var(--text);padding:12px;font-size:15px;width:100%;margin-bottom:10px}
.muted{color:var(--dim);font-size:12px;line-height:1.5}
header{display:flex;align-items:center;justify-content:space-between;padding:6px 0 14px}
.dot{width:10px;height:10px;border-radius:50%;display:inline-block;margin-right:8px}
.dot.on{background:var(--green);box-shadow:0 0 8px var(--green)}
.dot.off{background:var(--dim)}
#err{color:var(--red);font-size:13px;margin-top:10px;display:none}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}
#gate{display:flex;flex-direction:column;justify-content:center;min-height:70vh}
#app{display:none}
</style>
</head>
<body>

<div id="gate">
  <h1 style="margin-bottom:6px">JXProxy Remote</h1>
  <p class="muted" style="margin-bottom:18px">Connect to your Mac's JXProxy. The token is shown in Settings on the Mac (same as the proxy auth token).</p>
  <input id="tok" type="password" placeholder="Auth token" autocomplete="off">
  <button class="btn-primary" onclick="connect()">Connect</button>
  <div id="err"></div>
</div>

<div id="app">
  <header>
    <div>
      <h1>JXProxy</h1>
      <div class="muted" id="subline">—</div>
    </div>
    <span class="badge off" id="statusBadge">OFF</span>
  </header>

  <div class="card">
    <div class="row"><span class="lbl">Provider</span><span class="val" id="pvProvider">—</span></div>
    <div class="row"><span class="lbl">Model</span><span class="val" id="pvModel">—</span></div>
    <div class="row"><span class="lbl">Proxy port</span><span class="val" id="pvPort">—</span></div>
    <div class="row"><span class="lbl">Uptime</span><span class="val" id="pvUptime">—</span></div>
    <div class="row"><span class="lbl">Traffic</span><span class="val" id="pvTraffic">—</span></div>
    <div class="row"><span class="lbl">Local model</span><span class="val" id="pvLocal">—</span></div>
    <div style="display:flex;gap:10px;margin-top:10px">
      <button class="btn-primary" id="btnStart" onclick="act('start')" style="display:none">Start Proxy</button>
      <button class="btn-danger" id="btnStop" onclick="act('stop')" style="display:none">Stop Proxy</button>
    </div>
  </div>

  <h2>Providers</h2>
  <div id="providers"></div>

  <h2>Recent Traffic</h2>
  <div class="card" id="logs" style="padding:6px 14px"></div>
</div>

<script>
var TOKEN_KEY='jxproxy_token';
var token=localStorage.getItem(TOKEN_KEY)||'';
var pollTimer=null;

function $(id){return document.getElementById(id)}

// Escape a string for safe interpolation into innerHTML. Log hosts/URLs are
// attacker-controlled (any site can put markup in its own URL), so they must
// never reach innerHTML raw — that is stored XSS with the auth token in reach.
function esc(s){
  s=(s===undefined||s===null)?'':String(s);
  return s.replace(/[&<>"']/g,function(c){
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];
  });
}

function showGate(msg){
  $('app').style.display='none';
  $('gate').style.display='flex';
  if(msg){$('err').textContent=msg;$('err').style.display='block'}
}

function enterApp(){
  $('gate').style.display='none';
  $('app').style.display='block';
  refresh();
  clearInterval(pollTimer);
  pollTimer=setInterval(refresh,3000);
}

function connect(){
  token=$('tok').value.trim();
  localStorage.setItem(TOKEN_KEY,token);
  testToken();
}

async function api(path,opts){
  opts=opts||{};
  opts.headers=Object.assign({'x-api-key':token},opts.headers||{});
  var res=await fetch(path,opts);
  if(res.status===401){showGate('Wrong token — try again.');throw new Error('unauthorized')}
  if(!res.ok)throw new Error('HTTP '+res.status);
  return res.json();
}

async function testToken(){
  try{
    var s=await api('/api/status');
    if(s.ok){enterApp();refresh()}
  }catch(e){if(!/unauthorized/.test(e.message))showGate('Could not reach the Mac. Check the address and that Remote Web Control is on.')}
}

function fmtUp(sec){
  sec=Math.floor(sec||0);
  var h=Math.floor(sec/3600),m=Math.floor(sec%3600/60),s=sec%60;
  if(h>0)return h+'h '+m+'m';
  if(m>0)return m+'m '+s+'s';
  return s+'s';
}

async function refresh(){
  try{
    var s=await api('/api/status');
    renderStatus(s);
    renderLogs(await api('/api/logs'));
  }catch(e){}
}

function renderStatus(s){
  var on=s.proxyRunning;
  $('statusBadge').textContent=on?'ON':'OFF';
  $('statusBadge').className='badge '+(on?'on':'off');
  $('subline').textContent=s.providerName+' · '+(s.model||'auto');
  $('pvProvider').textContent=s.providerName;
  $('pvModel').textContent=s.model||'auto';
  $('pvPort').textContent=s.port;
  $('pvUptime').textContent=on?fmtUp(s.uptime):'—';
  $('pvTraffic').textContent=s.aiRouted+' routed · '+s.passthrough+' pass';
  $('pvLocal').textContent=s.localModel;
  $('btnStart').style.display=on?'none':'block';
  $('btnStop').style.display=on?'block':'none';
  loadProviders(s.provider);
}

async function loadProviders(active){
  try{
    var p=await api('/api/providers');
    var el=$('providers');
    el.innerHTML='';
    p.providers.forEach(function(pr){
      var d=document.createElement('div');
      d.className='provider'+(pr.active?' active':'');
      var keyTxt=pr.requiresKey?(pr.hasKey?'key set':'no key'):'keyless';
      d.innerHTML='<div style="flex:1"><div class="name">'+esc(pr.name)+'</div><div class="sub">'+esc(pr.id)+' · '+keyTxt+(pr.active?' · active':'')+'</div></div>'+(pr.active?'<span class="check">✓</span>':'');
      d.onclick=function(){if(!pr.active)act('setProvider',pr.id)};
      el.appendChild(d);
    });
  }catch(e){}
}

function renderLogs(l){
  var el=$('logs');
  if(!l.logs||!l.logs.length){el.innerHTML='<div class="muted" style="padding:10px 0">No traffic yet.</div>';return}
  el.innerHTML='';
  l.logs.slice(0,40).forEach(function(e){
    var d=document.createElement('div');
    d.className='log';
    var when=e.time?new Date(e.time).toLocaleTimeString():'';
    var actionBadge=e.action==='routeAI'?'<span class="badge route">ROUTE</span>':(e.action==='passthrough'?'<span class="badge pass">PASS</span>':'<span class="badge block">BLOCK</span>');
    var served=e.servedBy?(e.usedFallback?'<span class="badge fb">↪ '+esc(e.servedBy)+'</span>':'<span class="badge on">'+esc(e.servedBy)+'</span>'):'';
    d.innerHTML='<div class="t">'+esc(when)+' · '+esc(e.method)+' '+esc(e.host)+'</div><div class="line">'+actionBadge+'<span class="host">'+esc(e.url)+'</span>'+served+'</div>';
    el.appendChild(d);
  });
}

async function act(action,provider){
  try{
    var body={action:action};
    if(provider)body.provider=provider;
    await api('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    setTimeout(refresh,600);
  }catch(e){}
}

(function(){
  if(token){$('tok').value=token;testToken()}
  else showGate();
})();
</script>
</body>
</html>
"""
}
