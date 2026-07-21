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

local DataStoreService    = game:GetService("DataStoreService")
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local RunService          = game:GetService("RunService")
local MarketplaceService  = game:GetService("MarketplaceService")

-- ========================================================================
-- MONETIZASYON: ID'leri create.roblox.com'dan alip buraya yapistir.
-- 0 birakilan urun satilamaz, oyun normal calisir.
-- Ayni ID'ler MainGame.client.lua icinde de tanimli, ikisini birlikte guncelle.
-- ========================================================================
local GAMEPASS_2X_COINS    = 0   -- kalici: tur sonu coin odulu 2 kat
local PRODUCT_COINS_1K     = 0   -- tekrar alinabilir: +1.000 coin
local PRODUCT_COINS_5K     = 0   -- tekrar alinabilir: +5.000 coin
local PRODUCT_COINS_15K    = 0   -- tekrar alinabilir: +15.000 coin
local PRODUCT_THEME_NEON   = 0   -- Neon temasini Robux ile ac
local PRODUCT_THEME_SUNSET = 0   -- Sunset temasini Robux ile ac

local SERVER_ACT_DEBOUNCE = 0.15   -- NM_Act istekleri arasi asgari sure

local STORE_NAME        = "NeonMerge2048Save_v1"
local TOP_STORE_NAME    = "NeonMerge2048Top_v1"      -- skor siralamasi
local TILE_STORE_NAME   = "NeonMerge2048TopTile_v1"  -- en yuksek blok siralamasi
local AUTOSAVE_INTERVAL = 30
local MIN_WRITE_GAP     = 6
local MAX_SCORE         = 40_000_000
local MAX_COINS         = 1_000_000_000
local TOP_CACHE_SECONDS = 150   -- leaderboard onbellegi (~2.5 dk'da bir tazelenir)

local store     = DataStoreService:GetDataStore(STORE_NAME)
local topStore  = DataStoreService:GetOrderedDataStore(TOP_STORE_NAME)
local tileStore = DataStoreService:GetOrderedDataStore(TILE_STORE_NAME)

-- 3D karakter tamamen kapali: oyun saf 2D ScreenGui, avatar hic dogmaz
-- (dogru ozellik adi CharacterAutoLoads; CharacterAutoSpawn diye ozellik yok)
Players.CharacterAutoLoads = false

-- DataStore saglik kontrolu: erisim yoksa kayit calismaz, aciktan uyar
task.spawn(function()
	local ok, err
	for attempt = 1, 3 do
		ok, err = pcall(function()
			store:GetAsync("__health_check")
		end)
		if ok then return end
		task.wait(attempt)
	end
	local msg = tostring(err)
	warn("[NeonMerge2048] !!! DATASTORE ERISILEMIYOR !!! Hata: " .. msg)
	if msg:find("403") or msg:find("not allowed") or msg:find("publish") then
		warn("[NeonMerge2048] Sebep izin: 1) File > Publish to Roblox ile oyunu yayinla,")
		warn("[NeonMerge2048] 2) Game Settings > Security > 'Enable Studio Access to API Services' ac.")
	else
		warn("[NeonMerge2048] Sebep Roblox tarafinda gecici olabilir (500/502). Kayit yazma otomatik")
		warn("[NeonMerge2048] durdurulur, veri kaybi olmaz; erisim gelince kaldigi yerden devam eder.")
	end
end)

-- ========================================================================
-- MAGAZA KATALOGU (istemciyle birebir ayni tutulmali)
-- ========================================================================
-- Fiyatlar seviye basina ~2.5x katlanir (uzun vadeli meta hedefi)
local SHOP = {
	{ id = "spawn", max = 5, costs = { 75, 190, 470, 1200, 3000 } }, -- 4 sansi +%10/sv, sv4+ 8 sansi
	{ id = "start", max = 3, costs = { 250, 750, 2250 } },           -- run basi hazir tile 8/16/32
	{ id = "undo",  max = 3, costs = { 150, 450, 1350 } },           -- run basina geri alma hakki
	{ id = "coin",  max = 4, costs = { 300, 900, 2700, 8100 } },     -- coin kazanci +%25/sv
	{ id = "grid5", max = 1, costs = { 5000 } },                     -- 5x5 tahta kilidi
	{ id = "themeNeon",   max = 1, costs = { 1500 } },               -- kozmetik: Neon tema
	{ id = "themeSunset", max = 1, costs = { 2500 } },               -- kozmetik: Sunset tema
}
local SHOP_BY_ID = {}
for _, item in ipairs(SHOP) do SHOP_BY_ID[item.id] = item end

-- Tema kilidi: Light/Dark herkeste acik, digerleri magazadan alinir
local THEME_UNLOCK = { Neon = "themeNeon", Sunset = "themeSunset" }

local function themeAllowed(data, name)
	if name == "Light" or name == "Dark" then return true end
	local req = THEME_UNLOCK[name]
	return req ~= nil and (data.up[req] or 0) > 0
end

-- Gunluk odul: gun numarasi (UTC), art arda gunlerde artan coin
local DAILY_BASE = 100
local DAILY_STEP = 50
local DAILY_MAX_STREAK = 7

local function dayNumber()
	return math.floor(os.time() / 86400)
end

local function dailyReward(streak)
	return DAILY_BASE + DAILY_STEP * math.min(math.max(streak, 1) - 1, DAILY_MAX_STREAK - 1)
end

local function tileBonus(maxTile)
	if maxTile >= 4096 then return 400
	elseif maxTile >= 2048 then return 150
	elseif maxTile >= 1024 then return 60
	elseif maxTile >= 512 then return 25
	elseif maxTile >= 256 then return 10 end
	return 0
end

-- vip: 2x Coins gamepass sahipligi (istemcideki kopyayla birebir ayni olmali)
local function coinsForRun(score, maxTile, coinLv, vip)
	local base = math.floor(score / 200) + tileBonus(maxTile)
	local total = math.floor(base * (1 + 0.25 * coinLv))
	if vip then total *= 2 end
	return total
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
		bestTile = 0,   -- oyuncunun tum zamanlarda ulastigi en yuksek tile
		theme = "Light",
		up = sanitizeUp(nil),
		daily = { day = 0, streak = 0 },
		receipts = {},   -- islenmis PurchaseId listesi (cift islemeyi onler)
		paid = {},       -- Robux ile alinmis kalici kilitler (wipe sonrasi geri verilir)
		sfx = 70,        -- ses seviyesi yuzdesi (0-100)
		muted = false,   -- sessize alma (seviye korunur)
		run = nil,
	}
end

local function sanitizePaid(p)
	local out = {}
	if type(p) == "table" then
		for _, item in ipairs(SHOP) do
			if p[item.id] == true then out[item.id] = true end
		end
	end
	return out
end

local MAX_RECEIPTS = 40

local function sanitizeReceipts(list)
	local out = {}
	if type(list) == "table" then
		for _, id in ipairs(list) do
			if type(id) == "string" and #id <= 64 then
				table.insert(out, id)
				if #out >= MAX_RECEIPTS then break end
			end
		end
	end
	return out
end

local function hasReceipt(data, id)
	for _, existing in ipairs(data.receipts) do
		if existing == id then return true end
	end
	return false
end

local function addReceipt(data, id)
	table.insert(data.receipts, id)
	while #data.receipts > MAX_RECEIPTS do
		table.remove(data.receipts, 1)
	end
end

local function sanitizeDaily(d)
	local out = { day = 0, streak = 0 }
	if type(d) == "table" then
		out.day = sanitizeNumber(d.day, 10_000_000) or 0
		out.streak = math.clamp(sanitizeNumber(d.streak, 10000) or 0, 0, 10000)
	end
	return out
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
		milestone = 0,   -- kutlanmis en yuksek esik (2048 / 4096 / 8192 ...)
		prevBoard = nil, prevScore = 0,
	}
end

-- Istemciye gonderilecek durum (undo snapshot'i haric)
local function publicState(data)
	local run = data.run
	return {
		coins = data.coins,
		best = data.best,
		bestTile = data.bestTile,
		theme = data.theme,
		up = deepCopy(data.up),
		dailyReady = data.daily.day < dayNumber(),
		dailyStreak = data.daily.streak,
		dailyContinues = (data.daily.day == dayNumber() - 1),   -- seri kopmus mu
		vip = data.vip == true,   -- 2x Coins gamepass (oturumdan kopyalanir)
		sfx = data.sfx,
		muted = data.muted,
		run = run and {
			board = deepCopy(run.board),
			score = run.score, seed = run.seed, spawns = run.spawns,
			size = run.size, undoLeft = run.undoLeft,
			won = run.won, over = run.over, milestone = run.milestone,
		} or nil,
	}
end

-- ========================================================================
-- Leaderboard
-- ========================================================================
local function keyFor(userId)
	return "u_" .. userId
end

local topCaches = {
	score = { time = -math.huge, list = {}, ranks = {} },
	tile  = { time = -math.huge, list = {}, ranks = {} },
}
local nameCache = {}

local function writeOrdered(orderedStore, userId, value)
	pcall(function()
		orderedStore:SetAsync(tostring(userId), value)
	end)
end

-- Ilk 100 girisi ceker (kind: "score" | "tile"): ilk 10 icin isim + o sekmenin
-- metrigi, tamami icin rank haritasi. TOP_CACHE_SECONDS'ta bir tazelenir.
-- Her sekme tek metrik gosterdigi icin ek kayit okumasi yapilmaz.
local function fetchTop(kind)
	local cache = topCaches[kind]
	if os.clock() - cache.time < TOP_CACHE_SECONDS then
		return cache
	end
	cache.time = os.clock()
	local orderedStore = (kind == "tile") and tileStore or topStore
	local ok, pages = pcall(function()
		return orderedStore:GetSortedAsync(false, 100)
	end)
	if ok then
		local list, ranks = {}, {}
		for rank, entry in ipairs(pages:GetCurrentPage()) do
			local uid = tonumber(entry.key)
			if uid then
				ranks[uid] = rank
				if rank <= 10 then
					local name = nameCache[uid]
					if not name then
						local okN, n = pcall(function()
							return Players:GetNameFromUserIdAsync(uid)
						end)
						name = okN and n or "?"
						nameCache[uid] = name
					end
					local score, tile = 0, 0
					if kind == "tile" then tile = entry.value else score = entry.value end
					table.insert(list, { name = name, score = score, tile = tile })
				end
			end
		end
		cache.list = list
		cache.ranks = ranks
	end
	return cache
end

-- Run biter: coin odulu + best + leaderboard. Kazanilan coini dondurur.
local function endRun(session, run)
	local data = session.data
	local maxTile = boardMax(run.board, run.size)
	-- data.vip gecicidir: gamepass sahipliginden gelir, kayda yazilmaz
	local earned = coinsForRun(run.score, maxTile, data.up.coin, data.vip)
	data.coins = math.min(data.coins + earned, MAX_COINS)
	data.bestTile = math.max(data.bestTile, maxTile)
	if run.score > data.best then
		data.best = math.min(run.score, MAX_SCORE)
	end
	session.dirty = true
	return earned
end

local function pushBestToTop(playerObj, session)
	if not session.loaded or not session.data then return end
	local data = session.data
	if data.best > (session.topWritten or 0) then
		session.topWritten = data.best
		task.spawn(writeOrdered, topStore, playerObj.UserId, data.best)
	end
	if data.bestTile > (session.tileWritten or 0) then
		session.tileWritten = data.bestTile
		task.spawn(writeOrdered, tileStore, playerObj.UserId, data.bestTile)
	end
end

-- ========================================================================
-- DataStore yukle / yaz
-- ========================================================================
-- Basarili olursa veri dondurur, TUM denemeler basarisizsa nil.
-- nil dondugunde oturum "yuklendi" sayilmaz ve HICBIR yazma yapilmaz:
-- boylece gecici DataStore hatasi (502) mevcut kaydin uzerine bos veri yazamaz.
local LOAD_BACKOFF = { 0.2, 1 }   -- tur basina 2 deneme; ustu arka plan dongusune birakilir

local function loadData(userId)
	for attempt = 1, #LOAD_BACKOFF do
		local ok, result = pcall(function()
			return store:GetAsync(keyFor(userId))
		end)
		if ok then
			local data = defaultData()
			if type(result) == "table" then
				if result.schema == 2 then
					data.coins    = sanitizeNumber(result.coins, MAX_COINS) or 0
					data.best     = sanitizeNumber(result.best, MAX_SCORE) or 0
					data.bestTile = sanitizeNumber(result.bestTile, 1048576) or 0
					data.up       = sanitizeUp(result.up)
					data.daily    = sanitizeDaily(result.daily)
					data.receipts = sanitizeReceipts(result.receipts)
					data.paid     = sanitizePaid(result.paid)
					data.sfx      = math.clamp(sanitizeNumber(result.sfx, 100) or 70, 0, 100)
					data.muted    = result.muted == true
					data.theme = (type(result.theme) == "string" and themeAllowed(data, result.theme))
						and result.theme or "Light"
					local run = result.run
					if type(run) == "table" then
						local size = (run.size == 5) and 5 or 4
						local board = sanitizeBoard(run.board, size)
						local score = sanitizeNumber(run.score, MAX_SCORE)
						if board and score and (size == 4 or data.up.grid5 > 0) then
							data.bestTile = math.max(data.bestTile, boardMax(board, size))
							data.run = {
								board = board, score = score,
								seed = sanitizeNumber(run.seed, 2_000_000_000) or 1,
								spawns = sanitizeNumber(run.spawns, 1_000_000) or 0,
								size = size,
								undoLeft = math.clamp(sanitizeNumber(run.undoLeft, 10) or 0, 0, SHOP_BY_ID.undo.max),
								won = run.won == true,
								over = run.over == true,
								-- Eski kayitta milestone yok: tahtadaki en yuksek tile'i
								-- kutlanmis say, yoksa 4096'ya ulasmis oyuncuya tekrar kutlama cikar
								milestone = sanitizeNumber(run.milestone, 1048576)
									or ((run.won == true) and boardMax(board, size) or 0),
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
						data.bestTile = boardMax(board, 4)
						data.run = {
							board = board, score = score,
							seed = Random.new():NextInteger(1, 1_000_000_000),
							spawns = 0, size = 4, undoLeft = 0,
							won = boardMax(board, 4) >= 2048,
							over = not hasMoves(board, 4),
							milestone = (boardMax(board, 4) >= 2048) and boardMax(board, 4) or 0,
							prevBoard = nil, prevScore = 0,
						}
					end
				end
			end
			return data
		end
		warn(("[NeonMerge2048] Yukleme denemesi %d basarisiz (%s): %s"):format(attempt, userId, tostring(result)))
		task.wait(LOAD_BACKOFF[attempt])
	end
	return nil   -- veri kaybini onlemek icin varsayilan veriyle DEVAM ETME
end

local function serializeData(data)
	local run = data.run
	return {
		schema = 2,
		coins = data.coins,
		best = data.best,
		bestTile = data.bestTile,
		theme = data.theme,
		up = deepCopy(data.up),
		daily = deepCopy(data.daily),
		receipts = deepCopy(data.receipts),
		paid = deepCopy(data.paid),
		sfx = data.sfx,
		muted = data.muted,
		run = run and {
			board = deepCopy(run.board),
			score = run.score, seed = run.seed, spawns = run.spawns,
			size = run.size, undoLeft = run.undoLeft,
			won = run.won, over = run.over, milestone = run.milestone,
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

-- Yazma basariliysa istemciye "saved" bildirir (autosave gostergesi).
-- session.saving kilidi: es zamanli iki yazma birbirinin uzerine eski payload
-- yazamaz (ornegin arka arkaya iki Robux satin almasi).
local function saveSession(playerObj, session, force)
	if not session or not session.loaded then return false end
	if not session.dirty and not force then return false end

	if session.saving then
		-- Devam eden yazma var: bitmesini bekle, sonra guncel veriyle tekrar yaz
		local deadline = os.clock() + 15
		while session.saving and os.clock() < deadline do
			task.wait(0.05)
		end
		if session.saving then return false end
		if not session.dirty and not force then return true end
	end

	local now = os.clock()
	if not force and (now - session.lastWrite) < MIN_WRITE_GAP then return false end

	session.saving = true
	session.lastWrite = now
	session.dirty = false
	local ok = writeData(playerObj.UserId, serializeData(session.data))
	session.saving = false

	if not ok then
		session.dirty = true   -- basarisiz yazma kaybolmasin, sonraki turda tekrar denenir
	elseif playerObj.Parent then
		SyncEvent:FireClient(playerObj, { ev = "saved" })
	end
	return ok
end

-- ========================================================================
-- Monetizasyon: gamepass sahipligi + developer product islemleri
-- ========================================================================
local PRODUCT_GRANTS = {}   -- [productId] = { kind = "coins"|"theme", ... }

local function registerProduct(id, grant)
	if id ~= 0 then PRODUCT_GRANTS[id] = grant end
end
registerProduct(PRODUCT_COINS_1K,     { kind = "coins", amount = 1000 })
registerProduct(PRODUCT_COINS_5K,     { kind = "coins", amount = 5000 })
registerProduct(PRODUCT_COINS_15K,    { kind = "coins", amount = 15000 })
registerProduct(PRODUCT_THEME_NEON,   { kind = "theme", up = "themeNeon" })
registerProduct(PRODUCT_THEME_SUNSET, { kind = "theme", up = "themeSunset" })

-- Sahiplik oturum boyunca onbelleklenir; oyun ici satin almada aninda tazelenir
local function refreshVip(playerObj, session)
	if GAMEPASS_2X_COINS == 0 then return end
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(playerObj.UserId, GAMEPASS_2X_COINS)
	end)
	if ok and session.data then
		session.data.vip = owns and true or false
	end
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(playerObj, gamePassId, wasPurchased)
	if not wasPurchased or gamePassId ~= GAMEPASS_2X_COINS then return end
	local session = sessions[playerObj]
	if not session or not session.loaded then return end
	session.data.vip = true
	SyncEvent:FireClient(playerObj, { ev = "vip", vip = true })
end)

-- Developer product satin almalari. Oturum hazir degilse NotProcessedYet
-- dondurulur; Roblox tekrar dener, satin alma kaybolmaz.
MarketplaceService.ProcessReceipt = function(receiptInfo)
	local playerObj = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not playerObj then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local session = sessions[playerObj]
	if not session or not session.loaded then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local grant = PRODUCT_GRANTS[receiptInfo.ProductId]
	if not grant then
		-- ID sunucuda tanimli degil (ornegin yalnizca istemciye yazilmis).
		-- PurchaseGranted donersek Robux karsiliksiz yanar; tekrar denensin ki
		-- ID eklendiginde satin alma islensin.
		warn("[NeonMerge2048] Tanimsiz urun ID: " .. tostring(receiptInfo.ProductId)
			.. " - Server.server.lua icindeki PRODUCT_* sabitlerini doldur")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local data = session.data
	local purchaseKey = tostring(receiptInfo.PurchaseId)
	if hasReceipt(data, purchaseKey) then
		-- Zaten islenmis ama diske yazilmamis olabilir: once kalicilastir
		if session.dirty and not saveSession(playerObj, session, true) then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if grant.kind == "coins" then
		data.coins = math.min(data.coins + grant.amount, MAX_COINS)
	elseif grant.kind == "theme" then
		data.up[grant.up] = 1
		data.paid[grant.up] = true   -- Robux ile alindi: veri sifirlansa da geri verilir
	end
	addReceipt(data, purchaseKey)
	session.dirty = true

	-- Yazma basarisizsa odul verilmis sayilmaz; Roblox tekrar dener
	if not saveSession(playerObj, session, true) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	SyncEvent:FireClient(playerObj, {
		ev = "purchase", coins = data.coins, up = deepCopy(data.up),
	})
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- ========================================================================
-- Oyuncu akisi
-- ========================================================================
local function onPlayerAdded(playerObj)
	if sessions[playerObj] then return end   -- PlayerAdded + GetPlayers() cift tetiklemesi
	-- CharacterAutoSpawn kapali olsa da baska bir betik LoadCharacter cagirirsa
	-- karakteri aninda kaldir; 3D dunyada avatar asla gorunmez
	playerObj.CharacterAdded:Connect(function(character)
		task.defer(function()
			if character.Parent then character:Destroy() end
		end)
	end)
	if playerObj.Character then
		playerObj.Character:Destroy()
	end

	local session = { data = nil, loaded = false, dirty = false, lastWrite = 0, topWritten = 0, tileWritten = 0 }
	sessions[playerObj] = session

	-- Yukleme basarisiz oldukca arka planda denemeye devam eder; basarana kadar
	-- oturum "yuklenmis" sayilmaz, dolayisiyla hicbir kayit yazilmaz.
	-- Turlar arasi bekleme kademeli buyur: kesinti sirasinda GetAsync butcesini
	-- tuketip kurtarmayi geciktirmemek icin.
	task.spawn(function()
		local RETRY_WAITS = { 5, 10, 20, 30 }
		local round = 0
		while sessions[playerObj] == session do
			local data = loadData(playerObj.UserId)
			if data then
				session.data = data
				session.topWritten = data.best
				session.tileWritten = data.bestTile
				-- vip, loaded'dan ONCE belirlenmeli: waitSession loaded'i gorur gormez
				-- doner, sonra bakilirsa ilk GetData yaniti vip=false gider
				refreshVip(playerObj, session)
				session.loaded = true
				return
			end
			round += 1
			local wait = RETRY_WAITS[math.min(round, #RETRY_WAITS)]
			warn(("[NeonMerge2048] %s icin kayit yuklenemedi, %d sn sonra tekrar denenecek (bu sure boyunca kayit YAZILMAZ)"):format(playerObj.Name, wait))
			task.wait(wait)
		end
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, p)
end

-- Kisa deadline: yukleme uzarsa istemciye notReady dondurulur, istemci yeniden dener
local function waitSession(playerObj)
	local session = sessions[playerObj]
	local deadline = os.clock() + 3
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

-- Tek hamleyi isler; kutlanacak yeni esik varsa onu dondurur
local function applyMove(playerObj, session, dir)
	local data = session.data
	local run = data.run
	if not run or run.over then
		SyncEvent:FireClient(playerObj, { ev = "resync", state = publicState(data) })
		return false
	end

	local prevBoard = deepCopy(run.board)
	local prevScore = run.score
	local changed, gained = simMove(run.board, run.size, dir)
	if not changed then return true end

	run.prevBoard = prevBoard
	run.prevScore = prevScore
	run.score = math.min(run.score + gained, MAX_SCORE)
	spawnTile(run.board, run.size, run.seed, run.spawns, data.up.spawn)
	run.spawns += 1
	session.dirty = true

	local maxTile = boardMax(run.board, run.size)
	if maxTile > data.bestTile then
		data.bestTile = maxTile
	end
	-- Kilometre taslari: 2048 ve sonraki her katta bir kez kutlanir
	local newMilestone = nil
	if maxTile >= 2048 and maxTile > run.milestone then
		run.milestone = maxTile
		run.won = true
		newMilestone = maxTile
	end

	if not hasMoves(run.board, run.size) then
		run.over = true
		local earned = endRun(session, run)
		pushBestToTop(playerObj, session)
		SyncEvent:FireClient(playerObj, {
			ev = "over", earned = earned, coins = data.coins, best = data.best,
		})
		return false
	elseif newMilestone then
		SyncEvent:FireClient(playerObj, {
			ev = "win", tile = newMilestone, coins = data.coins, best = data.best,
		})
	end
	return true
end

-- Istemci hamleleri paket halinde gonderir (tek yon ya da yon dizisi).
-- Token bucket ile hiz siniri: sn'de 15 hamle, en fazla 30 birikimli.
local MOVE_RATE = 15
local MOVE_BURST = 30
local MAX_MOVES_PER_PACKET = 8

MoveEvent.OnServerEvent:Connect(function(playerObj, payload)
	local session = sessions[playerObj]
	if not session or not session.loaded then return end

	local dirs
	if type(payload) == "string" then
		dirs = { payload }
	elseif type(payload) == "table" then
		dirs = payload
	else
		return
	end

	local now = os.clock()
	session.moveBudget = math.min(MOVE_BURST,
		(session.moveBudget or MOVE_BURST) + (now - (session.lastMoveAt or now)) * MOVE_RATE)
	session.lastMoveAt = now

	local count = math.min(#dirs, MAX_MOVES_PER_PACKET)
	for i = 1, count do
		local dir = dirs[i]
		if type(dir) ~= "string" or not DIRECTIONS[dir] then return end
		if session.moveBudget < 1 then
			-- Hiz siniri asildi: kalan hamleler yok sayilir, istemci tam durumla eslenir
			SyncEvent:FireClient(playerObj, { ev = "resync", state = publicState(session.data) })
			return
		end
		session.moveBudget -= 1
		if not applyMove(playerObj, session, dir) then return end
	end
end)

-- NM_Act sel korumasi: istek basina asgari SERVER_ACT_DEBOUNCE bekleme.
-- Sinir asilirsa DataStore/durum mantigina hic girilmez, CPU harcanmaz.
local lastActTimes = {}

Act.OnServerInvoke = function(playerObj, req)
	local now = os.clock()
	local last = lastActTimes[playerObj]
	if last and (now - last) < SERVER_ACT_DEBOUNCE then
		return { ok = false, err = "too_fast" }
	end
	lastActTimes[playerObj] = now

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
		if type(req.t) == "string" and themeAllowed(data, req.t) then
			data.theme = req.t
			session.dirty = true
			return { ok = true }
		end
		return { ok = false, err = "bad_theme" }

	elseif a == "sfx" then
		-- Ses tercihi: kaydirici birakildiginda tek istek gelir
		if type(req.vol) == "number" and req.vol == req.vol then
			data.sfx = math.clamp(math.floor(req.vol), 0, 100)
		end
		if type(req.muted) == "boolean" then
			data.muted = req.muted
		end
		session.dirty = true
		return { ok = true }

	elseif a == "daily" then
		local today = dayNumber()
		if data.daily.day >= today then
			return { ok = false, err = "claimed" }
		end
		-- Art arda gun ise seri artar, kopmussa bastan baslar
		data.daily.streak = (data.daily.day == today - 1) and (data.daily.streak + 1) or 1
		data.daily.day = today
		local reward = dailyReward(data.daily.streak)
		data.coins = math.min(data.coins + reward, MAX_COINS)
		session.dirty = true
		return { ok = true, reward = reward, streak = data.daily.streak, coins = data.coins }

	elseif a == "wipe" then
		-- Tum ilerlemeyi siler; istemci iki asamali onay ister.
		-- Robux ile alinmis haklar korunur: gamepass, makbuz gecmisi ve
		-- Robux'la acilmis kilitler (coin ile alinanlar sifirlanir).
		local newData = defaultData()
		newData.vip = data.vip
		newData.receipts = deepCopy(data.receipts)
		newData.paid = deepCopy(data.paid)
		for id in pairs(newData.paid) do
			newData.up[id] = 1
		end
		-- Ses tercihi ilerleme degil, sifirlamada korunur
		newData.sfx = data.sfx
		newData.muted = data.muted
		session.data = newData
		newData.run = startRun(newData, 4)
		session.dirty = true
		session.topWritten = 0
		session.tileWritten = 0
		saveSession(playerObj, session, true)
		-- Siralamalardan da dus, yoksa kisisel best 0 iken tabloda eski skor kalir
		task.spawn(function()
			pcall(function() topStore:RemoveAsync(tostring(playerObj.UserId)) end)
			pcall(function() tileStore:RemoveAsync(tostring(playerObj.UserId)) end)
		end)
		return { ok = true, state = publicState(newData) }

	elseif a == "top" then
		local kind = (req.board == "tile") and "tile" or "score"
		local cache = fetchTop(kind)   -- yield eder; sonrasinda veriyi taze oku
		local fresh = session.data
		return {
			ok = true,
			list = cache.list,
			me = {
				rank = cache.ranks[playerObj.UserId],   -- o sekmenin ilk 100'unde degilse nil
				best = fresh.best,
				tile = fresh.bestTile,
			},
		}
	end

	return { ok = false, err = "unknown" }
end

Players.PlayerRemoving:Connect(function(playerObj)
	local session = sessions[playerObj]
	sessions[playerObj] = nil
	lastActTimes[playerObj] = nil   -- sizinti olmasin
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
