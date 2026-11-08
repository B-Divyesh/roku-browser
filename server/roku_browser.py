#!/usr/bin/env python3
"""Renders web pages in a hidden Brave and serves them to the Roku "Browser" channel.

A Roku can't run a browser engine, so the browsing happens here: the channel shows
JPEG frames of the page, draws its own cursor, and sends clicks, scrolls and typing
back. Videos found on a page are handed to the Roku's native player (or the YouTube
app), so they play smoothly with sound.
"""
import asyncio
import base64
import ctypes
import io
import json
import logging
import mimetypes
import os
import re
import secrets
import shutil
import signal
import socket
import time
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse

import aiohttp
from aiohttp import web
from PIL import Image

CONFIG_PATH = Path.home() / ".config/roku/config.json"
DATA = Path.home() / ".local/share/roku-browser"
DEFAULTS = {
    "roku": "",                 # Roku IP for ECP hand-offs; learned from the channel if empty
    "port": 8765,
    "discovery_port": 8766,
    "home": "start",            # "start" is the built-in TV start page
    "search": "https://search.brave.com/search?q={}",
    "zoom": 1.25,
    "idle_close_minutes": 15,
    "browser": "",              # empty: the first of BROWSERS that's installed
}
BROWSERS = ("brave", "brave-browser", "chromium", "chromium-browser", "google-chrome-stable", "google-chrome")
W, H = 1280, 720
CAPTURE_INTERVAL = 0.15         # seconds between full-size captures
JPEG_QUALITY = 88               # re-encoded with full colour detail so coloured text stays crisp
ZOOMS = (1.0, 1.25, 1.5, 1.75)
YOUTUBE_APP = "837"

log = logging.getLogger("roku-browser")

KEYS = {
    "Enter": dict(key="Enter", code="Enter", windowsVirtualKeyCode=13, text="\r"),
    "Backspace": dict(key="Backspace", code="Backspace", windowsVirtualKeyCode=8),
    "Tab": dict(key="Tab", code="Tab", windowsVirtualKeyCode=9),
    "Escape": dict(key="Escape", code="Escape", windowsVirtualKeyCode=27),
    "ArrowUp": dict(key="ArrowUp", code="ArrowUp", windowsVirtualKeyCode=38),
    "ArrowDown": dict(key="ArrowDown", code="ArrowDown", windowsVirtualKeyCode=40),
    "ArrowLeft": dict(key="ArrowLeft", code="ArrowLeft", windowsVirtualKeyCode=37),
    "ArrowRight": dict(key="ArrowRight", code="ArrowRight", windowsVirtualKeyCode=39),
    "Space": dict(key=" ", code="Space", windowsVirtualKeyCode=32, text=" "),
    "a": dict(key="a", code="KeyA", windowsVirtualKeyCode=65),
}

MEDIA_MIME = {
    "application/vnd.apple.mpegurl": "hls", "application/x-mpegurl": "hls",
    "audio/mpegurl": "hls", "audio/x-mpegurl": "hls", "application/dash+xml": "dash",
}
EXT_FORMAT = {".m3u8": "hls", ".mpd": "dash", ".mp4": "mp4", ".m4v": "mp4", ".mov": "mp4",
              ".mkv": "mkv", ".mp3": "mp3", ".m4a": "mp4", ".ts": "mp4"}

# Outlines of what can be clicked, so the channel can highlight targets under its cursor.
CLICKABLE_JS = r"""(() => {
  const sel = 'a[href], button, input:not([type=hidden]), select, textarea, summary, label[for], [role=button],' +
              '[role=link], [role=tab], [role=menuitem], [role=checkbox], [role=switch], [role=option], [onclick],' +
              '[contenteditable=""], [contenteditable=true]';
  const vw = innerWidth, vh = innerHeight, out = [];
  for (const el of document.querySelectorAll(sel)) {
    const r = el.getBoundingClientRect();
    if (r.width < 6 || r.height < 6 || r.bottom <= 0 || r.right <= 0 || r.top >= vh || r.left >= vw) continue;
    if (r.width * r.height > vw * vh * 0.45) continue;
    const cx = Math.min(Math.max(r.left + r.width / 2, 0), vw - 1), cy = Math.min(Math.max(r.top + r.height / 2, 0), vh - 1);
    const hit = document.elementFromPoint(cx, cy);
    if (!hit || (hit !== el && !el.contains(hit) && !hit.contains(el))) continue;
    out.push([r.left, r.top, r.width, r.height]);
    if (out.length >= 300) break;
  }
  return out;
})()"""

# Describes the focused field after a click, so the channel can pop up its keyboard.
FOCUSED_FIELD_JS = r"""(() => {
  let e = document.activeElement;
  while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;
  if (!e) return null;
  if (e.tagName === 'IFRAME') return {kind: 'text', value: '', label: '', multiline: false};
  const type = (e.type || '').toLowerCase();
  const nonText = ['button','submit','checkbox','radio','range','color','file','image','reset','hidden'];
  const editable = e.isContentEditable || e.tagName === 'TEXTAREA' ||
                   (e.tagName === 'INPUT' && !nonText.includes(type));
  if (!editable || e.disabled || e.readOnly) return null;
  const label = e.getAttribute('aria-label') || e.placeholder || e.name || '';
  return {kind: e.isContentEditable ? 'text' : (type || 'text'),
          value: e.isContentEditable ? e.innerText : (e.value || ''),
          label: label.slice(0, 80),
          multiline: e.tagName === 'TEXTAREA' || e.isContentEditable};
})()"""

# The page shown on launch and by "Start page": big targets for a remote-driven cursor.
START_HTML = """<!doctype html>
<html lang="en-GB"><head><meta charset="utf-8"><title>Start</title>
<style>
:root { --base:#1a141b; --surface:#251d26; --raised:#2f2530; --line:#3b2f3a; --text:#f0e4d4; --muted:#b5a698; --amber:#e89b5e; }
* { box-sizing: border-box; }
html, body { margin: 0; min-height: 100%; color: var(--text); font-family: Inter, system-ui, sans-serif;
  background: radial-gradient(900px 480px at 50% -12%, #43291f 0%, var(--base) 62%) fixed, var(--base); }
main { max-width: 880px; margin: 0 auto; padding: 30px 28px 24px; }
.clock { font-size: 54px; font-weight: 600; letter-spacing: -1.5px; line-height: 1; }
.date { color: var(--muted); font-size: 17px; margin-top: 8px; }
form { margin: 22px 0 26px; position: relative; }
form svg { position: absolute; left: 22px; top: 50%; transform: translateY(-50%); }
input { width: 100%; font: 500 21px Inter, system-ui, sans-serif; color: var(--text); padding: 17px 24px 17px 58px;
  border-radius: 999px; border: 1px solid var(--line); background: var(--surface); outline: none; }
input::placeholder { color: var(--muted); }
input:hover, input:focus { border-color: var(--amber); box-shadow: 0 0 0 4px rgba(232,155,94,.18); }
h2 { font-size: 13px; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: .1em; margin: 0 0 14px 4px; }
.grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; }
a.tile { display: flex; flex-direction: column; align-items: center; gap: 10px; padding: 16px 8px 14px; border-radius: 20px;
  background: var(--surface); border: 1px solid var(--line); color: var(--text); text-decoration: none; font-size: 15px; font-weight: 500;
  transition: background .12s, border-color .12s, transform .12s; }
a.tile:hover { background: var(--raised); border-color: var(--amber); transform: translateY(-2px); }
.icon { width: 54px; height: 54px; border-radius: 14px; background: #f6efe6; display: grid; place-items: center; }
.icon img { width: 32px; height: 32px; }
.tip { margin-top: 20px; text-align: center; color: var(--muted); font-size: 14px; }
.tip b { color: var(--text); font-weight: 600; }
</style></head>
<body><main>
  <div class="clock" id="clock"></div>
  <div class="date" id="date"></div>
  <form id="f" autocomplete="off">
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#e89b5e" stroke-width="2.4" stroke-linecap="round"><circle cx="10.5" cy="10.5" r="6.5"/><path d="m15.5 15.5 5 5"/></svg>
    <input id="q" type="search" placeholder="Search or enter address" aria-label="Search or enter address">
  </form>
  <h2>Favourites</h2>
  <div class="grid">%TILES%</div>
  <p class="tip">Press <b>Play/Pause</b> to search from any page, <b>&#x2731;</b> for the menu, and <b>Back</b> to go back.</p>
</main>
<script>
const SEARCH = %SEARCH%;
function tick() {
  const d = new Date();
  document.getElementById('clock').textContent = d.toLocaleTimeString('en-GB', {hour: '2-digit', minute: '2-digit'});
  document.getElementById('date').textContent = d.toLocaleDateString('en-GB', {weekday: 'long', day: 'numeric', month: 'long'});
}
tick(); setInterval(tick, 15000);
document.getElementById('f').addEventListener('submit', e => {
  e.preventDefault();
  const q = document.getElementById('q').value.trim();
  if (!q) return;
  location.href = /^[a-z][a-z0-9+.-]*:\\/\\//i.test(q) ? q
    : (!/\\s/.test(q) && /^[^\\s\\/]+\\.[a-z]{2,}(:\\d+)?(\\/.*)?$/i.test(q)) ? 'https://' + q
    : SEARCH.replace('{}', encodeURIComponent(q));
});
</script></body></html>"""
FAVOURITES = [
    ("YouTube", "https://www.youtube.com"), ("BBC News", "https://www.bbc.co.uk/news"),
    ("BBC Sport", "https://www.bbc.co.uk/sport"), ("BBC Weather", "https://www.bbc.co.uk/weather"),
    ("Wikipedia", "https://en.wikipedia.org"), ("Reddit", "https://www.reddit.com"),
    ("Twitch", "https://www.twitch.tv"), ("Google Maps", "https://www.google.com/maps"),
]


class CDPError(Exception):
    pass


def load_config():
    cfg = dict(DEFAULTS)
    try:
        cfg.update(json.loads(CONFIG_PATH.read_text()))
    except FileNotFoundError:
        pass
    if not cfg["browser"]:
        cfg["browser"] = next((b for b in BROWSERS if shutil.which(b)), "")
    if not cfg["browser"]:
        raise SystemExit("No Chromium-based browser found; install Brave, Chromium or Google Chrome.")
    return cfg


def local_ip_for(remote):
    """The address of this machine on the route to `remote`."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect((remote, 9))
        return s.getsockname()[0]


def to_jpeg(png):
    with Image.open(io.BytesIO(png)) as im:
        out = io.BytesIO()
        im.convert("RGB").save(out, "JPEG", quality=JPEG_QUALITY, subsampling=0)
        return out.getvalue()


def die_with_parent():
    """Runs in the browser's child process: if this service dies, so does the browser."""
    ctypes.CDLL("libc.so.6").prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG


def kill_stale_browser(profile):
    """A browser left over from a crash holds the profile; a new one would just hand off to it."""
    try:
        pid = int(os.readlink(profile / "SingletonLock").rsplit("-", 1)[1])
    except (OSError, ValueError, IndexError):
        return
    try:
        if str(profile) in Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace"):
            log.info("stopping leftover browser %d", pid)
            os.kill(pid, signal.SIGTERM)
            time.sleep(1)
    except (OSError, ProcessLookupError):
        pass


def youtube_id(url):
    u = urlparse(url)
    host = (u.hostname or "").removeprefix("www.").removeprefix("m.")
    if host == "youtu.be":
        return u.path.strip("/").split("/")[0] or None
    if host.endswith("youtube.com"):
        if u.path == "/watch":
            return parse_qs(u.query).get("v", [None])[0]
        m = re.match(r"^/(?:shorts|live|embed)/([\w-]{6,})", u.path)
        return m and m.group(1)
    return None


def format_for(path_or_url):
    return EXT_FORMAT.get(Path(urlparse(str(path_or_url)).path).suffix.lower())


class Browser:
    def __init__(self, cfg):
        self.cfg = cfg
        self.zoom = self._saved().get("zoom", cfg["zoom"])
        self.scale = 1.0                # TV pixels per channel coordinate: 1.5 on 1080p Rokus
        self.http = None                # aiohttp session for ECP and Roku checks
        self.proc = None
        self.cdp = None                 # aiohttp session owning the CDP websocket
        self.ws = None
        self.msg_id = 0
        self.pending = {}
        self.lock = asyncio.Lock()
        self.ua = None
        self.tabs = []                  # page target ids, last one is shown
        self.sessions = {}              # target id -> CDP session id
        self.info = {}                  # target id -> {"url", "title"}
        self.history = {}               # target id -> navigation history
        self.media = {}                 # target id -> playable streams seen on the page
        self.loading = set()
        self.frame_no = 0
        self.jpeg = b""
        self.png = b""
        self.links = []                 # clickable rects for the current frame, in 1280x720 coordinates
        self.state_ver = 0
        self.action = None              # one-shot instruction for the channel
        self.changed = asyncio.Condition()
        self.dirty = False
        self.capturing = False
        self.last_capture = 0.0
        self.paused = False
        self.last_activity = time.monotonic()
        self.roku_ip = cfg.get("roku") or ""
        self.roku_cache = {}
        self.files = {}                 # token -> local file being played on the TV
        self.boot = secrets.token_hex(3)  # lets the channel tell frames from a previous run apart

    # ---- lifecycle -------------------------------------------------------

    @property
    def running(self):
        return self.ws is not None and not self.ws.closed

    @property
    def active(self):
        return self.tabs[-1] if self.tabs else None

    async def ensure(self):
        self.last_activity = time.monotonic()
        async with self.lock:
            if not self.running:
                await self._start()
        if self.paused:
            await self._resume()

    async def _start(self):
        profile = DATA / "profile"
        profile.mkdir(parents=True, exist_ok=True)
        port_file = profile / "DevToolsActivePort"
        port_file.unlink(missing_ok=True)
        kill_stale_browser(profile)
        # Brave would reopen every old tab; we restore just the last page ourselves.
        shutil.rmtree(profile / "Default" / "Sessions", ignore_errors=True)
        args = [
            self.cfg["browser"], "--headless", f"--user-data-dir={profile}",
            "--remote-debugging-port=0", "--password-store=basic", "--no-first-run",
            "--no-default-browser-check", "--mute-audio", "--disable-smooth-scrolling",
            "--hide-scrollbars", f"--window-size={W},{H}", "about:blank",
        ]
        log.info("starting %s", self.cfg["browser"])
        self.proc = await asyncio.create_subprocess_exec(
            *args, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
            preexec_fn=die_with_parent)
        for _ in range(100):
            if port_file.exists() and len(port_file.read_text().splitlines()) >= 2:
                break
            await asyncio.sleep(0.1)
        else:
            self.proc.kill()
            raise CDPError("browser did not start")
        port, path = port_file.read_text().splitlines()[:2]
        self.cdp = aiohttp.ClientSession()
        self.ws = await self.cdp.ws_connect(f"ws://127.0.0.1:{port}{path}", max_msg_size=0)
        asyncio.create_task(self._reader())
        self.tabs, self.sessions, self.info, self.history, self.media = [], {}, {}, {}, {}
        self.loading.clear()
        version = await self.call("Browser.getVersion")
        self.ua = version["userAgent"].replace("HeadlessChrome", "Chrome")
        self.major = re.search(r"Chrome/(\d+)", self.ua).group(1)
        await self.call("Browser.setDownloadBehavior", {"behavior": "deny"})
        await self.call("Target.setDiscoverTargets", {"discover": True})
        for _ in range(50):
            if self.active and self.active in self.sessions:
                break
            await asyncio.sleep(0.1)
        self.paused = False
        await self.navigate(self._saved_url() or self.home_url())

    async def stop(self):
        if not self.running:
            return
        log.info("closing browser")
        self._save_session()
        try:
            await self.call("Browser.close", timeout=3)
        except Exception:
            pass
        if self.proc:
            try:
                await asyncio.wait_for(self.proc.wait(), 5)
            except asyncio.TimeoutError:
                self.proc.kill()
        await self.ws.close()
        await self.cdp.close()

    async def pause(self):
        """Stop capturing while nobody is watching."""
        if self.running and not self.paused and self.active:
            self.paused = True
            try:
                await self.page("Page.stopScreencast")
            except Exception:
                pass

    async def _resume(self):
        self.paused = False
        if self.active:
            await self._start_screencast(self.active)

    def _saved(self):
        try:
            return json.loads((DATA / "session.json").read_text())
        except (FileNotFoundError, ValueError):
            return {}

    def _saved_url(self):
        return self._saved().get("url")

    def _save_session(self):
        url = self.info.get(self.active, {}).get("url", "") or self._saved_url() or ""
        if url.startswith(("http://", "https://")):
            (DATA / "session.json").write_text(json.dumps({"url": url, "zoom": self.zoom}))

    # ---- CDP plumbing ----------------------------------------------------

    async def call(self, method, params=None, session=None, timeout=15):
        if not self.running:
            raise CDPError("browser not running")
        self.msg_id += 1
        mid = self.msg_id
        msg = {"id": mid, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        fut = asyncio.get_running_loop().create_future()
        self.pending[mid] = fut
        await self.ws.send_str(json.dumps(msg))
        try:
            return await asyncio.wait_for(fut, timeout)
        finally:
            self.pending.pop(mid, None)

    async def page(self, method, params=None, **kw):
        return await self.call(method, params, self.sessions[self.active], **kw)

    async def _reader(self):
        ws = self.ws
        try:
            async for m in ws:
                if m.type != aiohttp.WSMsgType.TEXT:
                    continue
                d = json.loads(m.data)
                if "id" in d:
                    fut = self.pending.get(d["id"])
                    if fut and not fut.done():
                        if "error" in d:
                            fut.set_exception(CDPError(d["error"].get("message")))
                        else:
                            fut.set_result(d.get("result", {}))
                else:
                    try:
                        self._event(d.get("method"), d.get("params", {}), d.get("sessionId"))
                    except Exception:
                        log.exception("handling %s", d.get("method"))
        finally:
            for fut in self.pending.values():
                if not fut.done():
                    fut.set_exception(CDPError("browser closed"))
            log.info("browser connection closed")

    def _target_for(self, session):
        for tid, sid in self.sessions.items():
            if sid == session:
                return tid
        return None

    def _event(self, method, p, session):
        """Runs inside the reader, so anything that calls CDP goes in a task."""
        if method == "Target.targetCreated":
            t = p["targetInfo"]
            if t["type"] == "page" and not t["url"].startswith(("chrome-extension:", "brave:", "chrome:")):
                self.info[t["targetId"]] = {"url": t["url"], "title": t["title"]}
                asyncio.create_task(self._adopt(t["targetId"]))
        elif method == "Target.targetDestroyed":
            asyncio.create_task(self._forget(p["targetId"]))
        elif method == "Target.targetInfoChanged":
            t = p["targetInfo"]
            if t["targetId"] in self.info:
                self.info[t["targetId"]] = {"url": t["url"], "title": t["title"]}
                if t["targetId"] == self.active:
                    self._save_session()
                    self.bump()
            return
        tid = self._target_for(session) if session else None
        if tid is None:
            return
        if method == "Page.screencastFrame":
            asyncio.create_task(self._ack(session, p["sessionId"]))
            if tid == self.active:
                self.mark_dirty()
        elif method == "Page.frameStartedLoading" and p["frameId"] == tid:
            self.loading.add(tid)
            self.bump()
        elif method == "Page.frameStoppedLoading" and p["frameId"] == tid:
            self.loading.discard(tid)
            self.bump()
            self.recapture()
            asyncio.create_task(self.refresh_info(tid))
        elif method == "Page.domContentEventFired":
            asyncio.create_task(self.refresh_info(tid))
        elif method == "Page.frameNavigated" and not p["frame"].get("parentId"):
            self.media[tid] = []
            asyncio.create_task(self._refresh_history(tid))
        elif method == "Page.navigatedWithinDocument":
            asyncio.create_task(self._refresh_history(tid))
            asyncio.create_task(self.refresh_info(tid))
        elif method == "Page.javascriptDialogOpening":
            asyncio.create_task(self.call("Page.handleJavaScriptDialog",
                                          {"accept": True, "promptText": p.get("defaultPrompt", "")}, session))
            if p.get("message") and p["type"] != "beforeunload":
                self.notify_tv(p["message"][:160])
        elif method == "Network.responseReceived":
            self._sniff(tid, p)
        elif method == "Inspector.targetCrashed":
            asyncio.create_task(self.call("Page.reload", {}, session))

    async def _ack(self, session, frame_session):
        # Holding the ack throttles the change signal; full captures happen separately.
        await asyncio.sleep(0.1)
        try:
            await self.call("Page.screencastFrameAck", {"sessionId": frame_session}, session)
        except Exception:
            pass

    async def _adopt(self, tid):
        try:
            r = await self.call("Target.attachToTarget", {"targetId": tid, "flatten": True})
        except CDPError:
            return
        sid = r["sessionId"]
        self.sessions[tid] = sid
        for method, params in (
            ("Page.enable", {}),
            ("Network.enable", {}),
            ("Emulation.setDeviceMetricsOverride", self.metrics()),
            ("Emulation.setScrollbarsHidden", {"hidden": True}),
            ("Emulation.setFocusEmulationEnabled", {"enabled": True}),
            ("Emulation.setUserAgentOverride", {
                "userAgent": self.ua, "acceptLanguage": "en-GB,en", "platform": "Linux",
                "userAgentMetadata": {
                    "brands": [{"brand": "Chromium", "version": self.major},
                               {"brand": "Brave", "version": self.major},
                               {"brand": "Not_A Brand", "version": "24"}],
                    "fullVersion": self.major, "platform": "Linux", "platformVersion": "",
                    "architecture": "x86", "model": "", "mobile": False}}),
        ):
            try:
                await self.call(method, params, sid)
            except CDPError as e:
                log.debug("%s: %s", method, e)
        await self._activate(tid)

    async def _activate(self, tid):
        old = self.active
        if old and old != tid and old in self.sessions:
            try:
                await self.call("Page.stopScreencast", {}, self.sessions[old])
            except CDPError:
                pass
        if tid in self.tabs:
            self.tabs.remove(tid)
        self.tabs.append(tid)
        await self._refresh_history(tid)
        if not self.paused:
            await self._start_screencast(tid)
        self.bump()

    async def _start_screencast(self, tid):
        try:
            await self.call("Page.startScreencast",
                            {"format": "jpeg", "quality": 10, "maxWidth": 160, "maxHeight": 90},
                            self.sessions[tid])
        except CDPError as e:
            log.debug("screencast: %s", e)
        self.mark_dirty()

    async def _forget(self, tid):
        was_active = tid == self.active
        for d in (self.sessions, self.info, self.history, self.media):
            d.pop(tid, None)
        self.loading.discard(tid)
        if tid in self.tabs:
            self.tabs.remove(tid)
        if was_active:
            if self.tabs:
                await self._activate(self.tabs[-1])
            elif self.running:
                await self.call("Target.createTarget", {"url": self.home_url()})

    async def refresh_info(self, tid):
        """The browser only reports a page's title when navigation starts, so ask for it."""
        try:
            t = (await self.call("Target.getTargetInfo", {"targetId": tid}))["targetInfo"]
        except CDPError:
            return
        new = {"url": t["url"], "title": t["title"]}
        if tid in self.info and self.info[tid] != new:
            self.info[tid] = new
            if tid == self.active:
                self._save_session()
                self.bump()
        await self._refresh_history(tid, only_if_changed=True)

    async def _refresh_history(self, tid, only_if_changed=False):
        try:
            hist = await self.call("Page.getNavigationHistory", {}, self.sessions[tid])
        except (CDPError, KeyError):
            return
        changed = self.history.get(tid) != hist
        self.history[tid] = hist
        if tid == self.active and (changed or not only_if_changed):
            self.bump()

    # ---- frames and state ------------------------------------------------

    def recapture(self):
        """Extra captures shortly after a change, in case the change signal was missed."""
        async def later():
            for delay in (0.4, 1.0, 2.5):
                await asyncio.sleep(delay)
                self.mark_dirty()
        asyncio.create_task(later())

    def mark_dirty(self):
        self.dirty = True
        if not self.capturing:
            asyncio.create_task(self._capture_loop())

    async def _capture_loop(self):
        self.capturing = True
        try:
            while self.dirty and self.active in self.sessions and not self.paused:
                wait = self.last_capture + CAPTURE_INTERVAL - time.monotonic()
                if wait > 0:
                    await asyncio.sleep(wait)
                self.dirty = False
                try:
                    links = await self.page("Runtime.evaluate", {"expression": CLICKABLE_JS, "returnByValue": True})
                    r = await self.page("Page.captureScreenshot", {"format": "png", "optimizeForSpeed": True})
                except (CDPError, KeyError, asyncio.TimeoutError) as e:
                    log.debug("capture: %s", e)
                    break
                self.last_capture = time.monotonic()
                png = base64.b64decode(r["data"])
                if png != self.png:
                    self.png = png
                    self.jpeg = await asyncio.to_thread(to_jpeg, png)
                    z = self.zoom
                    self.links = [[round(v * z) for v in rect]
                                  for rect in links.get("result", {}).get("value") or []]
                    self.frame_no += 1
                    log.debug("frame %d captured", self.frame_no)
                    await self._wake()
        finally:
            self.capturing = False

    async def _wake(self):
        async with self.changed:
            self.changed.notify_all()

    def bump(self):
        self.state_ver += 1
        asyncio.create_task(self._wake())

    def notify_tv(self, text):
        self.action = {"id": secrets.randbelow(1 << 30), "notice": text}
        self.bump()

    def snapshot(self, take_action=False):
        tid = self.active
        info = self.info.get(tid, {})
        url, title = info.get("url", ""), info.get("title", "")
        host = (urlparse(url).hostname or "").removeprefix("www.")
        if url.startswith(self.start_url()):
            title, host = "Start", ""
        if not title or title in (url, host) or title.startswith(host + "/"):
            title = ""
        label = "  ·  ".join(x for x in (title, host) if x) or "Loading…"
        s = {
            "frame": self.frame_no, "sv": self.state_ver, "boot": self.boot,
            "url": url, "title": title, "host": host, "label": label,
            "loading": tid in self.loading,
            "back": self._history_step(-1) is not None or len(self.tabs) > 1,
            "fwd": self._history_step(1) is not None,
            "tabs": len(self.tabs), "zoom": round(self.zoom * 100),
            "video": self._video_label(),
        }
        if take_action and self.action:
            s["action"], self.action = self.action, None
        return s

    def with_links(self, s, since):
        if s["frame"] != since:
            s["links"] = self.links
        return s

    def _video_label(self):
        url = self.info.get(self.active, {}).get("url", "")
        if youtube_id(url):
            return "Open in YouTube app"
        if self.media.get(self.active):
            return "Play video on TV"
        if shutil.which("yt-dlp") and url.startswith("http") and "google." not in url:
            return "Find video on this page"
        return ""

    # ---- input from the channel -----------------------------------------

    def css(self, q, key):
        return float(q.get(key, 0)) / self.zoom

    async def mouse(self, kind, x, y, **extra):
        await self.page("Input.dispatchMouseEvent", {"type": kind, "x": x, "y": y, **extra})

    async def press(self, name, modifiers=0, commands=None):
        k = dict(KEYS[name])
        text = k.pop("text", None)
        down = {"type": "keyDown" if text else "rawKeyDown", "modifiers": modifiers, **k}
        if text:
            down["text"] = down["unmodifiedText"] = text
        if commands:
            down["commands"] = commands
        await self.page("Input.dispatchKeyEvent", down)
        await self.page("Input.dispatchKeyEvent", {"type": "keyUp", "modifiers": modifiers, **k})

    async def type_text(self, text, enter=False, replace=True):
        if replace:
            await self.press("a", modifiers=2, commands=["selectAll"])
            if not text:
                await self.press("Backspace")
        if text:
            await self.page("Input.insertText", {"text": text})
        if enter:
            await self.press("Enter")

    def start_url(self):
        return f"http://127.0.0.1:{self.cfg['port']}/start"

    def home_url(self):
        return self.start_url() if self.cfg["home"] == "start" else self.cfg["home"]

    def to_url(self, q):
        q = q.strip()
        if re.match(r"^[a-z][a-z0-9+.-]*://", q, re.I) or q.startswith("about:"):
            return q
        if " " not in q:
            if re.match(r"^(localhost|\d{1,3}(\.\d{1,3}){3})(:\d+)?(/.*)?$", q):
                return "http://" + q
            if re.match(r"^[^\s/]+\.[a-z]{2,}(:\d+)?(/.*)?$", q, re.I):
                return "https://" + q
        return self.cfg["search"].format(quote(q))

    async def navigate(self, q):
        await self.page("Page.navigate", {"url": self.to_url(q)})

    def metrics(self):
        """Page width shrinks as text grows; frames always come out at the TV's own resolution."""
        z = self.zoom
        return {"width": round(W / z), "height": round(H / z), "deviceScaleFactor": z * self.scale, "mobile": False}

    async def apply_metrics(self):
        for sid in list(self.sessions.values()):
            await self.call("Emulation.setDeviceMetricsOverride", self.metrics(), sid)
        self.mark_dirty()
        self.bump()

    async def set_zoom(self, z):
        self.zoom = z
        self._save_session()
        await self.apply_metrics()

    async def set_scale(self, ui_width):
        scale = 1.5 if ui_width >= 1920 else 1.0
        if scale != self.scale:
            self.scale = scale
            if self.running:
                await self.apply_metrics()

    def _history_step(self, direction):
        """The nearest real page back (-1) or forward (+1); the blank page the browser starts on doesn't count."""
        hist = self.history.get(self.active, {})
        entries, i = hist.get("entries", []), hist.get("currentIndex", 0) + direction
        while 0 <= i < len(entries):
            if entries[i]["url"] != "about:blank":
                return entries[i]["id"]
            i += direction
        return None

    async def go_back(self):
        entry = self._history_step(-1)
        if entry is not None:
            await self.page("Page.navigateToHistoryEntry", {"entryId": entry})
            return True
        if len(self.tabs) > 1:
            await self.call("Target.closeTarget", {"targetId": self.active})
            return True
        return False

    async def go_forward(self):
        entry = self._history_step(1)
        if entry is not None:
            await self.page("Page.navigateToHistoryEntry", {"entryId": entry})

    async def handle(self, t, q):
        """One remote-control action from the channel. Coordinates are 1280x720 screen pixels."""
        log.debug("input %s", t)
        if t != "move":
            self.recapture()
        if t == "move":
            await self.mouse("mouseMoved", self.css(q, "x"), self.css(q, "y"))
        elif t == "click":
            x, y = self.css(q, "x"), self.css(q, "y")
            await self.mouse("mouseMoved", x, y)
            await self.mouse("mousePressed", x, y, button="left", buttons=1, clickCount=1)
            await self.mouse("mouseReleased", x, y, button="left", buttons=0, clickCount=1)
            await asyncio.sleep(0.25)
            r = await self.page("Runtime.evaluate", {"expression": FOCUSED_FIELD_JS, "returnByValue": True})
            field = r.get("result", {}).get("value")
            return {"edit": field} if field else {}
        elif t == "scroll":
            await self.mouse("mouseWheel", self.css(q, "x"), self.css(q, "y"),
                             deltaX=self.css(q, "dx"), deltaY=self.css(q, "dy"))
            self.mark_dirty()
        elif t == "page":
            await self.mouse("mouseWheel", W / self.zoom / 2, H / self.zoom / 2, deltaX=0,
                             deltaY=int(q.get("dir", 1)) * H / self.zoom * 0.85)
            self.mark_dirty()
        elif t == "text":
            await self.type_text(q.get("s", ""), enter=q.get("enter") == "1", replace=q.get("replace", "1") == "1")
        elif t == "key":
            await self.press(q.get("k", "Enter"))
        elif t == "nav":
            await self.navigate(q.get("q", ""))
        elif t == "home":
            await self.navigate(self.home_url())
        elif t == "back":
            return {"went": await self.go_back()}
        elif t == "forward":
            await self.go_forward()
        elif t == "reload":
            await self.page("Page.reload", {})
        elif t == "zoom":
            i = ZOOMS.index(min(ZOOMS, key=lambda z: abs(z - self.zoom)))
            await self.set_zoom(ZOOMS[(i + 1) % len(ZOOMS)])
        elif t == "closetab":
            if len(self.tabs) > 1:
                await self.call("Target.closeTarget", {"targetId": self.active})
        elif t == "video":
            return await self.video_on_page()
        else:
            raise web.HTTPBadRequest(text=f"unknown input {t}")
        return {}

    # ---- video hand-off --------------------------------------------------

    def _sniff(self, tid, p):
        r = p["response"]
        url, mime = r["url"], (r.get("mimeType") or "").lower()
        if url.startswith(("blob:", "data:")):
            return
        fmt = MEDIA_MIME.get(mime)
        ext_fmt = format_for(url)
        if not fmt and ext_fmt in ("hls", "dash"):
            fmt = ext_fmt
        if not fmt and p.get("type") == "Media" and (mime.startswith("video/") or ext_fmt):
            fmt = ext_fmt or "mp4"
        if not fmt:
            return
        found = self.media.setdefault(tid, [])
        # The first playlist is the master; later ones are its variants.
        if any(m["url"] == url or (fmt == "hls" and m["format"] == "hls") for m in found):
            return
        found.append({"url": url, "format": fmt})
        log.info("found %s stream on page: %s", fmt, url[:120])
        if tid == self.active:
            self.bump()

    async def video_on_page(self):
        info = self.info.get(self.active, {})
        vid = youtube_id(info.get("url", ""))
        if vid:
            await self.ecp(f"launch/{YOUTUBE_APP}?contentId={quote(vid)}&mediaType=movie")
            return {"notice": "Opening in YouTube…"}
        streams = self.media.get(self.active)
        if streams:
            m = streams[0]
            headers = [f"User-Agent: {self.ua}", f"Referer: {info.get('url', '')}"]
            try:
                cookies = (await self.page("Network.getCookies", {"urls": [m["url"]]}))["cookies"]
            except CDPError:
                cookies = []
            if cookies:
                headers.append("Cookie: " + "; ".join(f"{c['name']}={c['value']}" for c in cookies))
            return {"play": {"url": m["url"], "format": m["format"], "headers": headers,
                             "title": info.get("title", "")}}
        item = await self.ytdlp(info.get("url", ""))
        if item:
            return {"play": item}
        return {"notice": "No playable video found on this page"}

    async def ytdlp(self, url):
        exe = shutil.which("yt-dlp")
        if not exe or not url.startswith("http"):
            return None
        fmt = ("best[protocol^=http][vcodec!=none][acodec!=none][ext=mp4]/"
               "best[protocol^=m3u8][vcodec!=none][acodec!=none]/best[vcodec!=none][acodec!=none]")
        proc = await asyncio.create_subprocess_exec(
            exe, "-J", "--no-playlist", "-f", fmt, url,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        try:
            out, _ = await asyncio.wait_for(proc.communicate(), 45)
            info = json.loads(out)
        except (asyncio.TimeoutError, ValueError):
            proc.kill()
            return None
        if not info.get("url"):
            return None
        proto = info.get("protocol", "")
        keep = ("user-agent", "referer", "cookie", "origin")
        return {"url": info["url"],
                "format": "hls" if "m3u8" in proto else "dash" if "dash" in proto else "mp4",
                "headers": [f"{k}: {v}" for k, v in (info.get("http_headers") or {}).items() if k.lower() in keep],
                "title": info.get("title", "")}

    # ---- Roku control ----------------------------------------------------

    async def ecp(self, path, method="POST"):
        if not self.roku_ip:
            raise web.HTTPServiceUnavailable(text="Roku address unknown; set \"roku\" in config.json")
        async with self.http.request(method, f"http://{self.roku_ip}:8060/{path}",
                                     timeout=aiohttp.ClientTimeout(total=5)) as r:
            return r.status, await r.text()

    def base_url(self):
        return f"http://{local_ip_for(self.roku_ip or '192.168.0.1')}:{self.cfg['port']}"

    async def show_on_tv(self, action=None):
        """Put the Browser channel on screen, optionally with something for it to do."""
        if action:
            self.action = {"id": secrets.randbelow(1 << 30), **action}
            self.bump()
        _, active = await self.ecp("query/active-app", "GET")
        if 'id="dev"' not in active:
            await self.ecp(f"launch/dev?server={quote(self.base_url(), safe='')}")

    async def is_roku(self, ip):
        hit = self.roku_cache.get(ip)
        if hit and (hit[0] or time.monotonic() - hit[1] < 60):
            return hit[0]
        ok = False
        try:
            async with self.http.get(f"http://{ip}:8060/query/device-info",
                                     timeout=aiohttp.ClientTimeout(total=1.5)) as r:
                ok = r.status == 200 and "<device-info>" in await r.text()
        except (aiohttp.ClientError, asyncio.TimeoutError):
            pass
        self.roku_cache[ip] = (ok, time.monotonic())
        return ok


class Discovery(asyncio.DatagramProtocol):
    """Answers the channel's broadcast so it finds the laptop after an IP change."""

    def __init__(self, port):
        self.port = port

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        if data.strip() == b"ROKU-BROWSER?":
            reply = {"server": f"http://{local_ip_for(addr[0])}:{self.port}"}
            self.transport.sendto(json.dumps(reply).encode(), addr)


def make_app(b):
    @web.middleware
    async def guard(req, handler):
        ip = req.remote
        if ip in ("127.0.0.1", "::1"):
            return await handler(req)
        if await b.is_roku(ip):
            b.roku_ip = b.roku_ip or ip
            return await handler(req)
        raise web.HTTPForbidden(text="only the Roku and this laptop may use roku-browser")

    async def hello(req):
        return web.json_response({"app": "roku-browser", "v": 1})

    async def poll(req):
        since, sv = int(req.query.get("since", -1)), int(req.query.get("sv", -1))
        if req.remote not in ("127.0.0.1", "::1"):
            b.roku_ip = req.remote
        await b.set_scale(int(req.query.get("w", W)))
        await b.ensure()

        def ready():
            return (b.frame_no and b.frame_no != since) or b.state_ver != sv or b.action

        async with b.changed:
            try:
                await asyncio.wait_for(b.changed.wait_for(ready), float(req.query.get("wait", 10)))
            except asyncio.TimeoutError:
                pass
        b.last_activity = time.monotonic()
        return web.json_response(b.with_links(b.snapshot(take_action=True), since))

    async def start(req):
        tiles = "".join(
            f'<a class="tile" href="{url}"><span class="icon"><img alt="" '
            f'src="https://icons.duckduckgo.com/ip3/{urlparse(url).hostname}.ico"></span>{name}</a>'
            for name, url in FAVOURITES)
        page = START_HTML.replace("%TILES%", tiles).replace("%SEARCH%", json.dumps(b.cfg["search"]))
        return web.Response(text=page, content_type="text/html")

    async def frame(req):
        log.debug("frame %s served", req.match_info["n"])
        return web.Response(body=b.jpeg, content_type="image/jpeg", headers={"Cache-Control": "no-store"})

    async def input_(req):
        await b.ensure()
        try:
            return web.json_response(await b.handle(req.query.get("t", ""), req.query) or {})
        except CDPError as e:
            return web.json_response({"error": str(e)}, status=503)

    async def state(req):
        return web.json_response({**b.snapshot(), "running": b.running})

    async def open_(req):
        body = await req.json()
        await b.ensure()
        await b.navigate(body["q"])
        await b.show_on_tv()
        return web.json_response({"ok": True})

    async def type_(req):
        body = await req.json()
        await b.ensure()
        await b.type_text(body.get("text", ""), enter=body.get("enter", False), replace=False)
        return web.json_response({"ok": True})

    async def cast(req):
        body = await req.json()
        if body.get("path"):
            p = Path(body["path"]).expanduser().resolve()
            if not p.is_file():
                raise web.HTTPNotFound(text=f"no such file: {p}")
            token = secrets.token_urlsafe(12)
            b.files[token] = p
            item = {"url": f"{b.base_url()}/file/{token}/{quote(p.name)}",
                    "format": format_for(p) or "mp4", "headers": [], "title": p.stem}
        else:
            url = body["url"]
            vid = youtube_id(url)
            if vid:
                await b.ecp(f"launch/{YOUTUBE_APP}?contentId={quote(vid)}&mediaType=movie")
                return web.json_response({"ok": True, "via": "YouTube app"})
            fmt = format_for(url)
            item = ({"url": url, "format": fmt, "headers": [], "title": Path(urlparse(url).path).name}
                    if fmt else await b.ytdlp(url))
            if not item:
                await b.ensure()
                await b.navigate(url)
                await b.show_on_tv()
                return web.json_response({"ok": True, "via": "browser"})
        await b.show_on_tv({"play": item})
        return web.json_response({"ok": True, "via": "player", "item": item})

    async def file(req):
        p = b.files.get(req.match_info["token"])
        if not p:
            raise web.HTTPNotFound()
        return web.FileResponse(p, headers={"Content-Type": mimetypes.guess_type(p.name)[0] or "video/mp4"})

    app = web.Application(middlewares=[guard])
    app.add_routes([
        web.get("/hello", hello), web.get("/start", start), web.get("/poll", poll), web.get(r"/frame/{n}.jpg", frame),
        web.get("/input", input_), web.get("/state", state), web.post("/open", open_),
        web.post("/type", type_), web.post("/cast", cast), web.get("/file/{token}/{name}", file),
    ])
    return app


async def watchdog(b):
    tick = 0
    while True:
        await asyncio.sleep(1.5)
        tick += 1
        if b.running and not b.paused and b.active:
            b.mark_dirty()              # cheap heartbeat; unchanged frames aren't sent
            asyncio.create_task(b.refresh_info(b.active))
        if tick % 7:
            continue
        idle = time.monotonic() - b.last_activity
        if b.running and idle > b.cfg["idle_close_minutes"] * 60:
            await b.stop()
        elif b.running and idle > 45:
            await b.pause()


async def main():
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(levelname)s %(message)s")
    cfg = load_config()
    DATA.mkdir(parents=True, exist_ok=True)
    b = Browser(cfg)
    b.http = aiohttp.ClientSession()
    runner = web.AppRunner(make_app(b), access_log=None)
    await runner.setup()
    await web.TCPSite(runner, "0.0.0.0", cfg["port"]).start()
    loop = asyncio.get_running_loop()
    await loop.create_datagram_endpoint(lambda: Discovery(cfg["port"]),
                                        local_addr=("0.0.0.0", cfg["discovery_port"]),
                                        reuse_port=True, allow_broadcast=True)
    dog = asyncio.create_task(watchdog(b))
    log.info("listening on :%d (discovery :%d)", cfg["port"], cfg["discovery_port"])
    done = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, done.set)
    await done.wait()
    dog.cancel()
    await b.stop()
    await b.http.close()
    await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
