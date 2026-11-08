' Browser scene: shows frames rendered on the laptop and turns the remote into a
' mouse. The cursor is drawn here so it moves instantly; only clicks, scrolls and
' typing travel to the laptop.

sub init()
    m.reg = CreateObject("roRegistrySection", "browser")
    m.clock = CreateObject("roTimespan")
    m.hostRe = CreateObject("roRegex", "^[a-z]+://(www\.)?([^/:?#]+)", "i")

    m.front = m.top.findNode("pageA")
    m.back = m.top.findNode("pageB")
    m.front.observeField("loadStatus", "onPageLoad")
    m.back.observeField("loadStatus", "onPageLoad")
    ' What changed since the full picture, laid on top of it (see FrameCoder on the laptop).
    m.patchFront = m.top.findNode("patchA")
    m.patchBack = m.top.findNode("patchB")
    m.patchFront.observeField("loadStatus", "onPatchLoad")
    m.patchBack.observeField("loadStatus", "onPatchLoad")
    m.wantPatch = invalid
    m.patchLoading = ""
    m.shownPatch = ""
    ' Scrolling slides the picture at once; a frame that includes the scroll settles it.
    m.pages = m.top.findNode("pages")
    m.slide = m.top.findNode("slide")
    m.slideTo = m.top.findNode("slideTo")
    m.frameScroll = {}          ' frame -> the last scroll it includes
    m.scrollId = 0
    m.pendingScrolls = []       ' scrolls sent that the picture on screen doesn't include yet
    m.slideClock = CreateObject("roTimespan")
    m.cursor = m.top.findNode("cursor")
    m.highlight = m.top.findNode("highlight")
    m.ring = m.top.findNode("ring")
    m.progress = m.top.findNode("progress")
    m.toast = m.top.findNode("toast")
    m.toastBg = m.top.findNode("toastBg")
    m.toastLabel = m.top.findNode("toastLabel")
    m.notice = m.top.findNode("notice")
    m.noticeBg = m.top.findNode("noticeBg")
    m.noticeLabel = m.top.findNode("noticeLabel")
    m.hints = m.top.findNode("hints")
    m.menu = m.top.findNode("menu")
    m.menuCard = m.top.findNode("menuCard")
    m.menuTitle = m.top.findNode("menuTitle")
    m.menuSub = m.top.findNode("menuSub")
    m.menuList = m.top.findNode("menuList")
    m.offline = m.top.findNode("offline")
    m.video = m.top.findNode("video")
    m.spinner = m.top.findNode("spinner")

    m.moveTimer = m.top.findNode("moveTimer")
    m.toastTimer = m.top.findNode("toastTimer")
    m.noticeTimer = m.top.findNode("noticeTimer")
    m.hintsTimer = m.top.findNode("hintsTimer")
    m.idleTimer = m.top.findNode("idleTimer")
    m.anim = {}
    for each name in ["toastIn", "toastOut", "noticeIn", "noticeOut", "hintsIn", "hintsOut", "offlineOut", "clickAnim", "progressAnim", "cursorOut"]
        m.anim[name] = m.top.findNode(name)
    end for

    m.moveTimer.observeField("fire", "onMoveTick")
    m.toastTimer.observeField("fire", "hideToast")
    m.noticeTimer.observeField("fire", "hideNotice")
    m.hintsTimer.observeField("fire", "hideHints")
    m.idleTimer.observeField("fire", "onIdle")
    m.menuList.observeField("itemSelected", "onMenuSelect")
    m.video.observeField("state", "onVideoState")
    m.lite = m.top.findNode("lite")
    m.lite.observeField("request", "onLiteRequest")
    m.lite.observeField("status", "onLiteStatus")
    m.top.findNode("fallbackTimer").observeField("fire", "onFallback")
    m.top.findNode("lostTimer").observeField("fire", "onLost")

    ' Ember colours for the system keyboard dialog.
    palette = CreateObject("roSGNode", "RSGPalette")
    palette.colors = {
        DialogBackgroundColor: "0x1A141BFF", DialogTextColor: "0xF0E4D4FF", DialogItemColor: "0xF0E4D4FF",
        DialogFocusColor: "0xE89B5EFF", DialogFocusItemColor: "0x1A141BFF", DialogSecondaryTextColor: "0xB5A698FF",
        DialogSecondaryItemColor: "0x4A3C47FF", DialogInputFieldColor: "0x2F2530FF", DialogKeyboardColor: "0x2F2530FF",
        DialogFootprintColor: "0x4A3C47FF"
    }
    m.top.palette = palette

    m.spinner.poster.uri = "pkg:/images/spinner.png"
    m.spinner.control = "start"

    m.x = 640
    m.y = 360
    m.dir = ""
    m.ticks = 0
    m.scrollX = 0
    m.scrollY = 0
    m.lastScroll = 0
    m.lastMove = 0
    m.seq = 0
    m.server = ""
    m.mirroring = false     ' the video playing is the laptop's screen
    m.pendingMirror = false
    m.state = {frame: 0, url: "", label: "", title: "", host: "", loading: false, back: false, fwd: false, tabs: 1, zoom: 125, video: ""}
    m.boot = ""
    m.wantFrame = ""
    m.loadingFrame = ""
    m.shownFrame = ""
    m.lastAction = -1
    m.backArmed = -10000
    m.lastPlace = ""
    m.toastUp = false
    m.toastArmed = false
    m.pendingOpen = invalid
    m.online = false
    m.hintsChecked = false
    m.kbMode = ""
    m.kbButtons = []
    m.menuItems = []
    m.links = []
    m.pendingLinks = {}
    m.hover = invalid
    m.cursorShown = true
    m.revealed = false
    ' "connecting" until the laptop answers; "full" with it, "lite" without.
    m.mode = "connecting"
    m.ignoreOkUntil = 0
    m.laptopAvailable = false
    m.toldLaptop = false
    m.liteScale = 1.0
    m.kbField = -1
    placeCursor()

    m.poll = CreateObject("roSGNode", "PollTask")
    m.cmd = CreateObject("roSGNode", "CmdTask")
    m.poll.observeField("update", "onState")
    m.poll.observeField("online", "onOnline")
    m.poll.observeField("server", "onServer")
    m.cmd.observeField("result", "onResult")
    m.top.setFocus(true)
end sub

' ---- connection ---------------------------------------------------------

sub onLaunchArgs()
    args = m.top.launchArgs
    server = m.reg.read("server")
    if args <> invalid
        if args.server <> invalid and args.server <> "" then server = args.server
        if args.url <> invalid and args.url <> "" then m.pendingOpen = args.url
    end if
    m.poll.server = server
    m.cmd.server = server
    m.poll.control = "RUN"
    m.cmd.control = "RUN"
    if args <> invalid and args.mode = "lite"
        enterLite("")
    else
        m.top.findNode("fallbackTimer").control = "start"
    end if
    ' Asked for once the laptop answers; the command task is only just starting.
    if args <> invalid and args.mirror = "1" then m.pendingMirror = true
end sub

sub onFallback()
    if m.mode = "connecting" then enterLite("No laptop found, so this is Lite mode")
end sub

sub onLost()
    if m.mode = "full" and not m.online then enterLite("Lost the laptop, so this is Lite mode")
end sub

sub enterLite(message as string)
    m.mode = "lite"
    m.poll.active = false
    m.top.findNode("fallbackTimer").control = "stop"
    m.anim.offlineOut.control = "stop"
    m.offline.opacity = 0
    m.spinner.control = "stop"
    m.front.visible = false
    m.back.visible = false
    m.cursor.visible = false
    m.highlight.visible = false
    m.lite.visible = true
    if m.pendingOpen <> invalid
        m.lite.navigate = {url: m.pendingOpen}
        m.pendingOpen = invalid
    else if m.lite.status = invalid
        m.lite.navigate = {url: "lite:start"}
    end if
    ' A video started at launch (the laptop's screen, say) keeps the remote.
    if not m.video.visible then m.lite.setFocus(true)
    if message <> "" then showNotice(message)
    if not m.hintsChecked then hintsOnLaunch()
end sub

sub enterFull()
    m.mode = "full"
    m.poll.active = true
    m.top.findNode("fallbackTimer").control = "stop"
    m.lite.visible = false
    m.front.visible = true
    m.back.visible = true
    m.cursor.visible = true
    m.hover = invalid
    placeCursor()
    if not m.video.visible then m.top.setFocus(true)
    if not m.online
        m.offline.opacity = 1
        m.spinner.control = "start"
    end if
end sub

' Back on the scene, menu or keyboard: focus goes to whichever mode is showing.
sub restoreFocus()
    if m.mode = "lite"
        m.lite.setFocus(true)
    else
        m.top.setFocus(true)
    end if
end sub

sub onLiteRequest()
    r = m.lite.request
    if r = invalid then return
    if r.keyboard <> invalid
        k = r.keyboard
        m.kbField = k.field
        buttons = ["Go", "Done", "Cancel"]
        if k.kind = "textarea" then buttons = ["Done", "Cancel"]
        showKeyboard("lite", k.title, k.value, k.kind, buttons)
    else if r.play <> invalid
        playVideo(r.play)
        if r.notice <> invalid then showNotice(r.notice)
    else if r.launch <> invalid
        showNotice("Opening the app…")
        m.top.launchApp = r.launch
    else if r.notice <> invalid
        showNotice(r.notice)
    else if r.exitAsk = true
        askExit()
    end if
end sub

sub onLiteStatus()
    s = m.lite.status
    if s = invalid then return
    label = s.title
    if s.host <> "" and label <> "" then label = label + "  " + Chr(183) + "  " + s.host
    if label = "" then label = s.host
    if label = "" and s.loading = true then label = "Loading" + Chr(8230)
    updateChrome({url: s.url, label: label, loading: s.loading})
end sub

sub onInputArgs()
    args = m.top.inputArgs
    if args = invalid then return
    if args.server <> invalid and args.server <> ""
        m.poll.server = args.server
        m.cmd.server = args.server
    end if
    if args.mirror = "1"
        startMirror()
    else if args.mirror = "0" and m.mirroring
        m.mirroring = false
        stopVideo()
        showNotice("Stopped showing the laptop screen")
    end if
    if args.mode = "lite" and m.mode <> "lite" then enterLite("")
    if args.mode = "full" and m.mode <> "full" then enterFull()
    if args.url <> invalid and args.url <> ""
        if m.mode = "lite"
            m.lite.navigate = {url: args.url}
        else
            send("nav", {q: args.url})
        end if
    end if
end sub

sub onServer()
    m.server = m.poll.server
    m.cmd.server = m.server
    if m.server <> ""
        m.reg.write("server", m.server)
        m.reg.flush()
    end if
end sub

sub onOnline()
    online = m.poll.online
    if online = m.online then return
    m.online = online
    m.laptopAvailable = online
    ' Lite mode borrows the laptop for what the Roku can't do alone (Dailymotion sound).
    if online then m.lite.helper = m.server else m.lite.helper = ""
    if online and m.pendingMirror
        m.pendingMirror = false
        startMirror()
    end if
    if m.mode = "lite"
        if online and not m.toldLaptop
            m.toldLaptop = true
            showNotice("Your laptop is available: " + Chr(10033) + " menu " + Chr(8250) + " Full browser")
        end if
        return
    end if
    if online
        m.top.findNode("lostTimer").control = "stop"
        if m.mode = "connecting" then enterFull()
        m.anim.offlineOut.control = "start"
        m.spinner.control = "stop"
        if m.pendingOpen <> invalid
            send("nav", {q: m.pendingOpen})
            m.pendingOpen = invalid
        end if
        if not m.hintsChecked then hintsOnLaunch()
    else
        m.anim.offlineOut.control = "stop"
        m.offline.opacity = 1
        m.spinner.control = "start"
        m.top.findNode("lostTimer").control = "start"
    end if
end sub

sub onState()
    s = m.poll.update
    if s = invalid then return
    m.state = s
    if s.server <> invalid then m.server = s.server
    if s.boot <> invalid then m.boot = s.boot
    if s.frame > 0
        key = m.boot + "-" + s.frame.toStr()
        base = key
        if s.base <> invalid and s.base > 0 then base = m.boot + "-" + s.base.toStr()
        if s.links <> invalid then m.pendingLinks[key] = s.links
        if s.si <> invalid then m.frameScroll[key] = s.si
        if s.patch <> invalid
            m.wantPatch = {key: key, base: base, rect: s.patch}
        else
            m.wantPatch = invalid
            if base = m.shownFrame then hidePatch()     ' back to the full picture itself
        end if
        if base <> m.shownFrame
            m.wantFrame = base
            loadNext()
        else
            loadPatch()
        end if
    end if
    updateChrome(s)
    if s.action <> invalid then runAction(s.action)
end sub

' ---- page frames --------------------------------------------------------

sub loadNext()
    if m.loadingFrame <> "" or m.wantFrame = "" or m.wantFrame = m.shownFrame then return
    m.loadingFrame = m.wantFrame
    m.back.uri = m.server + "/frame/" + m.wantFrame + ".jpg"
end sub

' The hidden layer finished loading: show it and hide the old one in the same pass.
sub onPageLoad(event as object)
    node = event.getRoSGNode()
    status = event.getData()
    if not node.isSameNode(m.back) then return
    if status = "ready"
        m.back.opacity = 1
        m.front.opacity = 0
        old = m.front
        m.front = m.back
        m.back = old
        m.shownFrame = m.loadingFrame
        m.loadingFrame = ""
        hidePatch()                 ' patches belong to the picture before
        ' Click targets travel with their frame, so they match what's on screen.
        if m.pendingLinks.doesExist(m.shownFrame)
            m.links = m.pendingLinks[m.shownFrame]
            updateHover(false)
        end if
        settleSlide(m.shownFrame)
        keepLinks = {}
        for each k in m.pendingLinks
            if k = m.wantFrame or (m.wantPatch <> invalid and k = m.wantPatch.key) then keepLinks[k] = m.pendingLinks[k]
        end for
        m.pendingLinks = keepLinks
        loadNext()
        loadPatch()
    else if status = "failed"
        m.back.uri = ""
        m.loadingFrame = ""
    end if
end sub

' A patch: the rectangle that changed since the full picture now showing.
sub loadPatch()
    p = m.wantPatch
    if p = invalid or p.base <> m.shownFrame or m.patchLoading <> "" or p.key = m.shownPatch then return
    m.patchLoading = p.key
    m.patchBase = p.base
    m.patchBack.translation = [p.rect[0], p.rect[1]]
    m.patchBack.width = p.rect[2]
    m.patchBack.height = p.rect[3]
    m.patchBack.uri = m.server + "/patch/" + p.key + ".jpg"
end sub

sub onPatchLoad(event as object)
    node = event.getRoSGNode()
    status = event.getData()
    if not node.isSameNode(m.patchBack) or m.patchLoading = "" then return
    if status = "ready" and m.patchBase = m.shownFrame
        m.patchBack.visible = true
        m.patchFront.visible = false
        old = m.patchFront
        m.patchFront = m.patchBack
        m.patchBack = old
        m.shownPatch = m.patchLoading
        if m.pendingLinks.doesExist(m.shownPatch)
            m.links = m.pendingLinks[m.shownPatch]
            updateHover(false)
        end if
        settleSlide(m.shownPatch)
    else if status <> "ready" and status <> "failed"
        return                          ' still loading
    end if
    m.patchLoading = ""
    loadPatch()
end sub

sub hidePatch()
    m.patchFront.visible = false
    m.patchBack.visible = false
    m.shownPatch = ""
end sub

' Scrolling: the picture slides at once, natively on the Roku, by every scroll the frame
' on screen doesn't include yet; each frame from the laptop says which it includes. If the
' page couldn't scroll that far (its end), the real frame simply puts it right.
function nextScroll(dx as float, dy as float) as integer
    m.scrollId = m.scrollId + 1
    m.pendingScrolls.Push({id: m.scrollId, dx: dx, dy: dy})
    m.slideClock.Mark()
    m.highlight.visible = false
    slideTo(true)
    return m.scrollId
end function

' A new frame on screen: drop the scrolls it includes, slide by the rest.
sub settleSlide(key as string)
    if m.pendingScrolls.Count() = 0 then return
    si = m.frameScroll[key]
    if m.slideClock.TotalMilliseconds() > 2500
        m.pendingScrolls = []           ' scrolls the laptop never answered
    else if si <> invalid
        rest = []
        for each p in m.pendingScrolls
            if p.id > si then rest.Push(p)
        end for
        m.pendingScrolls = rest
    end if
    slideTo(false)
end sub

sub slideTo(animate as boolean)
    x = 0
    y = 0
    for each p in m.pendingScrolls
        x = x - p.dx
        y = y - p.dy
    end for
    if y > 720 then y = 720
    if y < -720 then y = -720
    m.slide.control = "stop"
    if animate
        m.slideTo.keyValue = [m.pages.translation, [x, y]]
        m.slide.control = "start"
    else
        m.pages.translation = [x, y]
    end if
end sub

' ---- remote -------------------------------------------------------------

function onKeyEvent(key as string, press as boolean) as boolean
    if m.video.visible
        if press and key = "back"
            stopVideo()
            return true
        end if
        return false
    end if
    if m.menu.visible
        if press and (key = "back" or key = "options") then closeMenu()
        return true
    end if
    if m.mode = "lite"
        ' Lite view handles moving and clicking; these are what it passes up.
        if not press then return false
        hideHints()
        if key = "options"
            openMenu()
        else if key = "play"
            openAddress()
        else if key = "replay"
            m.lite.command = "reload"
        else if key = "back"
            askExit()
        else
            return false
        end if
        return true
    end if
    if press then wake()
    if key = "up" or key = "down" or key = "left" or key = "right"
        if press
            hideHints()
            startMove(key)
        else
            stopMove(key)
        end if
        return true
    end if
    if not press then return true
    hideHints()
    if key = "OK"
        if m.revealed or m.clock.TotalMilliseconds() < m.ignoreOkUntil then return true
        click()
    else if key = "back"
        goBack()
    else if key = "play"
        openAddress()
    else if key = "options"
        openMenu()
    else if key = "rewind"
        ' The laptop pages by 85% of the screen.
        send("page", {dir: -1, sid: nextScroll(0, -612)})
    else if key = "fastforward"
        send("page", {dir: 1, sid: nextScroll(0, 612)})
    else if key = "replay"
        send("reload")
    else
        return false
    end if
    return true
end function

sub placeCursor()
    m.cursor.translation = [m.x - 3, m.y - 3]
    updateHover(true)
end sub

' Highlights the smallest clickable thing under the cursor. While moving, reaching
' a new target eases the cursor off so it's easy to stop on.
sub updateHover(moving as boolean)
    best = invalid
    bestArea = 0
    for each r in m.links
        if m.x >= r[0] and m.y >= r[1] and m.x < r[0] + r[2] and m.y < r[1] + r[3]
            area = r[2] * r[3]
            if best = invalid or area < bestArea
                best = r
                bestArea = area
            end if
        end if
    end for
    if best = invalid
        m.hover = invalid
        m.highlight.visible = false
        return
    end if
    same = m.hover <> invalid
    if same then same = m.hover[0] = best[0] and m.hover[1] = best[1] and m.hover[2] = best[2] and m.hover[3] = best[3]
    if same then return
    m.hover = best
    m.highlight.translation = [best[0] - 6, best[1] - 6]
    m.highlight.width = best[2] + 12
    m.highlight.height = best[3] + 12
    m.highlight.visible = m.cursorShown
    if moving and m.ticks > 5 then m.ticks = 5
end sub

' Any key brings the cursor back; it fades out again when the remote is idle.
sub wake()
    m.revealed = false
    if not m.cursorShown
        m.anim.cursorOut.control = "stop"
        m.cursor.opacity = 1
        m.highlight.opacity = 0.95
        m.cursorShown = true
        m.highlight.visible = m.hover <> invalid
        m.revealed = true
    end if
    m.idleTimer.control = "stop"
    m.idleTimer.control = "start"
end sub

sub onIdle()
    if m.menu.visible or m.video.visible then return
    m.cursorShown = false
    m.anim.cursorOut.control = "start"
end sub

sub startMove(key as string)
    m.dir = key
    m.ticks = 0
    stepCursor()
    m.moveTimer.control = "start"
end sub

sub stopMove(key as string)
    if m.dir <> key then return
    m.dir = ""
    m.moveTimer.control = "stop"
    flushScroll()
    sendMove()
end sub

sub onMoveTick()
    if m.dir = "" then return
    m.ticks = m.ticks + 1
    stepCursor()
end sub

' Moves the cursor one tick, accelerating while the key is held. Pushing past
' an edge scrolls the page instead.
sub stepCursor()
    t = m.ticks
    if t > 24 then t = 24
    speed = 7 + t * 1.2
    nx = m.x
    ny = m.y
    if m.dir = "left" then nx = nx - speed
    if m.dir = "right" then nx = nx + speed
    if m.dir = "up" then ny = ny - speed
    if m.dir = "down" then ny = ny + speed
    if nx < 0
        m.scrollX = m.scrollX + nx * 2
        nx = 0
    else if nx > 1279
        m.scrollX = m.scrollX + (nx - 1279) * 2
        nx = 1279
    end if
    if ny < 0
        m.scrollY = m.scrollY + ny * 2.5
        ny = 0
    else if ny > 719
        m.scrollY = m.scrollY + (ny - 719) * 2.5
        ny = 719
    end if
    m.x = nx
    m.y = ny
    placeCursor()
    now = m.clock.TotalMilliseconds()
    if (m.scrollX <> 0 or m.scrollY <> 0) and now - m.lastScroll > 90 then flushScroll()
    if now - m.lastMove > 250 then sendMove()
end sub

sub flushScroll()
    if m.scrollX = 0 and m.scrollY = 0 then return
    sid = nextScroll(Int(m.scrollX), Int(m.scrollY))
    send("scroll", {x: Int(m.x), y: Int(m.y), dx: Int(m.scrollX), dy: Int(m.scrollY), sid: sid})
    m.scrollX = 0
    m.scrollY = 0
    m.lastScroll = m.clock.TotalMilliseconds()
end sub

sub sendMove()
    m.lastMove = m.clock.TotalMilliseconds()
    send("move", {x: Int(m.x), y: Int(m.y)})
end sub

sub click()
    m.ring.translation = [m.x - 48, m.y - 48]
    m.anim.clickAnim.control = "start"
    flushScroll()
    send("click", {x: Int(m.x), y: Int(m.y)})
end sub

sub goBack()
    if m.state.back = true
        send("back")
        return
    end if
    askExit()
end sub

sub askExit()
    now = m.clock.TotalMilliseconds()
    if now - m.backArmed < 2500
        m.top.exitApp = true
    else
        m.backArmed = now
        showNotice("Press Back again to exit")
    end if
end sub

sub send(t as string, args = invalid as dynamic, timeout = 8000 as integer)
    m.seq = m.seq + 1
    c = {id: m.seq, t: t, timeout: timeout}
    if args <> invalid then c.args = args
    m.cmd.cmd = c
end sub

sub onResult()
    r = m.cmd.result
    if r = invalid or r.reply = invalid then return
    reply = r.reply
    if reply.failed = true
        if r.t <> "move" and r.t <> "scroll" then showNotice("Couldn't reach your laptop")
        return
    end if
    if reply.edit <> invalid then openFieldKeyboard(reply.edit)
    if reply.play <> invalid then playVideo(reply.play)
    if reply.airplay = true then hideNotice()
    if reply.notice <> invalid then showNotice(reply.notice)
end sub

sub runAction(a as object)
    if a.id = m.lastAction then return
    m.lastAction = a.id
    if a.notice <> invalid then showNotice(a.notice)
    if a.play <> invalid then playVideo(a.play)
end sub

' ---- typing -------------------------------------------------------------

sub openAddress()
    showKeyboard("address", "Search or enter address", "", "text", ["Go", "Cancel"])
end sub

sub openFieldKeyboard(edit as object)
    title = edit.label
    if title = invalid or title = "" then title = "Type text"
    if edit.multiline = true
        buttons = ["Done", "Cancel"]
    else
        buttons = ["Enter", "Done", "Cancel"]
    end if
    showKeyboard("field", title, edit.value, edit.kind, buttons)
end sub

sub showKeyboard(mode as string, title as string, value as string, kind as string, buttons as object)
    kb = CreateObject("roSGNode", "StandardKeyboardDialog")
    kb.title = title
    kb.text = value
    kb.buttons = buttons
    if kb.hasField("keyboardDomain")
        if kind = "password"
            kb.keyboardDomain = "password"
        else if kind = "email"
            kb.keyboardDomain = "email"
        else if kind = "number" or kind = "tel"
            kb.keyboardDomain = "numeric"
        end if
    end if
    kb.observeField("buttonSelected", "onKeyboardButton")
    kb.observeField("wasClosed", "onKeyboardClosed")
    m.kbMode = mode
    m.kbButtons = buttons
    m.top.dialog = kb
end sub

sub onKeyboardButton()
    kb = m.top.dialog
    if kb = invalid then return
    choice = m.kbButtons[kb.buttonSelected]
    text = kb.text
    kb.close = true
    if m.kbMode = "address"
        if choice = "Go" and text.trim() <> ""
            if m.mode = "lite"
                m.lite.input = {field: -1, text: text, submit: true, address: true}
            else
                send("nav", {q: text})
            end if
        end if
    else if m.kbMode = "lite"
        if choice <> "Cancel" then m.lite.input = {field: m.kbField, text: text, submit: choice = "Go"}
    else if choice = "Enter"
        send("text", {s: text, enter: 1})
    else if choice = "Done"
        send("text", {s: text, enter: 0})
    end if
end sub

sub onKeyboardClosed()
    restoreFocus()
end sub

' ---- menu ---------------------------------------------------------------

sub openMenu(focusId = "" as string)
    if m.mode = "lite"
        openLiteMenu(focusId)
        return
    end if
    s = m.state
    items = [{id: "address", title: "Search or enter address", value: ""}]
    if s.video <> invalid and s.video <> "" then items.push({id: "video", title: s.video, value: ""})
    items.push({id: "mirror", title: "Show laptop screen", value: ""})
    if s.fwd = true then items.push({id: "forward", title: "Forward", value: ""})
    items.push({id: "reload", title: "Reload", value: ""})
    items.push({id: "zoom", title: "Text size", value: s.zoom.toStr() + "%"})
    items.push({id: "home", title: "Start page", value: ""})
    if s.tabs > 1 then items.push({id: "closetab", title: "Close tab", value: s.tabs.toStr() + " open"})
    items.push({id: "lite", title: "Lite mode (no laptop)", value: ""})
    items.push({id: "help", title: "Remote buttons", value: ""})
    items.push({id: "exit", title: "Exit Browser", value: ""})
    title = "Browser"
    if s.title <> invalid and s.title <> "" then title = s.title
    showMenu(items, focusId, title, s.host)
end sub

sub openLiteMenu(focusId as string)
    s = m.lite.status
    items = [{id: "address", title: "Search or enter address", value: ""}]
    items.push({id: "reload", title: "Reload", value: ""})
    items.push({id: "zoom", title: "Text size", value: Int(m.liteScale * 100 + 0.5).toStr() + "%"})
    items.push({id: "home", title: "Start page", value: ""})
    if m.laptopAvailable
        items.push({id: "full", title: "Full browser (laptop)", value: ""})
        items.push({id: "mirror", title: "Show laptop screen", value: ""})
    end if
    items.push({id: "help", title: "Remote buttons", value: ""})
    items.push({id: "exit", title: "Exit Browser", value: ""})
    title = "Lite mode"
    host = ""
    if s <> invalid
        if s.title <> "" then title = s.title
        host = s.host
    end if
    showMenu(items, focusId, title, host)
end sub

sub showMenu(items as object, focusId as string, title as string, subtitle as string)
    content = CreateObject("roSGNode", "ContentNode")
    focus = 0
    for i = 0 to items.count() - 1
        c = content.createChild("ContentNode")
        c.title = items[i].title
        c.description = items[i].value
        if items[i].id = focusId then focus = i
    end for
    m.menuItems = items
    m.menuList.numRows = items.count()
    m.menuList.content = content
    m.menuList.jumpToItem = focus
    m.menuTitle.text = title
    m.menuSub.text = subtitle

    listH = items.count() * 56 - 4
    cardH = 112 + listH + 24
    top = Int((720 - cardH) / 2)
    m.menuCard.height = cardH
    m.menuCard.translation = [380, top]
    m.menuTitle.translation = [404, top + 24]
    m.menuSub.translation = [404, top + 60]
    m.menuList.translation = [404, top + 112]
    m.menu.visible = true
    m.cursor.visible = false
    m.highlight.visible = false
    m.menuList.setFocus(true)
end sub

sub closeMenu()
    m.menuList.setFocus(false)
    m.menu.visible = false
    ' The OK that picked a menu item can arrive again once focus moves; don't click with it.
    m.ignoreOkUntil = m.clock.TotalMilliseconds() + 500
    if m.mode = "lite" then m.lite.holdOk = true
    restoreFocus()
    if m.mode <> "lite"
        m.cursor.visible = true
        m.hover = invalid
        placeCursor()
    end if
end sub

sub onMenuSelect()
    id = m.menuItems[m.menuList.itemSelected].id
    if id = "mirror"
        closeMenu()
        startMirror()
        return
    end if
    if m.mode = "lite"
        onLiteMenuSelect(id)
        return
    end if
    if id = "zoom"
        ' Cycle in place so the size can be stepped through without reopening.
        sizes = [100, 125, 150, 175]
        nxt = 100
        for i = 0 to sizes.count() - 1
            if sizes[i] = m.state.zoom then nxt = sizes[(i + 1) mod sizes.count()]
        end for
        m.state.zoom = nxt
        send("zoom")
        openMenu("zoom")
        return
    end if
    closeMenu()
    if id = "address"
        openAddress()
    else if id = "video"
        showNotice("Finding the video…")
        send("video", invalid, 50000)
    else if id = "forward" or id = "reload" or id = "home" or id = "closetab"
        send(id)
    else if id = "help"
        showHints()
    else if id = "lite"
        enterLite("")
    else if id = "exit"
        m.top.exitApp = true
    end if
end sub

sub onLiteMenuSelect(id as string)
    if id = "zoom"
        scales = [1.0, 1.15, 1.3]
        nxt = 1.0
        for i = 0 to scales.count() - 1
            if Abs(scales[i] - m.liteScale) < 0.01 then nxt = scales[(i + 1) mod scales.count()]
        end for
        m.liteScale = nxt
        m.lite.textScale = nxt
        openLiteMenu("zoom")
        return
    end if
    closeMenu()
    if id = "address"
        openAddress()
    else if id = "reload" or id = "home"
        m.lite.command = id
    else if id = "full"
        enterFull()
    else if id = "help"
        showHints()
    else if id = "exit"
        m.top.exitApp = true
    end if
end sub

' ---- video --------------------------------------------------------------

' The laptop's screen, with its sound: over AirPlay, which takes over the TV, or as a
' live stream for this channel's player.
sub startMirror()
    showNotice("Getting your laptop's screen…")
    ' The first time, the laptop asks which screen to share; that can take a while.
    send("mirror", {on: 1}, 190000)
end sub

sub playVideo(p as object)
    content = CreateObject("roSGNode", "ContentNode")
    content.url = p.url
    content.streamFormat = p.format
    if p.title <> invalid then content.title = p.title
    if p.headers <> invalid and p.headers.count() > 0 then content.HttpHeaders = p.headers
    if p.live = true
        content.live = true
        content.PlayStart = 100000
    end if
    m.mirroring = (p.mirror = true)
    ' A page's own video: when the player stops, the page picks up where it got to.
    m.pageVideo = (p.page = true)
    hideNotice()
    m.video.content = content
    m.video.visible = true
    m.cursor.visible = false
    m.highlight.visible = false
    m.video.setFocus(true)
    m.video.control = "play"
    if m.pageVideo then showNotice("Back returns to the page")
end sub

sub stopVideo(failed = false as boolean)
    if m.pageVideo
        m.pageVideo = false
        failedFlag = 0
        if failed then failedFlag = 1
        send("videoend", {pos: Int(m.video.position), failed: failedFlag})
    end if
    if m.mirroring
        ' Stop capturing now, which also gives the laptop its sound back.
        m.mirroring = false
        send("mirror", {on: 0})
    end if
    m.video.control = "stop"
    m.video.visible = false
    if m.mode <> "lite"
        m.cursor.visible = true
        m.hover = invalid
        placeCursor()
    end if
    restoreFocus()
end sub

sub onVideoState()
    st = m.video.state
    if st = "error"
        print "video error: "; m.video.errorCode; " "; m.video.errorMsg
        mirroring = m.mirroring
        stopVideo(true)
        if mirroring
            showNotice("The laptop stopped showing its screen")
        else
            showNotice("Couldn't play this video")
        end if
    else if st = "finished"
        stopVideo()
    end if
end sub

' ---- chrome -------------------------------------------------------------

sub updateChrome(s as object)
    if s.loading = true
        if not m.progress.visible
            m.progress.visible = true
            m.anim.progressAnim.control = "start"
        end if
    else if m.progress.visible
        m.progress.visible = false
        m.anim.progressAnim.control = "stop"
    end if

    if s.url <> m.lastPlace
        m.lastPlace = s.url
        showToast(s.label)
    else if m.toastUp and s.label <> m.toastLabel.text
        setPill(m.toastLabel, m.toastBg, m.toast, s.label, 18, 24)
    end if
    if m.toastUp and not m.toastArmed and s.loading <> true
        m.toastArmed = true
        m.toastTimer.control = "start"
    end if
end sub

' Sizes a pill to its text and centres it horizontally at height y.
sub setPill(label as object, bg as object, group as object, text as string, y as float, pad as integer)
    label.width = 0
    label.text = text
    w = label.boundingRect().width
    if w > 880 then w = 880
    label.width = w
    bg.width = w + pad * 2
    group.findNode(bg.id.replace("Bg", "Edge")).width = bg.width
    group.translation = [(1280 - bg.width) / 2, y]
end sub

sub showToast(text as string)
    if text = "" then return
    setPill(m.toastLabel, m.toastBg, m.toast, text, 18, 24)
    m.toastTimer.control = "stop"
    m.toastArmed = false
    m.anim.toastOut.control = "stop"
    if not m.toastUp then m.anim.toastIn.control = "start"
    m.toastUp = true
end sub

sub hideToast()
    m.toastUp = false
    m.anim.toastOut.control = "start"
end sub

sub showNotice(text as string)
    setPill(m.noticeLabel, m.noticeBg, m.notice, text, 640, 26)
    hideHints()
    m.anim.noticeOut.control = "stop"
    if m.notice.opacity < 1 then m.anim.noticeIn.control = "start"
    ' Long messages stay up long enough to read.
    seconds = Len(text) / 16
    if seconds < 3.5 then seconds = 3.5
    m.noticeTimer.duration = seconds
    m.noticeTimer.control = "stop"
    m.noticeTimer.control = "start"
end sub

sub hideNotice()
    m.noticeTimer.control = "stop"
    ' A notice still fading in would otherwise finish appearing and stay.
    m.anim.noticeIn.control = "stop"
    if m.notice.opacity > 0 then m.anim.noticeOut.control = "start"
end sub

sub hintsOnLaunch()
    m.hintsChecked = true
    count = 0
    seen = m.reg.read("launches")
    if seen <> "" then count = seen.toInt()
    if count < 5
        m.reg.write("launches", (count + 1).toStr())
        m.reg.flush()
        showHints()
    end if
end sub

sub showHints()
    m.anim.hintsOut.control = "stop"
    m.anim.hintsIn.control = "start"
    m.hintsTimer.control = "stop"
    m.hintsTimer.control = "start"
end sub

sub hideHints()
    m.hintsTimer.control = "stop"
    if m.hints.opacity > 0.01
        m.anim.hintsIn.control = "stop"
        m.anim.hintsOut.control = "start"
    end if
end sub
