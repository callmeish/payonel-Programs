local component = require("component")
local event = require("event")
local shell = require("shell")
local ser = require("serialization")
local process = require("process")
local core_lib = require("psh")
local pipes = require("pipes")
local computer = require("computer")
local term = require("term") -- to create a window and inject proxies

local m = component.modem
assert(m)

local lib = {}

function lib.pipeIt(host, command)
  return
    string.format("/usr/bin/psh/psh-reader.lua" .. " %s %i | ", host.remote_id, host.remote_port) ..
    command ..
    string.format(" | " .. "/usr/bin/psh/psh-writer.lua" .. " %s %i", host.remote_id, host.remote_port)
end

function lib.new(host, hostArgs)
  -- we have not yet sent the ACCEPT back to th user
  host.port = hostArgs.port
  host.remote_id = hostArgs.remote_id
  host.remote_port = hostArgs.remote_port
  host.proxies = {}
  host.timeout = 5

  local command = hostArgs.command or ""
  if command == "" then
    command = os.getenv("SHELL")
  end
  host.command = command

  host.send = function(...) return m.send(host.remote_id, host.remote_port, ...) end
  -- TODO build remote proxies for gpu (and screen and keyboard?)
  host.output = function(...) return host.send(core_lib.api.OUTPUT, ...) end

  function host.applicable(meta)
    if not host.pco then
      core_lib.log.debug(host.lanel, "dead host got message")
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

  function host.set_meta(name, key, type, storage, ...)
    local initial_value = ...
    -- nil: call and return empty
    -- false: call and do not cache
    -- true: call and cache
    local meta =
    {
      key=key,
      type=type,
      storage=storage,
      value=initial_value,
      is_cached=storage and select('#', ...) > 0,
    }

    local proxy = host.proxy(name) -- creates on first call
    local mt = getmetatable(proxy)

    mt.meta[key] = meta
    return meta
  end

  function host.get_meta(name, key)
    local timeout = computer.uptime() + host.timeout
    local proxy = host.proxy(name)
    -- send request for meta
    host.send(core_lib.api.PROXY_META, name, key)
    core_lib.log.debug("meta request",name,key,debug.traceback())

    -- keyboard requests shouldn't fire indefinitely
    if name == "window" and key == "keyboard" then
      return host.set_meta(name, key, "string", true, "")
    end

    -- now wait for it
    while true do
      local ok, why = pcall(event.pull, 0)
      local mt = getmetatable(proxy)
      local meta = mt.meta[key]
      if meta then
        return meta
      elseif timeout < computer.uptime() then
        core_lib.log.debug(host.label,"timed out waiting for proxy metadata")
        host.close_msg = "Timed out waiting for proxy data about " .. name .. "." .. key
        host.stop()
        os.exit(1)
      end
    end
  end

  function host.proxy_index(proxy, key)
    local mt = getmetatable(proxy)
    local meta = mt.meta[key]
    if not meta then
      meta = host.get_meta(mt.name, key)
    end

    local callback = function(...)
      if not meta.is_cached then
        -- send proxy call
        --[[ proxy call ]]

        if meta.storage == nil then -- nothing else to do
          return
        end

        -- wait for result
        --[[ wait for proxy result ]]
        meta.value = false

        meta.is_cached = meta.storage
      end
      return meta.value
    end

    if meta.type == "function" then
      return callback
    else
      return callback()
    end
  end

  function host.proxy(name, base)
    -- there might already be metadata for this proxy object
    local proxy = host.proxies[name]
    local mt = proxy and getmetatable(proxy) or
    {
      name = name,
      meta = {},
      __index = host.proxy_index,
    }
    proxy = base or proxy or {}
    host.proxies[name] = setmetatable(proxy, mt)
    return proxy
  end

  function host.proc_init(...)
    -- we are now in our process!
    -- finally, tell the client we are ready for events
    core_lib.log.debug("sending accept: " .. tostring(host.remote_id) ..",".. tostring(host.remote_port) ..",".. core_lib.api.ACCEPT)
    m.send(host.remote_id, host.remote_port, core_lib.api.ACCEPT, host.port)

    -- create custom term window
    local window = host.proxy("window", term.internal.open())
    window.gpu = host.proxy("gpu")

    process.info().data.window = window
    term.setViewport(window.gpu.getViewport())

    core_lib.log.debug(host.label, "proc_init done")

    return ...
  end

  -- proc is the thread proc of this host
  function host.proc()
    core_lib.log.debug(host.label, "proc started")
    return shell.execute(host.command)
  end

  function host.pull(timeout)
    -- this is the fake computer.pullSignal during host process
    -- timeout is the expected sleep time
    -- and we should return an actual unpacked event signal

    -- wake us back up at least in timeout seconds
    event.timer(timeout, host.resume)

    local signal = table.pack(host.pco.yield_all())

    return table.unpack(signal, 1, signal.n)
  end

  function host.pco_status()
    if not host.pco or #host.pco.stack == 0 then
      return "dead"
    end
    return host.pco.status(host.pco.top())
  end

  function host.can_proxy()
    return host.screen and host.keyboard and host.viewport
  end

  -- resume is called as event tick
  function host.resume()
    -- we may have died (or been killed?) since the last resume
    if not host.pco then -- race condition?
      core_lib.log.debug(host.label, "potential race condition, host resumed after stop")
      return
    end

    if host.pco_status() == "dead" then
      core_lib.log.debug(host.label, "potential race condition, host resumed after thread dead")
      host.close_msg = "Aborted: thread died"
      host.stop()
      return
    end

    -- sanity check before we lose computer.pullSignal and the current coroutine lib
    local sig = event.current_signal
    assert(type(sig) == "table" and sig.n, "event signal missing, cannot resume host")

    -- intercept all future computer.pullSignals (it should actually yield_all)
    local _pull = computer.pullSignal

    computer.pullSignal = host.pull
    host.pco.resume_all(table.unpack(sig, 1, sig.n)) -- should be safe, resume_all pcalls unsafe code
    computer.pullSignal = _pull

    if host.pco_status() == "dead" then
      core_lib.log.debug(host.label, "host closing")
      host.stop()
      return
    end

    return true
  end

  function host.vstart()
    if host.pco then
      return false, "host is already started"
    end

    -- all we need is a thread
    -- but in order to invoke custom thread coroutines, we need a process
    -- not to worry, pipes.internal.create can create processes
    host.pco = pipes.internal.create(host.proc, host.proc_init, host.label)

    -- resume thread on next tick (single timer)
    event.timer(0, host.resume)
  end

  function host.vstop()
    if not host.pco then
      return false, "host is not started"
    end
    host.pco = nil
    m.send(host.remote_id, host.remote_port, core_lib.api.CLOSED, host.close_msg)
  end

  host.tokens[core_lib.api.KEEPALIVE] = function(meta, ...)
    m.send(host.remote_id, host.remote_port, core_lib.api.KEEPALIVE, 10)
    return true
  end

  host.tokens[core_lib.api.PROXY_META] = function(meta, name, key, type, storage, ...)
    core_lib.log.debug(host.label,"proxy meta update", name, key, type, storage, ...)
    host.set_meta(name, key, type, storage, ...)
    return true
  end

  host.tokens[core_lib.api.PROXY] = function(meta, method, ...)
    core_lib.log.debug(host.label,"proxy call", method, ...)
    if method == "screen" then
      host.screen = ...
    elseif method == "keyboard" then
      host.keyboard = ...
    elseif method == "viewport" then
      host.viewport = table.pack(...)
    else end
    return true
  end

  return host
end

return lib