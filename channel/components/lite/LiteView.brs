' Lite mode: shows pages the Roku fetched and parsed itself, no laptop needed.
' Text, links, images, search boxes and video cards are laid out natively, and
' the remote moves between the things you can click. Blocks are laid out a few
' at a time so the first screen appears straight away.

sub init()
    m.content = m.top.findNode("content")
    m.ring = m.top.findNode("ring")
    m.scrollAnim = m.top.findNode("scrollAnim")
    m.scrollInterp = m.top.findNode("scrollInterp")
    m.layoutTimer = m.top.findNode("layoutTimer")
    m.layoutTimer.observeField("fire", "onLayoutTick")
    m.repeatTimer = m.top.findNode("repeatTimer")
    m.repeatTimer.observeField("fire", "onRepeat")

    m.agent = CreateObject("roHttpAgent")
    m.agent.AddHeader("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36")

    m.task = CreateObject("roSGNode", "LiteTask")
    m.task.observeField("result", "onResult")
    m.task.control = "RUN"

    m.colX = 150
    m.colW = 980
    m.viewH = 720
    m.scale = 1.0
    m.history = []
    m.reqId = 0
    m.pending = invalid
    m.url = ""
    m.doc = invalid
    m.blocks = []
    m.pos = []
    m.focusables = []
    m.images = []
    m.imageIndex = {}
    m.inputLabels = {}
    m.focus = -1
    m.scroll = 0
    m.y = 0
    m.next = 0
    m.grid = invalid
    m.repeatKey = ""
    m.clock = CreateObject("roTimespan")
    m.okHeldUntil = 0
end sub

' The scene closed its menu: the OK that chose the item may arrive here too.
sub onHoldOk()
    m.okHeldUntil = m.clock.TotalMilliseconds() + 500
end sub

' ---- navigation -----------------------------------------------------------

sub onNavigate()
    n = m.top.navigate
    if n = invalid or n.url = invalid then return
    if n.url = "lite:start"
        if m.doc <> invalid then pushHistory()
        m.url = "lite:start"
        showDoc(startDoc(), 0, -1)
        setStatus(false)
        return
    end if
    load(n.url, n.post, true, invalid)
end sub

sub onCommand()
    c = m.top.command
    if c = "back"
        if not goBack() then m.top.request = {exitAsk: true}
    else if c = "reload"
        if m.url = "lite:start" or m.url = ""
            showDoc(startDoc(), 0, -1)
        else
            load(m.url, invalid, false, invalid)
        end if
    else if c = "home"
        m.top.navigate = {url: "lite:start"}
    end if
end sub

sub onTextScale()
    if m.top.textScale = m.scale then return
    m.scale = m.top.textScale
    if m.doc <> invalid then showDoc(m.doc, m.scroll, -1)
end sub

sub load(url as string, post as dynamic, push as boolean, extra as dynamic)
    m.reqId = m.reqId + 1
    m.pending = {id: m.reqId, url: url, push: push}
    req = {id: m.reqId, url: url, helper: m.top.helper}
    if post <> invalid then req.post = post
    if extra <> invalid then req.Append(extra)
    m.task.request = req
    setStatus(true)
end sub

sub onResult()
    r = m.task.result
    if r = invalid or m.pending = invalid or r.id <> m.pending.id then return
    p = m.pending
    m.pending = invalid
    if r.doc <> invalid
        if p.push and m.doc <> invalid then pushHistory()
        m.url = r.url
        showDoc(r.doc, 0, -1)
    else if r.play <> invalid
        m.top.request = {play: r.play, notice: r.notice}
    else if r.launch <> invalid
        m.top.request = {launch: r.launch}
    else if r.notice <> invalid
        m.top.request = {notice: r.notice}
    end if
    setStatus(false)
end sub

sub pushHistory()
    m.history.Push({url: m.url, scroll: m.scroll, focus: m.focus, doc: m.doc})
    ' Keep the last few pages in memory for an instant Back; older ones reload.
    n = m.history.Count()
    if n > 4 then m.history[n - 5].doc = invalid
end sub

function goBack() as boolean
    if m.history.Count() = 0 then return false
    e = m.history.Pop()
    m.url = e.url
    if e.doc <> invalid
        showDoc(e.doc, e.scroll, e.focus)
        setStatus(false)
    else
        load(e.url, invalid, false, invalid)
    end if
    return true
end function

sub setStatus(loading as boolean)
    title = ""
    if m.doc <> invalid and m.doc.title <> invalid then title = m.doc.title
    host = ""
    if Left(m.url, 4) = "http" then host = urlHost(m.url)
    m.top.status = {url: m.url, title: title, host: host, loading: loading, back: m.history.Count() > 0}
end sub

sub follow(url as string)
    if url = "" then return
    load(url, invalid, true, invalid)
end sub

' Address bar text: an address if it looks like one, otherwise a web search.
function addressFor(text as string) as string
    t = text.Trim()
    lower = LCase(t)
    if Left(lower, 7) = "http://" or Left(lower, 8) = "https://" then return t
    if Instr(1, t, " ") = 0 and Instr(1, t, ".") > 1 and Right(t, 1) <> "." then return "https://" + t
    return "https://html.duckduckgo.com/html/?q=" + percentEncode(t)
end function

' ---- documents and layout ---------------------------------------------------

sub showDoc(doc as object, scroll as float, focus as integer)
    m.layoutTimer.control = "stop"
    m.content.removeChildrenIndex(m.content.getChildCount(), 0)
    m.content.appendChild(m.ring)
    m.ring.visible = false
    m.doc = doc
    m.blocks = doc.blocks
    m.pos = []
    m.focusables = []
    m.images = []
    m.imageIndex = {}
    m.inputLabels = {}
    m.focus = -1
    m.next = 0
    m.y = 64
    m.grid = invalid
    m.restoreScroll = scroll
    m.restoreFocus = focus
    m.scrollAnim.control = "stop"
    m.scroll = 0
    m.content.translation = [0, 0]
    layoutSome(24)
    if m.next < m.blocks.Count() then m.layoutTimer.control = "start"
    afterLayout()
end sub

sub onLayoutTick()
    layoutSome(10)
    if m.next >= m.blocks.Count() then m.layoutTimer.control = "stop"
    afterLayout()
end sub

sub layoutSome(count as integer)
    n = m.blocks.Count()
    done = 0
    while m.next < n and done < count
        layoutBlock(m.next)
        m.next = m.next + 1
        done = done + 1
    end while
    if m.next >= n then closeGrid()
end sub

sub afterLayout()
    if m.restoreScroll > 0 and (contentHeight() >= m.restoreScroll + m.viewH or m.next >= m.blocks.Count())
        setScroll(m.restoreScroll, false)
        m.restoreScroll = 0
    end if
    if m.restoreFocus >= 0 and m.restoreFocus < m.focusables.Count()
        setFocus(m.restoreFocus, false)
        m.restoreFocus = -1
    else if m.focus < 0 and m.restoreFocus < 0
        first = firstVisibleFocusable()
        if first >= 0 then setFocus(first, false)
    end if
    loadVisibleImages()
end sub

function contentHeight() as float
    if m.grid <> invalid then return m.grid.y + m.grid.rowH
    return m.y
end function

function size(base as integer) as integer
    return Int(base * m.scale + 0.5)
end function

function styles(fontSize as integer, heading as boolean, color as string) as object
    regular = "pkg:/fonts/Inter-Medium.ttf"
    strong = "pkg:/fonts/Inter-SemiBold.ttf"
    body = regular
    if heading then body = strong
    return {
        "default": {fontUri: body, fontSize: fontSize, color: color},
        "b": {fontUri: strong, fontSize: fontSize, color: color},
        "a": {fontUri: body, fontSize: fontSize, color: "#8CB3D9FF"},
        "f": {fontUri: strong, fontSize: fontSize, color: "#E89B5EFF"}
    }
end function

' Label markup for a text block; the focused link gets the "f" style.
function markup(block as object, focusLink as integer) as string
    out = ""
    first = true
    for each r in block.r
        s = r.s
        if first
            while Len(s) > 0 and (Left(s, 1) = " " or Left(s, 1) = Chr(10))
                s = Mid(s, 2)
            end while
            if s <> "" then first = false
        end if
        s = s.Replace("<", Chr(8249)).Replace(">", Chr(8250))
        if r.a >= 0
            if r.a = focusLink
                out = out + "<f>" + s + "</f>"
            else
                out = out + "<a>" + s + "</a>"
            end if
        else if r.b
            out = out + "<b>" + s + "</b>"
        else
            out = out + s
        end if
    end for
    return out
end function

sub layoutBlock(i as integer)
    b = m.blocks[i]
    k = b.k
    if k = "card" or k = "tile"
        layoutGridItem(i, b)
        return
    end if
    closeGrid()
    g = CreateObject("roSGNode", "Group")
    w = m.colW
    h = 0
    gapBefore = 0
    gapAfter = size(16)
    body = size(22)
    if k = "h1" or k = "h2" or k = "h3" or k = "h4"
        sizes = {h1: 34, h2: 28, h3: 25, h4: 23}
        gapBefore = size(14)
        gapAfter = size(10)
        h = textBlock(g, b, i, 0, w, size(sizes[k]), true, "#F0E4D4FF")
    else if k = "li" or k = "lic"
        if k = "li"
            dot = CreateObject("roSGNode", "Label")
            dot.text = Chr(8226)
            dot.color = "0xE89B5EFF"
            dot.font = font("Inter-SemiBold", body)
            dot.translation = [6, 0]
            g.appendChild(dot)
        end if
        gapAfter = size(10)
        indent = 32
        ' Sites build story cards from list items: text under a heading isn't a list.
        prev = m.blocks[i - 1]
        if k = "lic" and prev <> invalid and Left(prev.k, 1) = "h" then indent = 0
        h = textBlock(g, b, i, indent, w - indent, body, false, "#F0E4D4FF")
    else if k = "quote"
        bar = CreateObject("roSGNode", "Rectangle")
        bar.width = 4
        bar.color = "0xE89B5E99"
        g.appendChild(bar)
        h = textBlock(g, b, i, 26, w - 26, body, false, "#D9CBBBFF")
        bar.height = h
    else if k = "caption"
        h = textBlock(g, b, i, 0, w, size(18), false, "#B5A698FF")
    else if k = "pre"
        h = textBlock(g, b, i, 0, w, size(18), false, "#E6D7C3FF")
    else if k = "hr"
        line = CreateObject("roSGNode", "Rectangle")
        line.width = w
        line.height = 1
        line.color = "0x3B2F3AFF"
        g.appendChild(line)
        h = 1
        gapBefore = size(8)
        gapAfter = size(24)
    else if k = "img"
        h = imageBlock(g, b, i, w)
    else if k = "input"
        h = inputBlock(g, b, i, w)
    else if k = "button"
        h = buttonBlock(g, b, i, 0)
    else if k = "video"
        h = videoBlock(g, b, i)
        gapAfter = size(24)
    else
        h = textBlock(g, b, i, 0, w, body, false, "#F0E4D4FF")
    end if
    if h <= 0
        m.pos[i] = {x: m.colX, y: m.y, w: 0, h: 0, node: invalid}
        return
    end if
    m.y = m.y + gapBefore
    g.translation = [m.colX, m.y]
    m.content.insertChild(g, m.content.getChildCount() - 1)
    m.pos[i] = {x: m.colX, y: m.y, w: w, h: h, node: g}
    m.y = m.y + h + gapAfter
end sub

function font(name as string, fontSize as integer) as object
    f = CreateObject("roSGNode", "Font")
    f.uri = "pkg:/fonts/" + name + ".ttf"
    f.size = fontSize
    return f
end function

function textBlock(g as object, b as object, i as integer, xOff as integer, width as integer, fontSize as integer, heading as boolean, color as string) as float
    label = CreateObject("roSGNode", "MultiStyleLabel")
    label.drawingStyles = styles(fontSize, heading, color)
    label.width = width
    label.wrap = true
    label.translation = [xOff, 0]
    label.text = markup(b, -1)
    g.appendChild(label)
    h = label.boundingRect().height
    if h <= 0 then return 0

    ' Links get focus spots. Their place inside the wrapped text is estimated from
    ' character offsets; it only has to be good enough to move and scroll by.
    total = Len(b.t)
    if total < 1 then total = 1
    lineH = fontSize * 1.33
    lines = Int(h / lineH + 0.5)
    if lines < 1 then lines = 1
    perLine = total / lines
    rowH = h / lines
    prev = -1
    for each r in b.r
        if r.a >= 0 and r.a <> prev
            line = Int(r.o / perLine)
            if line > lines - 1 then line = lines - 1
            fx = ((r.o - line * perLine) / perLine) * width
            fw = (Len(r.s) / perLine) * width
            if fw > width - fx then fw = width - fx
            if fw < 24 then fw = 24
            m.focusables.Push({b: i, kind: "link", link: r.a, rx: xOff + fx, ry: line * rowH, w: fw, h: rowH, label: label})
        end if
        prev = r.a
    end for
    return h
end function

function imageBlock(g as object, b as object, i as integer, width as integer) as float
    iw = b.w
    ih = b.h
    known = iw > 0 and ih > 0
    if known
        dw = displayWidth(iw, width)
        dh = dw * ih / iw
        if dh > 480
            dh = 480
            dw = dh * iw / ih
        end if
    else
        dw = 640
        dh = 360
    end if
    x = Int((width - dw) / 2)
    bg = CreateObject("roSGNode", "Rectangle")
    bg.color = "0x2A212AFF"
    bg.width = dw
    bg.height = dh
    bg.translation = [x, 0]
    g.appendChild(bg)
    p = CreateObject("roSGNode", "Poster")
    p.width = dw
    p.height = dh
    if known
        p.loadWidth = dw
        p.loadHeight = dh
        p.loadDisplayMode = "scaleToFit"
    else
        ' Decode at natural size (only huge images are scaled down), so the real
        ' size is known when it loads and small pictures aren't stretched.
        p.loadWidth = width
        p.loadHeight = 720
        p.loadDisplayMode = "limitSize"
    end if
    p.translation = [x, 0]
    p.id = "img" + i.toStr()
    p.setHttpAgent(m.agent)
    p.observeField("loadStatus", "onImageStatus")
    g.appendChild(p)
    m.images.Push({node: p, bg: bg, b: i, src: b.src, set: false, known: known})
    m.imageIndex[p.id] = m.images.Count() - 1
    if b.a >= 0 then m.focusables.Push({b: i, kind: "img", link: b.a, rx: x, ry: 0, w: dw, h: dh})
    return dh
end function

sub onImageStatus(event as object)
    p = event.getRoSGNode()
    status = event.getData()
    idx = m.imageIndex[p.id]
    if idx = invalid then return
    img = m.images[idx]
    if status = "ready"
        img.bg.visible = false
        if not img.known and p.bitmapWidth > 0 and p.bitmapHeight > 0
            img.known = true
            dw = displayWidth(p.bitmapWidth, m.colW)
            dh = dw * p.bitmapHeight / p.bitmapWidth
            if dh > 480
                dh = 480
                dw = dh * p.bitmapWidth / p.bitmapHeight
            end if
            x = Int((m.colW - dw) / 2)
            p.width = dw
            p.height = dh
            p.translation = [x, 0]
            for each f in m.focusables
                if f.b = img.b and f.kind = "img"
                    f.rx = x
                    f.w = dw
                    f.h = dh
                end if
            end for
            resizeBlock(img.b, dh)
        end if
    else if status = "failed"
        p.visible = false
        img.bg.visible = false
        resizeBlock(img.b, 0)
    end if
end sub

' Pictures can be enlarged a little for the TV, but small ones stay small: blown-up
' thumbnails look worse than modest sharp ones.
function displayWidth(natural as float, maxWidth as integer) as float
    w = natural
    if natural >= 240 then w = natural * 1.25
    if w > maxWidth then w = maxWidth
    return w
end function

' A block changed height (an image loaded): move everything below it.
sub resizeBlock(i as integer, newH as float)
    entry = m.pos[i]
    if entry = invalid then return
    delta = newH - entry.h
    if delta = 0 then return
    entry.h = newH
    for j = i + 1 to m.pos.Count() - 1
        q = m.pos[j]
        if q <> invalid
            q.y = q.y + delta
            if q.node <> invalid then q.node.translation = [q.x, q.y]
        end if
    end for
    m.y = m.y + delta
    if m.grid <> invalid then m.grid.y = m.grid.y + delta
    if entry.y < m.scroll then setScroll(m.scroll + delta, false)
    if m.focus >= 0 then placeRing(m.focusables[m.focus])
end sub

function inputBlock(g as object, b as object, i as integer, width as integer) as float
    h = size(54)
    ' A submit button for the same form sits on the same row.
    btn = invalid
    nb = m.blocks[i + 1]
    if nb <> invalid and nb.k = "button" and nb.f = b.f and b.f >= 0 then btn = nb
    fieldW = width
    btnW = 0
    if btn <> invalid
        btnW = buttonWidth(btn)
        fieldW = width - btnW - 16
    end if
    bg = CreateObject("roSGNode", "Poster")
    bg.uri = "pkg:/images/pill.9.png"
    bg.blendColor = "0x2B222BFF"
    bg.width = fieldW
    bg.height = h
    g.appendChild(bg)
    edge = CreateObject("roSGNode", "Poster")
    edge.uri = "pkg:/images/pill_edge.9.png"
    edge.blendColor = "0x54444FFF"
    edge.width = fieldW
    edge.height = h
    g.appendChild(edge)
    label = CreateObject("roSGNode", "Label")
    label.translation = [26, 0]
    label.width = fieldW - 52
    label.height = h
    label.vertAlign = "center"
    label.font = font("Inter-Medium", size(21))
    g.appendChild(label)
    m.inputLabels[i.toStr()] = label
    showInputValue(i)
    m.focusables.Push({b: i, kind: "input", rx: 0, ry: 0, w: fieldW, h: h})
    if btn <> invalid
        buttonBlock(g, btn, i + 1, fieldW + 16)
        m.pos[i + 1] = {x: m.colX, y: 0, w: 0, h: 0, node: invalid, sameRowAs: i}
        m.next = m.next + 1
    end if
    return h
end function

sub showInputValue(i as integer)
    label = m.inputLabels[i.toStr()]
    if label = invalid then return
    b = m.blocks[i]
    if b.v <> invalid and b.v <> ""
        text = b.v
        if b.type = "password" then text = String(Len(b.v), Chr(8226))
        label.text = text
        label.color = "0xF0E4D4FF"
    else
        hint = b.ph
        if hint = invalid or hint = "" then hint = "Type here"
        label.text = hint
        label.color = "0x8F8177FF"
    end if
end sub

function buttonWidth(b as object) as integer
    probe = CreateObject("roSGNode", "Label")
    probe.font = font("Inter-SemiBold", size(20))
    probe.text = b.label
    return Int(probe.boundingRect().width) + 48
end function

function buttonBlock(g as object, b as object, i as integer, x as integer) as float
    h = size(54)
    w = buttonWidth(b)
    bg = CreateObject("roSGNode", "Poster")
    bg.uri = "pkg:/images/pill.9.png"
    bg.blendColor = "0xE89B5EFF"
    bg.width = w
    bg.height = h
    bg.translation = [x, 0]
    g.appendChild(bg)
    label = CreateObject("roSGNode", "Label")
    label.text = b.label
    label.font = font("Inter-SemiBold", size(20))
    label.color = "0x1A141BFF"
    label.width = w
    label.height = h
    label.horizAlign = "center"
    label.vertAlign = "center"
    label.translation = [x, 0]
    g.appendChild(label)
    ' A button laid out beside its field shares that field's block position.
    owner = i
    if x > 0 then owner = i - 1
    m.focusables.Push({b: owner, kind: "button", button: i, rx: x, ry: 0, w: w, h: h})
    return h
end function

function videoBlock(g as object, b as object, i as integer) as float
    v = b.v
    thumb = b.thumb
    caption = "Play video"
    if v.yt <> invalid
        thumb = "https://i.ytimg.com/vi/" + v.yt + "/hqdefault.jpg"
        caption = "Watch on YouTube"
    else if v.dm <> invalid
        thumb = "https://www.dailymotion.com/thumbnail/video/" + v.dm
        caption = "Play from Dailymotion"
    end if
    w = 480
    h = 270
    bg = CreateObject("roSGNode", "Rectangle")
    bg.color = "0x2A212AFF"
    bg.width = w
    bg.height = h
    g.appendChild(bg)
    if thumb <> invalid and thumb <> ""
        p = CreateObject("roSGNode", "Poster")
        p.width = w
        p.height = h
        p.loadDisplayMode = "scaleToFill"
        p.setHttpAgent(m.agent)
        p.uri = thumb
        g.appendChild(p)
    end if
    badge = CreateObject("roSGNode", "Poster")
    badge.uri = "pkg:/images/pill.9.png"
    badge.blendColor = "0x1A141BFF"
    badge.opacity = 0.85
    badge.width = 92
    badge.height = 60
    badge.translation = [(w - 92) / 2, (h - 60) / 2]
    g.appendChild(badge)
    play = CreateObject("roSGNode", "Label")
    play.text = Chr(9654)
    play.font = font("Inter-SemiBold", 28)
    play.color = "0xE89B5EFF"
    play.width = 92
    play.height = 60
    play.horizAlign = "center"
    play.vertAlign = "center"
    play.translation = [(w - 92) / 2, (h - 60) / 2]
    g.appendChild(play)
    label = CreateObject("roSGNode", "Label")
    label.text = caption
    label.font = font("Inter-SemiBold", size(24))
    label.color = "0xF0E4D4FF"
    label.translation = [w + 28, 20]
    label.width = m.colW - w - 28
    g.appendChild(label)
    if b.title <> invalid and b.title <> ""
        t = CreateObject("roSGNode", "Label")
        t.text = b.title
        t.font = font("Inter-Medium", size(19))
        t.color = "0xB5A698FF"
        t.wrap = true
        t.maxLines = 4
        t.translation = [w + 28, 62]
        t.width = m.colW - w - 28
        g.appendChild(t)
    end if
    m.focusables.Push({b: i, kind: "video", rx: 0, ry: 0, w: w, h: h})
    return h
end function

' Cards (videos, 3 per row) and tiles (favourites, 4 per row) flow in a grid.
sub layoutGridItem(i as integer, b as object)
    cols = 3
    gap = 28
    if b.k = "tile"
        cols = 4
        gap = 20
    end if
    itemW = Int((m.colW - gap * (cols - 1)) / cols)
    if m.grid = invalid or m.grid.kind <> b.k
        closeGrid()
        m.grid = {kind: b.k, col: 0, y: m.y + size(6), rowH: 0, gap: gap}
    else if m.grid.col >= cols
        m.grid.y = m.grid.y + m.grid.rowH + gap
        m.grid.col = 0
        m.grid.rowH = 0
    end if
    x = m.colX + m.grid.col * (itemW + gap)
    g = CreateObject("roSGNode", "Group")
    if b.k = "card"
        h = cardNode(g, b, itemW, i)
    else
        h = tileNode(g, b, itemW)
    end if
    g.translation = [x, m.grid.y]
    g.scaleRotateCenter = [itemW / 2, h / 2]
    m.content.insertChild(g, m.content.getChildCount() - 1)
    m.pos[i] = {x: x, y: m.grid.y, w: itemW, h: h, node: g}
    link = -1
    if b.a <> invalid then link = b.a
    m.focusables.Push({b: i, kind: b.k, link: link, rx: 0, ry: 0, w: itemW, h: h, node: g})
    if h > m.grid.rowH then m.grid.rowH = h
    m.grid.col = m.grid.col + 1
end sub

sub closeGrid()
    if m.grid = invalid then return
    m.y = m.grid.y + m.grid.rowH + size(24)
    m.grid = invalid
end sub

function cardNode(g as object, b as object, w as integer, i as integer) as float
    th = Int(w * 9 / 16)
    bg = CreateObject("roSGNode", "Rectangle")
    bg.color = "0x2A212AFF"
    bg.width = w
    bg.height = th
    g.appendChild(bg)
    p = CreateObject("roSGNode", "Poster")
    p.width = w
    p.height = th
    p.loadWidth = w
    p.loadHeight = th
    p.loadDisplayMode = "scaleToFill"
    p.setHttpAgent(m.agent)
    p.id = "card" + m.images.Count().toStr()
    g.appendChild(p)
    m.images.Push({node: p, bg: bg, b: -1, src: b.thumb, set: false, known: true, cardPos: i})
    if b.dur <> invalid and b.dur <> ""
        badgeLabel = CreateObject("roSGNode", "Label")
        badgeLabel.font = font("Inter-SemiBold", 15)
        badgeLabel.text = b.dur
        bw = badgeLabel.boundingRect().width + 14
        badge = CreateObject("roSGNode", "Rectangle")
        badge.color = "0x1A141BDD"
        badge.width = bw
        badge.height = 24
        badge.translation = [w - bw - 8, th - 32]
        g.appendChild(badge)
        badgeLabel.color = "0xF0E4D4FF"
        badgeLabel.width = bw
        badgeLabel.height = 24
        badgeLabel.horizAlign = "center"
        badgeLabel.vertAlign = "center"
        badgeLabel.translation = [w - bw - 8, th - 32]
        g.appendChild(badgeLabel)
    end if
    title = CreateObject("roSGNode", "Label")
    title.text = b.title
    title.font = font("Inter-SemiBold", size(18))
    title.color = "0xF0E4D4FF"
    title.wrap = true
    title.maxLines = 2
    title.lineSpacing = 0
    title.width = w
    title.translation = [0, th + 10]
    g.appendChild(title)
    titleH = title.boundingRect().height
    sub2 = CreateObject("roSGNode", "Label")
    sub2.text = b.sub
    sub2.font = font("Inter-Medium", size(15))
    sub2.color = "0xB5A698FF"
    sub2.width = w
    sub2.translation = [0, th + 14 + titleH]
    g.appendChild(sub2)
    return th + 18 + titleH + size(20)
end function

function tileNode(g as object, b as object, w as integer) as float
    h = 128
    bg = CreateObject("roSGNode", "Poster")
    bg.uri = "pkg:/images/card.9.png"
    bg.blendColor = "0x251D26FF"
    bg.width = w
    bg.height = h
    g.appendChild(bg)
    labelY = 0
    if b.icon <> invalid and b.icon <> ""
        plate = CreateObject("roSGNode", "Poster")
        plate.uri = "pkg:/images/focus.9.png"
        plate.blendColor = "0xF6EFE6FF"
        plate.width = 54
        plate.height = 54
        plate.translation = [(w - 54) / 2, 18]
        g.appendChild(plate)
        icon = CreateObject("roSGNode", "Poster")
        icon.width = 34
        icon.height = 34
        icon.loadDisplayMode = "scaleToFit"
        icon.setHttpAgent(m.agent)
        icon.uri = b.icon
        icon.translation = [(w - 34) / 2, 28]
        g.appendChild(icon)
        labelY = 80
    end if
    label = CreateObject("roSGNode", "Label")
    label.text = b.title
    label.font = font("Inter-Medium", size(18))
    label.color = "0xF0E4D4FF"
    label.width = w - 16
    label.horizAlign = "center"
    if labelY = 0
        label.height = h
        label.vertAlign = "center"
        label.translation = [8, 0]
    else
        label.translation = [8, labelY]
    end if
    g.appendChild(label)
    return h
end function

' ---- images load as they come near the screen --------------------------------

sub loadVisibleImages()
    top = m.scroll - m.viewH
    bottom = m.scroll + m.viewH * 2
    for each img in m.images
        if not img.set
            y = 0
            h = 0
            if img.b >= 0 and m.pos[img.b] <> invalid
                y = m.pos[img.b].y
                h = m.pos[img.b].h
            else if img.cardPos <> invalid and m.pos[img.cardPos] <> invalid
                y = m.pos[img.cardPos].y
                h = m.pos[img.cardPos].h
            else
                y = -1
            end if
            if y >= 0 and y < bottom and y + h > top
                img.node.uri = img.src
                img.set = true
            end if
        end if
    end for
end sub

' ---- scrolling and focus ------------------------------------------------------

function maxScroll() as float
    v = contentHeight() + 48 - m.viewH
    if v < 0 then v = 0
    return v
end function

sub setScroll(v as float, animate as boolean)
    if v > maxScroll() then v = maxScroll()
    if v < 0 then v = 0
    from = m.content.translation
    m.scroll = v
    if animate
        m.scrollAnim.control = "stop"
        m.scrollInterp.keyValue = [from, [0, -v]]
        m.scrollAnim.control = "start"
    else
        m.scrollAnim.control = "stop"
        m.content.translation = [0, -v]
    end if
    loadVisibleImages()
end sub

function absX(f as object) as float
    return m.pos[f.b].x + f.rx
end function

function absY(f as object) as float
    return m.pos[f.b].y + f.ry
end function

function linkUrl(f as object) as string
    if f.link = invalid or f.link < 0 then return ""
    return m.doc.links[f.link].u
end function

function firstVisibleFocusable() as integer
    for i = 0 to m.focusables.Count() - 1
        y = absY(m.focusables[i])
        if y >= m.scroll + 40 and y < m.scroll + m.viewH - 60 then return i
    end for
    return -1
end function

sub setFocus(idx as integer, scrollTo as boolean)
    if m.focus >= 0 and m.focus < m.focusables.Count() then unfocus(m.focusables[m.focus])
    m.focus = idx
    m.ring.visible = false
    if idx < 0 then return
    f = m.focusables[idx]
    if f.kind = "link"
        f.label.text = markup(m.blocks[f.b], f.link)
    else
        placeRing(f)
        m.ring.visible = true
        if f.node <> invalid then f.node.scale = [1.04, 1.04]
    end if
    if scrollTo then ensureVisible(f)
end sub

sub unfocus(f as object)
    if f.kind = "link"
        f.label.text = markup(m.blocks[f.b], -1)
    else if f.node <> invalid
        f.node.scale = [1, 1]
    end if
end sub

sub placeRing(f as object)
    if f.kind = "link" then return
    grow = 0
    if f.node <> invalid then grow = f.w * 0.02
    m.ring.translation = [absX(f) - 7 - grow, absY(f) - 7 - grow * f.h / f.w]
    m.ring.width = f.w + 14 + grow * 2
    m.ring.height = f.h + 14 + grow * 2 * f.h / f.w
end sub

sub ensureVisible(f as object)
    y = absY(f)
    if y < m.scroll + 70
        setScroll(y - 70, true)
    else if y + f.h > m.scroll + m.viewH - 50
        setScroll(y + f.h - m.viewH + 50, true)
    end if
end sub

' Up/Down: the nearest thing above or below. If it's far away, scroll instead so
' the text in between can be read.
sub moveVertical(dir as integer)
    viewTop = m.scroll
    viewBottom = m.scroll + m.viewH
    cur = invalid
    if m.focus >= 0
        cur = m.focusables[m.focus]
        cy = absY(cur)
        if cy + cur.h < viewTop or cy > viewBottom then cur = invalid
    end if
    if cur <> invalid
        refY = absY(cur)
        refX = absX(cur) + cur.w / 2
        ' From something wide (a search box), go to the start of the next row.
        if cur.w > m.colW * 0.6 then refX = absX(cur)
    else
        refX = 640
        if dir > 0 then refY = viewTop + 30 else refY = viewBottom - 30
    end if
    ' Links to where the focused one already goes (a result's title, address and
    ' snippet; a story's headline and photo) are skipped: one press per destination.
    here = ""
    if cur <> invalid then here = linkUrl(cur)
    best = -1
    bestScore = 1000000
    for i = 0 to m.focusables.Count() - 1
        f = m.focusables[i]
        dy = (absY(f) - refY) * dir
        if dy > 8 and here <> "" and linkUrl(f) = here then dy = 0
        if dy > 8
            dx = Abs(absX(f) + f.w / 2 - refX)
            score = dy + dx * 0.3
            if score < bestScore
                bestScore = score
                best = i
            end if
        end if
    end for
    if best >= 0
        f = m.focusables[best]
        y = absY(f)
        if (dir > 0 and y + f.h <= viewBottom + 60) or (dir < 0 and y >= viewTop - 60)
            setFocus(best, true)
            return
        end if
    end if
    scrollBy(dir * 300)
end sub

' Left/Right: the neighbour on the same row, else the previous/next item.
sub moveHorizontal(dir as integer)
    if m.focus < 0
        moveVertical(dir)
        return
    end if
    cur = m.focusables[m.focus]
    cy = absY(cur) + cur.h / 2
    cx = absX(cur) + cur.w / 2
    best = -1
    bestDx = 1000000
    for i = 0 to m.focusables.Count() - 1
        f = m.focusables[i]
        if Abs(absY(f) + f.h / 2 - cy) < cur.h * 0.6 + 4
            dx = (absX(f) + f.w / 2 - cx) * dir
            if dx > 4 and dx < bestDx
                bestDx = dx
                best = i
            end if
        end if
    end for
    if best < 0
        best = m.focus + dir
        if best < 0 or best >= m.focusables.Count() then return
    end if
    setFocus(best, true)
end sub

sub scrollBy(delta as float)
    before = m.scroll
    setScroll(m.scroll + delta, true)
    if m.scroll = before then return
    ' Keep focus on screen: if it scrolled away, pick what's now visible.
    if m.focus >= 0
        y = absY(m.focusables[m.focus])
        if y < m.scroll or y > m.scroll + m.viewH
            first = firstVisibleFocusable()
            if first >= 0 then setFocus(first, false) else setFocus(-1, false)
        end if
    end if
end sub

' ---- remote -----------------------------------------------------------------

function onKeyEvent(key as string, press as boolean) as boolean
    if key = "up" or key = "down" or key = "left" or key = "right"
        if press
            m.repeatKey = key
            moveBy(key)
            m.repeatTimer.duration = 0.4
            m.repeatTimer.control = "start"
        else if key = m.repeatKey
            m.repeatKey = ""
            m.repeatTimer.control = "stop"
        end if
        return true
    end if
    if not press then return false
    if key = "OK"
        if m.clock.TotalMilliseconds() >= m.okHeldUntil then activate()
        return true
    else if key = "fastforward"
        scrollBy(m.viewH * 0.85)
        return true
    else if key = "rewind"
        scrollBy(-m.viewH * 0.85)
        return true
    else if key = "back"
        return goBack()
    end if
    return false
end function

sub onRepeat()
    if m.repeatKey = ""
        m.repeatTimer.control = "stop"
        return
    end if
    m.repeatTimer.duration = 0.12
    moveBy(m.repeatKey)
end sub

sub moveBy(key as string)
    if key = "down"
        moveVertical(1)
    else if key = "up"
        moveVertical(-1)
    else if key = "right"
        moveHorizontal(1)
    else if key = "left"
        moveHorizontal(-1)
    end if
end sub

sub activate()
    if m.focus < 0 then return
    f = m.focusables[m.focus]
    b = m.blocks[f.b]
    if f.kind = "link" or f.kind = "img" or f.kind = "tile"
        if f.link >= 0 then follow(m.doc.links[f.link].u)
    else if f.kind = "input"
        hint = b.ph
        if hint = invalid or hint = "" then hint = "Type"
        value = b.v
        if value = invalid then value = ""
        m.top.request = {keyboard: {title: hint, value: value, kind: b.type, field: m.focus}}
    else if f.kind = "button"
        btn = m.blocks[f.button]
        if btn.app <> invalid
            m.top.request = {launch: {app: btn.app}}
        else
            submitForm(btn.f, btn)
        end if
    else if f.kind = "video"
        playItem(b.v)
    else if f.kind = "card"
        playItem(b.act)
    end if
end sub

sub playItem(v as object)
    if v.yt <> invalid
        m.top.request = {launch: {app: "837", contentId: v.yt, mediaType: "movie"}}
    else if v.dm <> invalid
        load(m.url, invalid, false, {dm: v.dm})
    else if v.u <> invalid
        m.top.request = {play: {url: v.u, format: v.fmt, title: m.doc.title, headers: []}}
    end if
end sub

' The keyboard closed on a field: keep the text, and send the form if asked.
sub onInput()
    r = m.top.input
    if r = invalid or r.field = invalid then return
    if r.address = true
        follow(addressFor(r.text))
        return
    end if
    if r.field < 0 or r.field >= m.focusables.Count() then return
    f = m.focusables[r.field]
    b = m.blocks[f.b]
    b.v = r.text
    showInputValue(f.b)
    if not r.submit then return
    if b.address = true
        follow(addressFor(r.text))
    else
        submitForm(b.f, invalid)
    end if
end sub

sub submitForm(formIndex as integer, button as dynamic)
    if formIndex < 0 or formIndex >= m.doc.forms.Count() then return
    form = m.doc.forms[formIndex]
    pairs = []
    for each h in form.hidden
        pairs.Push(percentEncode(h.n) + "=" + percentEncode(h.v))
    end for
    for each b in m.blocks
        if b.k = "input" and b.f = formIndex and b.n <> invalid and b.n <> ""
            value = b.v
            if value = invalid then value = ""
            pairs.Push(percentEncode(b.n) + "=" + percentEncode(value))
        end if
    end for
    if button <> invalid and button.n <> invalid and button.n <> "" then pairs.Push(percentEncode(button.n) + "=" + percentEncode(button.v))
    query = pairs.Join("&")
    if form.method = "post"
        load(form.action, {type: "application/x-www-form-urlencoded", body: query}, true, invalid)
    else
        target = form.action
        q = Instr(1, target, "?")
        if q > 0 then target = Left(target, q - 1)
        follow(target + "?" + query)
    end if
end sub

' ---- start page ---------------------------------------------------------------

function startDoc() as object
    doc = {title: "Start", url: "lite:start", base: "", links: [], videos: [], forms: [{action: "https://html.duckduckgo.com/html/", method: "get", hidden: []}], blocks: []}
    doc.blocks.Push({k: "input", f: 0, n: "q", v: "", ph: "Search the web or type an address", type: "search", address: true})
    doc.blocks.Push({k: "h2", r: [{s: "Favourites", a: -1, b: false, o: 0}], t: "Favourites"})
    favourites = [
        ["BBC News", "https://www.bbc.co.uk/news", "bbc.co.uk"],
        ["YouTube", "https://www.youtube.com/", "youtube.com"],
        ["Dailymotion", "https://www.dailymotion.com/", "dailymotion.com"],
        ["Wikipedia", "https://en.wikipedia.org/wiki/Main_Page", "wikipedia.org"],
        ["BBC Weather", "https://www.bbc.co.uk/weather", "bbc.co.uk"],
        ["The Guardian", "https://www.theguardian.com/uk", "theguardian.com"],
        ["CNN Lite", "https://lite.cnn.com/", "cnn.com"],
        ["Hacker News", "https://news.ycombinator.com/", "ycombinator.com"]
    ]
    for each fav in favourites
        doc.links.Push({u: fav[1]})
        doc.blocks.Push({k: "tile", title: fav[0], icon: "https://www.google.com/s2/favicons?domain=" + fav[2] + "&sz=128", a: doc.links.Count() - 1})
    end for
    note = "Lite mode runs on the Roku itself, without JavaScript: news, reference and search sites work, and videos play in the Roku's player or the YouTube app. For every site exactly as on a computer, run roku-browser on your laptop."
    doc.blocks.Push({k: "caption", r: [{s: note, a: -1, b: false, o: 0}], t: note})
    return doc
end function
