--[[
	NEON MERGE 2048 — sunucu (ServerScriptService > Script)

	Gorevi: oyuncu verisinin kalici kaydi (DataStoreService).
	- Giriste kayit yuklenir, istemci NM_GetData (RemoteFunction) ile ceker.
	- Istemci her hamlede NM_Save (RemoteEvent) ile durumunu gonderir;
	  sunucu dogrular, bellekte tutar.
	- DataStore yazimi: 30 sn'de bir (degistiyse) + cikista + sunucu kapanisinda.
	- Dogrulama: tahta 4x4 ve degerler 2'nin kuvveti, skor tavanli, tema enum.
	  Best skoru sunucu hesaplar (max eski best, gelen skor).

	Kayit anahtari: NeonMerge2048Save_v1 / "u_<UserId>"
	NOT: MainGame.client.lua ile birlikte guncelle.
]]

local DataStoreService  = game:GetService("DataStoreService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local STORE_NAME        = "NeonMerge2048Save_v1"
local AUTOSAVE_INTERVAL = 30       -- sn
local MIN_WRITE_GAP     = 6        -- ayni oyuncuya iki yazim arasi en az sure
local MAX_SCORE         = 4_000_000 -- 4x4 2048'de teorik skor tavaninin ustu
local GRID              = 4

local store = DataStoreService:GetDataStore(STORE_NAME)

-- ========================================================================
-- Remotes
-- ========================================================================
local GetData = Instance.new("RemoteFunction")
GetData.Name = "NM_GetData"
GetData.Parent = ReplicatedStorage

local SaveEvent = Instance.new("RemoteEvent")
SaveEvent.Name = "NM_Save"
SaveEvent.Parent = ReplicatedStorage

-- ========================================================================
-- Dogrulama
-- ========================================================================
local VALID_TILE = { [0] = true }
do
	local v = 2
	while v <= 131072 do VALID_TILE[v] = true v *= 2 end
end

local function sanitizeBoard(b)
	if type(b) ~= "table" then return nil end
	local out = {}
	for r = 1, GRID do
		if type(b[r]) ~= "table" then return nil end
		out[r] = {}
		for c = 1, GRID do
			local v = b[r][c]
			if type(v) ~= "number" or not VALID_TILE[v] then return nil end
			out[r][c] = v
		end
	end
	return out
end

local function sanitizeScore(s)
	if type(s) ~= "number" or s ~= s or s < 0 then return nil end
	return math.min(math.floor(s), MAX_SCORE)
end

-- ========================================================================
-- Oturum yonetimi
-- ========================================================================
local DEFAULT_DATA = { board = nil, score = 0, best = 0, theme = "Light" }

local sessions = {}   -- [player] = { data, loaded, dirty, lastWrite }

local function deepCopy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = deepCopy(v) end
	return out
end

local function keyFor(userId)
	return "u_" .. userId
end

local function loadData(userId)
	for attempt = 1, 3 do
		local ok, result = pcall(function()
			return store:GetAsync(keyFor(userId))
		end)
		if ok then
			if type(result) == "table" then
				-- Kayittaki alanlari da suzerek yukle (bozuk kayit oyunu kirmasin)
				local data = deepCopy(DEFAULT_DATA)
				data.board = sanitizeBoard(result.board)
				data.score = sanitizeScore(result.score) or 0
				data.best  = sanitizeScore(result.best) or 0
				data.theme = (result.theme == "Dark") and "Dark" or "Light"
				return data
			end
			return deepCopy(DEFAULT_DATA)
		end
		warn(("[NeonMerge2048] Yukleme denemesi %d basarisiz (%s): %s"):format(attempt, userId, tostring(result)))
		task.wait(attempt)
	end
	return deepCopy(DEFAULT_DATA)
end

local function writeData(userId, data)
	for attempt = 1, 3 do
		local ok, err = pcall(function()
			store:UpdateAsync(keyFor(userId), function()
				return data
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
	writeData(playerObj.UserId, deepCopy(session.data))
end

-- ========================================================================
-- Oyuncu akisi
-- ========================================================================
local function onPlayerAdded(playerObj)
	local session = { data = nil, loaded = false, dirty = false, lastWrite = 0 }
	sessions[playerObj] = session
	session.data = loadData(playerObj.UserId)
	session.loaded = true
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, p)
end

GetData.OnServerInvoke = function(playerObj)
	local session = sessions[playerObj]
	local deadline = os.clock() + 15
	while (not session or not session.loaded) and os.clock() < deadline do
		task.wait(0.1)
		session = sessions[playerObj]
	end
	if not session or not session.loaded then
		return deepCopy(DEFAULT_DATA)
	end
	return deepCopy(session.data)
end

SaveEvent.OnServerEvent:Connect(function(playerObj, payload)
	local session = sessions[playerObj]
	if not session or not session.loaded then return end
	if type(payload) ~= "table" then return end

	local board = sanitizeBoard(payload.board)
	local score = sanitizeScore(payload.score)
	if score == nil then return end

	-- board=nil gecerli: yeni oyun baslangicinda tahta sifirlanmis olabilir,
	-- ama gecerli tahta geldiyse aynen sakla (yarim oyun devam edebilsin)
	session.data.board = board
	session.data.score = score
	session.data.best  = math.max(session.data.best, score)
	if payload.theme == "Dark" or payload.theme == "Light" then
		session.data.theme = payload.theme
	end
	session.dirty = true
end)

Players.PlayerRemoving:Connect(function(playerObj)
	local session = sessions[playerObj]
	sessions[playerObj] = nil
	if session then
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
