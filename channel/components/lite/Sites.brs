' YouTube and Dailymotion for Lite mode. Their web pages are JavaScript apps, so
' Lite mode talks to the same data services their own apps use and builds native
' pages of video cards from the answers.

function youtubePage(url as string) as object
    if urlPath(url) = "/results"
        query = percentDecode(queryParam(url, "search_query"), true)
        if query <> "" then return {doc: youtubeSearch(query, url)}
    end if
    if urlPath(url) <> "/" and urlPath(url) <> "/feed/trending"
        ' Channels and playlists: the YouTube app does those best.
        return {launch: {app: "837"}}
    end if
    doc = videoDoc("YouTube", url, "https://www.youtube.com/results", "search_query", "Search YouTube")
    doc.blocks.Push(heading("h2", "Browse"))
    for each topic in ["Music", "News", "Football highlights", "Gaming", "Comedy", "Science", "Film trailers", "Cooking", "Nature documentaries"]
        doc.links.Push({u: "https://www.youtube.com/results?search_query=" + percentEncode(topic)})
        doc.blocks.Push({k: "tile", title: topic, icon: "", a: doc.links.Count() - 1})
    end for
    doc.blocks.Push({k: "button", f: -1, label: "Open the YouTube app", app: "837"})
    return {doc: doc}
end function

function youtubeSearch(query as string, url as string) as object
    ' Written by hand: FormatJson lower-cases keys, and YouTube needs "clientName".
    body = "{""context"":{""client"":{""clientName"":""MWEB"",""clientVersion"":""2.20251101.01.00"",""hl"":""en"",""gl"":""GB""}},""query"":" + FormatJson(query) + "}"
    t = CreateObject("roTimespan")
    resp = http("https://www.youtube.com/youtubei/v1/search?prettyPrint=false", {type: "application/json", body: body}, "application/json")
    json = invalid
    if resp.code = 200 then json = ParseJson(resp.body)
    doc = videoDoc("YouTube: " + query, url, "https://www.youtube.com/results", "search_query", "Search YouTube")
    doc.blocks[0].v = query
    if json = invalid
        doc.blocks.Push(paragraph("YouTube didn't answer. Try again in a moment."))
        return doc
    end if
    found = []
    findKey(json, "videoWithContextRenderer", found, 0)
    for each v in found
        id = v.videoId
        if id <> invalid
            subtitle = joinParts([runText(v.shortBylineText), runText(v.shortViewCountText), runText(v.publishedTimeText)])
            duration = runText(v.lengthText)
            if duration = "" then duration = "LIVE"
            doc.blocks.Push({k: "card", thumb: "https://i.ytimg.com/vi/" + id + "/mqdefault.jpg", title: runText(v.headline), sub: subtitle, dur: duration, act: {yt: id}})
        end if
    end for
    print "lite: youtube search "; query; " -> "; found.Count(); " videos in "; t.TotalMilliseconds(); " ms"
    if found.Count() = 0 then doc.blocks.Push(paragraph("No videos found."))
    return doc
end function

function dailymotionPage(url as string) as object
    query = ""
    path = urlPath(url)
    if Left(path, 8) = "/search/"
        query = Mid(path, 9)
        slash = Instr(1, query, "/")
        if slash > 0 then query = Left(query, slash - 1)
    end if
    if query = "" then query = queryParam(url, "q")
    query = percentDecode(query, true)
    fields = "id,title,duration,thumbnail_360_url,owner.screenname,views_total"
    api = "https://api.dailymotion.com/videos?limit=30&fields=" + fields
    title = "Dailymotion"
    if query <> ""
        api = api + "&search=" + percentEncode(query)
        title = "Dailymotion: " + query
    else
        country = LCase(CreateObject("roDeviceInfo").GetCountryCode())
        api = api + "&sort=trending&country=" + country
        title = "Dailymotion: trending"
    end if
    doc = videoDoc(title, url, "https://www.dailymotion.com/search", "q", "Search Dailymotion")
    doc.blocks[0].v = query
    resp = http(api, invalid, "application/json")
    json = invalid
    if resp.code = 200 then json = ParseJson(resp.body)
    if json = invalid or json.list = invalid
        doc.blocks.Push(paragraph("Dailymotion didn't answer. Try again in a moment."))
        return {doc: doc}
    end if
    for each v in json.list
        views = ""
        if v.views_total <> invalid then views = shortCount(v.views_total) + " views"
        doc.blocks.Push({k: "card", thumb: v.thumbnail_360_url, title: v.title, sub: joinParts([v["owner.screenname"], views]), dur: clock(v.duration), act: {dm: v.id}})
    end for
    if json.list.Count() = 0 then doc.blocks.Push(paragraph("No videos found."))
    return {doc: doc}
end function

' Dailymotion muxes audio and video into fragmented MP4, and a Roku can't find
' the audio in that. With the laptop around, its roku-browser repackages the
' stream (no re-encoding) so it plays with sound; without it, picture only.
function dailymotionPlay(id as string, helper as dynamic) as object
    if helper <> invalid and helper <> ""
        return {play: {url: helper + "/dailymotion/" + id, format: "hls", title: "Dailymotion", headers: []}}
    end if
    resp = http("https://www.dailymotion.com/player/metadata/video/" + id, invalid, "application/json", true)
    meta = invalid
    if resp.code = 200 then meta = ParseJson(resp.body)
    if meta = invalid then return {notice: "Dailymotion didn't answer. Try again in a moment."}
    if meta.error <> invalid
        reason = "This video can't be played here."
        if type(meta.error) = "roAssociativeArray" and meta.error.title <> invalid then reason = meta.error.title
        return {notice: reason}
    end if
    stream = invalid
    if meta.qualities <> invalid and meta.qualities.auto <> invalid and meta.qualities.auto.Count() > 0 then stream = meta.qualities.auto[0].url
    if stream = invalid then return {notice: "No playable stream for this video."}
    title = meta.title
    if title = invalid then title = "Dailymotion"
    return {play: {url: stream, format: "hls", title: title, headers: []}, notice: "No sound without the laptop: the Roku can't decode Dailymotion's audio by itself."}
end function

' A page with a search box at the top, for the video sites.
function videoDoc(title as string, url as string, action as string, field as string, hint as string) as object
    return {
        title: title, url: url, base: url, links: [], videos: [],
        forms: [{action: action, method: "get", hidden: []}],
        blocks: [{k: "input", f: 0, n: field, v: "", ph: hint, type: "search"}]
    }
end function

function heading(kind as string, text as string) as object
    return {k: kind, r: [{s: text, a: -1, b: false, o: 0}], t: text}
end function

function paragraph(text as string) as object
    return {k: "p", r: [{s: text, a: -1, b: false, o: 0}], t: text}
end function

' Depth-first search for every object stored under `key`.
sub findKey(node as dynamic, key as string, out as object, depth as integer)
    if depth > 24 or out.Count() >= 40 then return
    t = type(node)
    if t = "roAssociativeArray"
        hit = node[key]
        if hit <> invalid
            out.Push(hit)
            return
        end if
        for each k in node
            v = node[k]
            vt = type(v)
            if vt = "roAssociativeArray" or vt = "roArray" then findKey(v, key, out, depth + 1)
        end for
    else if t = "roArray"
        for each v in node
            vt = type(v)
            if vt = "roAssociativeArray" or vt = "roArray" then findKey(v, key, out, depth + 1)
        end for
    end if
end sub

' Text of a YouTube {runs: [...]} or {simpleText: ...} value.
function runText(v as dynamic) as string
    if v = invalid then return ""
    if v.simpleText <> invalid then return v.simpleText
    if v.runs <> invalid
        s = ""
        for each r in v.runs
            if r.text <> invalid then s = s + r.text
        end for
        return s
    end if
    return ""
end function

function joinParts(parts as object) as string
    kept = []
    for each p in parts
        if p <> invalid and p <> "" then kept.Push(p)
    end for
    return kept.Join("  " + Chr(183) + "  ")
end function

function clock(seconds as dynamic) as string
    if seconds = invalid then return ""
    s = Int(seconds)
    h = Int(s / 3600)
    mins = Int((s mod 3600) / 60)
    secs = s mod 60
    mm = mins.toStr()
    ss = secs.toStr()
    if Len(ss) = 1 then ss = "0" + ss
    if h > 0
        if Len(mm) = 1 then mm = "0" + mm
        return h.toStr() + ":" + mm + ":" + ss
    end if
    return mm + ":" + ss
end function

function shortCount(n as dynamic) as string
    if n >= 1000000 then return (Int(n / 100000) / 10).toStr() + "M"
    if n >= 1000 then return Int(n / 1000).toStr() + "K"
    return Int(n).toStr()
end function
