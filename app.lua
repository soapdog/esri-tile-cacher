#!env tarantool
--
-- Little ESRI Cacher
--
-- Caches tiles from ESRI.
--
-- Author: Andre Alves Garzia <andre@andregarzia.com>
-- Date: 2017-05-17
--
--

box.cfg {
  listen = 3301
}

local fiber = require "fiber"

-- setup database
--
-- Two spaces are created, the hot one which resides on RAM and the cold one
-- is stored on disk.
box.once('init', function()
  print("Creating tiles spaces and indexes...")

  -- create space for "hot" tiles
  box.schema.create_space('tiles_hot')

  box.space.tiles_hot:create_index(
    "primary", {type = 'hash', parts = {1, 'str'}}
  )
  box.space.tiles_hot:create_index(
    "date_created", {type = "tree", parts = {3, 'unsigned'}}
  )

  box.space.tiles_hot:create_index(
    "last_access", {type = "tree", parts = {4, 'unsigned'}}
  )

  -- create space for "cold" tiles
  box.schema.create_space('tiles_cold', {engine = "vinyl"})

  box.space.tiles_cold:create_index(
    "primary", {type = 'tree', parts = {1, 'str'}}
  )
  box.space.tiles_cold:create_index(
    "date_created", {type = "tree", parts = {3, 'unsigned'}}
  )

  box.space.tiles_cold:create_index(
    "last_access", {type = "tree", parts = {4, 'unsigned'}}
  )
end)

-- Saves a tile in the hot storage. Used after fetching it from ArcGIS.
function save_tile(url, tile)
  local t = box.tuple.new({url, tile, os.time(), os.time()})
  box.space.tiles_hot:replace(t)
  print("Saved hot tile for " .. url)
end

-- Fetch a tile from ArcGIS
function get_tile_from_esri(url)
  print("Requesting tile from server...")
  local curl = require "curl"
  local http_client = curl.http()
  local r = http_client:request("GET",url)
  if r.code ~= 200 then
      print('Failed to get tile: ', r.reason)
      return false
  end
  return true, r.body
end

-- This is a very important function.
--
-- It fetches the tile from hot, or if present in cold store, moves it
-- to hot. In both cases the tile is cached and thus returned.
function is_tile_cached(url)

  -- check in the hot tiles
  local tiles = box.space.tiles_hot:select(url)

  if (#tiles > 0) then
    box.space.tiles_hot:update(url, {{"=", 4, os.time()}})
    return tiles[1]
  end

  -- check the cold tiles (slower)
  tiles = box.space.tiles_cold:select(url)

  if (#tiles > 0) then
    -- found in cold storage, move to hot storage...
    local t = box.tuple.new({url, tiles[1][2], tiles[1][3], os.time()})
    box.space.tiles_hot:replace(t)
    box.space.tiles_cold:delete(url)
    return t
  end

  return false
end

-- fetches a tile from storage or ArcGIS. If from ArcGIS then cache.
function get_tile(url)
  local t = is_tile_cached(url)

  if (t) then
    print("Tile is cached for " .. url)
    return t
  end

  local succ, t = get_tile_from_esri(url)

  if succ then
    save_tile(url, t)
    return {true, t}
  end

  return false
end

-- Find what tiles should be moved to cold storage
function collect_cold_tiles()
  local timestamp = os.time() - (60 * 2) -- this is the two minutes treshold.
  local tiles = box.space.tiles_hot.index.last_access:select({timestamp}, {
    iterator = "LT"
  })
  return tiles
end

-- this is the fiber, a cooperative lightweight thread.
--
-- It collects tiles and move them to cold storage. It has a tentative
-- heartbeat of 10 seconds.
function tiles_collector_fiber()
  fiber.name("tiles collector")
  while true do
    local tiles = collect_cold_tiles()
    print(tostring(#tiles) .. " tiles to move to cold storage")
    for _, t in ipairs(tiles) do
      local url = t[1]
      local created = t[3]
      local accessed = t[4]
      local image = t[2]
      local new_t = box.tuple.new({url, image, created, accessed})
      box.space.tiles_cold:replace(new_t)
      box.space.tiles_hot:delete(url)
    end
    report()
    fiber.sleep(10)
  end
end

function report()
  print("HOT - Records: " .. tostring(box.space.tiles_hot:count()) .. " in " .. tostring(box.space.tiles_hot:bsize()) .. " bytes")
  print("COLD - Records: " .. tostring(box.space.tiles_cold:count()) .. " in " .. tostring(box.space.tiles_cold:bsize()) .. " bytes")
end

-- This is the HTTP Request handler, it talks back to whoever called our nanoservice toy
function handler(self)
  local url = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/"
  url = url .. self:stash("num1") .. "/"
  url = url .. self:stash("num2") .. "/"
  url = url .. self:stash("num3")

  print("Received HTTP Request for url " .. url)
  return {
    status = 200,
    headers = {
      ['content-type'] = 'image/jpeg'
    },
    body = get_tile(url)[2]
  }
end

function start_server()
  local httpd = require('http.server').new("0.0.0.0", "8080")

  httpd:route({path = "/ArcGIS/cache/World_Street_Map/:num1/:num2/:num3"}, handler)

  httpd:start()
end

start_server()

local collector = fiber.create(tiles_collector_fiber)

-- this is handy for debugging.
require('console').start()
