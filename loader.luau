local url = "https://raw.githubusercontent.com/IDLEGLANCE/Forest-Control/main/Forest-Control-Gen2.luau?v=" .. tostring(os.time())
local fetch = request or http_request or (syn and syn.request)
local source
if type(fetch) == "function" then
    local ok, response = pcall(fetch, { Url = url, Method = "GET", Headers = { ["Cache-Control"] = "no-cache", Pragma = "no-cache" } })
    if ok and type(response) == "table" and response.StatusCode == 200 and type(response.Body) == "string" then source = response.Body end
end
source = source or game:HttpGet(url)
local fn, reason = loadstring(source)
assert(fn, reason)
fn()
