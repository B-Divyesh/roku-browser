#!/usr/bin/env python3
"""Renders web pages in a hidden Brave and serves them to the Roku "Browser" channel.

A Roku can't run a browser engine, so the browsing happens here: the channel shows
JPEG frames of the page, draws its own cursor, and sends clicks, scrolls and typing
back. Videos found on a page are handed to the Roku's native player (or the YouTube
app), so they play smoothly with sound.
"""
import asyncio
import base64
import contextlib
import ctypes
import hashlib
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
from urllib.parse import parse_qs, quote, urljoin, urlparse

import aiohttp
import yarl
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

# Runs in every page and frame: reports a video or audio element starting to play, so its
# stream can go to the TV's own player. The page itself only reaches the TV as pictures,
# a few a second and silent, which is fine for reading and hopeless for watching.
MEDIA_BINDING = "__rokuBrowserMedia"
MEDIA_JS = r"""(() => {
  if (window.__rokuBrowserWatching) return;
  window.__rokuBrowserWatching = true;
  const report = v => {
    if (typeof __rokuBrowserMedia !== 'function') return;
    window.__rokuBrowserPlaying = v;
    const r = v.getBoundingClientRect();
    __rokuBrowserMedia(JSON.stringify({
      src: v.currentSrc || v.src || '', time: v.currentTime,
      duration: isFinite(v.duration) ? v.duration : -1, muted: v.muted || v.volume === 0,
      video: v.tagName === 'VIDEO', area: (r.width * r.height) / (innerWidth * innerHeight || 1)}));
  };
  document.addEventListener('playing', e => {
    if (e.target instanceof HTMLMediaElement) report(e.target);
  }, true);
  // Players built as web components keep their <video> in a shadow root, whose media
  // events never reach the document; they all start it with play(), though.
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () {
    if (!this.__rokuBrowserHooked) {
      this.__rokuBrowserHooked = true;
      if (this.getRootNode() !== document) this.addEventListener('playing', () => report(this));
    }
    return play.apply(this, arguments);
  };
})()"""

# Lite mode's pages, compiled from the rendered page by the laptop's browser.
LITE_COMPILE_JS = (Path(__file__).parent / "lite_compile.js").read_text()

# Describes the focused field after a click, so the channel can pop up its keyboard.
FOCUSED_FIELD_JS = r"""(() => {
  let e = document.activeElement;
  while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;
  if (!e) return null;
  // Focus inside a frame from another site: the server asks that frame instead.
  if (e.tagName === 'IFRAME') return {frame: true};
  if (window !== top && !document.hasFocus()) return null;
  const type = (e.type || '').toLowerCase();
  const nonText = ['button','submit','checkbox','radio','range','color','file','image','reset','hidden'];
  const editable = e.isContentEditable || e.tagName === 'TEXTAREA' ||
                   (e.tagName === 'INPUT' && !nonText.includes(type));
  if (!editable || e.disabled || e.readOnly) return null;
  const label = e.getAttribute('aria-label') || e.placeholder || e.name || '';
  // Google, Bing and Yandex search boxes are one-row textareas where Enter searches.
  const search = e.getAttribute('role') === 'combobox' || !!e.closest('[role=search]') ||
                 ['search', 'go', 'send'].includes(e.enterKeyHint);
  return {kind: e.isContentEditable ? 'text' : (type || 'text'),
          value: e.isContentEditable ? e.innerText : (e.value || ''),
          label: label.slice(0, 80),
          multiline: (e.tagName === 'TEXTAREA' || e.isContentEditable) && !search};
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
.icon img { width: 34px; height: 34px; }
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


def shrink_image(data, width):
    """A page image at the width Lite mode shows it, as JPEG (or PNG where it's see-through):
    quick for a Roku to decode, whatever the site sent (WebP, AVIF, huge photos)."""
    with Image.open(io.BytesIO(data)) as im:
        im.seek(0)
        im = im.convert("RGBA" if im.mode in ("RGBA", "LA", "P") else "RGB")
        if im.width > width:
            im.thumbnail((width, width * 4))
        out = io.BytesIO()
        if im.mode == "RGBA" and im.getextrema()[3][0] < 255:
            im.save(out, "PNG")
            return out.getvalue(), "image/png"
        im.convert("RGB").save(out, "JPEG", quality=82)
        return out.getvalue(), "image/jpeg"


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


def dailymotion_id(url):
    u = urlparse(url)
    host = (u.hostname or "").removeprefix("www.")
    if host == "dai.ly":
        return u.path.strip("/").split("/")[0] or None
    if host.endswith("dailymotion.com"):
        m = re.match(r"^/(?:embed/)?video/([a-z0-9]+)", u.path)
        return m.group(1) if m else parse_qs(u.query).get("video", [None])[0]
    return None


def hls_choice(text, base):
    """From an HLS master playlist: the best picture up to 1080p (H.264 if there's a
    choice) and its stereo AAC soundtrack when that's a separate playlist. Fed the whole
    master, ffmpeg reads every variant and falls far behind real time."""
    def attrs(line):
        return {k: v.strip('"') for k, v in re.findall(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)', line.split(":", 1)[1])}
    lines = [ln.strip() for ln in text.splitlines()]
    variants, audio = [], {}
    for i, line in enumerate(lines):
        if line.startswith("#EXT-X-STREAM-INF:"):
            uri = next((ln for ln in lines[i + 1:] if ln and not ln.startswith("#")), None)
            if uri:
                variants.append((attrs(line), urljoin(base, uri)))
        elif line.startswith("#EXT-X-MEDIA:"):
            a = attrs(line)
            if a.get("TYPE") == "AUDIO" and a.get("URI"):
                audio.setdefault(a.get("GROUP-ID"), []).append(a)
    if not variants:
        return base, None

    def score(v):
        a = v[0]
        height = int((a.get("RESOLUTION", "0x0").split("x") + ["0"])[1] or 0)
        codecs = a.get("CODECS", "")
        return (height <= 1080, "mp4a" in codecs or "AUDIO" not in a, "avc1" in codecs,
                height if height <= 1080 else -height, int(a.get("BANDWIDTH", 0)))
    best, uri = max(variants, key=score)
    group = audio.get(best.get("AUDIO"))
    if not group:
        return uri, None
    track = max(group, key=lambda a: (a.get("DEFAULT") == "YES", a.get("LANGUAGE", "").startswith("en")))
    return uri, urljoin(base, track["URI"])


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
        self.frames = {}                # session of an embedded frame -> its page's target id
        self.private_contexts = set()   # browser contexts whose tabs never reach the TV
        self.listeners = {}             # session -> callback(method, params), for those tabs
        self.request_headers = {}       # (session, request id) -> headers that matter for replaying it
        self.last_click = 0.0           # videos only go to the TV's player when the user started them
        self.handoff = None             # the page video now playing in the TV's player
        self.playing = None             # (target, session, details) of the media last started
        self.no_handoff = set()         # streams the TV's player couldn't play
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
        self.shot_lock = asyncio.Lock()  # mouse events wait while a screenshot is taken
        self.last_capture = 0.0
        self.paused = False
        self.stopping = False
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
        self.stopping = True
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
        self.stopping = False

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
        if session in self.listeners:
            self.listeners[session](method, p)
            return
        if method == "Target.targetCreated":
            t = p["targetInfo"]
            if t.get("browserContextId") in self.private_contexts:
                return
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
        if method == "Target.attachedToTarget":
            owner = self._target_for(session) or self.frames.get(session)
            if owner and p["targetInfo"]["type"] == "iframe":
                self.frames[p["sessionId"]] = owner
                asyncio.create_task(self._watch(p["sessionId"]))
            return
        if method == "Target.detachedFromTarget":
            self.frames.pop(p.get("sessionId"), None)
            return
        tid = self._target_for(session) if session else None
        if tid is None:
            # An embedded frame: only its streams and its playing media matter.
            tid = self.frames.get(session)
            if tid is None or method not in ("Network.requestWillBeSent", "Network.responseReceived",
                                             "Runtime.bindingCalled"):
                return
        if method == "Network.requestWillBeSent":
            h = {k.lower(): v for k, v in p["request"].get("headers", {}).items()}
            keep = {k: h[k] for k in ("referer", "origin", "user-agent") if k in h}
            if keep:
                self.request_headers[(session, p["requestId"])] = keep
                while len(self.request_headers) > 500:
                    self.request_headers.pop(next(iter(self.request_headers)))
            return
        if method == "Runtime.bindingCalled":
            if p.get("name") == MEDIA_BINDING and tid == self.active:
                try:
                    asyncio.create_task(self._media_playing(tid, session, json.loads(p.get("payload", "{}"))))
                except ValueError:
                    pass
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
            self._sniff(tid, session, p)
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
            ("Emulation.setDeviceMetricsOverride", self.metrics()),
            ("Emulation.setScrollbarsHidden", {"hidden": True}),
            ("Emulation.setFocusEmulationEnabled", {"enabled": True}),
        ):
            try:
                await self.call(method, params, sid)
            except CDPError as e:
                log.debug("%s: %s", method, e)
        await self._watch(sid)
        await self._activate(tid)

    async def _watch(self, sid):
        """For a page and every frame embedded in it: our user agent, network events (to
        find video streams) and the play reporter. Frames from other sites are separate
        targets, and video players very often are one."""
        # A frame is caught before its document exists; Chrome applies scripts and
        # bindings to documents still to come only with these domains switched on.
        early = (("Page.enable", {}), ("Runtime.enable", {})) if sid in self.frames else ()
        try:
            for method, params in (
                *early,
                ("Network.enable", {}),
                ("Emulation.setUserAgentOverride", {
                    "userAgent": self.ua, "acceptLanguage": "en-GB,en", "platform": "Linux",
                    "userAgentMetadata": {
                        "brands": [{"brand": "Chromium", "version": self.major},
                                   {"brand": "Brave", "version": self.major},
                                   {"brand": "Not_A Brand", "version": "24"}],
                        "fullVersion": self.major, "platform": "Linux", "platformVersion": "",
                        "architecture": "x86", "model": "", "mobile": False}}),
                ("Runtime.addBinding", {"name": MEDIA_BINDING}),
                ("Page.addScriptToEvaluateOnNewDocument", {"source": MEDIA_JS}),
                ("Runtime.evaluate", {"expression": MEDIA_JS}),
                ("Target.setAutoAttach", {"autoAttach": True, "waitForDebuggerOnStart": False, "flatten": True,
                                          "filter": [{"type": "iframe"}]}),
            ):
                try:
                    await self.call(method, params, sid)
                except (CDPError, asyncio.TimeoutError) as e:
                    log.debug("%s: %s", method, e)
        finally:
            if sid in self.frames:
                # Harmless if the frame wasn't waiting; never leave one paused.
                try:
                    await self.call("Runtime.runIfWaitingForDebugger", {}, sid)
                except (CDPError, asyncio.TimeoutError):
                    pass

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
        if tid not in self.sessions:
            return                      # closed meanwhile
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
            elif self.running and not self.stopping:
                try:
                    await self.call("Target.createTarget", {"url": self.home_url()})
                except CDPError as e:
                    log.debug("reopening a tab: %s", e)

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
                    async with self.shot_lock:
                        r = await self.page("Page.captureScreenshot", {"format": "png", "optimizeForSpeed": True},
                                            timeout=5)
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

    @contextlib.asynccontextmanager
    async def pointer(self):
        """Mouse events go between screenshots. To take one, Chromium briefly rescales
        the emulated view, and pointer events sent meanwhile land at 1/zoom of their
        position. A screenshot cut short (by a navigation, say) can leave that scale
        behind; sending the metrics again clears it, and is a no-op otherwise."""
        try:
            await asyncio.wait_for(self.shot_lock.acquire(), 2)
            held = True
        except asyncio.TimeoutError:
            held = False
        try:
            await self.page("Emulation.setDeviceMetricsOverride", self.metrics())
            yield
        finally:
            if held:
                self.shot_lock.release()

    async def mouse(self, kind, x, y, **extra):
        await self.page("Input.dispatchMouseEvent", {"type": kind, "x": x, "y": y, **extra})

    async def _field_in_frames(self):
        """The text field focused inside one of the page's embedded frames, if any."""
        for sid, tid in list(self.frames.items()):
            if tid != self.active:
                continue
            try:
                r = await self.call("Runtime.evaluate", {"expression": FOCUSED_FIELD_JS, "returnByValue": True},
                                    sid, timeout=2)
            except (CDPError, asyncio.TimeoutError):
                continue
            field = r.get("result", {}).get("value")
            if field and not field.get("frame"):
                return field
        return None

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
            async with self.pointer():
                await self.mouse("mouseMoved", self.css(q, "x"), self.css(q, "y"))
        elif t == "click":
            self.last_click = time.monotonic()
            x, y = self.css(q, "x"), self.css(q, "y")
            async with self.pointer():
                await self.mouse("mouseMoved", x, y)
                await self.mouse("mousePressed", x, y, button="left", buttons=1, clickCount=1)
                await self.mouse("mouseReleased", x, y, button="left", buttons=0, clickCount=1)
            await asyncio.sleep(0.25)
            r = await self.page("Runtime.evaluate", {"expression": FOCUSED_FIELD_JS, "returnByValue": True})
            field = r.get("result", {}).get("value")
            if field and field.get("frame"):
                field = await self._field_in_frames()
            return {"edit": field} if field else {}
        elif t == "scroll":
            async with self.pointer():
                await self.mouse("mouseWheel", self.css(q, "x"), self.css(q, "y"),
                                 deltaX=self.css(q, "dx"), deltaY=self.css(q, "dy"))
            self.mark_dirty()
        elif t == "page":
            async with self.pointer():
                await self.mouse("mouseWheel", W / self.zoom / 2, H / self.zoom / 2, deltaX=0,
                                 deltaY=int(q.get("dir", 1)) * H / self.zoom * 0.85)
            self.mark_dirty()
        elif t == "text":
            await self.type_text(q.get("s", ""), enter=q.get("enter") == "1", replace=q.get("replace", "1") == "1")
        elif t == "key":
            self.last_click = time.monotonic()
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
            return await self.hand_off()
        elif t == "videoend":
            await self.video_ended(float(q.get("pos") or 0), q.get("failed") == "1")
        else:
            raise web.HTTPBadRequest(text=f"unknown input {t}")
        return {}

    # ---- video hand-off --------------------------------------------------

    def _sniff(self, tid, session, p):
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
        if any(m["url"] == url for m in found):
            return
        found.append({"url": url, "format": fmt, "session": session, "request": p["requestId"],
                      "seen": time.monotonic(),
                      "headers": self.request_headers.get((session, p["requestId"]), {})})
        del found[:-40]
        log.info("found %s stream on page: %s", fmt, url[:120])
        if tid == self.active:
            self.bump()

    async def hand_off(self, session=None, info=None):
        """Plays the page's video in the TV's own player, smooth and with sound, and pauses
        it in the page. YouTube opens in its app; anything else this laptop fetches the
        way the page did and repackages for the Roku."""
        tid = self.active
        page_url = self.info.get(tid, {}).get("url", "")
        vid = youtube_id(page_url)
        if vid:
            await self.ecp(f"launch/{YOUTUBE_APP}?contentId={quote(vid)}&mediaType=movie")
            return {"notice": "Opening in YouTube…"}
        dm = dailymotion_id(page_url)
        if dm:
            return await self.dailymotion_item(dm)
        if info is None and self.playing and self.playing[0] == tid:
            _, session, info = self.playing
        stream = await self._page_stream(tid, session, info)
        if stream:
            start = max(0.0, (info or {}).get("time", 0) - 1)
            try:
                item = await self._replay(stream, start)
            except web.HTTPException:
                self.no_handoff.add(stream["url"])
                return {"notice": "The TV's player couldn't open this video"}
            if session:
                try:
                    await self.call("Runtime.evaluate", {
                        "expression": "window.__rokuBrowserPlaying && window.__rokuBrowserPlaying.pause()"}, session)
                except CDPError:
                    pass
            self.handoff = {"url": stream["url"], "session": session, "start": start}
            return {"play": item}
        item = await self.ytdlp(page_url)
        if item:
            return {"play": item}
        return {"notice": "No playable video found on this page"}

    async def _media_playing(self, tid, session, info):
        """A video (or audio) started in the page. If the user started it and it isn't an
        advert, it goes to the TV's player."""
        self.playing = (tid, session, info)
        log.info("page media playing: %s (muted=%s, %.0f%% of its frame, %.0f s long, last click %.0f s ago)",
                 (info.get("src") or "?")[:90], info.get("muted"), 100 * info.get("area", 0),
                 info.get("duration", -1), time.monotonic() - self.last_click)
        if self.handoff and not await self._tv_playing():
            self.handoff = None         # the TV's player was left some other way (Home, say)
        if (self.handoff or self.paused or info.get("muted")
                or time.monotonic() - self.last_click > 120     # not something the user started
                or (info.get("video") and info.get("area", 0) < 0.08)    # a tiny or hidden player
                or 0 < info.get("duration", -1) < 45            # an advert or a preview
                or info.get("src") in self.no_handoff):
            return
        result = await self.hand_off(session, info)
        log.info("handing the page's video to the TV: %s", result.get("play", {}).get("url") or result.get("notice"))
        if "play" not in result:
            self.no_handoff.add(info.get("src") or self.info.get(tid, {}).get("url", ""))
        self.action = {"id": secrets.randbelow(1 << 30), **result}
        self.bump()

    async def video_ended(self, pos, failed):
        """The TV's player stopped: the page's video waits, paused, where the TV got to."""
        h, self.handoff = self.handoff, None
        self.remuxer.stop(clean=True)
        if not h:
            return
        if failed:
            self.no_handoff.add(h["url"])
        if h["session"]:
            js = (f"(v => {{ if (v) {{ v.currentTime = {h['start'] + pos:.2f}; v.pause(); }} }})"
                  "(window.__rokuBrowserPlaying)")
            try:
                await self.call("Runtime.evaluate", {"expression": js}, h["session"])
            except CDPError:
                pass
        self.recapture()

    async def _tv_playing(self):
        try:
            _, xml = await self.ecp("query/media-player", "GET")
        except (aiohttp.ClientError, asyncio.TimeoutError, web.HTTPException):
            return False
        return 'id="dev"' in xml and re.search(r'state="(play|buffer|pause)"', xml) is not None

    async def _page_stream(self, tid, session=None, info=None):
        """The stream behind the playing media: its own address or, for players that feed
        it in pieces (a blob: address), the playlist its frame loaded. Players load their
        master playlist and then its variants; adverts come from frames of their own."""
        src = (info or {}).get("src", "")
        found = self.media.get(tid, [])
        if src.startswith("http"):
            known = next((m for m in found if m["url"] == src), None)
            return known or {"url": src, "format": format_for(src) or "mp4", "session": session, "headers": {}}
        lists = [m for m in found if m["format"] in ("hls", "dash")]
        if session:
            lists = [m for m in lists if m["session"] == session] or lists
        if not lists:
            return None if src else (found[-1] if found else None)
        for m in reversed(lists):
            if m["format"] == "dash" or await self._is_master(m):
                return m
        return lists[-1]

    async def _is_master(self, m):
        if "master" not in m:
            m["master"] = "#EXT-X-STREAM-INF" in await self._body(m)
        return m["master"]

    async def _body(self, m):
        """A playlist's text as the page received it."""
        if "body" not in m:
            m["body"] = ""
            try:
                r = await self.call("Network.getResponseBody", {"requestId": m["request"]}, m["session"])
                m["body"] = base64.b64decode(r["body"]).decode(errors="replace") if r.get("base64Encoded") else r["body"]
            except (CDPError, KeyError, ValueError):
                pass
        return m["body"]

    async def _replay(self, m, start):
        """This laptop fetches the stream as the page did (same referrer, origin, browser
        and cookies) and repackages it as TS segments, whose sound a Roku always plays."""
        h = m.get("headers", {})
        info = self.info.get(self.active, {})
        headers = [f"Referer: {h.get('referer') or info.get('url', '')}"]
        if h.get("origin"):
            headers.append(f"Origin: {h['origin']}")
        try:
            cookies = (await self.page("Network.getCookies", {"urls": [m["url"]]}))["cookies"]
        except CDPError:
            cookies = []
        if cookies:
            headers.append("Cookie: " + "; ".join(f"{c['name']}={c['value']}" for c in cookies))
        url, audio = m["url"], None
        if m["format"] == "hls":
            text = await self._body(m)
            if text:
                url, audio = hls_choice(text, m["url"])
        key = await self.remuxer.start(url, headers=headers, start=start,
                                       user_agent=h.get("user-agent") or self.ua, audio=audio)
        return {"url": f"{self.base_url()}/remux/{key}/index.m3u8", "format": "hls", "headers": [],
                "title": info.get("title", ""), "page": True}

    async def dailymotion_item(self, video_id):
        """A Dailymotion video as a stream the Roku plays with sound (remuxed here)."""
        try:
            async with self.http.get(f"https://www.dailymotion.com/player/metadata/video/{video_id}",
                                     headers={"User-Agent": ROKU_UA},
                                     timeout=aiohttp.ClientTimeout(total=15)) as r:
                meta = await r.json(content_type=None)
        except (aiohttp.ClientError, asyncio.TimeoutError, ValueError):
            return {"notice": "Dailymotion didn't answer. Try again in a moment."}
        if meta.get("error"):
            return {"notice": (meta["error"].get("title") if isinstance(meta["error"], dict) else None)
                    or "This video can't be played here."}
        master = ((meta.get("qualities") or {}).get("auto") or [{}])[0].get("url")
        if not master:
            return {"notice": "No playable stream for this video."}
        variant = await self.best_variant(master)
        if not shutil.which("ffmpeg"):
            return {"play": {"url": variant, "format": "hls", "headers": [], "title": meta.get("title", "")},
                    "notice": "No sound: install ffmpeg on the laptop for Dailymotion with sound."}
        return {"play": {"url": f"{self.base_url()}/remux?u={quote(variant, safe='')}", "format": "hls",
                         "headers": [], "title": meta.get("title", "")}}

    async def best_variant(self, master):
        """The highest quality up to 1080p from an HLS master playlist."""
        try:
            async with self.http.get(master, headers={"User-Agent": ROKU_UA},
                                     timeout=aiohttp.ClientTimeout(total=15)) as r:
                text = await r.text()
                base = str(r.url)
        except (aiohttp.ClientError, asyncio.TimeoutError):
            return master
        best, best_h = master, -1
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        for i, line in enumerate(lines[:-1]):
            if line.startswith("#EXT-X-STREAM-INF"):
                m = re.search(r"RESOLUTION=\d+x(\d+)", line)
                h = int(m.group(1)) if m else 0
                if best_h < h <= 1080:
                    best, best_h = urljoin(base, lines[i + 1].split("#")[0]), h
        return best

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
        # Sent exactly as given: the Roku answers 404 to an input whose parameters have
        # bare ":" and "/", which is what aiohttp would otherwise turn "%3A%2F" back into.
        url = yarl.URL(f"http://{self.roku_ip}:8060/{path}", encoded=True)
        async with self.http.request(method, url, timeout=aiohttp.ClientTimeout(total=5)) as r:
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

    async def mirror_on_tv(self, on):
        """Has the Browser channel play (or stop) the mirror's video; it asks for the stream itself."""
        _, active = await self.ecp("query/active-app", "GET")
        args = f"mirror={int(on)}&server={quote(self.base_url(), safe='')}"
        if 'id="dev"' in active:
            await self.ecp(f"input?{args}")
        elif on:
            await self.ecp(f"launch/dev?{args}")

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


# Dailymotion serves the Roku as itself; its CDN refuses a Roku that claims to be Chrome.
ROKU_UA = "Roku/DVP-15.3"


class Renderer:
    """Lite mode's pages, run through this laptop's browser when it's reachable: the
    JavaScript runs, CSS decides what's visible, and the page comes back already in Lite
    mode's own structure (lite_compile.js). The Roku then only reads JSON, with its
    built-in parser, instead of parsing HTML in BrightScript, and lays it out natively.
    Uses a tab of its own in a private context, so the TV's tabs never see it."""

    def __init__(self, browser):
        self.b = browser
        self.sid = None
        self.ws = None                  # the browser connection that tab belongs to
        self.waiting = {}               # CDP event -> asyncio.Event
        self.lock = asyncio.Lock()      # one page at a time

    async def render(self, url):
        async with self.lock:
            await self.b.ensure()
            await self._tab()
            loaded = self.waiting["Page.domContentEventFired"] = asyncio.Event()
            began = time.monotonic()
            r = await self.b.call("Page.navigate", {"url": url}, self.sid)
            if r.get("errorText"):
                raise web.HTTPBadGateway(text=r["errorText"])
            try:
                await asyncio.wait_for(loaded.wait(), 10)
            except asyncio.TimeoutError:
                pass
            # Pages built with JavaScript fill in after that; give them a few moments.
            while True:
                r = await self.b.call("Runtime.evaluate", {"expression": LITE_COMPILE_JS, "returnByValue": True},
                                      self.sid, timeout=10)
                doc = r.get("result", {}).get("value") or {}
                if doc.get("chars", 0) >= 600 or time.monotonic() - began > 6:
                    break
                await asyncio.sleep(0.5)
            log.info("lite page compiled: %s, %d blocks in %.1f s", url[:90], len(doc.get("blocks", [])),
                     time.monotonic() - began)
            return doc

    async def _tab(self):
        if self.sid and self.ws is self.b.ws and self.b.running:
            return
        ctx = (await self.b.call("Target.createBrowserContext", {"disposeOnDetach": True}))["browserContextId"]
        self.b.private_contexts.add(ctx)
        tid = (await self.b.call("Target.createTarget", {"url": "about:blank", "browserContextId": ctx}))["targetId"]
        self.sid = (await self.b.call("Target.attachToTarget", {"targetId": tid, "flatten": True}))["sessionId"]
        self.ws = self.b.ws
        self.b.listeners[self.sid] = self._event
        for method, params in (
            ("Page.enable", {}),
            ("Emulation.setUserAgentOverride", {"userAgent": self.b.ua, "acceptLanguage": "en-GB,en"}),
            ("Emulation.setDeviceMetricsOverride", {"width": 1280, "height": 900, "deviceScaleFactor": 1,
                                                    "mobile": False}),
        ):
            await self.b.call(method, params, self.sid)

    def _event(self, method, p):
        if method in self.waiting:
            self.waiting.pop(method).set()


class Remuxer:
    """Repackages a stream with ffmpeg (copying, not re-encoding) into HLS with TS segments.

    Dailymotion (and others) mux audio and video into one fragmented-MP4 stream; a Roku
    plays the picture from those but can't find the audio. In TS segments it can.
    One stream at a time; the previous one is stopped and its files removed.
    """

    def __init__(self):
        self.key = None
        self.proc = None
        self.dir = DATA / "remux"

    async def start(self, url, headers=(), start=0.0, user_agent=ROKU_UA, audio=None):
        key = hashlib.sha1(f"{url} {audio} {start:.1f}".encode()).hexdigest()[:12]
        out = self.dir / key
        alive = self.proc is not None and self.proc.returncode is None
        if key != self.key or not (alive or (out / "index.m3u8").exists()):
            if alive:
                self.proc.kill()
            shutil.rmtree(self.dir, ignore_errors=True)
            out.mkdir(parents=True)
            self.key = key
            source = ["-user_agent", user_agent]
            if headers:
                source += ["-headers", "".join(h + "\r\n" for h in headers)]
            if start:
                source += ["-ss", f"{start:.2f}"]
            inputs = [*source, "-i", url]
            if audio:
                inputs += [*source, "-i", audio, "-map", "0:v:0", "-map", "1:a:0"]
            with open(DATA / "remux.log", "ab") as errors:
                self.proc = await asyncio.create_subprocess_exec(
                    "ffmpeg", "-nostdin", "-loglevel", "error", *inputs,
                    # The picture is copied as it is. The sound becomes stereo AAC, which every
                    # Roku plays: many films carry Dolby Digital, which this one refuses.
                    "-sn", "-dn", "-c:v", "copy", "-c:a", "aac", "-ac", "2", "-b:a", "192k",
                    "-f", "hls", "-hls_time", "4",
                    "-hls_list_size", "0", "-hls_playlist_type", "event",
                    "-hls_segment_filename", str(out / "seg%05d.ts"), str(out / "index.m3u8"),
                    stdout=asyncio.subprocess.DEVNULL, stderr=errors,
                    preexec_fn=die_with_parent)
            log.info("remuxing %s from %.0f s", url[:100], start)
        index = out / "index.m3u8"
        for _ in range(150):
            if index.exists() and index.read_text().count("#EXTINF") >= 2:
                return key
            if self.proc.returncode not in (None, 0):
                raise web.HTTPBadGateway(text="couldn't read that stream")
            await asyncio.sleep(0.2)
        raise web.HTTPGatewayTimeout(text="the stream took too long to start")

    def stop(self, clean=False):
        if self.proc is not None and self.proc.returncode is None:
            self.proc.kill()
        if clean:
            # A whole film can be gigabytes; it isn't kept once the TV is done with it.
            shutil.rmtree(self.dir, ignore_errors=True)
            self.key = None


async def command_output(*args, env=None, timeout=10):
    """A quick helper command's output, or "" if it's missing or fails."""
    try:
        proc = await asyncio.create_subprocess_exec(
            *args, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, env=env)
    except OSError:
        return ""
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        return ""
    return out.decode(errors="replace").strip() if proc.returncode == 0 else ""


async def session_env():
    """The desktop's variables. The service can start before the desktop shares them."""
    env = dict(os.environ)
    if not env.get("WAYLAND_DISPLAY"):
        for line in (await command_output("systemctl", "--user", "show-environment")).splitlines():
            key, _, value = line.partition("=")
            if key in ("WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "SWAYSOCK"):
                env.setdefault(key, value)
    if not env.get("WAYLAND_DISPLAY"):
        runtime = Path(env.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}")
        sockets = sorted(p.name for p in runtime.glob("wayland-*") if not p.name.endswith(".lock"))
        if sockets:
            env["WAYLAND_DISPLAY"] = sockets[0]
    return env


def notify(title, body=""):
    """A desktop notification, so it's always clear when the screen is on the TV."""
    if shutil.which("notify-send"):
        asyncio.create_task(command_output("notify-send", "-a", "Roku", "-i", "video-display", title, body))


MIRROR_SINK = "roku_mirror"
RENDER_NODE = "/dev/dri/renderD128"


def find_tool(name):
    """A program on PATH or in ~/.local/bin, which a service's PATH may lack."""
    return shutil.which(name) or shutil.which(name, path=str(Path.home() / ".local/bin"))


class MirrorError(Exception):
    pass


class PairingNeeded(MirrorError):
    """The TV is showing an AirPlay code; it has to be typed in on the laptop once."""


class Mirror:
    """Shows this laptop's screen on the TV, with its sound.

    The Roku's own mirroring (Miracast) can't be reached from Linux: the Roku runs its own
    Wi-Fi Direct group, and NetworkManager only negotiates new ones. Two ways round it:

    - AirPlay, on Rokus that have it: doubletake, an AirPlay sender, captures the screen
      through the desktop's screen-sharing portal. A fraction of a second behind.
    - Otherwise the Roku's video player: wf-recorder encodes on the GPU and ffmpeg cuts
      half-second HLS segments. The player keeps a few seconds in hand, so ~6 s behind.

    Either way, sound moves to a virtual "Roku TV" output meanwhile, so it plays on the TV
    rather than the laptop, and comes back when mirroring ends: when asked, when the TV
    ends it, or when the TV stops watching.
    """

    def __init__(self, browser):
        self.b = browser
        self.dir = DATA / "mirror"
        self.socket = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}") / "roku-browser-airplay.sock"
        self.kind = None                # "airplay" or "video" while mirroring
        self.state = ""                 # doubletake's: connecting, pin_required, streaming, idle
        self.asked_code = 0.0           # when the TV started showing a pairing code
        self.shown = False              # the TV got as far as showing the screen
        self.away = 0                   # checks in a row that found the TV off its AirPlay screen
        self.was_on_tv = ""             # the app the TV showed before AirPlay took over
        self.airplay = None             # the doubletake daemon
        self.token = None               # secret part of the video stream's address
        self.rec = self.seg = None      # wf-recorder | ffmpeg for the video player
        self.module = None              # pactl module of the virtual sound output
        self.prev_sink = ""
        self.last_fetch = 0.0
        self.lock = asyncio.Lock()      # the TV and the laptop can both ask at once

    @property
    def running(self):
        if self.kind == "airplay":
            return self.airplay is not None and self.airplay.returncode is None and \
                self.state in ("connecting", "pin_required", "streaming")
        return self.seg is not None and self.seg.returncode is None

    def path(self):
        return f"/mirror/{self.token}/index.m3u8"

    def owns(self, token):
        return self.token is not None and secrets.compare_digest(token, self.token)

    async def start(self):
        """Starts mirroring and says how: "airplay", or "video" for the Browser channel to play."""
        async with self.lock:
            if self.running:
                return self.kind
            await self.stop()
            if await self._airplay_available():
                await self._start_airplay()
            else:
                await self._start_video()
            return self.kind

    async def pair(self, code):
        """The code shown on the TV the first time this laptop mirrors to it over AirPlay."""
        async with self.lock:
            if self.kind != "airplay" or self.state != "pin_required":
                raise MirrorError("The TV isn't waiting for a code. Run “roku mirror” again.")
            await self._ctl("pin", code)
            await self._until_streaming()

    async def stop(self):
        if self.kind is None and self.module is None:
            return
        shown, ended_here = self.shown, self.running
        if self.airplay is not None:
            if self.airplay.returncode is None:
                await self._ctl("disconnect", timeout=5)
            await self._end(self.airplay)
            self.airplay = None
            if ended_here:
                await self._tv_back()
        await self._kill()
        await self._sound_back()
        shutil.rmtree(self.dir, ignore_errors=True)
        self.kind, self.state, self.token, self.shown, self.away = None, "", None, False, 0
        if shown:
            log.info("mirroring stopped")
            notify("Stopped showing this screen on the TV")

    async def check(self):
        """Called every few seconds while mirroring: ends it once the TV has."""
        if self.kind is None or self.lock.locked():
            return
        if self.kind == "airplay":
            if self.airplay is not None and self.airplay.returncode is None:
                self.state = (await self._ctl("status", timeout=5)).get("state", "")
            if self.state == "streaming":
                # Back or Home leaves AirPlay running unseen, and doubletake rebuilds its
                # capture when the Roku drops it; that churn preceded a Hyprland freeze.
                try:
                    _, active = await self.b.ecp("query/active-app", "GET")
                    self.away = 0 if "AirPlay" in active else self.away + 1
                except (aiohttp.ClientError, asyncio.TimeoutError):
                    pass
                if self.away >= 2:
                    await self.stop()
                    return
            unanswered = self.state == "pin_required" and time.monotonic() - self.asked_code > 180
            if not self.running or unanswered:
                await self.stop()       # Home on the remote, say, ended the AirPlay session
        elif not self.running or time.monotonic() - self.last_fetch > 30:
            await self.stop()           # the capture died, or the TV stopped watching

    # ---- AirPlay ---------------------------------------------------------

    async def _airplay_available(self):
        if not (find_tool("doubletake") and find_tool("doubletake-ctl") and self.b.roku_ip):
            return False
        if not await command_output("gst-inspect-1.0", "vah264enc"):
            # Without GStreamer's GPU encoder the capture falls back to shared-memory
            # buffers, and that is how Hyprland 0.57.1 froze, twice, on 2026-11-08.
            raise MirrorError("AirPlay mirroring needs GStreamer's GPU encoder first: "
                              "sudo pacman -S gst-plugin-va")
        try:
            async with self.b.http.get(f"http://{self.b.roku_ip}:7000/info",
                                       timeout=aiohttp.ClientTimeout(total=2)) as r:
                return r.status == 200
        except (aiohttp.ClientError, asyncio.TimeoutError):
            return False

    async def _start_airplay(self):
        self.kind, self.state = "airplay", "connecting"
        try:
            _, active = await self.b.ecp("query/active-app", "GET")
            found = re.search(r'<app id="([^"]+)"', active)
            self.was_on_tv = found.group(1) if found else ""
        except (aiohttp.ClientError, asyncio.TimeoutError):
            self.was_on_tv = ""
        if self.airplay is None or self.airplay.returncode is not None:
            self.socket.unlink(missing_ok=True)
            self.dir.mkdir(parents=True, exist_ok=True)
            with open(self.dir / "airplay.log", "wb") as errors:
                self.airplay = await asyncio.create_subprocess_exec(
                    find_tool("doubletake"), "-daemonize", "-socket", str(self.socket), "-hwaccel", "vaapi",
                    stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.DEVNULL, stderr=errors,
                    env=await session_env(), preexec_fn=die_with_parent)
            for _ in range(50):
                if self.socket.exists():
                    break
                await asyncio.sleep(0.1)
        await self._sound_to_tv()       # first: doubletake records whatever the default output is
        await self._ctl("connect", self.b.roku_ip)
        await self._until_streaming()

    async def _until_streaming(self):
        # The first time, the desktop asks which screen to share (doubletake allows two
        # minutes) and the TV shows a pairing code. Later runs need neither.
        for _ in range(260):
            status = await self._ctl("status", timeout=5)
            self.state = status.get("state", "")
            if self.state == "streaming":
                self.shown = True
                log.info("mirroring to the TV over AirPlay")
                notify("Showing this screen on the TV",
                       "Sound plays from the TV. To stop, press Home on the Roku remote or run “roku mirror stop”.")
                return
            if self.state == "pin_required":
                self.asked_code = time.monotonic()
                raise PairingNeeded("The TV is showing a code. Type it in on the laptop: roku mirror")
            if self.state == "idle" or self.airplay.returncode is not None:
                reason = status.get("error") or "doubletake stopped"
                await self.stop()
                raise MirrorError(f"Couldn't start AirPlay mirroring: {reason}")
            await asyncio.sleep(0.5)
        await self.stop()
        raise MirrorError("AirPlay mirroring took too long to start.")

    async def _tv_back(self):
        """Ended from the laptop, the Roku would sit on its AirPlay screen; go back to
        what it showed before."""
        try:
            _, active = await self.b.ecp("query/active-app", "GET")
            if "AirPlay" not in active:
                return
            if self.was_on_tv == "dev":
                await self.b.ecp(f"launch/dev?server={quote(self.b.base_url(), safe='')}")
            else:
                await self.b.ecp("keypress/Home")
        except (aiohttp.ClientError, asyncio.TimeoutError):
            pass

    async def _ctl(self, *args, timeout=30):
        out = await command_output(find_tool("doubletake-ctl") or "doubletake-ctl", "-socket", str(self.socket),
                                   *args, timeout=timeout)
        try:
            return json.loads(out)
        except ValueError:
            return {}

    # ---- the Roku's video player -----------------------------------------

    async def _start_video(self):
        if not shutil.which("wf-recorder"):
            raise MirrorError("Showing the laptop screen needs doubletake (for AirPlay) or wf-recorder.")
        env = await session_env()
        output = await self._output(env)
        self.kind = "video"
        self.token = secrets.token_urlsafe(16)
        self.last_fetch = time.monotonic()
        out = self.dir / self.token
        out.mkdir(parents=True)
        monitor = await self._sound_to_tv()
        # GPU buffers only: the CPU route captures through shared memory (see _airplay_available).
        for gpu in (True,) if os.path.exists(RENDER_NODE) else ():
            await self._spawn(out, output, monitor, gpu, env)
            if await self._first_segments(out):
                break
            await self._kill()
        else:
            reason = self._last_error() or "this laptop has no GPU video encoder"
            await self.stop()
            raise MirrorError(f"Couldn't capture the laptop screen: {reason}")
        self.last_fetch = time.monotonic()
        self.shown = True
        log.info("mirroring %s to the TV's video player, encoding on the %s", output or "the screen",
                 "GPU" if gpu else "CPU")
        notify("Showing this screen on the TV",
               "Sound plays from the TV. To stop, press Back on the Roku remote or run “roku mirror stop”.")

    async def _output(self, env):
        """The screen to show: Hyprland's focused monitor, else the first wf-recorder lists."""
        try:
            monitors = json.loads(await command_output("hyprctl", "monitors", "-j", env=env))
            return next(m["name"] for m in monitors if m.get("focused"))
        except (ValueError, StopIteration, KeyError, TypeError):
            pass
        found = re.search(r"Name: (\S+)", await command_output("wf-recorder", "-L", env=env))
        return found.group(1) if found else None

    async def _spawn(self, out, output, monitor, gpu, env):
        fit = "w=1920:h=1080:force_original_aspect_ratio=decrease:force_divisible_by=2"
        if gpu:
            video = ["-c", "h264_vaapi", "-d", RENDER_NODE, "-F", f"scale_vaapi={fit}:format=nv12:out_range=tv",
                     "-p", "rc_mode=VBR", "-p", "b=6000000", "-p", "maxrate=9000000"]
        else:
            video = ["-c", "libx264", "-x", "yuv420p", "-F", f"scale={fit}:out_range=tv",
                     "-p", "preset=veryfast", "-p", "tune=zerolatency", "-p", "b=5000000"]
        # Constant 30 fps with a keyframe every half second, so every segment can start playback.
        rec = ["wf-recorder", *(["-o", output] if output else []), *video, "-r", "30", "-b", "0", "-p", "g=15"]
        if monitor:
            rec += [f"--audio={monitor}", "-C", "aac"]
        rec += ["-m", "mpegts", "-f", "pipe:1"]
        read, write = os.pipe()
        with open(self.dir / "capture.log", "ab") as errors:
            self.seg = await asyncio.create_subprocess_exec(
                "ffmpeg", "-nostdin", "-loglevel", "error",
                # Start writing at once instead of studying the first five seconds.
                "-fflags", "nobuffer", "-analyzeduration", "500000", "-probesize", "500000",
                "-i", "pipe:0", "-c", "copy",
                # The encoder labels its limited-range picture as full range; TVs would wash it out.
                "-bsf:v", "h264_metadata=video_full_range_flag=0",
                "-f", "hls", "-hls_time", "0.5", "-hls_list_size", "6",
                "-hls_flags", "delete_segments+independent_segments+omit_endlist",
                "-hls_segment_filename", str(out / "seg%05d.ts"), str(out / "index.m3u8"),
                stdin=read, stdout=asyncio.subprocess.DEVNULL, stderr=errors, preexec_fn=die_with_parent)
            self.rec = await asyncio.create_subprocess_exec(
                *rec, stdin=asyncio.subprocess.DEVNULL, stdout=write, stderr=errors, env=env,
                preexec_fn=die_with_parent)
        os.close(read)
        os.close(write)

    async def _first_segments(self, out):
        index = out / "index.m3u8"
        for _ in range(60):
            if index.exists() and index.read_text().count("#EXTINF") >= 2:
                return True
            if self.rec.returncode is not None or self.seg.returncode is not None:
                return False
            await asyncio.sleep(0.2)
        return False

    def _last_error(self):
        try:
            lines = (self.dir / "capture.log").read_text(errors="replace").splitlines()
        except OSError:
            return ""
        return next((ln.strip() for ln in reversed(lines) if "rror" in ln), "")[:160]

    async def _kill(self):
        await asyncio.gather(*(self._end(p) for p in (self.rec, self.seg) if p is not None))
        self.rec = self.seg = None

    @staticmethod
    async def _end(proc):
        if proc.returncode is None:
            proc.terminate()
            try:
                await asyncio.wait_for(proc.wait(), 3)
            except asyncio.TimeoutError:
                proc.kill()

    async def _sound_to_tv(self):
        """A virtual output for the TV, made the default so apps' sound moves to it."""
        if not shutil.which("pactl"):
            return None
        await self.drop_leftovers()
        self.prev_sink = await command_output("pactl", "get-default-sink")
        module = await command_output("pactl", "load-module", "module-null-sink", f"sink_name={MIRROR_SINK}",
                                      """sink_properties='device.description="Roku TV"'""")
        if not module.isdigit():
            return None
        self.module = module
        await command_output("pactl", "set-default-sink", MIRROR_SINK)
        return MIRROR_SINK + ".monitor"

    async def _sound_back(self):
        if self.module is None:
            return
        if self.prev_sink and self.prev_sink != MIRROR_SINK:
            await command_output("pactl", "set-default-sink", self.prev_sink)
        await command_output("pactl", "unload-module", self.module)
        self.module = None

    @staticmethod
    async def drop_leftovers():
        """Removes a virtual output left behind by a crash, so sound comes back to the laptop."""
        for line in (await command_output("pactl", "list", "short", "modules")).splitlines():
            if "module-null-sink" in line and f"sink_name={MIRROR_SINK}" in line:
                await command_output("pactl", "unload-module", line.split()[0])


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
            f'src="https://www.google.com/s2/favicons?domain={urlparse(url).hostname}&sz=128"></span>{name}</a>'
            for name, url in FAVOURITES)
        page = START_HTML.replace("%TILES%", tiles).replace("%SEARCH%", json.dumps(b.cfg["search"]))
        return web.Response(text=page, content_type="text/html")

    async def frame(req):
        log.debug("frame %s served", req.match_info["n"])
        return web.Response(body=b.jpeg, content_type="image/jpeg", headers={"Cache-Control": "no-store"})

    async def input_(req):
        if req.query.get("t") == "mirror":
            return web.json_response(await mirror_for_tv(req))
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
            dm = dailymotion_id(url)
            if dm:
                r = await b.dailymotion_item(dm)
                if "notice" in r:
                    return web.json_response({"ok": False, "error": r["notice"]})
                await b.show_on_tv({"play": r["play"]})
                return web.json_response({"ok": True, "via": "player", "item": r["play"]})
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

    async def dailymotion(req):
        """For Lite mode: one link that ends at a Dailymotion stream with sound."""
        r = await b.dailymotion_item(req.match_info["id"])
        if "play" not in r:
            raise web.HTTPBadGateway(text=r.get("notice", ""))
        raise web.HTTPFound(r["play"]["url"])

    async def remux(req):
        url = req.query.get("u", "")
        if not url.startswith("http"):
            raise web.HTTPBadRequest()
        key = await remuxer.start(url)
        raise web.HTTPFound(f"/remux/{key}/index.m3u8")

    async def remux_file(req):
        key, name = req.match_info["key"], req.match_info["name"]
        path = remuxer.dir / key / name
        if key != remuxer.key or "/" in name or not path.is_file():
            raise web.HTTPNotFound()
        kind = "application/vnd.apple.mpegurl" if name.endswith(".m3u8") else "video/mp2t"
        return web.FileResponse(path, headers={"Content-Type": kind, "Cache-Control": "no-store"})

    async def file(req):
        p = b.files.get(req.match_info["token"])
        if not p:
            raise web.HTTPNotFound()
        return web.FileResponse(p, headers={"Content-Type": mimetypes.guess_type(p.name)[0] or "video/mp4"})

    async def mirror_for_tv(req):
        """The channel asking to show this laptop's screen (on=1) or to stop (on=0)."""
        if req.query.get("on", "1") != "1":
            await mirror.stop()
            return {}
        # Only this laptop's own Roku may watch its screen, not anything that answers like one.
        if b.roku_ip and req.remote not in (b.roku_ip, "127.0.0.1", "::1"):
            raise web.HTTPForbidden(text="only this laptop's Roku can show its screen")
        try:
            kind = await mirror.start()
        except PairingNeeded:
            return {"notice": "The first time, pair on the laptop: run “roku mirror” and type in the code on the TV"}
        except MirrorError as e:
            return {"notice": str(e)}
        if kind == "airplay":
            return {"airplay": True}    # the Roku's AirPlay screen takes over from the channel
        return {"play": {"url": b.base_url() + mirror.path(), "format": "hls", "title": "Laptop screen",
                         "headers": [], "live": True, "mirror": True}}

    async def mirror_(req):
        """`roku mirror [stop]` on this laptop."""
        if req.remote not in ("127.0.0.1", "::1"):
            raise web.HTTPForbidden()
        body = await req.json()
        on, kind = body.get("on", True), mirror.kind
        try:
            if body.get("code"):
                await mirror.pair(body["code"])
                kind = mirror.kind
            elif on:
                kind = await mirror.start()
            else:
                await mirror.stop()
        except PairingNeeded as e:
            return web.json_response({"ok": False, "pair": True, "error": str(e)})
        except MirrorError as e:
            return web.json_response({"ok": False, "error": str(e)})
        if kind != "video":
            return web.json_response({"ok": True, "via": kind or ""})
        try:
            await b.mirror_on_tv(on)
        except (aiohttp.ClientError, asyncio.TimeoutError):
            await mirror.stop()
            return web.json_response({"ok": False, "error": "Couldn't reach the Roku. Is it on?"})
        return web.json_response({"ok": True, "via": "video"})

    async def mirror_file(req):
        token, name = req.match_info["token"], req.match_info["name"]
        path = mirror.dir / token / name
        if not mirror.owns(token) or "/" in name or not path.is_file():
            raise web.HTTPNotFound()
        mirror.last_fetch = time.monotonic()
        if name.endswith(".m3u8"):
            # Players stay about three segments behind the newest, so half-second segments
            # halve the delay. ffmpeg rounds their target duration down to 0, which a Roku
            # refuses; 1 is what it accepts.
            text = path.read_text().replace("#EXT-X-TARGETDURATION:0\n", "#EXT-X-TARGETDURATION:1\n")
            return web.Response(text=text, content_type="application/vnd.apple.mpegurl",
                                headers={"Cache-Control": "no-store"})
        return web.FileResponse(path, headers={"Content-Type": "video/mp2t", "Cache-Control": "no-store"})

    async def lite(req):
        """A page compiled for Lite mode (see Renderer)."""
        url = req.query.get("u", "")
        if not url.startswith(("http://", "https://")):
            raise web.HTTPBadRequest()
        try:
            doc = await renderer.render(url)
        except (CDPError, asyncio.TimeoutError) as e:
            raise web.HTTPBadGateway(text=str(e))
        shrink = lambda u, w: f"{b.base_url()}/img?w={w}&u={quote(u, safe='')}" if u else u
        for blk in doc.get("blocks", []):
            if blk.get("k") == "img":
                blk["src"] = shrink(blk["src"], 1040)
            elif blk.get("k") == "video":
                blk["thumb"] = shrink(blk.get("thumb", ""), 640)
        doc["image"] = shrink(doc.get("image", ""), 640)
        return web.json_response(doc)

    async def img(req):
        url = req.query.get("u", "")
        width = max(64, min(int(req.query.get("w") or 1040), 1920))
        if not url.startswith(("http://", "https://")):
            raise web.HTTPBadRequest()
        hit = images.get((url, width))
        if hit is None:
            try:
                async with b.http.get(url, headers={"User-Agent": b.ua or "Mozilla/5.0", "Accept": "image/*"},
                                      timeout=aiohttp.ClientTimeout(total=15)) as r:
                    if r.status != 200:
                        raise web.HTTPNotFound()
                    data = await r.content.read(15 << 20)
                hit = await asyncio.to_thread(shrink_image, data, width)
            except (aiohttp.ClientError, asyncio.TimeoutError, OSError, ValueError):
                raise web.HTTPNotFound()
            images[(url, width)] = hit
            while len(images) > 150:
                images.pop(next(iter(images)))
        body, kind = hit
        return web.Response(body=body, content_type=kind, headers={"Cache-Control": "max-age=3600"})

    images = {}                         # (address, width) -> (bytes, type), most recent last
    renderer = Renderer(b)
    remuxer = Remuxer()
    b.remuxer = remuxer
    mirror = Mirror(b)
    b.mirror = mirror
    app = web.Application(middlewares=[guard])
    app.add_routes([
        web.get("/hello", hello), web.get("/start", start), web.get("/poll", poll), web.get(r"/frame/{n}.jpg", frame),
        web.get("/input", input_), web.get("/state", state), web.post("/open", open_),
        web.post("/type", type_), web.post("/cast", cast), web.get("/file/{token}/{name}", file),
        web.get("/remux", remux), web.get("/remux/{key}/{name}", remux_file),
        web.get("/dailymotion/{id}", dailymotion),
        web.post("/mirror", mirror_), web.get("/mirror/{token}/{name}", mirror_file),
        web.get("/lite", lite), web.get("/img", img),
    ])
    return app


async def watchdog(b):
    tick = 0
    while True:
        await asyncio.sleep(1.5)
        tick += 1
        if tick % 2 == 0:
            await b.mirror.check()
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
    await Mirror.drop_leftovers()
    dog = asyncio.create_task(watchdog(b))
    log.info("listening on :%d (discovery :%d)", cfg["port"], cfg["discovery_port"])
    done = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, done.set)
    await done.wait()
    dog.cancel()
    b.remuxer.stop()
    await b.mirror.stop()
    await b.stop()
    await b.http.close()
    await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
