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
end sub

sub onInputArgs()
    args = m.top.inputArgs
    if args = invalid then return
    if args.server <> invalid and args.server <> "" then m.poll.server = args.server
    if args.url <> invalid and args.url <> "" then send("nav", {q: args.url})
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
    if online
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
        if key <> m.shownFrame
            m.wantFrame = key
            if s.links <> invalid then m.pendingLinks[key] = s.links
            loadNext()
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
        ' Click targets travel with their frame, so they match what's on screen.
        if m.pendingLinks.doesExist(m.shownFrame)
            m.links = m.pendingLinks[m.shownFrame]
            updateHover(false)
        end if
        keep = m.pendingLinks[m.wantFrame]
        m.pendingLinks = {}
        if keep <> invalid then m.pendingLinks[m.wantFrame] = keep
        loadNext()
    else if status = "failed"
        m.back.uri = ""
        m.loadingFrame = ""
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
        if m.revealed then return true
        click()
    else if key = "back"
        goBack()
    else if key = "play"
        openAddress()
    else if key = "options"
        openMenu()
    else if key = "rewind"
        send("page", {dir: -1})
    else if key = "fastforward"
        send("page", {dir: 1})
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
    send("scroll", {x: Int(m.x), y: Int(m.y), dx: Int(m.scrollX), dy: Int(m.scrollY)})
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
        if choice = "Go" and text.trim() <> "" then send("nav", {q: text})
    else if choice = "Enter"
        send("text", {s: text, enter: 1})
    else if choice = "Done"
        send("text", {s: text, enter: 0})
    end if
end sub

sub onKeyboardClosed()
    m.top.setFocus(true)
end sub

' ---- menu ---------------------------------------------------------------

sub openMenu(focusId = "" as string)
    s = m.state
    items = [{id: "address", title: "Search or enter address", value: ""}]
    if s.video <> invalid and s.video <> "" then items.push({id: "video", title: s.video, value: ""})
    if s.fwd = true then items.push({id: "forward", title: "Forward", value: ""})
    items.push({id: "reload", title: "Reload", value: ""})
    items.push({id: "zoom", title: "Text size", value: s.zoom.toStr() + "%"})
    items.push({id: "home", title: "Start page", value: ""})
    if s.tabs > 1 then items.push({id: "closetab", title: "Close tab", value: s.tabs.toStr() + " open"})
    items.push({id: "help", title: "Remote buttons", value: ""})
    items.push({id: "exit", title: "Exit Browser", value: ""})

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

    title = "Browser"
    if s.title <> invalid and s.title <> "" then title = s.title
    m.menuTitle.text = title
    m.menuSub.text = s.host

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
    m.top.setFocus(true)
    m.menu.visible = false
    m.cursor.visible = true
    m.hover = invalid
    placeCursor()
end sub

sub onMenuSelect()
    id = m.menuItems[m.menuList.itemSelected].id
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
    else if id = "exit"
        m.top.exitApp = true
    end if
end sub

' ---- video --------------------------------------------------------------

sub playVideo(p as object)
    content = CreateObject("roSGNode", "ContentNode")
    content.url = p.url
    content.streamFormat = p.format
    if p.title <> invalid then content.title = p.title
    if p.headers <> invalid and p.headers.count() > 0 then content.HttpHeaders = p.headers
    hideNotice()
    m.video.content = content
    m.video.visible = true
    m.cursor.visible = false
    m.highlight.visible = false
    m.video.setFocus(true)
    m.video.control = "play"
end sub

sub stopVideo()
    m.video.control = "stop"
    m.video.visible = false
    m.cursor.visible = true
    m.hover = invalid
    placeCursor()
    m.top.setFocus(true)
end sub

sub onVideoState()
    st = m.video.state
    if st = "error"
        print "video error: "; m.video.errorCode; " "; m.video.errorMsg
        stopVideo()
        showNotice("Couldn't play this video")
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
    m.noticeTimer.control = "stop"
    m.noticeTimer.control = "start"
end sub

sub hideNotice()
    m.noticeTimer.control = "stop"
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
