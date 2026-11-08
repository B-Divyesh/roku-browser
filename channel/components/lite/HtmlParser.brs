' Turns a web page into blocks the Lite view can lay out: headings, paragraphs
' with inline links, lists, quotes, images, form fields and videos. There is no
' JavaScript or CSS here, only what the HTML itself says.
'
' Speed matters on a Roku: regexes over a whole page take tens of seconds there,
' so the page is split on "<" once (native) and walked with plain string calls.

function htmlToDoc(html as string, pageUrl as string) as object
    st = newParserState(pageUrl)
    parts = html.Split("<")
    addText(st, parts[0])
    count = parts.Count()
    for i = 1 to count - 1
        part = parts[i]
        if st.skipComment
            e = Instr(1, part, "-->")
            if e > 0
                st.skipComment = false
                addText(st, Mid(part, e + 3))
            end if
        else if st.skip <> ""
            ' Inside script/style: only its closing tag matters.
            if LCase(Left(part, st.skipLen)) = st.skip
                st.skip = ""
                gt = Instr(1, part, ">")
                if gt > 0 then addText(st, Mid(part, gt + 1))
            end if
        else if Left(part, 3) = "!--"
            e = Instr(4, part, "-->")
            if e > 0
                addText(st, Mid(part, e + 3))
            else
                st.skipComment = true
            end if
        else
            gt = Instr(1, part, ">")
            if gt > 0 and not oddQuotes(Left(part, gt - 1))
                handleTag(st, Left(part, gt - 1))
                if gt < Len(part) and st.skip = "" then addText(st, Mid(part, gt + 1))
            else if looksLikeTag(part)
                ' A "<" inside an attribute value split this tag; stitch it back together.
                buf = part
                gt = tagEnd(buf)
                while gt = 0 and i < count - 1 and Len(buf) < 200000
                    i = i + 1
                    buf = buf + "<" + parts[i]
                    gt = tagEnd(buf)
                end while
                if gt > 0
                    handleTag(st, Left(buf, gt - 1))
                    if gt < Len(buf) and st.skip = "" then addText(st, Mid(buf, gt + 1))
                end if
            else
                addText(st, "<" + part)
            end if
        end if
        if st.doc.blocks.Count() >= st.maxBlocks then exit for
    end for
    flushBlock(st)
    finishDoc(st)
    return st.doc
end function

function newParserState(pageUrl as string) as object
    return {
        doc: {title: "", url: pageUrl, base: pageUrl, blocks: [], links: [], forms: [], videos: [], image: "", description: "", canonical: "", ogTitle: ""},
        runs: [], plain: "", kind: "p", link: -1, bold: 0, pre: 0, quote: 0, li: 0, liFresh: false,
        chrome: 0, main: 0, space: false, skip: "", skipLen: 0, skipComment: false,
        inTitle: false, title: "", form: -1, button: invalid, select: invalid, picture: "",
        media: false, hideTag: "", hideNest: 0, maxBlocks: 900, images: 0,
        ws: CreateObject("roRegex", "\s+", ""),
        blockKinds: {
            p: "p", div: "p", section: "p", article: "p", main: "p", header: "p", footer: "p", nav: "p",
            aside: "p", h1: "h1", h2: "h2", h3: "h3", h4: "h4", h5: "h4", h6: "h4", ul: "p", ol: "p",
            li: "li", dl: "p", dt: "p", dd: "p", blockquote: "quote", pre: "pre", table: "p", tr: "p",
            figure: "p", figcaption: "caption", fieldset: "p", details: "p", summary: "p", address: "p",
            center: "p", caption: "p", hgroup: "p", legend: "p", form: "p", body: "p", menu: "p"
        },
        skipTags: {script: true, style: true, svg: true, template: true, object: true, canvas: true, math: true, noembed: true, textarea: true, iframe: true}
    }
end function

sub handleTag(st as object, tag as string)
    if tag = "" then return
    closing = false
    if Left(tag, 1) = "/"
        closing = true
        tag = Mid(tag, 2)
    end if
    name = tagName(tag)
    if name = "" then return

    ' Inside a hidden element, only watch for where it ends.
    if st.hideTag <> ""
        if name = st.hideTag
            if closing
                if st.hideNest = 0
                    st.hideTag = ""
                else
                    st.hideNest = st.hideNest - 1
                end if
            else
                st.hideNest = st.hideNest + 1
            end if
        end if
        return
    end if

    if closing
        closeTag(st, name)
    else
        openTag(st, name, tag)
    end if
end sub

function oddQuotes(tag as string) as boolean
    if Instr(1, tag, """") = 0 then return false
    return ((Len(tag) - Len(tag.Replace("""", ""))) mod 2) = 1
end function

function looksLikeTag(part as string) as boolean
    c = Asc(Left(part, 1))
    return (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or c = 47
end function

' Position of the ">" that really ends the tag, skipping any inside quoted values; 0 if not in buf.
function tagEnd(buf as string) as integer
    from = 1
    while true
        gt = Instr(from, buf, ">")
        dq = Instr(from, buf, """")
        sq = Instr(from, buf, "'")
        if gt = 0 then return 0
        q = 0
        if dq > 0 and dq < gt then q = dq
        if sq > 0 and sq < gt and (q = 0 or sq < q) then q = sq
        if q = 0 then return gt
        closer = Instr(q + 1, buf, Mid(buf, q, 1))
        if closer = 0 then return 0
        from = closer + 1
    end while
    return 0
end function

function tagName(tag as string) as string
    n = Len(tag)
    if n > 12 then n = 12
    i = 1
    while i <= n
        c = Asc(Mid(tag, i, 1))
        if not ((c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57) or c = 45) then exit while
        i = i + 1
    end while
    return LCase(Left(tag, i - 1))
end function

function isVoid(name as string) as boolean
    return name = "img" or name = "input" or name = "br" or name = "hr" or name = "meta" or name = "link" or name = "source" or name = "wbr" or name = "embed"
end function

' Elements a browser wouldn't show: hidden, aria-hidden or screen-reader-only.
' Also menus that start closed (dropdowns) and search-engine ads.
function isHidden(lt as string) as boolean
    if Instr(1, lt, "hidden") = 0 and Instr(1, lt, "none") = 0 and Instr(1, lt, "sr-only") = 0 and Instr(1, lt, "dropdown") = 0 and Instr(1, lt, "menu-content") = 0 and Instr(1, lt, "--ad") = 0 then return false
    return Instr(1, lt, " hidden") > 0 or Instr(1, lt, "aria-hidden=""true""") > 0 or Instr(1, lt, "display:none") > 0 or Instr(1, lt, "display: none") > 0 or Instr(1, lt, "visually-hidden") > 0 or Instr(1, lt, "sr-only") > 0 or Instr(1, lt, "screen-reader") > 0 or Instr(1, lt, "dropdown-content") > 0 or Instr(1, lt, "dropdown-menu") > 0 or Instr(1, lt, "menu-content") > 0 or Instr(1, lt, "result--ad") > 0 or Instr(1, lt, "name=""state_hidden""") > 0
end function

sub openTag(st as object, name as string, tag as string)
    lt = LCase(tag)
    if Len(tag) > Len(name) + 6 and isHidden(lt)
        if not isVoid(name)
            st.hideTag = name
            st.hideNest = 0
        end if
        return
    end if

    if st.skipTags.DoesExist(name)
        if name = "textarea" then textareaField(st, tag, lt)
        if name = "iframe" then addMediaUrl(st, resolveUrl(st.doc.base, decodeEntities(attr(tag, lt, "src"))))
        st.skip = "/" + name
        st.skipLen = Len(st.skip)
        return
    end if

    kind = st.blockKinds[name]
    if kind <> invalid
        flushBlock(st)
        if name = "li"
            st.li = st.li + 1
            st.liFresh = true
        else if name = "blockquote"
            st.quote = st.quote + 1
        else if name = "pre"
            st.pre = st.pre + 1
        else if name = "nav" or name = "footer" or name = "aside"
            st.chrome = st.chrome + 1
        else if name = "main" or name = "article"
            st.main = st.main + 1
        else if name = "form"
            openForm(st, tag, lt)
        end if
        if kind <> "p" then st.kind = kind
        return
    end if

    if name = "a"
        st.link = -1
        url = resolveUrl(st.doc.base, decodeEntities(attr(tag, lt, "href")))
        if url <> ""
            st.doc.links.Push({u: url})
            st.link = st.doc.links.Count() - 1
        end if
    else if name = "br"
        if st.plain <> ""
            addRun(st, Chr(10))
            st.space = false
        end if
    else if name = "b" or name = "strong"
        st.bold = st.bold + 1
    else if name = "td" or name = "th"
        if st.plain <> "" then st.space = true
    else if name = "img"
        imageBlock(st, tag, lt)
    else if name = "source"
        if st.media
            addMediaUrl(st, resolveUrl(st.doc.base, decodeEntities(attr(tag, lt, "src"))))
        else if st.picture = "" and Instr(1, lt, "avif") = 0
            set = attr(tag, lt, "srcset")
            if set <> "" then st.picture = pickSrcset(set, "")
        end if
    else if name = "input"
        inputField(st, tag, lt)
    else if name = "button"
        if st.form >= 0 and attr(tag, lt, "type") <> "button" and attr(tag, lt, "type") <> "reset"
            st.button = {k: "button", f: st.form, label: "", n: attr(tag, lt, "name"), v: decodeEntities(attr(tag, lt, "value"))}
        else
            st.hideTag = "button"
            st.hideNest = 0
        end if
    else if name = "select"
        if st.form >= 0
            st.select = {n: attr(tag, lt, "name"), v: invalid}
        else
            st.hideTag = "select"
            st.hideNest = 0
        end if
    else if name = "option"
        if st.select <> invalid and (st.select.v = invalid or Instr(1, lt, " selected") > 0)
            st.select.v = decodeEntities(attr(tag, lt, "value"))
        end if
    else if name = "hr"
        flushBlock(st)
        st.doc.blocks.Push({k: "hr"})
    else if name = "title"
        st.inTitle = true
    else if name = "meta"
        metaTag(st, tag, lt)
    else if name = "link"
        if LCase(attr(tag, lt, "rel")) = "canonical" then st.doc.canonical = resolveUrl(st.doc.base, decodeEntities(attr(tag, lt, "href")))
    else if name = "base"
        href = resolveUrl(st.doc.url, decodeEntities(attr(tag, lt, "href")))
        if href <> "" then st.doc.base = href
    else if name = "video" or name = "audio"
        st.media = true
        addMediaUrl(st, resolveUrl(st.doc.base, decodeEntities(attr(tag, lt, "src"))))
    else if name = "embed"
        addMediaUrl(st, resolveUrl(st.doc.base, decodeEntities(attr(tag, lt, "src"))))
    end if
end sub

sub closeTag(st as object, name as string)
    kind = st.blockKinds[name]
    if kind <> invalid
        flushBlock(st)
        if name = "li" and st.li > 0
            st.li = st.li - 1
        else if name = "blockquote" and st.quote > 0
            st.quote = st.quote - 1
        else if name = "pre" and st.pre > 0
            st.pre = st.pre - 1
        else if (name = "nav" or name = "footer" or name = "aside") and st.chrome > 0
            st.chrome = st.chrome - 1
        else if (name = "main" or name = "article") and st.main > 0
            st.main = st.main - 1
        else if name = "form"
            st.form = -1
        end if
        if kind <> "p" then st.kind = "p"
        return
    end if
    if name = "a"
        st.link = -1
    else if name = "b" or name = "strong"
        if st.bold > 0 then st.bold = st.bold - 1
    else if name = "title"
        st.inTitle = false
    else if name = "button"
        if st.button <> invalid
            label = cleanText(st, st.button.label)
            if label = "" then label = "Go"
            st.button.label = label
            flushBlock(st)
            st.doc.blocks.Push(st.button)
            st.button = invalid
        end if
    else if name = "select"
        if st.select <> invalid
            if st.select.n <> "" and st.select.v <> invalid then st.doc.forms[st.form].hidden.Push({n: st.select.n, v: st.select.v})
            st.select = invalid
        end if
    else if name = "video" or name = "audio"
        st.media = false
    else if name = "picture"
        st.picture = ""
    end if
end sub

sub addText(st as object, t as string)
    if t = "" then return
    if st.inTitle
        st.title = st.title + t
        return
    end if
    if st.select <> invalid or st.hideTag <> "" then return
    if st.button <> invalid
        st.button.label = st.button.label + t
        return
    end if
    if st.pre > 0
        addRun(st, decodeEntities(t))
        return
    end if
    trimmed = t.Trim()
    if trimmed = ""
        st.space = true
        return
    end if
    lead = Left(t, 1) <> Left(trimmed, 1)
    trail = Right(t, 1) <> Right(trimmed, 1)
    trimmed = cleanText(st, trimmed)
    if (lead or st.space) and st.plain <> "" and Right(st.plain, 1) <> Chr(10) then trimmed = " " + trimmed
    st.space = trail
    addRun(st, trimmed)
end sub

' Collapses whitespace and decodes entities.
function cleanText(st as object, t as string) as string
    if Instr(1, t, Chr(10)) > 0 or Instr(1, t, "  ") > 0 or Instr(1, t, Chr(9)) > 0 or Instr(1, t, Chr(13)) > 0
        t = st.ws.ReplaceAll(t, " ")
    end if
    return decodeEntities(t).Trim()
end function

sub addRun(st as object, s as string)
    bold = st.bold > 0
    n = st.runs.Count()
    if n > 0
        last = st.runs[n - 1]
        if last.a = st.link and last.b = bold
            last.s = last.s + s
            st.plain = st.plain + s
            return
        end if
    end if
    st.runs.Push({s: s, a: st.link, b: bold, o: Len(st.plain)})
    st.plain = st.plain + s
end sub

sub flushBlock(st as object)
    if st.runs.Count() = 0 then return
    if st.plain.Trim() = ""
        st.runs = []
        st.plain = ""
        st.space = false
        return
    end if
    kind = st.kind
    if kind = "p"
        if st.quote > 0
            kind = "quote"
        else if st.li > 0
            kind = "lic"
        end if
    end if
    if kind = "li"
        if not st.liFresh then kind = "lic"
        st.liFresh = false
    end if
    block = {k: kind, r: st.runs, t: st.plain}
    if st.chrome > 0 then block.c = true
    if st.main > 0 then block.m = true
    st.doc.blocks.Push(block)
    st.runs = []
    st.plain = ""
    st.space = false
end sub

' Value of an attribute, as written (entities still encoded).
function attr(tag as string, lt as string, name as string) as string
    key = name + "="
    from = 1
    i = 0
    while true
        i = Instr(from, lt, key)
        if i <= 1 then return ""
        before = Mid(lt, i - 1, 1)
        if before = " " or before = Chr(10) or before = Chr(9) or before = Chr(13) or before = "/" then exit while
        from = i + 1
    end while
    j = i + Len(key)
    quote = Mid(tag, j, 1)
    if quote = """" or quote = "'"
        e = Instr(j + 1, tag, quote)
        if e = 0 then e = Len(tag) + 1
        return Mid(tag, j + 1, e - j - 1)
    end if
    e = Instr(j, tag, " ")
    if e = 0 then e = Len(tag) + 1
    value = Mid(tag, j, e - j)
    if Right(value, 1) = "/" then value = Left(value, Len(value) - 1)
    return value
end function

sub imageBlock(st as object, tag as string, lt as string)
    if st.images >= 60 then return
    w = Val(attr(tag, lt, "width"))
    h = Val(attr(tag, lt, "height"))
    if (w > 0 and w < 64) or (h > 0 and h < 48) then return
    src = attr(tag, lt, "src")
    if src = "" or Left(src, 5) = "data:"
        for each key in ["data-src", "data-lazy-src", "data-original", "data-url", "data-hi-res-src"]
            src = attr(tag, lt, key)
            if src <> "" then exit for
        end for
    end if
    set = attr(tag, lt, "srcset")
    if set = "" then set = attr(tag, lt, "data-srcset")
    if set <> "" then src = pickSrcset(set, src)
    ' A <picture>'s sources usually include a bigger version than the <img> fallback.
    if st.picture <> "" and (set = "" or src = "" or Left(src, 5) = "data:") then src = st.picture
    if src = "" or Left(src, 5) = "data:" then return
    url = resolveUrl(st.doc.base, decodeEntities(src))
    lower = LCase(urlPath(url))
    if url = "" or Right(lower, 4) = ".svg" or Right(lower, 4) = ".gif" or isTracker(url) then return
    flushBlock(st)
    st.doc.blocks.Push({k: "img", src: url, alt: cleanText(st, decodeEntities(attr(tag, lt, "alt"))), w: w, h: h, a: st.link})
    st.images = st.images + 1
end sub

function isTracker(u as string) as boolean
    host = urlHost(u)
    for each t in ["scorecardresearch.com", "doubleclick.net", "google-analytics.com", "facebook.com", "pixel.", "beacon.", "analytics.", "bat.bing.com", "quantserve.com"]
        if Instr(1, host, t) > 0 then return true
    end for
    return false
end function

' Picks a srcset candidate around 640px wide: sharp on a TV without being huge.
function pickSrcset(set as string, fallback as string) as string
    best = ""
    bestW = 0
    largest = ""
    largestW = 0
    items = set.Split(", ")
    if items.Count() = 1 then items = set.Split(",")
    for each item in items
        item = item.Trim()
        sp = Instr(1, item, " ")
        u = item
        w = 0
        if sp > 0
            u = Left(item, sp - 1)
            d = Mid(item, sp + 1).Trim()
            if LCase(Right(d, 1)) = "w" then w = Val(Left(d, Len(d) - 1))
        end if
        if u <> ""
            if w >= 560 and (best = "" or w < bestW)
                best = u
                bestW = w
            end if
            if w >= largestW
                largest = u
                largestW = w
            end if
        end if
    end for
    if best <> "" then return best
    if largest <> "" then return largest
    return fallback
end function

sub openForm(st as object, tag as string, lt as string)
    action = decodeEntities(attr(tag, lt, "action"))
    url = st.doc.url
    if action <> ""
        resolved = resolveUrl(st.doc.base, action)
        if resolved <> "" then url = resolved
    end if
    method = "get"
    if LCase(attr(tag, lt, "method")) = "post" then method = "post"
    st.doc.forms.Push({action: url, method: method, hidden: []})
    st.form = st.doc.forms.Count() - 1
end sub

sub inputField(st as object, tag as string, lt as string)
    if st.form < 0 then return
    kind = LCase(attr(tag, lt, "type"))
    if kind = "" then kind = "text"
    name = attr(tag, lt, "name")
    value = decodeEntities(attr(tag, lt, "value"))
    form = st.doc.forms[st.form]
    if kind = "hidden"
        if name <> "" then form.hidden.Push({n: name, v: value})
    else if kind = "submit" or kind = "image"
        label = value
        if label = "" then label = decodeEntities(attr(tag, lt, "alt"))
        if label = "" then label = "Go"
        flushBlock(st)
        st.doc.blocks.Push({k: "button", f: st.form, label: label, n: name, v: value})
    else if kind = "checkbox" or kind = "radio"
        if name <> "" and Instr(1, lt, " checked") > 0
            if value = "" then value = "on"
            form.hidden.Push({n: name, v: value})
        end if
    else if kind = "text" or kind = "search" or kind = "email" or kind = "url" or kind = "tel" or kind = "number" or kind = "password"
        hint = attr(tag, lt, "placeholder")
        if hint = "" then hint = attr(tag, lt, "aria-label")
        if hint = "" then hint = attr(tag, lt, "title")
        flushBlock(st)
        st.doc.blocks.Push({k: "input", f: st.form, n: name, v: value, ph: decodeEntities(hint), type: kind})
    end if
end sub

sub textareaField(st as object, tag as string, lt as string)
    if st.form < 0 then return
    flushBlock(st)
    st.doc.blocks.Push({k: "input", f: st.form, n: attr(tag, lt, "name"), v: "", ph: decodeEntities(attr(tag, lt, "placeholder")), type: "textarea"})
end sub

sub metaTag(st as object, tag as string, lt as string)
    prop = LCase(attr(tag, lt, "property"))
    if prop = "" then prop = LCase(attr(tag, lt, "name"))
    if prop = "" then return
    content = decodeEntities(attr(tag, lt, "content"))
    if prop = "og:image" and st.doc.image = ""
        st.doc.image = resolveUrl(st.doc.base, content)
    else if prop = "og:title"
        st.doc.ogTitle = content
    else if (prop = "description" or prop = "og:description") and st.doc.description = ""
        st.doc.description = content
    else if prop = "og:video" or prop = "og:video:url" or prop = "og:video:secure_url"
        addMediaUrl(st, resolveUrl(st.doc.base, content))
    end if
end sub

' Records a playable video: a direct stream, or a YouTube/Dailymotion video.
sub addMediaUrl(st as object, u as string)
    if u = "" then return
    item = invalid
    yt = youtubeId(u)
    dm = dailymotionId(u)
    if yt <> ""
        item = {yt: yt, key: "yt:" + yt}
    else if dm <> ""
        item = {dm: dm, key: "dm:" + dm}
    else
        fmt = mediaFormat(u)
        if fmt <> "" then item = {u: u, fmt: fmt, key: u}
    end if
    if item = invalid then return
    for each v in st.doc.videos
        if v.key = item.key then return
    end for
    st.doc.videos.Push(item)
end sub

sub finishDoc(st as object)
    doc = st.doc
    title = cleanText(st, st.title)
    if title = "" then title = doc.ogTitle
    doc.title = title

    ' When there's a substantial article, leave out the site's navigation and footers.
    mainChars = 0
    for each b in doc.blocks
        if b.m = true and b.t <> invalid then mainChars = mainChars + Len(b.t)
    end for
    if mainChars > 1200
        kept = []
        for each b in doc.blocks
            if b.c <> true or b.m = true then kept.Push(b)
        end for
        doc.blocks = kept
    end if

    for each l in doc.links
        l.u = unwrapRedirect(l.u)
    end for

    ' Videos found on the page go first, as play cards.
    if doc.videos.Count() > 0
        blocks = []
        for i = 0 to doc.videos.Count() - 1
            if i < 3 then blocks.Push({k: "video", v: doc.videos[i], title: doc.title, thumb: doc.image})
        end for
        blocks.Append(doc.blocks)
        doc.blocks = blocks
    end if
end sub

function decodeEntities(s as string) as string
    if Instr(1, s, "&") = 0 then return s
    i = Instr(1, s, "&#")
    guard = 0
    while i > 0 and guard < 400
        semi = Instr(i, s, ";")
        if semi > 0 and semi - i <= 9
            body = Mid(s, i + 2, semi - i - 2)
            code = 0
            if LCase(Left(body, 1)) = "x"
                code = Val(Mid(body, 2), 16)
            else
                code = Val(body)
            end if
            if code = 160 then code = 32
            if code > 0
                s = Left(s, i - 1) + Chr(code) + Mid(s, semi + 1)
            end if
        end if
        i = Instr(i + 1, s, "&#")
        guard = guard + 1
    end while
    if Instr(1, s, "&") = 0 then return s
    for each pair in namedEntities()
        if Instr(1, s, pair[0]) > 0 then s = s.Replace(pair[0], pair[1])
    end for
    return s
end function

function namedEntities() as object
    if m.entities = invalid
        m.entities = [
            ["&nbsp;", " "], ["&lt;", "<"], ["&gt;", ">"], ["&quot;", """"], ["&apos;", "'"],
            ["&mdash;", Chr(8212)], ["&ndash;", Chr(8211)], ["&hellip;", Chr(8230)], ["&rsquo;", Chr(8217)],
            ["&lsquo;", Chr(8216)], ["&rdquo;", Chr(8221)], ["&ldquo;", Chr(8220)], ["&copy;", Chr(169)],
            ["&reg;", Chr(174)], ["&trade;", Chr(8482)], ["&pound;", Chr(163)], ["&euro;", Chr(8364)],
            ["&middot;", Chr(183)], ["&bull;", Chr(8226)], ["&times;", Chr(215)], ["&laquo;", Chr(171)],
            ["&raquo;", Chr(187)], ["&deg;", Chr(176)], ["&eacute;", Chr(233)], ["&egrave;", Chr(232)],
            ["&aacute;", Chr(225)], ["&iacute;", Chr(237)], ["&oacute;", Chr(243)], ["&uacute;", Chr(250)],
            ["&ntilde;", Chr(241)], ["&uuml;", Chr(252)], ["&ouml;", Chr(246)], ["&auml;", Chr(228)],
            ["&szlig;", Chr(223)], ["&ccedil;", Chr(231)], ["&rarr;", Chr(8594)], ["&larr;", Chr(8592)],
            ["&thinsp;", " "], ["&ensp;", " "], ["&emsp;", " "], ["&zwj;", ""], ["&zwnj;", ""], ["&shy;", ""],
            ["&amp;", "&"]
        ]
    end if
    return m.entities
end function
