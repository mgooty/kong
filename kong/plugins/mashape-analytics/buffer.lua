-- ALF buffer module
--
-- This module contains a buffered array of ALF objects. When the buffer is full (max number of entries
-- or max payload size), it is converted to a JSON payload and moved to another buffer of payloads to be
-- sent to the server.
--
-- 1 buffer of ALFs (gets flushed once it reached the mmax size)
-- 1 queue of ready-to-be-sent batches which are JSON payloads
--
-- We only remove a payload from the sent queue if it has been correctly received by the socket server.
-- We retry if there is any error during the sending.
-- We run a 'delayed timer' in case no call is received for a while to still flush
-- the buffer and have 'real-time' analytics.
--
-- @see alf_serializer.lua
-- @see handler.lua

local json = require "cjson"
local http = require "resty_http"

local MB = 1024 * 1024
local MAX_BUFFER_SIZE = 1 * MB
local EMPTY_ARRAY_PLACEHOLDER = "__empty_array_placeholder__"
-- Mashape Analytics socket server properties
local ANALYTICS_SOCKET = {
  host = "socket.analytics.mashape.com",
  port = 80,
  path = "/1.0.0/batch"
}

local buffer_mt = {}
buffer_mt.__index = buffer_mt

-- A handler for delayed batch sending. When no call has been made for X seconds
-- (X being conf.delay), we send the batch to keep analytics as close to real-time
-- as possible.
local delayed_send_handler
delayed_send_handler = function(premature, buffer)
  if ngx.now() - buffer.latest_call < buffer.AUTO_FLUSH_DELAY then
    -- If the latest call was received during the wait delay, abort the delayed send and
    -- report it for X more seconds.
    local ok, err = ngx.timer.at(buffer.AUTO_FLUSH_DELAY, delayed_send_handler, buffer)
    if not ok then
      buffer.lock_delayed = false -- re-enable creation of a delayed-timer for this buffer
      ngx.log(ngx.ERR, "[mashape-analytics] failed to create delayed batch sending timer: ", err)
    end
  else
    -- Buffer is not full but it's been too long without an API call, let's flush it
    -- and send the data to analytics.
    buffer:flush()
    buffer.lock_delayed = false
    buffer.send_batch(nil, buffer)
  end
end

-- Instanciate a new buffer with configuration and properties
function buffer_mt.new(conf)
  local buffer = {
    MAX_ENTRIES = conf.batch_size,
    MAX_SIZE = MAX_BUFFER_SIZE,
    AUTO_FLUSH_DELAY = conf.delay,
    entries = {}, -- current buffer as an array of strings (serialized ALFs)
    entries_size = 0, -- current buffer size in bytes
    sending_queue = {}, -- array of constructed payloads (batches of ALFs) to be sent
    lock_sending = false, -- lock if currently sending its data
    lock_delayed = false, -- lock if a delayed timer is already set for this buffer
    latest_call = nil -- date at which a request was last made to this API (for delayed timer)
  }
  return setmetatable(buffer, buffer_mt)
end

-- Add an ALF (already serialized) to the buffer
-- If the buffer is full (max entries or size in bytes), convert the buffer
-- to a JSON payload and place it in an array to be sent, then trigger a sending.
-- If the buffer is not full, start a delayed timer in case no call is received
-- for a while.
function buffer_mt:add_alf(alf)
  -- Keep track of the latest call for the delayed timer
  self.latest_call = ngx.now()

  local str = json.encode(alf)
  str = str:gsub("\""..EMPTY_ARRAY_PLACEHOLDER.."\"", ""):gsub("\\/", "/")

  -- Check what would be the size of the buffer
  local next_n_entries = #self.entries + 1
  local alf_size = string.len(str)

  -- If size or entries exceed the max limits
  local full = next_n_entries > self.MAX_ENTRIES or self:get_size() > self.MAX_SIZE
  if full then
    self:flush()
    -- Batch size reached, let's send the data
    local ok, err = ngx.timer.at(0, self.send_batch, self)
    if not ok then
      ngx.log(ngx.ERR, "[mashape-analytics] failed to create batch sending timer: ", err)
    end
  elseif not self.lock_delayed then
    -- Batch size not yet reached.
    -- Set a timer sending the data only in case nothing happens for awhile or if the batch_size is taking
    -- too much time to reach the limit and trigger the flush.
    local ok, err = ngx.timer.at(self.AUTO_FLUSH_DELAY, delayed_send_handler, self)
    if ok then
      self.lock_delayed = true -- Make sure only one delayed timer is ever pending for a given buffer
    else
      ngx.log(ngx.ERR, "[mashape-analytics] failed to create delayed batch sending timer: ", err)
    end
  end

  -- Insert in entries
  table.insert(self.entries, str)
  -- Update current buffer size
  self.entries_size = self.entries_size + alf_size
end

-- Build a JSON payload of the current buffer.
function buffer_mt:payload_string()
  return "["..table.concat(self.entries, ",").."]"
end

-- Get the size of the current buffer if it was to be converted to a JSON payload
function buffer_mt:get_size()
  local commas = string.rep(",", #self.entries - 1)
  return string.len(commas.."[]") + self.entries_size
end

-- Flush the buffer
-- 1. Convert the content of it into a JSON payload
-- 2. Add the payload to the queue of payloads to be sent
-- 3. Empty the buffer and reset the current buffer size
function buffer_mt:flush()
  local payload = self:payload_string()
  table.insert(self.sending_queue, payload)
  self.entries = {}
  self.entries_size = 0
end

-- Send the oldest payload (batch of ALFs) from the queue to the socket server.
-- The payload will be removed if the socket server acknowledged the batch.
-- If the queue still has payloads to be sent, keep on sending them.
function buffer_mt.send_batch(premature, self)
  if self.lock_sending then return end
  self.lock_sending = true -- simple lock

  if table.getn(self.sending_queue) < 1 then
    return
  end

  -- Let's send the oldest payload in our buffer
  local message = self.sending_queue[1]

  local batch_saved = false
  local client = http:new()
  client:set_timeout(50000) -- 5 sec

  local ok, err = client:connect(ANALYTICS_SOCKET.host, ANALYTICS_SOCKET.port)
  if ok then
    local res, err = client:request({path = ANALYTICS_SOCKET.path, body = message})
    if not res then
      ngx.log(ngx.ERR, "[mashape-analytics] failed to send batch: "..err)
    elseif res.status == 200 then
      batch_saved = true
      ngx.log(ngx.DEBUG, string.format("[mashape-analytics] successfully saved the batch. (%s)", res.body))
    else
      ngx.log(ngx.ERR, string.format("[mashape-analytics] socket server refused the batch. Status: (%s) Error: (%s)", res.status, res.body))
    end

    -- close connection, or put it into the connection pool
    if not res or res.headers["connection"] == "close" then
      ok, err = client:close()
      if not ok then
        ngx.log(ngx.ERR, "[mashape-analytics] failed to close socket: "..err)
      end
    else
      client:set_keepalive()
    end
  else
    ngx.log(ngx.ERR, "[mashape-analytics] failed to connect to the socket server: "..err)
  end

  if batch_saved then
    -- Remove the payload that was sent
    table.remove(self.sending_queue, 1)
  end

  self.lock_sending = false

  -- Keep sendind data if the buffer is not yet emptied
  if #self.sending_queue > 0 then
    local ok, err = ngx.timer.at(0, self.send_batch, self)
    if not ok then
      ngx.log(ngx.ERR, "[mashape-analytics] failed to create batch retry timer: ", err)
    end
  end
end

return buffer_mt
