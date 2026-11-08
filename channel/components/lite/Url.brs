' URL helpers shared by the Lite parser and fetcher.

' Resolves href against the page address; "" for anchors and non-web links.
function resolveUrl(base as string, href as string) as string
    h = href.Trim()
    hash = Instr(1, h, "#")
    if hash > 0 then h = Left(h, hash - 1)
    if h = "" then return ""
    lh = LCase(Left(h, 8))
    if Left(lh, 7) = "http://" or lh = "https://" then return h
    if Left(h, 2) = "//"
        if LCase(Left(base, 5)) = "http:" then return "http:" + h
        return "https:" + h
    end if
    colon = Instr(1, h, ":")
    slash = Instr(1, h, "/")
    query = Instr(1, h, "?")
    if colon > 0 and (slash = 0 or colon < slash) and (query = 0 or colon < query) then return ""
    origin = urlOrigin(base)
    if origin = "" then return ""
    if Left(h, 1) = "/" then return origin + h
    path = urlPath(base)
    if Left(h, 1) = "?" then return origin + path + h
    dir = Left(path, lastIndexOf(path, "/"))
    if dir = "" then dir = "/"
    return origin + normalizePath(dir + h)
end function

' "https://host:port" part of a URL.
function urlOrigin(u as string) as string
    sep = Instr(1, u, "://")
    if sep = 0 then return ""
    i = sep + 3
    n = Len(u)
    while i <= n
        c = Mid(u, i, 1)
        if c = "/" or c = "?" or c = "#" then exit while
        i = i + 1
    end while
    return Left(u, i - 1)
end function

' Path of a URL without its query or fragment, always starting with "/".
function urlPath(u as string) as string
    rest = Mid(u, Len(urlOrigin(u)) + 1)
    for each sep in ["?", "#"]
        i = Instr(1, rest, sep)
        if i > 0 then rest = Left(rest, i - 1)
    end for
    if Left(rest, 1) <> "/" then rest = "/" + rest
    return rest
end function

function urlHost(u as string) as string
    o = urlOrigin(u)
    h = LCase(Mid(o, Instr(1, o, "://") + 3))
    colon = Instr(1, h, ":")
    if colon > 0 then h = Left(h, colon - 1)
    if Left(h, 4) = "www." then h = Mid(h, 5)
    return h
end function

' Value of one query parameter, still percent-encoded.
function queryParam(u as string, name as string) as string
    q = Instr(1, u, "?")
    if q = 0 then return ""
    for each pair in Mid(u, q + 1).Split("&")
        eq = Instr(1, pair, "=")
        if eq > 0 and Left(pair, eq - 1) = name then return Mid(pair, eq + 1)
    end for
    return ""
end function

function lastIndexOf(s as string, needle as string) as integer
    last = 0
    i = Instr(1, s, needle)
    while i > 0
        last = i
        i = Instr(i + 1, s, needle)
    end while
    return last
end function

' Collapses "." and ".." segments, keeping any query string.
function normalizePath(p as string) as string
    query = ""
    q = Instr(1, p, "?")
    if q > 0
        query = Mid(p, q)
        p = Left(p, q - 1)
    end if
    out = []
    for each seg in p.Split("/")
        if seg = ".."
            if out.Count() > 1 then out.Pop()
        else if seg <> "."
            out.Push(seg)
        end if
    end for
    joined = out.Join("/")
    if Left(joined, 1) <> "/" then joined = "/" + joined
    if Right(p, 1) = "/" and Right(joined, 1) <> "/" then joined = joined + "/"
    return joined + query
end function

' Decodes %XX escapes (UTF-8 aware); "+" becomes a space when asked.
function percentDecode(s as string, plusIsSpace = false as boolean) as string
    if plusIsSpace then s = s.Replace("+", " ")
    if Instr(1, s, "%") = 0 then return s
    bytes = CreateObject("roByteArray")
    i = 1
    n = Len(s)
    while i <= n
        c = Mid(s, i, 1)
        if c = "%" and i + 2 <= n
            bytes.Push(Val(Mid(s, i + 1, 2), 16))
            i = i + 3
        else
            piece = CreateObject("roByteArray")
            piece.FromAsciiString(c)
            bytes.Append(piece)
            i = i + 1
        end if
    end while
    return bytes.ToAsciiString()
end function

function percentEncode(s as string) as string
    out = ""
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(s)
    for each b in bytes
        if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b = 45 or b = 46 or b = 95 or b = 126
            out = out + Chr(b)
        else if b = 32
            out = out + "+"
        else
            hex = StrI(b, 16)
            if Len(hex) = 1 then hex = "0" + hex
            out = out + "%" + UCase(hex)
        end if
    end for
    return out
end function

' The real target of search-engine redirect links.
function unwrapRedirect(u as string) as string
    if Instr(1, u, "duckduckgo.com/l/?") > 0
        target = queryParam(u, "uddg")
        if target <> "" then return percentDecode(target)
    end if
    return u
end function

' YouTube video id from watch, short, embed or youtu.be addresses; "" otherwise.
function youtubeId(u as string) as string
    host = urlHost(u)
    path = urlPath(u)
    id = ""
    if host = "youtu.be"
        id = Mid(path, 2)
    else if host = "youtube.com" or host = "m.youtube.com" or host = "youtube-nocookie.com" or host = "music.youtube.com"
        if path = "/watch"
            id = queryParam(u, "v")
        else
            for each prefix in ["/shorts/", "/embed/", "/live/", "/v/"]
                if Left(path, Len(prefix)) = prefix then id = Mid(path, Len(prefix) + 1)
            end for
        end if
    end if
    slash = Instr(1, id, "/")
    if slash > 0 then id = Left(id, slash - 1)
    if Len(id) < 6 or Len(id) > 20 then return ""
    return id
end function

' Dailymotion video id from page, embed or dai.ly addresses; "" otherwise.
function dailymotionId(u as string) as string
    host = urlHost(u)
    path = urlPath(u)
    id = ""
    if host = "dai.ly"
        id = Mid(path, 2)
    else if host = "dailymotion.com" or host = "geo.dailymotion.com"
        if Left(path, 7) = "/video/" then id = Mid(path, 8)
        if Left(path, 13) = "/embed/video/" then id = Mid(path, 14)
        if id = "" then id = queryParam(u, "video")
    end if
    for each sep in ["/", "_"]
        i = Instr(1, id, sep)
        if i > 0 then id = Left(id, i - 1)
    end for
    if Len(id) < 5 or Len(id) > 12 then return ""
    return id
end function

' Roku stream format for a media address, or "" if it isn't one.
function mediaFormat(u as string) as string
    p = LCase(urlPath(u))
    for each pair in [[".m3u8", "hls"], [".mpd", "dash"], [".mp4", "mp4"], [".m4v", "mp4"], [".mov", "mp4"], [".mkv", "mkv"], [".mp3", "mp3"], [".m4a", "mp4"], [".aac", "mp4"]]
        if Right(p, Len(pair[0])) = pair[0] then return pair[1]
    end for
    return ""
end function
