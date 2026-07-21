--[[
	NEON MERGE 2048 v3 — sunucu (ServerScriptService > Script)

	SUNUCU-OTORITER CEKIRDEK: oyun mantigi (slide/merge/spawn/skor/coin) sunucuda
	simule edilir. Istemci hamle yonu gonderir, ayni deterministik simulasyonu
	gorsel icin lokal oynatir; para/skor/kayit otoritesi sunucudur.

	Protokol:
	- NM_GetData (RemoteFunction) : giriste tam durum (coins, best, tema, upgrade'ler, run)
	- NM_Move    (RemoteEvent, C->S): hamle yonu ("Up"/"Down"/"Left"/"Right")
	- NM_Act     (RemoteFunction) : new / grid / undo / buy / theme / top
	- NM_Sync    (RemoteEvent, S->C): over (coin odulu) / win / resync (uyumsuzlukta tam durum)

	Determinizm: spawn = Random.new(seed + spawnIndex * 7919). Istemci ve sunucu
	ayni seed/sayacla ayni spawn'i uretir; CORE SIM blogu iki dosyada birebir aynidir.

	Kayit: DataStore "NeonMerge2048Save_v1" (schema=2, eski kayitlar migrate edilir),
	leaderboard OrderedDataStore "NeonMerge2048Top_v1".
	NOT: MainGame.client.lua ile birlikte guncelle.
]]

local DataStoreService  = game:GetService("DataStoreService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local STORE_NAME        = "NeonMerge2048Save_v1"
local TOP_STORE_NAME    = "NeonMerge2048Top_v1"
local AUTOSAVE_INTERVAL = 30
local MIN_WRITE_GAP     = 6
local MAX_SCORE         = 40_000_000
local MAX_COINS         = 1_000_000_000
local TOP_CACHE_SECONDS = 60

local store    = DataStoreService:GetDataStore(STORE_NAME)
local topStore = DataStoreService:GetOrderedDataStore(TOP_STORE_NAME)

-- ========================================================================
-- MAGAZA KATALOGU (istemciyle birebir ayni tutulmali)
-- ========================================================================
local SHOP = {
	{ id = "spawn", max = 5, costs = { 50, 100, 200, 400, 800 } },   -- 4 sansi +%10/sv, sv4+ 8 sansi
	{ id = "start", max = 3, costs = { 150, 400, 1000 } },           -- run basi hazir tile 8/16/32
	{ id = "undo",  max = 3, costs = { 100, 300, 700 } },            -- run basina geri alma hakki
	{ id = "coin",  max = 4, costs = { 200, 500, 1200, 2500 } },     -- coin kazanci +%25/sv
	{ id = "grid5", max = 1, costs = { 3000 } },                     -- 5x5 tahta kilidi
}
local SHOP_BY_ID = {}
for _, item in ipairs(SHOP) do SHOP_BY_ID[item.id] = item end

local function tileBonus(maxTile)
	if maxTile >= 4096 then return 400
	elseif maxTile >= 2048 then return 150
	elseif maxTile >= 1024 then return 60
	elseif maxTile >= 512 then return 25
	elseif maxTile >= 256 then return 10 end
	return 0
end

local function coinsForRun(score, maxTile, coinLv)
	local base = math.floor(score / 100) + tileBonus(maxTile)
	return math.floor(base * (1 + 0.25 * coinLv))
end

-- ========================================================================
-- CORE SIM (istemci ile birebir ayni tutulmali)
-- ========================================================================
local DIRECTIONS = {
	Left  = function(i, n) local t = {} for j = 1, n do t[j] = { i, j } end return t end,
	Right = function(i, n) local t = {} for j = 1, n do t[j] = { i, n - j + 1 } end return t end,
	Up    = function(i, n) local t = {} for j = 1, n do t[j] = { j, i } end return t end,
	Down  = function(i, n) local t = {} for j = 1, n do t[j] = { n - j + 1, i } end return t end,
}

local function newBoard(n)
	local b = {}
	for r = 1, n do
		b[r] = {}
		for c = 1, n do b[r][c] = 0 end
	end
	return b
end

local function deepCopy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = deepCopy(v) end
	return out
end

-- Tek satiri hareket yonune sikistir + birlestir; srcMap animasyon icin kaynak indeksleri
local function processLine(line)
	local n = #line
	local vals = {}
	for idx, v in ipairs(line) do
		if v ~= 0 then table.insert(vals, { v = v, src = idx }) end
	end
	local out, mergedAt, srcMap, gained = {}, {}, {}, 0
	local i = 1
	while i <= #vals do
		local cur, nxt = vals[i], vals[i + 1]
		if nxt and cur.v == nxt.v then
			table.insert(out, cur.v * 2)
			mergedAt[#out] = true
			srcMap[#out] = { cur.src, nxt.src }
			gained += cur.v * 2
			i += 2
		else
			table.insert(out, cur.v)
			srcMap[#out] = { cur.src }
			i += 1
		end
	end
	while #out < n do table.insert(out, 0) end
	return out, mergedAt, srcMap, gained
end

-- board'u yerinde degistirir; changed, kazanilan skor, anim listesi, merge popSet dondurur
local function simMove(board, n, dir)
	local coordFn = DIRECTIONS[dir]
	local changed = false
	local gainedTotal = 0
	local anims = {}
	local popSet = {}
	for i = 1, n do
		local coords = coordFn(i, n)
		local line = {}
		for j, rc in ipairs(coords) do line[j] = board[rc[1]][rc[2]] end
		local out, mergedAt, srcMap, gained = processLine(line)
		gainedTotal += gained
		for j, rc in ipairs(coords) do
			if out[j] ~= line[j] then changed = true end
			if srcMap[j] then
				for _, src in ipairs(srcMap[j]) do
					local s = coords[src]
					table.insert(anims, {
						fr = s[1], fc = s[2], tr = rc[1], tc = rc[2],
						v = line[src], merged = mergedAt[j] or false,
					})
				end
				if mergedAt[j] then popSet[rc[1] .. "_" .. rc[2]] = true end
			end
			board[rc[1]][rc[2]] = out[j]
		end
	end
	return changed, gainedTotal, anims, popSet
end

-- Deterministik spawn: ayni seed + spawnIndex her iki tarafta ayni sonucu verir
local function spawnTile(board, n, seed, spawnIndex, spawnLv)
	local empties = {}
	for r = 1, n do
		for c = 1, n do
			if board[r][c] == 0 then table.insert(empties, { r, c }) end
		end
	end
	if #empties == 0 then return nil end
	local rng = Random.new(seed + spawnIndex * 7919)
	local pick = empties[rng:NextInteger(1, #empties)]
	local fourChance = math.min(0.1 + 0.1 * spawnLv, 0.6)
	local eightChance = 0.05 * math.max(0, spawnLv - 3)
	local roll = rng:NextNumber()
	local v = 2
	if roll < eightChance then v = 8
	elseif roll < eightChance + fourChance then v = 4 end
	board[pick[1]][pick[2]] = v
	return pick[1], pick[2], v
end

local function hasMoves(board, n)
	for r = 1, n do
		for c = 1, n do
			local v = board[r][c]
			if v == 0 then return true end
			if c < n and board[r][c + 1] == v then return true end
			if r < n and board[r + 1][c] == v then return true end
		end
	end
	return false
end

local function boardMax(board, n)
	local m = 0
	for r = 1, n do
		for c = 1, n do
			if board[r][c] > m then m = board[r][c] end
		end
	end
	return m
end
-- ==================== CORE SIM SONU ====================

-- ========================================================================
-- Dogrulama
-- ========================================================================
local VALID_TILE = { [0] = true }
do
	local v = 2
	while v <= 1048576 do VALID_TILE[v] = true v *= 2 end
end

local function sanitizeBoard(b, n)
	if type(b) ~= "table" then return nil end
	local out = {}
	for r = 1, n do
		if type(b[r]) ~= "table" then return nil end
		out[r] = {}
		for c = 1, n do
			local v = b[r][c]
			if type(v) ~= "number" or not VALID_TILE[v] then return nil end
			out[r][c] = v
		end
	end
	return out
end

local function sanitizeNumber(s, cap)
	if type(s) ~= "number" or s ~= s or s < 0 then return nil end
	return math.min(math.floor(s), cap)
end

local function sanitizeUp(up)
	local out = {}
	for _, item in ipairs(SHOP) do
		local lv = (type(up) == "table") and up[item.id] or 0
		if type(lv) ~= "number" or lv ~= lv then lv = 0 end
		out[item.id] = math.clamp(math.floor(lv), 0, item.max)
	end
	return out
end

-- ========================================================================
-- Oturum ve run yonetimi
-- ========================================================================
local sessions = {}   -- [player] = { data, loaded, dirty, lastWrite, topWritten }

local function defaultData()
	return {
		schema = 2,
		coins = 0,
		best = 0,
		theme = "Light",
		up = sanitizeUp(nil),
		run = nil,
	}
end

local function startRun(data, size)
	local seed = Random.new():NextInteger(1, 1_000_000_000)
	local board = newBoard(size)
	local spawns = 0
	spawnTile(board, size, seed, spawns, data.up.spawn) spawns += 1
	spawnTile(board, size, seed, spawns, data.up.spawn) spawns += 1
	if data.up.start > 0 then
		-- Head Start: bos bir kareye 8/16/32 yerlestir (spawn sayacini tuketir)
		local rng = Random.new(seed + spawns * 7919)
		local empties = {}
		for r = 1, size do
			for c = 1, size do
				if board[r][c] == 0 then table.insert(empties, { r, c }) end
			end
		end
		if #empties > 0 then
			local pick = empties[rng:NextInteger(1, #empties)]
			board[pick[1]][pick[2]] = 2 ^ (2 + data.up.start)
		end
		spawns += 1
	end
	return {
		board = board, score = 0, seed = seed, spawns = spawns,
		size = size, undoLeft = data.up.undo, won = false, over = false,
		prevBoard = nil, prevScore = 0,
	}
end

-- Istemciye gonderilecek durum (undo snapshot'i haric)
local function publicState(data)
	local run = data.run
	return {
		coins = data.coins,
		best = data.best,
		theme = data.theme,
		up = deepCopy(data.up),
		run = run and {
			board = deepCopy(run.board),
			score = run.score, seed = run.seed, spawns = run.spawns,
			size = run.size, undoLeft = run.undoLeft,
			won = run.won, over = run.over,
		} or nil,
	}
end

-- ========================================================================
-- Leaderboard
-- ========================================================================
local topCache = { time = -math.huge, list = {} }
local nameCache = {}

local function writeTop(userId, value)
	pcall(function()
		topStore:SetAsync(tostring(userId), value)
	end)
end

local function fetchTop()
	if os.clock() - topCache.time < TOP_CACHE_SECONDS then
		return topCache.list
	end
	topCache.time = os.clock()
	local ok, pages = pcall(function()
		return topStore:GetSortedAsync(false, 10)
	end)
	if ok then
		local list = {}
		for _, entry in ipairs(pages:GetCurrentPage()) do
			local uid = tonumber(entry.key)
			local name = nameCache[uid]
			if not name and uid then
				local okN, n = pcall(function()
					return Players:GetNameFromUserIdAsync(uid)
				end)
				name = okN and n or "?"
				nameCache[uid] = name
			end
			table.insert(list, { name = name or "?", score = entry.value })
		end
		topCache.list = list
	end
	return topCache.list
end

-- Run biter: coin odulu + best + leaderboard. Kazanilan coini dondurur.
local function endRun(session, run)
	local data = session.data
	local earned = coinsForRun(run.score, boardMax(run.board, run.size), data.up.coin)
	data.coins = math.min(data.coins + earned, MAX_COINS)
	if run.score > data.best then
		data.best = math.min(run.score, MAX_SCORE)
	end
	session.dirty = true
	return earned
end

local function pushBestToTop(playerObj, session)
	if session.data.best > (session.topWritten or 0) then
		session.topWritten = session.data.best
		local best = session.data.best
		task.spawn(writeTop, playerObj.UserId, best)
	end
end

-- ========================================================================
-- DataStore yukle / yaz
-- ========================================================================
local function keyFor(userId)
	return "u_" .. userId
end

local function loadData(userId)
	for attempt = 1, 3 do
		local ok, result = pcall(function()
			return store:GetAsync(keyFor(userId))
		end)
		if ok then
			local data = defaultData()
			if type(result) == "table" then
				if result.schema == 2 then
					data.coins = sanitizeNumber(result.coins, MAX_COINS) or 0
					data.best  = sanitizeNumber(result.best, MAX_SCORE) or 0
					data.theme = (result.theme == "Dark") and "Dark" or "Light"
					data.up    = sanitizeUp(result.up)
					local run = result.run
					if type(run) == "table" then
						local size = (run.size == 5) and 5 or 4
						local board = sanitizeBoard(run.board, size)
						local score = sanitizeNumber(run.score, MAX_SCORE)
						if board and score and (size == 4 or data.up.grid5 > 0) then
							data.run = {
								board = board, score = score,
								seed = sanitizeNumber(run.seed, 2_000_000_000) or 1,
								spawns = sanitizeNumber(run.spawns, 1_000_000) or 0,
								size = size,
								undoLeft = math.clamp(sanitizeNumber(run.undoLeft, 10) or 0, 0, SHOP_BY_ID.undo.max),
								won = run.won == true,
								over = run.over == true,
								prevBoard = nil, prevScore = 0,
							}
						end
					end
				else
					-- v2 oncesi eski kayit: board/score/best/theme duz alanlardaydi
					data.best  = sanitizeNumber(result.best, MAX_SCORE) or 0
					data.theme = (result.theme == "Dark") and "Dark" or "Light"
					local board = sanitizeBoard(result.board, 4)
					local score = sanitizeNumber(result.score, MAX_SCORE)
					if board and score then
						data.run = {
							board = board, score = score,
							seed = Random.new():NextInteger(1, 1_000_000_000),
							spawns = 0, size = 4, undoLeft = 0,
							won = boardMax(board, 4) >= 2048,
							over = not hasMoves(board, 4),
							prevBoard = nil, prevScore = 0,
						}
					end
				end
			end
			return data
		end
		warn(("[NeonMerge2048] Yukleme denemesi %d basarisiz (%s): %s"):format(attempt, userId, tostring(result)))
		task.wait(attempt)
	end
	return defaultData()
end

local function serializeData(data)
	local run = data.run
	return {
		schema = 2,
		coins = data.coins,
		best = data.best,
		theme = data.theme,
		up = deepCopy(data.up),
		run = run and {
			board = deepCopy(run.board),
			score = run.score, seed = run.seed, spawns = run.spawns,
			size = run.size, undoLeft = run.undoLeft,
			won = run.won, over = run.over,
		} or nil,
	}
end

local function writeData(userId, payload)
	for attempt = 1, 3 do
		local ok, err = pcall(function()
			store:UpdateAsync(keyFor(userId), function()
				return payload
			end)
		end)
		if ok then return true end
		warn(("[NeonMerge2048] Yazma denemesi %d basarisiz (%s): %s"):format(attempt, userId, tostring(err)))
		task.wait(attempt)
	end
	return false
end

local function saveSession(playerObj, session, force)
	if not session or not session.loaded then return end
	if not session.dirty and not force then return end
	local now = os.clock()
	if not force and (now - session.lastWrite) < MIN_WRITE_GAP then return end
	session.lastWrite = now
	session.dirty = false
	writeData(playerObj.UserId, serializeData(session.data))
end

-- ========================================================================
-- Remotes
-- ========================================================================
local GetData = Instance.new("RemoteFunction")
GetData.Name = "NM_GetData"
GetData.Parent = ReplicatedStorage

local Act = Instance.new("RemoteFunction")
Act.Name = "NM_Act"
Act.Parent = ReplicatedStorage

local MoveEvent = Instance.new("RemoteEvent")
MoveEvent.Name = "NM_Move"
MoveEvent.Parent = ReplicatedStorage

local SyncEvent = Instance.new("RemoteEvent")
SyncEvent.Name = "NM_Sync"
SyncEvent.Parent = ReplicatedStorage

-- ========================================================================
-- Oyuncu akisi
-- ========================================================================
local function onPlayerAdded(playerObj)
	local session = { data = nil, loaded = false, dirty = false, lastWrite = 0, topWritten = 0 }
	sessions[playerObj] = session
	session.data = loadData(playerObj.UserId)
	session.topWritten = session.data.best
	session.loaded = true
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, p)
end

local function waitSession(playerObj)
	local session = sessions[playerObj]
	local deadline = os.clock() + 15
	while (not session or not session.loaded) and os.clock() < deadline do
		task.wait(0.1)
		session = sessions[playerObj]
	end
	if session and session.loaded then return session end
	return nil
end

GetData.OnServerInvoke = function(playerObj)
	local session = waitSession(playerObj)
	if not session then
		-- Kayit hala yuklenemedi: istemciye "hazir degil" isareti gonder,
		-- istemci tekrar dener (bu durumda hamleler islenmez, sessiz veri kaybi olmaz)
		return { notReady = true }
	end
	local data = session.data
	if not data.run or data.run.over then
		local size = (data.run and data.run.size) or 4
		if size == 5 and data.up.grid5 < 1 then size = 4 end
		data.run = startRun(data, size)
		session.dirty = true
	end
	return publicState(data)
end

MoveEvent.OnServerEvent:Connect(function(playerObj, dir)
	local session = sessions[playerObj]
	if not session or not session.loaded then return end
	if type(dir) ~= "string" or not DIRECTIONS[dir] then return end
	local data = session.data
	local run = data.run
	if not run or run.over then
		SyncEvent:FireClient(playerObj, { ev = "resync", state = publicState(data) })
		return
	end

	local prevBoard = deepCopy(run.board)
	local prevScore = run.score
	local changed, gained = simMove(run.board, run.size, dir)
	if not changed then return end

	run.prevBoard = prevBoard
	run.prevScore = prevScore
	run.score = math.min(run.score + gained, MAX_SCORE)
	spawnTile(run.board, run.size, run.seed, run.spawns, data.up.spawn)
	run.spawns += 1
	session.dirty = true

	local justWon = false
	if not run.won and boardMax(run.board, run.size) >= 2048 then
		run.won = true
		justWon = true
	end

	if not hasMoves(run.board, run.size) then
		run.over = true
		local earned = endRun(session, run)
		pushBestToTop(playerObj, session)
		SyncEvent:FireClient(playerObj, {
			ev = "over", earned = earned, coins = data.coins, best = data.best,
		})
	elseif justWon then
		SyncEvent:FireClient(playerObj, {
			ev = "win", coins = data.coins, best = data.best,
		})
	end
end)

Act.OnServerInvoke = function(playerObj, req)
	local session = sessions[playerObj]
	if not session or not session.loaded then return { ok = false, err = "loading" } end
	if type(req) ~= "table" or type(req.a) ~= "string" then return { ok = false, err = "bad" } end
	local data = session.data
	local a = req.a

	if a == "new" or a == "grid" then
		local size = (data.run and data.run.size) or 4
		if a == "grid" then
			size = (req.size == 5) and 5 or 4
			if size == 5 and data.up.grid5 < 1 then
				return { ok = false, err = "locked" }
			end
		end
		local earned = 0
		if data.run and not data.run.over and data.run.score > 0 then
			earned = endRun(session, data.run)
			pushBestToTop(playerObj, session)
		end
		data.run = startRun(data, size)
		session.dirty = true
		return { ok = true, earned = earned, state = publicState(data) }

	elseif a == "undo" then
		local run = data.run
		if not run or run.over or run.undoLeft < 1 or not run.prevBoard then
			return { ok = false, err = "no_undo" }
		end
		run.board = run.prevBoard
		run.score = run.prevScore
		run.spawns = math.max(0, run.spawns - 1)
		run.undoLeft -= 1
		run.prevBoard = nil
		session.dirty = true
		return { ok = true, state = publicState(data) }

	elseif a == "buy" then
		local item = SHOP_BY_ID[req.id]
		if not item then return { ok = false, err = "bad_item" } end
		local lv = data.up[item.id]
		if lv >= item.max then return { ok = false, err = "max" } end
		local cost = item.costs[lv + 1]
		if data.coins < cost then return { ok = false, err = "poor" } end
		data.coins -= cost
		data.up[item.id] = lv + 1
		-- undo alimi aktif run'a aninda 1 hak ekler
		if item.id == "undo" and data.run and not data.run.over then
			data.run.undoLeft += 1
		end
		session.dirty = true
		return { ok = true, coins = data.coins, up = deepCopy(data.up) }

	elseif a == "theme" then
		if req.t == "Light" or req.t == "Dark" then
			data.theme = req.t
			session.dirty = true
			return { ok = true }
		end
		return { ok = false, err = "bad_theme" }

	elseif a == "top" then
		return { ok = true, list = fetchTop() }
	end

	return { ok = false, err = "unknown" }
end

Players.PlayerRemoving:Connect(function(playerObj)
	local session = sessions[playerObj]
	sessions[playerObj] = nil
	if session then
		pushBestToTop(playerObj, session)
		saveSession(playerObj, session, true)
	end
end)

-- Otomatik kayit dongusu
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for playerObj, session in pairs(sessions) do
			task.spawn(saveSession, playerObj, session, false)
		end
	end
end)

-- Sunucu kapanirken herkesi zorla kaydet
game:BindToClose(function()
	if RunService:IsStudio() then
		task.wait(1)
	end
	local pending = 0
	for playerObj, session in pairs(sessions) do
		pending += 1
		task.spawn(function()
			saveSession(playerObj, session, true)
			pending -= 1
		end)
	end
	local deadline = os.clock() + 20
	while pending > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end)
