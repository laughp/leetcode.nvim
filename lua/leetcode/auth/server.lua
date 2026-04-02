--- Minimal async TCP/HTTP server using vim.loop (libuv).
--- Listens on 127.0.0.1 on an OS-assigned port, waits for a single HTTP
--- GET request, extracts the `cookie` query-parameter, calls `on_cookie`,
--- sends a user-friendly HTML response, then shuts itself down.
---
--- Usage:
---   local server = require("leetcode.auth.server")
---   local port, err = server.start(function(cookie_str, err)
---     ...
---   end)

local uv = vim.loop

---@class lc.auth.Server
local M = {}

-- How long (ms) we wait for the browser callback before giving up.
local TIMEOUT_MS = 5 * 60 * 1000 -- 5 minutes

-- Maximum bytes we will buffer from a single connection before dropping it.
-- A legitimate HTTP request line fits comfortably within 8 KB.
local MAX_BUF = 8 * 1024

--- Generate a cryptographically-adequate random hex nonce.
--- Uses /dev/urandom on Unix; falls back to a time+math.random mix.
---@return string  32 hex characters (128 bits)
local function generate_nonce()
    local f = io.open("/dev/urandom", "rb")
    if f then
        local bytes = f:read(16)
        f:close()
        if bytes and #bytes == 16 then
            return (bytes:gsub(".", function(c)
                return ("%02x"):format(c:byte())
            end))
        end
    end
    -- Fallback (weaker, but better than nothing on non-Unix)
    math.randomseed(os.time() + os.clock() * 1e6)
    local parts = {}
    for _ = 1, 8 do
        parts[#parts + 1] = ("%04x"):format(math.random(0, 0xffff))
    end
    return table.concat(parts)
end

--- Decode %XX percent-encoding (and + as space) in a URL component.
---@param s string
---@return string
local function url_decode(s)
    s = s:gsub("%+", " ")
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

--- Extract a single named query-parameter from a raw query string.
--- e.g. parse_param("foo=bar&baz=qux", "foo") -> "bar"
---@param query string
---@param name  string
---@return string|nil
local function parse_param(query, name)
    -- Match at start, after &, or at start of string
    local pattern = "[?&]?" .. name .. "=([^& \r\n#]*)"
    local val = query:match(pattern)
    if val then
        return url_decode(val)
    end
end

--- Extract the query string from a raw HTTP request line.
--- e.g. "GET /?cookie=abc HTTP/1.1" -> "cookie=abc"
---@param request string  raw bytes received on the socket
---@return string|nil
local function extract_query(request)
    -- First line of the HTTP request: "GET /path?query HTTP/x.x"
    local path = request:match("^GET ([^ \r\n]+)")
    if not path then
        return nil
    end
    return path:match("%?(.+)$") or ""
end

local HTML_SUCCESS = table.concat({
    "HTTP/1.1 200 OK\r\n",
    "Content-Type: text/html; charset=utf-8\r\n",
    "Connection: close\r\n",
    "\r\n",
    "<!DOCTYPE html><html><head>",
    "<meta charset='utf-8'>",
    "<title>LeetCode – Neovim Login</title>",
    "<style>",
    "body{font-family:system-ui,sans-serif;display:flex;align-items:center;",
    "justify-content:center;min-height:100vh;margin:0;background:#1e1e2e;color:#cdd6f4}",
    ".card{background:#313244;border-radius:12px;padding:2rem 3rem;text-align:center;",
    "box-shadow:0 4px 24px #0005}",
    "h1{color:#a6e3a1;margin-bottom:.5rem}p{color:#bac2de}",
    "</style></head><body>",
    "<div class='card'>",
    "<h1>&#10003; Signed in!</h1>",
    "<p>You can close this tab and return to Neovim.</p>",
    "</div></body></html>",
}, "")

local HTML_ERROR = table.concat({
    "HTTP/1.1 400 Bad Request\r\n",
    "Content-Type: text/html; charset=utf-8\r\n",
    "Connection: close\r\n",
    "\r\n",
    "<!DOCTYPE html><html><head>",
    "<meta charset='utf-8'>",
    "<title>LeetCode – Login Error</title>",
    "<style>",
    "body{font-family:system-ui,sans-serif;display:flex;align-items:center;",
    "justify-content:center;min-height:100vh;margin:0;background:#1e1e2e;color:#cdd6f4}",
    ".card{background:#313244;border-radius:12px;padding:2rem 3rem;text-align:center;",
    "box-shadow:0 4px 24px #0005}",
    "h1{color:#f38ba8;margin-bottom:.5rem}p{color:#bac2de}",
    "</style></head><body>",
    "<div class='card'>",
    "<h1>&#10007; Login failed</h1>",
    "<p>No cookie was received. Please try again from Neovim.</p>",
    "</div></body></html>",
}, "")

--- Start the one-shot HTTP callback server.
--- Returns the port and nonce it bound to, or nil + error message.
--- The caller must include `&state=<nonce>` in the URL sent to the browser;
--- the server will reject any callback that omits or mismatches the nonce.
---@param on_cookie fun(cookie: string|nil, err: string|nil)
---@return integer|nil port, string|nil nonce_or_err, string|nil err
function M.start(on_cookie)
    local tcp = uv.new_tcp()
    if not tcp then
        return nil, nil, "failed to create TCP handle"
    end

    -- Bind to a random OS-assigned port on loopback.
    local ok, bind_err = pcall(function()
        tcp:bind("127.0.0.1", 0)
    end)
    if not ok then
        return nil, nil, "TCP bind failed: " .. tostring(bind_err)
    end

    local addr = tcp:getsockname()
    if not addr then
        return nil, nil, "could not determine bound port"
    end
    local port = addr.port

    local nonce = generate_nonce()

    -- Cleanup helper: close the server and cancel the timeout.
    local closed = false
    local timer = uv.new_timer()

    local function shutdown(cookie, err)
        if closed then
            return
        end
        closed = true

        if timer then
            timer:stop()
            if not timer:is_closing() then
                timer:close()
            end
        end
        if not tcp:is_closing() then
            tcp:close()
        end

        vim.schedule(function()
            on_cookie(cookie, err)
        end)
    end

    -- Timeout: fire on_cookie with an error if nothing arrives in time.
    timer:start(TIMEOUT_MS, 0, function()
        shutdown(nil, "Timed out waiting for browser callback")
    end)

    -- cookie_found: once we have successfully parsed a cookie from any
    -- connection, remember it so subsequent connections (favicon, etc.)
    -- don't trigger a false "no cookie" shutdown.
    local cookie_found = nil

    tcp:listen(128, function(listen_err)
        if listen_err then
            shutdown(nil, "Listen error: " .. tostring(listen_err))
            return
        end

        local client = uv.new_tcp()
        if not client then
            return
        end

        tcp:accept(client)

        -- If we already have the cookie, drain and close subsequent connections
        -- (e.g. browser favicon requests) without doing anything further.
        if cookie_found ~= nil then
            client:close()
            return
        end

        local buf = ""
        client:read_start(function(read_err, chunk)
            if read_err or not chunk then
                if not client:is_closing() then
                    client:close()
                end
                return
            end

            buf = buf .. chunk

            -- Guard against slow-drip / oversized requests.
            if #buf > MAX_BUF then
                if not client:is_closing() then
                    client:close()
                end
                return
            end

            -- We only need the first line; wait until we have it.
            if not buf:find("\r\n") then
                return
            end

            -- We have enough; stop reading immediately.
            client:read_stop()

            local query = extract_query(buf)
            local cookie = query and parse_param(query, "cookie")
            local state  = query and parse_param(query, "state")

            -- Reject any request that doesn't carry the correct nonce.
            -- This prevents other browser tabs from injecting a fake cookie.
            if state ~= nonce then
                client:write(HTML_ERROR, function()
                    if not client:is_closing() then
                        client:close()
                    end
                end)
                return
            end

            if cookie then
                -- Mark as found so any racing connections are discarded.
                cookie_found = cookie
                client:write(HTML_SUCCESS, function()
                    if not client:is_closing() then
                        client:close()
                    end
                    shutdown(cookie, nil)
                end)
            else
                -- This connection has no cookie (could be a pre-flight or
                -- favicon fetch that raced ahead). Reply and keep waiting.
                client:write(HTML_ERROR, function()
                    if not client:is_closing() then
                        client:close()
                    end
                end)
            end
        end)
    end)

    return port, nonce, nil
end

return M
