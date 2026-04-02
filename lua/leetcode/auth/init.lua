--- Browser-based OAuth login for leetcode.nvim.
---
--- Flow (mirrors the VSCode extension's "Web Authorization"):
---
---  1. Start a one-shot local HTTP server on a random loopback port.
---  2. Open the system browser to:
---       https://leetcode.com/authorize-login/http/?path=localhost:<port>
---     LeetCode's server handles the login page; on success it redirects the
---     browser to:
---       http://localhost:<port>?cookie=<url-encoded-cookie-string>
---  3. The local server receives that GET request, extracts the `cookie`
---     query parameter, sends a friendly "You can close this tab" HTML page,
---     then shuts itself down.
---  4. The cookie is passed to `Cookie.set()`, which validates it and writes
---     it to disk, then `cmd.start_user_session()` transitions the UI to the
---     main menu — exactly the same path taken by the manual cookie-paste flow.
---
--- CN support: when `config.is_cn` is true we hit leetcode.cn instead.

local log = require("leetcode.logger")
local config = require("leetcode.config")

---@class lc.auth.Browser
local M = {}

--- Open a URL in the system default browser, cross-platform.
---@param url string
local function open_browser(url)
    if vim.ui and vim.ui.open then
        -- Neovim 0.10+
        vim.ui.open(url)
        return
    end

    local uname = vim.loop.os_uname().sysname
    local cmd

    if uname == "Darwin" then
        cmd = { "open", url }
    elseif uname == "Linux" then
        cmd = { "xdg-open", url }
    else
        -- Windows / WSL fallback
        cmd = { "cmd.exe", "/c", "start", "", url }
    end

    vim.fn.jobstart(cmd, { detach = true })
end

--- Build the authorize-login URL for the given loopback port and nonce.
--- LeetCode's server will redirect to:
---   http://localhost:<port>?cookie=<value>&state=<nonce>
--- after the user signs in. The nonce is verified by the server to prevent
--- other browser tabs from injecting a fake cookie (CSRF).
---@param port integer
---@param nonce string
---@return string
local function auth_url(port, nonce)
    local urls = require("leetcode.api.urls")
    local domain = config.is_cn and "cn" or "com"
    -- append &state=<nonce> so LeetCode passes it back verbatim
    return ("https://leetcode.%s%s&state=%s"):format(
        domain,
        urls.authorize_login:format(port),
        nonce
    )
end

--- Perform browser-based login.
--- `cb` is called with (true) on success or (false) on failure.
---@param cb? fun(success: boolean)
function M.login(cb)
    cb = cb or function() end

    local Spinner = require("leetcode.logger.spinner")
    local sp = Spinner:start("Waiting for browser login")

    local server = require("leetcode.auth.server")

    local port, nonce, start_err = server.start(function(cookie_str, server_err)
        if server_err or not cookie_str then
            local msg = server_err or "No cookie received from browser"
            sp:error("Browser login failed")
            log.error("Browser login failed: " .. msg)
            cb(false)
            return
        end

        -- Hand off to the same cookie-set path used by the manual flow.
        local cookie = require("leetcode.cache.cookie")
        local set_err = cookie.set(cookie_str)

        if set_err then
            sp:error("Sign-in failed")
            log.error("Sign-in failed: " .. set_err)
            cb(false)
            return
        end

        sp:success("Signed in!")
        local cmd = require("leetcode.command")
        cmd.start_user_session()
        cb(true)
    end)

    if not port then
        sp:error("Could not start login server")
        log.error("Could not start login server: " .. (start_err or "unknown error"))
        cb(false)
        return
    end

    local url = auth_url(port, nonce)
    -- Do not log the port or nonce — they are secret for the duration of the flow.
    log.info("Opening browser for LeetCode login…")
    open_browser(url)
end

return M
