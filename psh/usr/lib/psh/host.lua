local shell = require("shell")
local buffer = require("buffer")
local process = require("process")
local psh = require("psh")
local tty = require("tty")
local term = require("term")
local thread = require("thread")
local event = require("event")

local H = {}

local _init_packet_timeout = 5

local parsers = {}

parsers[psh.api.init] = function(packet_label, packet_body)
  assert(packet_label == psh.api.init)
  return {
    command = packet_body.cmd or "/bin/sh",
    timeout = packet_body.timeout or _init_packet_timeout,
    X = packet_body.X or false,
    buffer = "",
    [0] = packet_body[0],
    [1] = packet_body[1],
    [2] = packet_body[2]
  }
end

local stream_base = {
  write = function(self, ...)
    if self.closed then return nil, "closed" end
    local buf = table.concat({...})
    return psh.push(self.socket, psh.api.io, {[self.id] = buf})
  end,
  read = function(self)
    if self.closed then return nil, "closed" end
    -- sh input sets the cursor, without sy,tails
    -- and then tty write expects it
    -- it's a dumb mistake, so we set sy and tails here to be safe
    local cursor = tty.window.cursor
    if cursor then
      cursor.sy = cursor.sy or 0
      cursor.tails = cursor.tails or {}
    end

    if self.context.buffer == "" then
      event.pull(0)
    end

    local buf = self.context.buffer
    self.context.buffer = ""
    if not buf then
      return false, "interrupted"
    end

    return buf
  end,
  close = function(self)
    self.closed = true
  end
}

local function new_stream(socket, context, id)
  local stream = {
    socket = socket,
    context = context,
    id = id
  }

  setmetatable(stream, {__index=stream_base})

  local bs = buffer.new("rw", stream)
  bs.tty = context[id]
  bs:setvbuf("no")
  process.closeOnExit(bs)

  context.io = context.io or {}
  context.io[id] = bs

  return bs
end

local function new_gpu(socket, context)
  local gpu = {}
  context.screen = string.format("remote:screen:%s", socket.remote_id)
  context.keyboard = string.format("remote:keyboard:%s", socket.remote_id)

  function gpu.getScreen()
    return context.screen
  end

  function gpu.getViewport()
    tty.window.keyboard = context.keyboard
    if not gpu.width then
      gpu.width, gpu.height = table.unpack(context[1] or {0,0})
    end
    return gpu.width, gpu.height
  end

  function gpu.copy(...)
    -- 1, 25, 80, 0, 0, -24
  end

  function gpu.fill(...)
    -- 1, 1, 80, 24, " "
  end

  return gpu
end

local function socket_handler(socket, context)
  while socket:wait(0) do
    local eType, packet = psh.pull(socket, context.timeout)
    if packet then
      if eType == psh.api.io then
        local input = packet[0] -- stdin
        if input ~= nil then -- false is valid
          if input == 0 then -- 0 is an encoded nil
            context.io[0]:close()
          elseif input == false then -- input is not closed, just interrupted
            context.buffer = false
          elseif type(input) == "string" then
            -- return input
            context.buffer = (context.buffer or "")  .. input
          end
        end
      elseif eType == psh.api.hint then
        local hint = (tty.window.cursor or {}).hint
        if hint then
          log("hint",
            packet[1],
            packet[2],
            hint(packet[1], packet[2])
          )
        end
      end
    end
  end
end

function H.run(socket)
  local ok = pcall(function()
    if not socket:wait(_init_packet_timeout) then
      return -- host timed out
    end
    -- the socket connection hasn't proven it is for psh
    -- though it is using psh.sockets
    -- give it time to provide the init packet to establish a psh session
    local context = parsers[psh.api.init](psh.pull(socket, _init_packet_timeout))

    for i=0,2 do
      if context[i] ~= nil then
        io.stream(i, new_stream(socket, context, i))
      else
        io.stream(i):close()
      end
    end

    local handler_thread = thread.create(socket_handler, socket, context)
    local cmd_thread = thread.create(function()
      local window = term.internal.open()
      window.keyboard = context.keyboard
      process.info().data.window = window
      term.bind(new_gpu(socket, context))
  
      shell.getShell()(nil, context.command)
    end)

    thread.waitForAny({handler_thread, cmd_thread})
    handler_thread:kill()
    cmd_thread:kill()
  end)

  if not ok then
    event.push("host_crashed", socket:remote_address(), socket:id())
  end

  socket:close()
end

return H
