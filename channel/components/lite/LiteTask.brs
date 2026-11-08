' Loads pages for Lite mode on a background thread and turns them into documents.
' Video sites whose pages need JavaScript go through their data APIs instead, so
' they can still be searched and played: YouTube results open in the YouTube app,
' Dailymotion videos play in the Roku's own player.

sub init()
    m.top.functionName = "work"
end sub

sub work()
    port = CreateObject("roMessagePort")
    m.top.observeField("request", port)
    m.http = newTransfer()
    while true
        msg = wait(0, port)
        if type(msg) = "roSGNodeEvent"
            req = msg.getData()
            if req <> invalid and req.url <> invalid
                result = load(req)
                result.id = req.id
                if result.url = invalid then result.url = req.url
                m.top.result = result
            end if
        end if
    end while
end sub

function userAgent() as string
    return "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"
end function

' One transfer object for the whole session, so cookies carry between pages.
function newTransfer() as object
    x = CreateObject("roUrlTransfer")
    x.SetCertificatesFile("common:/certs/ca-bundle.crt")
    x.InitClientCertificates()
    x.EnableEncodings(true)
    x.EnableCookies()
    x.RetainBodyOnError(true)
    x.SetMessagePort(CreateObject("roMessagePort"))
    return x
end function

' asRoku: send the Roku's own user agent. Some CDNs refuse a Roku that claims to be Chrome.
function http(url as string, post = invalid as dynamic, accept = "text/html,application/xhtml+xml,*/*;q=0.8" as string, asRoku = false as boolean) as object
    x = m.http
    if asRoku
        ' A plain request, as the Roku's video player makes them: no client certificate.
        x = CreateObject("roUrlTransfer")
        x.SetCertificatesFile("common:/certs/ca-bundle.crt")
        x.EnableCookies()
        x.RetainBodyOnError(true)
        x.SetMessagePort(CreateObject("roMessagePort"))
    end if
    x.SetUrl(url)
    headers = {"Accept-Language": "en-GB,en;q=0.8", "Accept": accept}
    if not asRoku then headers["User-Agent"] = userAgent()
    ' As the Roku itself (like its video player): no extra headers or compression.
    if asRoku then headers = {}
    ' The content type has to be part of the initial headers; added later, the
    ' Roku's own form-encoded default wins and JSON APIs reject the request.
    if post <> invalid then headers["Content-Type"] = post.type
    x.SetHeaders(headers)
    ok = false
    if post = invalid
        x.SetRequest("GET")
        ok = x.AsyncGetToString()
    else
        x.SetRequest("POST")
        ok = x.AsyncPostFromString(post.body)
    end if
    if not ok then return {code: 0, body: "", headers: {}, error: "couldn't start the request"}
    msg = wait(25000, x.GetMessagePort())
    if type(msg) <> "roUrlEvent"
        x.AsyncCancel()
        return {code: 0, body: "", headers: {}, error: "the site took too long to answer"}
    end if
    headers = msg.GetResponseHeaders()
    if headers = invalid then headers = {}
    return {code: msg.GetResponseCode(), body: msg.GetString(), headers: headers, error: msg.GetFailureReason()}
end function

function load(req as object) as object
    url = req.url
    if req.dm <> invalid then return dailymotionPlay(req.dm, req.helper)

    yt = youtubeId(url)
    if yt <> "" then return {launch: {app: "837", contentId: yt, mediaType: "movie"}}
    host = urlHost(url)
    if host = "youtube.com" or host = "m.youtube.com" then return youtubePage(url)
    if host = "dailymotion.com" or host = "dai.ly"
        dm = dailymotionId(url)
        if dm <> "" then return dailymotionPlay(dm, req.helper)
        return dailymotionPage(url)
    end if
    fmt = mediaFormat(url)
    if fmt <> "" then return {play: {url: url, format: fmt, title: Mid(urlPath(url), lastIndexOf(urlPath(url), "/") + 1), headers: []}}

    t = CreateObject("roTimespan")
    resp = http(url, req.post)
    fetchMs = t.TotalMilliseconds()
    if resp.code < 200 or resp.code >= 400
        reason = resp.error
        if resp.code > 0 then reason = "The site answered with error " + resp.code.toStr() + "."
        if reason = "" or reason = invalid then reason = "Check the address, or try again."
        return {doc: messageDoc(url, "Couldn't open this page", reason)}
    end if
    ctype = resp.headers["content-type"]
    if ctype = invalid then ctype = ""
    ctype = LCase(ctype)
    if Instr(1, ctype, "image/") > 0
        return {doc: {title: urlHost(url), url: url, base: url, links: [], forms: [], videos: [], blocks: [{k: "img", src: url, alt: "", w: 0, h: 0, a: -1}]}}
    end if
    if Instr(1, ctype, "video/") > 0 or Instr(1, ctype, "audio/") > 0 or Instr(1, ctype, "mpegurl") > 0
        fmt = "mp4"
        if Instr(1, ctype, "mpegurl") > 0 then fmt = "hls"
        return {play: {url: url, format: fmt, title: urlHost(url), headers: []}}
    end if
    if ctype <> "" and Instr(1, ctype, "html") = 0 and Instr(1, ctype, "text/plain") = 0 and Instr(1, ctype, "xml") = 0
        return {doc: messageDoc(url, "This is a file, not a page", "Lite mode can only show web pages, pictures and videos.")}
    end if
    t.Mark()
    doc = htmlToDoc(resp.body, url)
    print "lite: "; url; " fetched "; Len(resp.body); " chars in "; fetchMs; " ms, parsed "; doc.blocks.Count(); " blocks in "; t.TotalMilliseconds(); " ms"
    chars = 0
    for each blk in doc.blocks
        if blk.t <> invalid then chars = chars + Len(blk.t)
    end for
    if doc.blocks.Count() = 0 or (chars < 400 and doc.videos.Count() = 0)
        ' Script-built sites only send "enable JavaScript" text without it.
        note = "This site is built with JavaScript, which Lite mode doesn't run. With roku-browser on your laptop, the full browser shows it as on a computer."
        doc.blocks.Push({k: "hr"})
        doc.blocks.Push({k: "caption", r: [{s: note, a: -1, b: false, o: 0}], t: note})
    end if
    return {doc: doc}
end function

function messageDoc(url as string, title as string, text as string) as object
    return {
        title: title, url: url, base: url, links: [{u: url}], forms: [], videos: [],
        blocks: [
            {k: "h1", r: [{s: title, a: -1, b: false, o: 0}], t: title},
            {k: "p", r: [{s: text, a: -1, b: false, o: 0}], t: text},
            {k: "p", r: [{s: "Try again", a: 0, b: false, o: 0}], t: "Try again"}
        ]
    }
end function
