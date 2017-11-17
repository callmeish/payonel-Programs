local component = require("component")
local event = require("event")
local shell = require("shell")
local ser = require("serialization")
local process = require("process")
local core_lib = require("psh")
local thread = require("thread")
local computer = require("computer")
local term = require("term")
local tty = require("tty")
local buffer = require("buffer")

local m = assert(component.modem)

local lib = {}

function lib.new(host, hostArgs)
  -- we have not yet sent the ACCEPT back to th user
  host.port = hostArgs.port
  host.remote_id = hostArgs.remote_id
  host.remote_port = hostArgs.remote_port
  host.proxies = {}
  host.events = {}
  host.timeout = 5
  host.command = hostArgs.command == "" and os.getenv("SHELL") or hostArgs.command
  host.width = hostArgs.width
  host.height = hostArgs.height

  host.send = function(...) return core_lib.send(host.remote_id, host.remote_port, ...) end

  function host.applicable(meta)
    if not host.thread or host.thread:status() == "dead" then
      core_lib.log.error(host.label, "dead host got message")
      return false
    elseif meta.remote_id ~= host.remote_id then
      core_lib.log.debug(host.label, "ignoring msg, wrong id")
      return false
    elseif meta.port ~= host.port then
      core_lib.log.debug(host.label, "ignoring msg, wrong local port")
      return false
    end

    return true
  end

  local function build_invoke(comp, method, skip_self)
    return function(...)
      host.send(core_lib.api.INVOKE, comp, method, select(skip_self and 2 or 1, ...))
    end
  end

  function host.proc(...)
    -- create remote proxies
    local old_gpu = tty.gpu()

    host.window = term.internal.open(0, 0, host.width, host.height)
    process.info().data.window = host.window

    host.gpu = setmetatable({}, {__index=function(tbl, key)
      if key == "getScreen" then
        return function() return host.remote_id end
      end
      return build_invoke("gpu", key)
    end})

    tty.bind(host.gpu)

    host.stream = setmetatable({handle=false}, {__index=function(tbl, key)
      if key == "read" then
        return tty.stream.read
      end
      return build_invoke("stream", key, 2)
    end, __metatable = "file"})

    host.io = {}
    for fh=0,2 do
      local mode = fh == 0 and "r" or "w"
      host.io[fh] = buffer.new(mode, host.stream)
      host.io[fh]:setvbuf("no")
      host.io[fh].tty = true
      host.io[fh].close = host.stream.close
      io.stream(fh, host.io[fh], mode)
    end

    host.send(core_lib.api.ACCEPT, host.port)
    core_lib.log.info("host command starting", host.command)
    return shell.execute(host.command)
  end

  function host.vstart()
    if host.thread then
      return false, "host is already started"
    end

    host.thread = thread.create(host.proc)
  end

  function host.vstop()
    if not host.thread then
      return false, "host is not started"
    end
    if host.thread:status() == "dead" then
      return false, "host is already dead"
    end
    host.thread:kill()
    host.send(core_lib.api.CLOSED, host.close_msg, x, y)
  end

  host.tokens[core_lib.api.KEEPALIVE] = function(meta, ...)
    host.send(core_lib.api.KEEPALIVE, 10)
    return true
  end

  return host
end

return lib
