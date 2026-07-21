--[[
	NEON MERGE 2048 v3 — istemci (StarterPlayer > StarterPlayerScripts > LocalScript)

	Mimari:
	1. CONFIG      : tema tablolari, tile paleti, magaza katalogu, sabitler
	2. CORE SIM    : sunucuyla birebir ayni deterministik oyun cekirdegi
	3. REMOTES     : NM_GetData / NM_Act / NM_Move / NM_Sync
	4. UI BUILD    : header (2 satir HUD) + board (grid + anim katmani) + overlay + magaza
	5. THEME       : state-tabanli tema yoneticisi, TweenService gecisleri
	6. RENDER/ANIM : kayma animasyonu (ghost tile), pop-in (0.8 -> 1.05 -> 1.0), neon hue
	7. GAME FLOW   : hamle (lokal sim + sunucuya bildir), undo, yeni oyun, 4x4/5x5
	8. SHOP UI     : coin magazasi + TOP 10 leaderboard sekmesi
	9. INPUT       : klavye (WASD + ok) ve mobil swipe (TouchSwipe), debounce

	Sunucu-otoriter: skor/coin/kayit otoritesi sunucudadir; istemci ayni simulasyonu
	gorsel icin lokal oynatir (deterministik spawn: seed + spawnIndex).
	NOT: Server.server.lua olmadan calismaz; iki dosyayi birlikte guncelle.
]]

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst   = game:GetService("ReplicatedFirst")
local MarketplaceService = game:GetService("MarketplaceService")
local ContentProvider    = game:GetService("ContentProvider")
local Debris             = game:GetService("Debris")

-- ========================================================================
-- MONETIZASYON ID'leri: Server.server.lua ile BIREBIR ayni olmali.
-- 0 birakilan urun magazada gorunmez.
-- ========================================================================
local GAMEPASS_2X_COINS    = 1921208641
local PRODUCT_COINS_1K     = 3611041230
local PRODUCT_COINS_5K     = 3611041323
local PRODUCT_COINS_15K    = 3611041446
local PRODUCT_THEME_NEON   = 3611041669
local PRODUCT_THEME_SUNSET = 3611041725

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- 3D dunya yuklenmesini bekleyen varsayilan yukleme ekrani gereksiz: oyun 2D
pcall(function()
	ReplicatedFirst:RemoveDefaultLoadingScreen()
end)

-- 3D dunya kapali: kamera Scriptable kilitlenir, bos gokyuzune bakar;
-- oyun tamamen ScreenGui uzerinde calisir
local function lockCamera()
	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = CFrame.new(0, 1000, 0)
		camera:GetPropertyChangedSignal("CameraType"):Connect(function()
			camera.CameraType = Enum.CameraType.Scriptable
		end)
	end
end
lockCamera()
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(lockCamera)

-- ========================================================================
-- 1. CONFIG
-- ========================================================================
local BOARD_RADIUS  = 16
local TILE_RADIUS   = 12
local MOVE_DEBOUNCE = 0.13
local SLIDE_TIME    = 0.09
local THEME_TWEEN   = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function hex(h)
	return Color3.fromRGB(
		tonumber(h:sub(1, 2), 16),
		tonumber(h:sub(3, 4), 16),
		tonumber(h:sub(5, 6), 16)
	)
end

local THEMES = {
	Light = {
		screen     = hex("FFFFFF"),
		board      = hex("FFFFFF"),
		empty      = hex("E0E0E0"),
		text       = hex("3C3C3C"),
		button     = hex("E0E0E0"),
		buttonText = hex("3C3C3C"),
		statValue  = hex("3C3C3C"),
		statLabel  = hex("8A8A8A"),
		stroke     = hex("D0D0D0"),
		strokeT    = 0.2,
		tileTint   = nil,   -- referans palet, tonlama yok
	},
	Dark = {
		screen     = hex("121212"),
		board      = hex("2A2A2A"),
		empty      = hex("EAE6DF"),
		text       = hex("EAE6DF"),
		button     = hex("2A2A2A"),
		buttonText = hex("EAE6DF"),
		statValue  = hex("EAE6DF"),
		statLabel  = hex("9A968F"),
		stroke     = hex("3A3A40"),
		strokeT    = 0.2,
		tileTint   = { color = hex("000000"), amount = 0.08 },   -- siyah zeminde parlamasin
	},
	-- Kozmetik temalar (magazadan acilir)
	Neon = {
		screen     = hex("0A0A12"),
		board      = hex("14142A"),
		empty      = hex("1E1E3C"),
		text       = hex("E8E8FF"),
		button     = hex("1E1E3C"),
		buttonText = hex("E8E8FF"),
		statValue  = hex("E8E8FF"),
		statLabel  = hex("8888BB"),
		stroke     = hex("00E5FF"),
		strokeT    = 0.45,
		tileTint   = { color = hex("00E5FF"), amount = 0.14 },   -- elektrik mavisine kayar
	},
	Sunset = {
		screen     = hex("2B1B2E"),
		board      = hex("3D2438"),
		empty      = hex("5C3448"),
		text       = hex("FFE8D6"),
		button     = hex("3D2438"),
		buttonText = hex("FFE8D6"),
		statValue  = hex("FFE8D6"),
		statLabel  = hex("C89B8C"),
		stroke     = hex("FF8C42"),
		strokeT    = 0.35,
		tileTint   = { color = hex("FF8C42"), amount = 0.2 },    -- gun batimi sicakligina kayar
	},
}

-- Tema sirasi ve kilidi (sunucudaki THEME_UNLOCK ile ayni tutulmali)
local THEME_ORDER = { "Light", "Dark", "Neon", "Sunset" }
local THEME_UNLOCK = { Neon = "themeNeon", Sunset = "themeSunset" }
local THEME_ICON = { Light = "☀️", Dark = "🌙", Neon = "💡", Sunset = "🌇" }

local TILE_COLORS = {
	[2]    = hex("FFD700"),
	[4]    = hex("FF8C00"),
	[8]    = hex("FF4500"),
	[16]   = hex("FF1493"),
	[32]   = hex("00E676"),
	[64]   = hex("00E5FF"),
	[128]  = hex("2979FF"),
	[256]  = hex("AA00FF"),
	[512]  = hex("F50057"),
	[1024] = hex("FFAB00"),
	[2048] = hex("00E676"), -- 2048+ taban rengi; Heartbeat'te hue dongusuyle ezilir
}

local ACCENT     = hex("2979FF")
local DARK_TEXT  = Color3.fromRGB(55, 55, 55)
local WHITE_TEXT = Color3.new(1, 1, 1)

local function textColorFor(bg)
	local lum = 0.299 * bg.R + 0.587 * bg.G + 0.114 * bg.B
	return (lum > 0.62) and DARK_TEXT or WHITE_TEXT
end

-- MAGAZA KATALOGU (sunucuyla birebir ayni tutulmali; metinler yalnizca istemcide)
-- Fiyatlar seviye basina ~2.5x katlanir (sunucuyla birebir ayni tutulmali)
local SHOP = {
	{ id = "spawn", max = 5, costs = { 75, 190, 470, 1200, 3000 },
	  name = "Lucky Spawns", desc = "+10% chance of 4s per level, 8s at Lv4+" },
	{ id = "start", max = 3, costs = { 250, 750, 2250 },
	  name = "Head Start", desc = "Start each run with a bonus tile (8/16/32)" },
	{ id = "undo",  max = 3, costs = { 150, 450, 1350 },
	  name = "Undo", desc = "+1 undo per run per level" },
	{ id = "coin",  max = 4, costs = { 300, 900, 2700, 8100 },
	  name = "Coin Rush", desc = "+25% coins earned per level" },
	{ id = "grid5", max = 2, costs = { 5000, 20000 },
	  name = "Bigger Board", desc = "Lv1 unlocks 5x5, Lv2 unlocks 6x6 (switch in shop)" },
	{ id = "themeNeon", max = 1, costs = { 15000 },
	  name = "Neon Theme", desc = "Cosmetic: deep blue neon palette" },
	{ id = "themeSunset", max = 1, costs = { 25000 },
	  name = "Sunset Theme", desc = "Cosmetic: warm dusk palette" },
}

-- ========================================================================
-- SES: asset ID'leri buraya yapistir (0 birakilan ses calmaz)
-- ========================================================================
local SOUND_IDS = {
	move      = 93910757377994,    -- kaydirma (birlestirmesiz gecerli hamle)
	merge     = 100659874443815,   -- birlestirme
	buy       = 101429305734272,   -- magaza satin alma
	gameOver  = 127143445001460,   -- tur bitti
	milestone = 106777367308214,   -- 2048 / 4096 / 8192 kutlamasi
	daily     = 101429305734272,   -- gunluk odul (coin sesiyle ayni)
}
local SOUND_VOLUME = 0.5   -- %100 seviyedeki tavan ses siddeti

-- Ayarlar panelindeki sira ve gorunen adlar (sunucudaki SOUND_KEYS ile ayni kume)
local SOUND_ORDER = { "move", "merge", "milestone", "buy", "gameOver", "daily" }
local SOUND_LABELS = {
	move      = "Slide",
	merge     = "Merge",
	milestone = "Celebration",
	buy       = "Shop purchase",
	gameOver  = "Game over",
	daily     = "Daily bonus",
}

-- Ses tercihi tek noktadan yonetilir: master seviye + sessize alma.
-- Ses basina ayri anahtar yerine bu yontem tercih edildi (standart oyun UX'i).
local soundVolume = 70      -- 0-100, sunucudan yuklenir
local soundMuted = false
local soundOff = {}         -- kapatilmis ses anahtarlari (ayarlardan)
local sounds = {}           -- [ad] = sablon Sound (calinmaz, klonlanir)
local soundFolder = nil     -- sablonlarin ve calan kopyalarin kabi

local function effectiveVolume()
	if soundMuted then return 0 end
	return SOUND_VOLUME * (soundVolume / 100)
end

local function applySoundVolume()
	local vol = effectiveVolume()
	if not soundFolder then return end
	-- Sablonlar ve o an calan kopyalar birlikte guncellenir (mute aninda etki eder)
	for _, child in ipairs(soundFolder:GetChildren()) do
		if child:IsA("Sound") then child.Volume = vol end
	end
end

local function initSounds(parent)
	soundFolder = Instance.new("Folder")
	soundFolder.Name = "SFX"
	soundFolder.Parent = parent

	local vol = effectiveVolume()
	local preload = {}
	for name, id in pairs(SOUND_IDS) do
		if id ~= 0 then
			local s = Instance.new("Sound")
			s.Name = "SFX_" .. name
			s.SoundId = "rbxassetid://" .. id
			s.Volume = vol
			s.Parent = soundFolder
			sounds[name] = s
			table.insert(preload, s)
		end
	end
	-- Onbellege al: yuklenmemis ses ilk tetiklemelerde sessiz kalir
	if #preload > 0 then
		task.spawn(function()
			pcall(function() ContentProvider:PreloadAsync(preload) end)
		end)
	end
end

-- Her tetiklemede sablonun kopyasi calinir. Tek Sound'u tekrar tekrar Play()
-- etmek arka arkaya hamlelerde sesi bastan baslatip duyulmaz hale getiriyordu.
-- scale: bu tetikleme icin siddet carpani (1 = tam). Ust uste binen seslerde
-- ikincil olani kismak icin kullanilir.
local function playSound(name, scale)
	if soundMuted or soundVolume <= 0 or soundOff[name] then return end
	local template = sounds[name]
	if not template or not soundFolder then return end
	local s = template:Clone()
	s.Volume = effectiveVolume() * (scale or 1)
	s.Parent = soundFolder
	s:Play()
	s.Ended:Once(function() s:Destroy() end)
	Debris:AddItem(s, 6)   -- Ended gelmezse (yuklenemeyen ses) sizinti olmasin
end

local function tileBonus(maxTile)
	if maxTile >= 4096 then return 400
	elseif maxTile >= 2048 then return 150
	elseif maxTile >= 1024 then return 60
	elseif maxTile >= 512 then return 25
	elseif maxTile >= 256 then return 10 end
	return 0
end

-- vip: 2x Coins gamepass sahipligi (sunucudaki kopyayla birebir ayni olmali)
-- Tahta boyutu: taban 4x4, grid5 seviyesi basina +1 (sunucuyla ayni)
local BASE_BOARD_SIZE = 4

local function coinsForRun(score, maxTile, coinLv, vip)
	local base = math.floor(score / 200) + tileBonus(maxTile)
	local total = math.floor(base * (1 + 0.25 * coinLv))
	if vip then total *= 2 end
	return total
end

-- ========================================================================
-- 2. CORE SIM (sunucu ile birebir ayni tutulmali)
-- ========================================================================
local DIRECTIONS = {
	Left  = function(i, n) local t = {} for j = 1, n do t[j] = { i, j } end return t end,
	Right = function(i, n) local t = {} for j = 1, n do t[j] = { i, n - j + 1 } end return t end,
	Up    = function(i, n) local t = {} for j = 1, n do t[j] = { j, i } end return t end,
	Down  = function(i, n) local t = {} for j = 1, n do t[j] = { n - j + 1, i } end return t end,
}

local function deepCopy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = deepCopy(v) end
	return out
end

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
-- 3. REMOTES (Server.server.lua olusturur)
-- ========================================================================
local GetData   = ReplicatedStorage:WaitForChild("NM_GetData")   -- RemoteFunction
local Act       = ReplicatedStorage:WaitForChild("NM_Act")       -- RemoteFunction
local MoveEvent = ReplicatedStorage:WaitForChild("NM_Move")      -- RemoteEvent (C->S)
local SyncEvent = ReplicatedStorage:WaitForChild("NM_Sync")      -- RemoteEvent (S->C)

local function act(req)
	local ok, res = pcall(function()
		return Act:InvokeServer(req)
	end)
	if ok and type(res) == "table" then return res end
	return nil
end

-- ========================================================================
-- Oyun durumu
-- ========================================================================
local S = {
	loaded = false, busy = false, shopOpen = false,
	size = 4, board = nil, score = 0, best = 0, coins = 0,
	seed = 1, spawns = 0, undoLeft = 0, won = false, over = false,
	milestone = 0, dailyReady = false, dailyStreak = 0, dailyContinues = false, vip = false,
	up = { spawn = 0, start = 0, undo = 0, coin = 0, grid5 = 0, themeNeon = 0, themeSunset = 0 },
}
local currentTheme = "Light"

-- Tile rengi tema tonlamasindan gecer. Deger -> renk eslemesi KORUNUR
-- (oyuncu tahtayi renkten hizli okur), yalnizca tum palete ayni ton katilir.
local function tileColor(v)
	local base = TILE_COLORS[math.min(v, 2048)] or TILE_COLORS[2048]
	local tint = THEMES[currentTheme].tileTint
	if tint then base = base:Lerp(tint.color, tint.amount) end
	return base
end

-- ========================================================================
-- 4. UI BUILD
-- ========================================================================
local function make(className, props, parent)
	local inst = Instance.new(className)
	for k, v in pairs(props) do inst[k] = v end
	inst.Parent = parent
	return inst
end

local function corner(parent, radius)
	return make("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

-- "Hover card" derinlik efekti: kart konteynerlerine ince UIStroke;
-- renk/saydamlik tema gecisinde topluca tween'lenir
local strokes = {}
local function stroke(parent)
	local st = make("UIStroke", {
		Thickness = 1.5,
		Color = THEMES.Light.stroke,
		Transparency = THEMES.Light.strokeT,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
	table.insert(strokes, st)
	return st
end

-- Coin ikonu: altin daire + kalin "$" (asset bagimsiz, her temada net gorunur)
local function coinIcon(parent, size, zindex)
	local icon = make("Frame", {
		Name = "CoinIcon",
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = hex("FFD700"),
		BorderSizePixel = 0,
		ZIndex = zindex or 2,
	}, parent)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, icon)
	make("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		Text = "$",
		TextColor3 = Color3.fromRGB(120, 85, 0),
		TextScaled = true,
		ZIndex = (zindex or 2) + 1,
	}, icon)
	return icon
end

local gui = make("ScreenGui", {
	Name = "NeonMerge2048",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, playerGui)

local screenBg = make("Frame", {
	Name = "ScreenBackground",
	Size = UDim2.fromScale(1, 1),
	BorderSizePixel = 0,
}, gui)

local container = make("Frame", {
	Name = "Container",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromScale(0.94, 0.94),
	BackgroundTransparency = 1,
}, screenBg)
make("UISizeConstraint", { MaxSize = Vector2.new(450, 578) }, container)

-- Header satir 1: baslik + butonlar (UNDO / NEW / SHOP / tema), 54px
local headerTop = make("Frame", {
	Name = "HeaderTop",
	Size = UDim2.new(1, 0, 0, 54),
	BackgroundTransparency = 1,
}, container)

local title = make("TextLabel", {
	Name = "Title",
	Size = UDim2.new(1, -266, 1, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	Text = "Neon Merge\n2048",
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Left,
}, headerTop)
make("UITextSizeConstraint", { MaxTextSize = 24 }, title)

local function headerButton(name, text, width, rightOffset)
	local b = make("TextButton", {
		Name = name,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, rightOffset, 0.5, 0),
		Size = UDim2.fromOffset(width, 44),
		Font = Enum.Font.GothamBold,
		Text = text,
		TextSize = 16,
		AutoButtonColor = true,
		BorderSizePixel = 0,
	}, headerTop)
	corner(b, TILE_RADIUS)
	stroke(b)
	return b
end

-- Sag kume (sagdan sola): tema | TOP 10 | SHOP | NEW | UNDO
local themeButton = headerButton("ThemeToggle", "🌙", 48, 0)
local topButton   = headerButton("Top10", "TOP 10", 68, -54)
local shopButton  = headerButton("Shop", "SHOP", 62, -128)
local newButton   = headerButton("NewGame", "NEW", 56, -196)
local undoButton  = headerButton("Undo", "UNDO 0", 76, -258)
undoButton.Visible = false

-- Duyarli header: dar ekranda butonlar ve baslik kuculur, TOP 10 kisalir.
-- Butonlar sagdan sola dizildigi icin genislikler kumulatif hesaplanir.
local function layoutHeader()
	local width = container.AbsoluteSize.X
	if width <= 0 then return end
	local compact = width < 400
	local tiny = width < 330

	local themeW = compact and 40 or 48
	local topW   = tiny and 44 or (compact and 56 or 68)
	local shopW  = compact and 52 or 62
	local newW   = compact and 46 or 56
	local undoW  = compact and 62 or 76
	local gap    = compact and 5 or 6
	local fontSize = compact and 13 or 16
	local height = compact and 38 or 44

	topButton.Text = tiny and "TOP" or "TOP 10"

	local offset = 0
	for _, entry in ipairs({
		{ themeButton, themeW }, { topButton, topW }, { shopButton, shopW },
		{ newButton, newW }, { undoButton, undoW },
	}) do
		local button, w = entry[1], entry[2]
		button.Size = UDim2.fromOffset(w, height)
		button.Position = UDim2.new(1, -offset, 0.5, 0)
		offset += w + gap
	end
	themeButton.TextSize = compact and 18 or 22
	for _, b in ipairs({ topButton, shopButton, newButton }) do
		b.TextSize = fontSize
	end
	undoButton.TextSize = fontSize - 2

	-- Baslik, buton kumesinden arta kalan alani kullanir
	local used = themeW + topW + shopW + newW + gap * 3
	if undoButton.Visible then used += undoW + gap end
	title.Size = UDim2.new(1, -(used + 12), 1, 0)
end

layoutHeader()
container:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutHeader)

-- Header satir 2: SCORE / BEST / COINS
local headerStats = make("Frame", {
	Name = "HeaderStats",
	Position = UDim2.new(0, 0, 0, 60),
	Size = UDim2.new(1, 0, 0, 50),
	BackgroundTransparency = 1,
}, container)

local function makeStat(name, caption, index)
	local frame = make("Frame", {
		Name = name,
		Position = UDim2.new((index - 1) / 3, (index - 1) * 3, 0, 0),
		Size = UDim2.new(1 / 3, -6, 1, 0),
		BorderSizePixel = 0,
	}, headerStats)
	corner(frame, TILE_RADIUS)
	local cap = make("TextLabel", {
		Name = "Caption",
		Position = UDim2.new(0, 0, 0, 5),
		Size = UDim2.new(1, 0, 0, 12),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = caption,
		TextSize = 10,
	}, frame)
	local value = make("TextLabel", {
		Name = "Value",
		Position = UDim2.new(0, 4, 0, 17),
		Size = UDim2.new(1, -8, 1, -21),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		Text = "0",
		TextScaled = true,
	}, frame)
	make("UITextSizeConstraint", { MaxTextSize = 20 }, value)
	stroke(frame)
	return frame, cap, value
end

local scoreFrame, scoreCap, scoreValue = makeStat("Score", "SCORE", 1)
local bestFrame,  bestCap,  bestValue  = makeStat("Best",  "BEST",  2)
local coinFrame,  coinCap,  coinValue  = makeStat("Coins", "COINS", 3)

-- Coin kutusuna ikon: deger sola kayar, altin "$" dairesi basa gelir
coinIcon(coinFrame, 18, 2).Position = UDim2.new(0, 8, 0, 31)
coinValue.Position = UDim2.new(0, 28, 0, 17)
coinValue.Size = UDim2.new(1, -34, 1, -21)

-- Board: dis cerceve > gridFrame (hucreler) + animLayer (kayan ghost tile'lar)
local board = make("Frame", {
	Name = "Board",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 120),
	Size = UDim2.new(1, 0, 1, -120),
	BorderSizePixel = 0,
}, container)
corner(board, BOARD_RADIUS)
local boardStroke = stroke(board)   -- kutlama efektinde parlatilir
make("UIAspectRatioConstraint", {
	AspectRatio = 1,
	AspectType = Enum.AspectType.FitWithinMaxSize,
}, board)
make("UIPadding", {
	PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12),
	PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
}, board)

local gridFrame = make("Frame", {
	Name = "GridFrame",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
}, board)

local gridLayout = make("UIGridLayout", {
	CellSize = UDim2.new(0.25, -8, 0.25, -8),
	CellPadding = UDim2.fromOffset(10, 10),
	FillDirection = Enum.FillDirection.Horizontal,
	FillDirectionMaxCells = 4,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	SortOrder = Enum.SortOrder.LayoutOrder,
}, gridFrame)

local animLayer = make("Frame", {
	Name = "AnimLayer",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	ZIndex = 5,
}, board)

-- Efekt katmani: konfeti her seyin ustunde ciziliyor (overlay dahil)
local fxLayer = make("Frame", {
	Name = "FxLayer",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	ClipsDescendants = true,
	Active = false,
	ZIndex = 30,
}, board)
corner(fxLayer, BOARD_RADIUS)

local cells = {}   -- cells[r][c] = { frame, tile, scale }

local function buildGrid(n)
	for _, child in ipairs(gridFrame:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
	-- Tahta buyudukce bosluk ve yazi tavani kuculur (4x4 / 5x5 / 6x6)
	local pad = (n <= 4) and 10 or ((n == 5) and 8 or 6)
	local maxTextSize = (n <= 4) and 40 or ((n == 5) and 32 or 26)
	local cellRadius = (n <= 4) and TILE_RADIUS or ((n == 5) and 10 or 8)
	gridLayout.CellPadding = UDim2.fromOffset(pad, pad)
	gridLayout.CellSize = UDim2.new(1 / n, -pad, 1 / n, -pad)
	gridLayout.FillDirectionMaxCells = n
	cells = {}
	local emptyColor = THEMES[currentTheme].empty
	for r = 1, n do
		cells[r] = {}
		for c = 1, n do
			local cell = make("Frame", {
				Name = ("Cell_%d_%d"):format(r, c),
				LayoutOrder = (r - 1) * n + c,
				BackgroundColor3 = emptyColor,
				BorderSizePixel = 0,
			}, gridFrame)
			corner(cell, cellRadius)

			local tile = make("TextLabel", {
				Name = "Tile",
				Size = UDim2.fromScale(1, 1),
				BorderSizePixel = 0,
				Font = Enum.Font.GothamBlack,
				Text = "",
				TextScaled = true,
				Visible = false,
				ZIndex = 2,
			}, cell)
			corner(tile, cellRadius)
			make("UITextSizeConstraint", { MaxTextSize = maxTextSize }, tile)
			local scale = make("UIScale", { Scale = 1 }, tile)

			cells[r][c] = { frame = cell, tile = tile, scale = scale }
		end
	end
end

buildGrid(4)

-- Yukleme katmani: sunucudan kayit gelene kadar tahtanin ustunde durur.
-- Kayit gecikirse oyuncu bos tahtaya degil, durum mesajina bakar.
local loadingLayer = make("Frame", {
	Name = "LoadingLayer",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.fromRGB(15, 15, 15),
	BackgroundTransparency = 0.25,
	ZIndex = 15,
}, board)
corner(loadingLayer, BOARD_RADIUS)

local loadingText = make("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromScale(0.85, 0.25),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "Loading...",
	TextColor3 = WHITE_TEXT,
	TextScaled = true,
	ZIndex = 16,
}, loadingLayer)
make("UITextSizeConstraint", { MaxTextSize = 22 }, loadingText)

local function setLoading(text)
	loadingText.Text = text
	loadingLayer.Visible = true
end

local function hideLoading()
	loadingLayer.Visible = false
end

-- Autosave gostergesi: sunucu kayit bildirdiginde 1.5 sn gorunup soner
local saveLabel = make("TextLabel", {
	Name = "SaveIndicator",
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -4, 1, -4),
	Size = UDim2.fromOffset(110, 20),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "💾 Saving...",
	TextSize = 12,
	TextTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Right,
	ZIndex = 40,
}, container)

local saveToken = 0
local function flashSaveIndicator()
	saveToken += 1
	local token = saveToken
	saveLabel.TextColor3 = THEMES[currentTheme].statLabel
	TweenService:Create(saveLabel,
		TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ TextTransparency = 0.15 }):Play()
	task.delay(1.5, function()
		if token ~= saveToken then return end   -- yeni kayit geldi, o kendi zamanlayicisini kurar
		TweenService:Create(saveLabel,
			TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ TextTransparency = 1 }):Play()
	end)
end

-- Game over / win katmani
local overlay = make("Frame", {
	Name = "RunOverlay",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.fromRGB(15, 15, 15),
	BackgroundTransparency = 0.35,
	Visible = false,
	ZIndex = 10,
}, board)
corner(overlay, BOARD_RADIUS)

local overTitle = make("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.32),
	Size = UDim2.fromScale(0.85, 0.18),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	Text = "Game Over",
	TextColor3 = WHITE_TEXT,
	TextScaled = true,
	ZIndex = 11,
}, overlay)
make("UITextSizeConstraint", { MaxTextSize = 42 }, overTitle)

local overSub = make("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.47),
	Size = UDim2.fromScale(0.85, 0.1),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "",
	TextColor3 = hex("FFD700"),
	TextScaled = true,
	ZIndex = 11,
}, overlay)
make("UITextSizeConstraint", { MaxTextSize = 22 }, overSub)

local function overlayButton(name, text, y, bg)
	local b = make("TextButton", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, y),
		Size = UDim2.new(0.5, 0, 0, 42),
		BackgroundColor3 = bg,
		Font = Enum.Font.GothamBold,
		Text = text,
		TextColor3 = WHITE_TEXT,
		TextSize = 18,
		AutoButtonColor = true,
		BorderSizePixel = 0,
		ZIndex = 11,
	}, overlay)
	corner(b, TILE_RADIUS)
	return b
end

local primaryButton   = overlayButton("Primary", "New Game", 0.62, ACCENT)
local secondaryButton = overlayButton("Secondary", "Continue", 0.75, hex("00C853"))
secondaryButton.Visible = false

-- Gunluk odul katmani (tahtanin ustunde, yukleme bitince gosterilir)
local dailyLayer = make("Frame", {
	Name = "DailyLayer",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.fromRGB(15, 15, 15),
	BackgroundTransparency = 0.25,
	Visible = false,
	ZIndex = 12,
}, board)
corner(dailyLayer, BOARD_RADIUS)

local dailyTitle = make("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.32),
	Size = UDim2.fromScale(0.85, 0.16),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	Text = "Daily Bonus",
	TextColor3 = WHITE_TEXT,
	TextScaled = true,
	ZIndex = 13,
}, dailyLayer)
make("UITextSizeConstraint", { MaxTextSize = 34 }, dailyTitle)

local dailySub = make("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.48),
	Size = UDim2.fromScale(0.85, 0.12),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "",
	TextColor3 = hex("FFD700"),
	TextScaled = true,
	ZIndex = 13,
}, dailyLayer)
make("UITextSizeConstraint", { MaxTextSize = 20 }, dailySub)

-- Ilk oyun ipucu: yalnizca hic ilerlemesi olmayan oyuncuya, ilk gecerli hamlede yok olur
local tutorialTip = make("TextLabel", {
	Name = "TutorialTip",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.new(0.86, 0, 0, 66),
	BackgroundColor3 = Color3.fromRGB(20, 20, 24),
	BackgroundTransparency = 0.12,
	Font = Enum.Font.GothamBold,
	Text = "Swipe or press W/A/S/D to slide\nand merge identical tiles!",
	TextColor3 = WHITE_TEXT,
	TextSize = 15,
	TextWrapped = true,
	Visible = false,
	ZIndex = 25,
}, board)
corner(tutorialTip, TILE_RADIUS)

local tutorialActive = false

local function showTutorial()
	tutorialActive = true
	tutorialTip.Visible = true
	tutorialTip.TextTransparency = 1
	tutorialTip.BackgroundTransparency = 1
	TweenService:Create(tutorialTip, TweenInfo.new(0.35), {
		TextTransparency = 0, BackgroundTransparency = 0.12,
	}):Play()
	-- Hafif suzulme: dikkat ceker ama rahatsiz etmez
	task.spawn(function()
		local up = true
		while tutorialActive do
			TweenService:Create(tutorialTip,
				TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
					Position = UDim2.new(0.5, 0, 0.5, up and -6 or 6),
				}):Play()
			up = not up
			task.wait(1.1)
		end
	end)
end

local function dismissTutorial()
	if not tutorialActive then return end
	tutorialActive = false
	TweenService:Create(tutorialTip, TweenInfo.new(0.3), {
		TextTransparency = 1, BackgroundTransparency = 1,
	}):Play()
	task.delay(0.35, function()
		tutorialTip:Destroy()   -- kalici olarak yok edilir
	end)
end

local dailyButton = make("TextButton", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.66),
	Size = UDim2.new(0.5, 0, 0, 42),
	BackgroundColor3 = hex("00C853"),
	Font = Enum.Font.GothamBold,
	Text = "Claim",
	TextColor3 = WHITE_TEXT,
	TextSize = 18,
	AutoButtonColor = true,
	BorderSizePixel = 0,
	ZIndex = 13,
}, dailyLayer)
corner(dailyButton, TILE_RADIUS)

-- Magaza / leaderboard modali
local shopModal = make("Frame", {
	Name = "ShopModal",
	Size = UDim2.fromScale(1, 1),
	BorderSizePixel = 0,
	Active = true,   -- altindaki header butonlarina tiklama sizmasin
	Visible = false,
	ZIndex = 20,
}, container)
corner(shopModal, BOARD_RADIUS)
stroke(shopModal)

-- Tiklama perdesi: Active = true bir Frame'de girdiyi guvenilir sekilde yutmuyor,
-- GuiButton yutuyor. Bu olmadan modal acikken altindaki NEW / UNDO / SHOP / tema
-- butonlari tiklanabiliyordu (yanlislikla tur bitirme riski).
-- Boyut/konum UIPadding'i telafi eder: perde kenarlardaki 10 px seride de kapsar,
-- yoksa modalin dis cercevesinden alttaki butonlara tiklanabiliyor
make("TextButton", {
	Name = "InputBlocker",
	Position = UDim2.fromOffset(-10, -10),
	Size = UDim2.new(1, 20, 1, 20),
	BackgroundTransparency = 1,
	Text = "",
	AutoButtonColor = false,
	Selectable = false,
	Active = true,
	ZIndex = 20,
}, shopModal)

make("UIPadding", {
	PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10),
	PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
}, shopModal)

-- Acik sekmenin adi ortada yazar (sekme butonlari header'a tasindi)
local modalTitle = make("TextLabel", {
	Name = "ModalTitle",
	Size = UDim2.new(1, 0, 0, 34),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	Text = "SHOP",
	TextSize = 20,
	ZIndex = 21,
}, shopModal)

-- Modal alt sekme cubugu (SHOP ve TOP 10 ayni yapiyi kullanir)
local function subTabBar(name)
	return make("Frame", {
		Name = name,
		Position = UDim2.new(0, 0, 0, 40),
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 21,
	}, shopModal)
end

local function subTabButton(parent, text, xOffset)
	local b = make("TextButton", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, xOffset, 0, 0),
		Size = UDim2.fromOffset(88, 28),
		Font = Enum.Font.GothamBold,
		Text = text,
		TextSize = 13,
		AutoButtonColor = true,
		BorderSizePixel = 0,
		ZIndex = 21,
	}, parent)
	corner(b, 14)
	return b
end

-- TOP 10 alt sekmeleri: SCORE (skor siralamasi) / BLOCK (en yuksek blok siralamasi)
local topSubBar = subTabBar("TopSubBar")
local scoreTabButton = subTabButton(topSubBar, "SCORE", -47)
local blockTabButton = subTabButton(topSubBar, "BLOCK", 47)

-- SHOP alt sekmeleri: COIN (coin ile alinanlar) / ROBUX (Robux urunleri)
local shopSubBar = subTabBar("ShopSubBar")
local coinTabButton  = subTabButton(shopSubBar, "COIN", -47)
local robuxTabButton = subTabButton(shopSubBar, "ROBUX", 47)

local closeButton = make("TextButton", {
	Name = "Close",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, 0, 0, 0),
	Size = UDim2.fromOffset(34, 34),
	Font = Enum.Font.GothamBold,
	Text = "X",
	TextSize = 16,
	AutoButtonColor = true,
	BorderSizePixel = 0,
	ZIndex = 21,
}, shopModal)
corner(closeButton, TILE_RADIUS)

local shopList = make("ScrollingFrame", {
	Name = "List",
	Position = UDim2.new(0, 0, 0, 42),
	Size = UDim2.new(1, 0, 1, -42),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ZIndex = 21,
}, shopModal)
make("UIListLayout", {
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, shopList)

-- Kendi siralaman: TOP 10 sekmesinde altta sabit bar (RANK / BEST / BLOCK)
local meBar = make("Frame", {
	Name = "MeBar",
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 0, 1, 0),
	Size = UDim2.new(1, 0, 0, 48),
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 21,
}, shopModal)
corner(meBar, TILE_RADIUS)

-- Iki alan: sirandaki yer + aktif sekmenin metrigi (baslik sekmeye gore degisir)
local meCaps, meVals = {}, {}
local function meStat(caption, index)
	local cap = make("TextLabel", {
		Position = UDim2.new((index - 1) / 2, 0, 0, 6),
		Size = UDim2.new(0.5, 0, 0, 12),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = caption,
		TextSize = 10,
		ZIndex = 22,
	}, meBar)
	local val = make("TextLabel", {
		Position = UDim2.new((index - 1) / 2, 0, 0, 20),
		Size = UDim2.new(0.5, 0, 0, 22),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		Text = "-",
		TextSize = 16,
		ZIndex = 22,
	}, meBar)
	table.insert(meCaps, cap)
	table.insert(meVals, val)
	return val, cap
end
local meRankVal = meStat("RANK", 1)
local meMetricVal, meMetricCap = meStat("SCORE", 2)

-- ========================================================================
-- AYARLAR: sag alt disk butonu + panel (master seviye, ses basina anahtar,
-- veri sifirlama). Tum widget'lar tek tabloda: Luau'nun 200 top-level local
-- sinirini zorlamamak icin.
-- ========================================================================
local SET = { toggles = {} }

SET.button = make("TextButton", {
	Name = "SettingsButton",
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -16, 1, -16),
	Size = UDim2.fromOffset(46, 46),
	Font = Enum.Font.GothamBold,
	Text = "⚙",
	TextSize = 24,
	AutoButtonColor = true,
	BorderSizePixel = 0,
	ZIndex = 45,
}, screenBg)
corner(SET.button, TILE_RADIUS)
stroke(SET.button)

-- Tam ekran perde
SET.modal = make("Frame", {
	Name = "SettingsModal",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.fromRGB(10, 10, 12),
	BackgroundTransparency = 0.45,
	Active = true,
	Visible = false,
	ZIndex = 60,
}, screenBg)

-- Tiklama perdesi (shopModal ile ayni gerekce): Frame tek basina girdiyi
-- guvenilir yutmuyor, alttaki header butonlari tiklanabiliyordu
make("TextButton", {
	Name = "InputBlocker",
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Text = "",
	AutoButtonColor = false,
	Selectable = false,
	Active = true,
	ZIndex = 60,
}, SET.modal)

SET.panel = make("Frame", {
	Name = "Panel",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.new(0.92, 0, 0.86, 0),
	Active = true,
	BorderSizePixel = 0,
	ZIndex = 61,
}, SET.modal)
corner(SET.panel, BOARD_RADIUS)
stroke(SET.panel)
make("UISizeConstraint", { MaxSize = Vector2.new(420, 520) }, SET.panel)
make("UIPadding", {
	PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12),
	PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
}, SET.panel)

SET.title = make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 30),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	Text = "SETTINGS",
	TextSize = 20,
	ZIndex = 62,
}, SET.panel)

SET.close = make("TextButton", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, 0, 0, 0),
	Size = UDim2.fromOffset(32, 32),
	Font = Enum.Font.GothamBold,
	Text = "X",
	TextSize = 16,
	AutoButtonColor = true,
	BorderSizePixel = 0,
	ZIndex = 62,
}, SET.panel)
corner(SET.close, TILE_RADIUS)

-- Icerik listesi: panel kucuk ekranda tasmasin diye kaydirilabilir
SET.list = make("ScrollingFrame", {
	Name = "List",
	Position = UDim2.new(0, 0, 0, 40),
	Size = UDim2.new(1, 0, 1, -40),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ZIndex = 62,
}, SET.panel)
make("UIListLayout", {
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, SET.list)

-- Ayar satiri olusturucu (magazadaki shopRow'un ayarlar karsiligi)
local function setRow(height, order)
	local row = make("Frame", {
		Size = UDim2.new(1, -6, 0, height),
		LayoutOrder = order,
		BorderSizePixel = 0,
		ZIndex = 62,
	}, SET.list)
	corner(row, TILE_RADIUS)
	return row
end

-- 1) Master seviye + sessize alma
SET.row = setRow(134, 1)

SET.label = make("TextLabel", {
	Position = UDim2.fromOffset(14, 12),
	Size = UDim2.new(1, -100, 0, 20),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "MASTER VOLUME",
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Left,
	ZIndex = 63,
}, SET.row)

SET.percent = make("TextLabel", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -14, 0, 12),
	Size = UDim2.fromOffset(80, 20),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	Text = "70%",
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Right,
	ZIndex = 63,
}, SET.row)

-- Gorunmez genis dokunma alani: 10 px'lik cizgi mobilde tutulamaz.
-- TextButton oldugu icin isaretci girdisini kendisi alir.
SET.hit = make("TextButton", {
	Position = UDim2.fromOffset(14, 40),
	Size = UDim2.new(1, -28, 0, 40),
	BackgroundTransparency = 1,
	Text = "",
	AutoButtonColor = false,
	Active = true,
	ZIndex = 64,
}, SET.row)

SET.track = make("Frame", {
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 0, 0.5, 0),
	Size = UDim2.new(1, 0, 0, 10),
	BorderSizePixel = 0,
	ZIndex = 63,
}, SET.hit)
corner(SET.track, 5)

SET.fill = make("Frame", {
	Size = UDim2.fromScale(0.7, 1),
	BackgroundColor3 = ACCENT,
	BorderSizePixel = 0,
	ZIndex = 64,
}, SET.track)
corner(SET.fill, 5)

SET.knob = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.7, 0.5),
	Size = UDim2.fromOffset(20, 20),
	BackgroundColor3 = ACCENT,
	BorderSizePixel = 0,
	ZIndex = 65,
}, SET.track)
corner(SET.knob, 10)

SET.mute = make("TextButton", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 14, 1, -12),
	Size = UDim2.fromOffset(112, 34),
	Font = Enum.Font.GothamBold,
	Text = "MUTE ALL",
	TextSize = 13,
	AutoButtonColor = true,
	BorderSizePixel = 0,
	ZIndex = 63,
}, SET.row)
corner(SET.mute, 17)

SET.hint = make("TextLabel", {
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -14, 1, -12),
	Size = UDim2.new(1, -140, 0, 34),
	BackgroundTransparency = 1,
	Font = Enum.Font.Gotham,
	Text = "Applies to all game sounds",
	TextSize = 11,
	TextXAlignment = Enum.TextXAlignment.Right,
	ZIndex = 63,
}, SET.row)

-- 2) Ses basina ac/kapa anahtarlari
SET.soundsHeader = make("TextLabel", {
	Size = UDim2.new(1, -6, 0, 18),
	LayoutOrder = 2,
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBold,
	Text = "  INDIVIDUAL SOUNDS",
	TextSize = 10,
	TextXAlignment = Enum.TextXAlignment.Left,
	ZIndex = 62,
}, SET.list)

SET.soundLabels = {}
for i, key in ipairs(SOUND_ORDER) do
	local row = setRow(44, 2 + i)
	SET.soundLabels[key] = make("TextLabel", {
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -104, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = SOUND_LABELS[key],
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 63,
	}, row)
	local toggle = make("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(72, 30),
		Font = Enum.Font.GothamBold,
		Text = "ON",
		TextSize = 13,
		AutoButtonColor = true,
		BorderSizePixel = 0,
		ZIndex = 63,
	}, row)
	corner(toggle, 15)
	SET.toggles[key] = toggle
end

-- 3) Veri sifirlama (magazadan buraya tasindi)
SET.resetRow = setRow(58, 20)
SET.reset = make("TextButton", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.new(1, -28, 0, 36),
	BackgroundColor3 = hex("5C3448"),
	Font = Enum.Font.GothamBold,
	Text = "RESET ALL DATA",
	TextColor3 = hex("FFB3B3"),
	TextSize = 13,
	AutoButtonColor = true,
	BorderSizePixel = 0,
	ZIndex = 63,
}, SET.resetRow)
corner(SET.reset, TILE_RADIUS)

-- ========================================================================
-- 5. THEME MANAGER
-- ========================================================================
-- Ileri bildirimler: tema degisiminde magaza ve ayar paneli yeniden boyanir
local rebuildShop
local refreshSoundUI

local function tween(inst, props)
	TweenService:Create(inst, THEME_TWEEN, props):Play()
end

local function applyTheme(name)
	currentTheme = name
	local t = THEMES[name]
	tween(screenBg, { BackgroundColor3 = t.screen })
	tween(board, { BackgroundColor3 = t.board })
	tween(shopModal, { BackgroundColor3 = t.board })
	tween(title, { TextColor3 = t.text })
	for _, b in ipairs({ themeButton, topButton, shopButton, newButton, undoButton,
		closeButton, SET.button, SET.close }) do
		tween(b, { BackgroundColor3 = t.button, TextColor3 = t.buttonText })
	end
	tween(SET.panel, { BackgroundColor3 = t.board })
	tween(SET.title, { TextColor3 = t.text })
	tween(SET.row, { BackgroundColor3 = t.empty })
	tween(SET.resetRow, { BackgroundColor3 = t.empty })
	tween(SET.track, { BackgroundColor3 = t.button })
	tween(SET.soundsHeader, { TextColor3 = t.statLabel })
	local rowText = textColorFor(t.empty)
	tween(SET.label, { TextColor3 = rowText })
	tween(SET.percent, { TextColor3 = rowText })
	tween(SET.hint, { TextColor3 = rowText, TextTransparency = 0.35 })
	for _, key in ipairs(SOUND_ORDER) do
		tween(SET.soundLabels[key], { TextColor3 = rowText })
		SET.toggles[key].Parent.BackgroundColor3 = t.empty
	end
	-- Anahtar butonlarinin renkleri durum bagimli: paneldeyken yeniden hesapla
	if refreshSoundUI and SET.modal.Visible then refreshSoundUI() end
	-- Alt sekmelerin pasif olani tema rengini alir; aktif olan rebuildShop'ta mavi boyanir
	if shopModal.Visible then rebuildShop() end
	tween(modalTitle, { TextColor3 = t.text })
	for _, statFrame in ipairs({ scoreFrame, bestFrame, coinFrame }) do
		tween(statFrame, { BackgroundColor3 = t.button })
	end
	for _, capLabel in ipairs({ scoreCap, bestCap, coinCap }) do
		tween(capLabel, { TextColor3 = t.statLabel })
	end
	for _, valLabel in ipairs({ scoreValue, bestValue, coinValue }) do
		tween(valLabel, { TextColor3 = t.statValue })
	end
	for _, st in ipairs(strokes) do
		tween(st, { Color = t.stroke, Transparency = t.strokeT })
	end
	for r = 1, S.size do
		for c = 1, S.size do
			local cell = cells[r][c]
			tween(cell.frame, { BackgroundColor3 = t.empty })
			-- Tile'lar da tema tonlamasini alir; deger-renk eslemesi degismez
			if S.board and S.board[r] and (S.board[r][c] or 0) > 0 then
				local color = tileColor(S.board[r][c])
				tween(cell.tile, { BackgroundColor3 = color, TextColor3 = textColorFor(color) })
			end
		end
	end
	themeButton.Text = THEME_ICON[name] or "☀️"
	-- Mute butonu durum rengini korur (aktifken kirmizimsi)
	if soundMuted then
		SET.mute.BackgroundColor3 = hex("D32F2F")
		SET.mute.TextColor3 = WHITE_TEXT
	else
		tween(SET.mute, { BackgroundColor3 = t.button, TextColor3 = t.buttonText })
	end
end

-- Acik temalar: Light/Dark her zaman, digerleri magazadan alinmissa
local function unlockedThemes()
	local list = {}
	for _, name in ipairs(THEME_ORDER) do
		local req = THEME_UNLOCK[name]
		if not req or (S.up[req] or 0) > 0 then
			table.insert(list, name)
		end
	end
	return list
end

-- Temayi uygula + sunucuya kaydet. Hiz sinirina takilirsa tekrar dener,
-- yoksa sunucu eski temayi kaydeder ve tekrar giriste secim geri doner.
local function setTheme(name)
	applyTheme(name)
	task.spawn(function()
		for _ = 1, 3 do
			local res = act({ a = "theme", t = name })
			if not (res and res.err == "too_fast") then return end
			task.wait(0.2)
		end
	end)
end

themeButton.Activated:Connect(function()
	if not S.loaded then return end   -- yukleme bitmeden secim sunucuda kaydedilemez
	local list = unlockedThemes()
	local index = 1
	for i, name in ipairs(list) do
		if name == currentTheme then index = i break end
	end
	setTheme(list[(index % #list) + 1])
end)

-- ========================================================================
-- AYARLAR: kaydirici surukleme + kalici tercih
-- ========================================================================
local settingsOpen = false
local dragInput = nil   -- suruklemeyi baslatan InputObject (coklu dokunmayi ayirt eder)

refreshSoundUI = function()
	local t = THEMES[currentTheme]
	local ratio = soundVolume / 100
	SET.fill.Size = UDim2.fromScale(ratio, 1)
	SET.knob.Position = UDim2.fromScale(ratio, 0.5)
	SET.percent.Text = soundMuted and "MUTED" or (soundVolume .. "%")
	local dim = soundMuted and hex("6E6E76") or ACCENT
	SET.fill.BackgroundColor3 = dim
	SET.knob.BackgroundColor3 = dim
	if soundMuted then
		SET.mute.Text = "UNMUTE"
		SET.mute.BackgroundColor3 = hex("D32F2F")
		SET.mute.TextColor3 = WHITE_TEXT
	else
		SET.mute.Text = "MUTE ALL"
		SET.mute.BackgroundColor3 = t.button
		SET.mute.TextColor3 = t.buttonText
	end
	-- Ses basina anahtarlar: acikken yesil, kapaliyken tema rengi.
	-- Master mute aciksa hepsi soluk gorunur (etkisiz oldugu belli olsun).
	for _, key in ipairs(SOUND_ORDER) do
		local button = SET.toggles[key]
		local on = not soundOff[key]
		button.Text = on and "ON" or "OFF"
		button.BackgroundColor3 = on and hex("00C853") or t.button
		button.TextColor3 = on and WHITE_TEXT or t.statLabel
		button.BackgroundTransparency = soundMuted and 0.5 or 0
	end
end

-- Tercihi sunucuya yaz (kaydirici birakilinca tek istek; hiz sinirinda tekrar dener)
local function pushSoundSetting()
	task.spawn(function()
		for _ = 1, 3 do
			local res = act({ a = "sfx", vol = soundVolume, muted = soundMuted, off = soundOff })
			if not (res and res.err == "too_fast") then return end
			task.wait(0.2)
		end
	end)
end

local function setVolumeFromX(x)
	local left = SET.track.AbsolutePosition.X
	local width = SET.track.AbsoluteSize.X
	if width <= 0 then return end
	soundVolume = math.clamp(math.floor(((x - left) / width) * 100 + 0.5), 0, 100)
	if soundVolume > 0 then soundMuted = false end
	applySoundVolume()
	refreshSoundUI()
end

SET.hit.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragInput = input
		setVolumeFromX(input.Position.X)
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if not dragInput then return end
	-- Fare surukleme ayri bir InputObject uretir; dokunmada ayni parmak olmali
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		setVolumeFromX(input.Position.X)
	elseif input == dragInput then
		setVolumeFromX(input.Position.X)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if not dragInput then return end
	if input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1 then
		dragInput = nil
		pushSoundSetting()   -- yalnizca birakinca kaydedilir, istek seli olmaz
	end
end)

SET.mute.Activated:Connect(function()
	if not S.loaded then return end
	soundMuted = not soundMuted
	if not soundMuted and soundVolume == 0 then soundVolume = 50 end
	applySoundVolume()
	refreshSoundUI()
	pushSoundSetting()
end)

-- Ses basina ac/kapa: kapali ses hic calmaz, seviye ayarindan bagimsizdir
for _, key in ipairs(SOUND_ORDER) do
	SET.toggles[key].Activated:Connect(function()
		if not S.loaded then return end
		soundOff[key] = (not soundOff[key]) or nil
		refreshSoundUI()
		pushSoundSetting()
	end)
end

local function setSettingsOpen(open)
	settingsOpen = open
	SET.modal.Visible = open
	if open then
		refreshSoundUI()
	else
		dragInput = nil   -- panel kapanirken takili surukleme kalmasin
	end
end

SET.button.Activated:Connect(function()
	-- Yukleme bitmeden acilirsa tercih sunucuya yazilamaz ve applyState ezer
	if not S.loaded then return end
	setSettingsOpen(not settingsOpen)
end)

SET.close.Activated:Connect(function()
	setSettingsOpen(false)
end)

-- ========================================================================
-- 6. RENDER + ANIMASYON + GORSEL EFEKTLER
-- ========================================================================

-- Yuksek degerli birlestirmede (512+) kisa, sert tahta sarsintisi (~0.12 sn)
local BOARD_BASE_POS = board.Position
local shakeToken = 0

local function shakeBoard()
	shakeToken += 1
	local token = shakeToken
	task.spawn(function()
		local steps = 4
		for i = 1, steps do
			if token ~= shakeToken then return end
			local decay = 1 - (i - 1) / steps
			local mag = (2 + math.random() * 2) * decay   -- 2-4 px, sonuna dogru soner
			local angle = math.random() * math.pi * 2
			TweenService:Create(board, TweenInfo.new(0.03, Enum.EasingStyle.Linear), {
				Position = BOARD_BASE_POS + UDim2.fromOffset(
					math.cos(angle) * mag, math.sin(angle) * mag),
			}):Play()
			task.wait(0.03)
		end
		if token == shakeToken then
			TweenService:Create(board, TweenInfo.new(0.03, Enum.EasingStyle.Quad), {
				Position = BOARD_BASE_POS,
			}):Play()
		end
	end)
end

-- Kutlama: renkli konfeti parcaciklari + tahta cercevesinin parlamasi
local CONFETTI_COLORS = {
	hex("FFD700"), hex("FF4500"), hex("FF1493"),
	hex("00E676"), hex("00E5FF"), hex("AA00FF"),
}

local function pulseStroke()
	TweenService:Create(boardStroke,
		TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Transparency = 0, Thickness = 4 }):Play()
	task.delay(0.22, function()
		-- Tema bu arada degismis olabilir: guncel degerlere don
		TweenService:Create(boardStroke,
			TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Transparency = THEMES[currentTheme].strokeT, Thickness = 1.5 }):Play()
	end)
end

local function burstConfetti(count)
	pulseStroke()
	for i = 1, count do
		local size = math.random(6, 13)
		local piece = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.15 + math.random() * 0.7, -0.05 - math.random() * 0.15),
			Size = UDim2.fromOffset(size, size),
			BackgroundColor3 = CONFETTI_COLORS[math.random(#CONFETTI_COLORS)],
			BorderSizePixel = 0,
			Rotation = math.random(0, 360),
			ZIndex = 31,
		}, fxLayer)
		corner(piece, math.floor(size / 2))
		local fallTime = 0.9 + math.random() * 0.7
		TweenService:Create(piece, TweenInfo.new(fallTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.fromScale(
				math.clamp(piece.Position.X.Scale + (math.random() - 0.5) * 0.3, 0, 1), 1.15),
			Rotation = piece.Rotation + math.random(-260, 260),
		}):Play()
		TweenService:Create(piece, TweenInfo.new(fallTime, Enum.EasingStyle.Linear), {
			BackgroundTransparency = 1,
		}):Play()
		task.delay(fallTime + 0.05, function()
			piece:Destroy()
		end)
	end
end

local function popTile(scale)
	scale.Scale = 0.8
	local up = TweenService:Create(scale,
		TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1.05 })
	up:Play()
	up.Completed:Once(function()
		TweenService:Create(scale,
			TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end)
end

local function updateHUD()
	scoreValue.Text = tostring(S.score)
	bestValue.Text = tostring(S.best)
	coinValue.Text = tostring(S.coins)
	undoButton.Text = "UNDO " .. S.undoLeft
	undoButton.Visible = (S.up.undo > 0)
	layoutHeader()   -- UNDO gorunurlugu degisince baslik alani yeniden hesaplanir
end

local function render(popSet)
	for r = 1, S.size do
		for c = 1, S.size do
			local v = S.board[r][c]
			local cell = cells[r][c]
			if v == 0 then
				cell.tile.Visible = false
			else
				local color = tileColor(v)
				cell.tile.Visible = true
				cell.tile.Text = tostring(v)
				cell.tile.BackgroundColor3 = color
				cell.tile.TextColor3 = textColorFor(color)
				if popSet and popSet[r .. "_" .. c] then
					popTile(cell.scale)
				end
			end
		end
	end
	if S.score > S.best then S.best = S.score end
	updateHUD()
end

-- Kayma animasyonu: eski tahtadaki her tile icin ghost olusturup hedefe tween'ler
local function playSlide(anims, done)
	for r = 1, S.size do
		for c = 1, S.size do
			cells[r][c].tile.Visible = false
		end
	end
	local layerPos = animLayer.AbsolutePosition
	local ghosts = {}
	-- Ghost'lar hucrelerle ayni koseyi ve yazi tavanini kullanir (4x4 / 5x5 / 6x6)
	local ghostRadius = (S.size <= 4) and TILE_RADIUS or ((S.size == 5) and 10 or 8)
	local ghostTextMax = (S.size <= 4) and 40 or ((S.size == 5) and 32 or 26)
	for _, a in ipairs(anims) do
		local fromCell = cells[a.fr][a.fc].frame
		local toCell = cells[a.tr][a.tc].frame
		local color = tileColor(a.v)
		local ghost = make("TextLabel", {
			Position = UDim2.fromOffset(
				fromCell.AbsolutePosition.X - layerPos.X,
				fromCell.AbsolutePosition.Y - layerPos.Y),
			Size = UDim2.fromOffset(fromCell.AbsoluteSize.X, fromCell.AbsoluteSize.Y),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBlack,
			Text = tostring(a.v),
			TextColor3 = textColorFor(color),
			TextScaled = true,
			ZIndex = 6,
		}, animLayer)
		corner(ghost, ghostRadius)
		make("UITextSizeConstraint", { MaxTextSize = ghostTextMax }, ghost)
		table.insert(ghosts, ghost)
		if a.fr ~= a.tr or a.fc ~= a.tc then
			TweenService:Create(ghost,
				TweenInfo.new(SLIDE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Position = UDim2.fromOffset(
						toCell.AbsolutePosition.X - layerPos.X,
						toCell.AbsolutePosition.Y - layerPos.Y),
				}):Play()
		end
	end
	task.delay(SLIDE_TIME + 0.02, function()
		for _, g in ipairs(ghosts) do g:Destroy() end
		done()
	end)
end

-- 2048+ tile'lari icin dinamik neon hue dongusu
RunService.Heartbeat:Connect(function()
	if not S.board then return end
	local hue = (os.clock() * 0.35) % 1
	local rainbow = Color3.fromHSV(hue, 0.8, 1)
	local txt = textColorFor(rainbow)
	for r = 1, S.size do
		for c = 1, S.size do
			if S.board[r] and S.board[r][c] and S.board[r][c] >= 2048 then
				local tile = cells[r][c].tile
				if tile.Visible then
					tile.BackgroundColor3 = rainbow
					tile.TextColor3 = txt
				end
			end
		end
	end
end)

-- ========================================================================
-- 7. GAME FLOW
-- ========================================================================
-- Hamle paketleme: ilk hamle aninda gider (gecikme yok), pencere icindeki
-- arka arkaya hamleler tek pakette birlesir. Sira korundugu icin sunucu
-- simulasyonu istemciyle birebir ayni kalir.
local moveQueue = {}
local moveFlushScheduled = false
local lastFlushAt = -math.huge
local MOVE_FLUSH_WINDOW = 0.2

local function flushMoves()
	moveFlushScheduled = false
	if #moveQueue == 0 then return end
	local batch = moveQueue
	moveQueue = {}
	lastFlushAt = os.clock()
	MoveEvent:FireServer(batch)
end

local function queueMove(dir)
	table.insert(moveQueue, dir)
	local sinceFlush = os.clock() - lastFlushAt
	if sinceFlush >= MOVE_FLUSH_WINDOW then
		flushMoves()
	elseif not moveFlushScheduled then
		moveFlushScheduled = true
		task.delay(MOVE_FLUSH_WINDOW - sinceFlush, flushMoves)
	end
end

-- Sunucu tam durum gonderdiginde bekleyen hamleler gecersizdir
local function dropQueuedMoves()
	moveQueue = {}
	moveFlushScheduled = false
end

local function showOver(earned)
	overTitle.Text = "Game Over"
	-- earned nil ise (resync yolu) odul metni gosterilmez; kesin degeri NM_Sync yazar
	overSub.Text = earned and ("+" .. earned .. " COINS") or ""
	primaryButton.Text = "New Game"
	secondaryButton.Visible = false
	overlay.Visible = true
end

local function showWin(tile)
	overTitle.Text = tostring(tile or 2048) .. "!"
	overSub.Text = "Milestone reached, keep going!"
	primaryButton.Text = "New Game"
	secondaryButton.Visible = true
	overlay.Visible = true
end

-- Sunucudan gelen tam durumu uygula
local function applyState(state, earned)
	if type(state) ~= "table" then return end
	dropQueuedMoves()   -- sunucu durumu otorite; bekleyen hamleler uygulanmamali
	S.coins = state.coins or S.coins
	S.best = state.best or S.best
	S.up = state.up or S.up
	if state.dailyReady ~= nil then S.dailyReady = state.dailyReady end
	if state.dailyStreak ~= nil then S.dailyStreak = state.dailyStreak end
	if state.dailyContinues ~= nil then S.dailyContinues = state.dailyContinues end
	if state.vip ~= nil then S.vip = state.vip == true end   -- 2x Coins gamepass
	-- Ses tercihi sunucuda saklanir; yuklemede UI ve sesler eslenir
	if type(state.sfx) == "number" then
		soundVolume = math.clamp(math.floor(state.sfx), 0, 100)
	end
	if state.muted ~= nil then soundMuted = state.muted == true end
	if type(state.sfxOff) == "table" then
		soundOff = {}
		for _, key in ipairs(SOUND_ORDER) do
			if state.sfxOff[key] == true then soundOff[key] = true end
		end
	end
	applySoundVolume()
	refreshSoundUI()
	if state.theme and state.theme ~= currentTheme then
		applyTheme(state.theme)
	end
	local run = state.run
	if run then
		if run.size ~= S.size then
			S.size = run.size
			buildGrid(S.size)
		end
		S.board = run.board
		S.score = run.score
		S.seed = run.seed
		S.spawns = run.spawns
		S.undoLeft = run.undoLeft
		S.won = run.won
		S.over = run.over
		S.milestone = run.milestone or (run.won and 2048 or 0)
	end
	overlay.Visible = false
	if S.over then
		showOver(earned)
	end
	render(nil)
end

local function requestNewGame(size)
	if not S.loaded or S.busy then return end
	S.busy = true
	flushMoves()   -- bekleyen hamleler yeni turdan once islenmelidir
	local req = size and { a = "grid", size = size } or { a = "new" }
	local res = act(req)
	if res and res.ok then
		applyState(res.state)
	end
	S.busy = false
end

local function requestUndo()
	if not S.loaded or S.busy or S.over or S.undoLeft < 1 then return end
	S.busy = true
	flushMoves()   -- undo, sunucudaki son hamlenin snapshot'ini geri alir
	local res = act({ a = "undo" })
	if res and res.ok then
		applyState(res.state)
	end
	S.busy = false
end

local function doMove(dir)
	-- overlay/dailyLayer acikken hamle kilitli (Continue/New Game/Claim beklenir)
	if not S.loaded or S.busy or S.over or S.shopOpen or settingsOpen then return end
	if overlay.Visible or dailyLayer.Visible then return end
	local changed, gained, anims, popSet = simMove(S.board, S.size, dir)
	if not changed then return end
	S.busy = true
	dismissTutorial()   -- ilk gecerli hamlede ipucu kalici olarak kaybolur
	S.score = S.score + gained
	local sr, sc = spawnTile(S.board, S.size, S.seed, S.spawns, S.up.spawn)
	S.spawns += 1
	if sr then popSet[sr .. "_" .. sc] = true end
	queueMove(dir)
	-- Kaydirma sesi her gecerli hamlede calar (girdi onayi). Birlestirme varsa
	-- merge sesi one cikar, slide kisilir; ikisi esit seviyede binince camurlasiyor.
	if gained > 0 then
		playSound("move", 0.45)
		playSound("merge")
	else
		playSound("move")
	end

	-- 512+ birlestirmede tahta sarsilir (anims'te merged girisleri birlesme oncesi degeri tutar)
	local maxMerge = 0
	for _, a in ipairs(anims) do
		if a.merged and a.v * 2 > maxMerge then maxMerge = a.v * 2 end
	end
	if maxMerge >= 512 then shakeBoard() end

	local maxTile = boardMax(S.board, S.size)
	local newMilestone = nil
	if maxTile >= 2048 and maxTile > S.milestone then
		S.milestone = maxTile
		S.won = true
		newMilestone = maxTile
	end
	playSlide(anims, function()
		render(popSet)
		if newMilestone then
			showWin(newMilestone)
			playSound("milestone")
			burstConfetti(28)
		end
		if not hasMoves(S.board, S.size) then
			S.over = true
			-- Odul metni lokal formulle aninda gosterilir; coin bakiyesini
			-- YALNIZCA sunucu gunceller (NM_Sync "over"), cift sayim olmaz
			local earned = coinsForRun(S.score, maxTile, S.up.coin, S.vip)
			updateHUD()
			showOver(earned)
			playSound("gameOver")
			flushMoves()   -- bekleyen hamleleri hemen gonder, sunucu turu kapatabilsin
		end
		task.delay(MOVE_DEBOUNCE - SLIDE_TIME, function()
			S.busy = false
		end)
	end)
end

primaryButton.Activated:Connect(function()
	requestNewGame(nil)
end)

secondaryButton.Activated:Connect(function()
	-- 2048 sonrasi devam: overlay kapanir, run surer
	overlay.Visible = false
end)

newButton.Activated:Connect(function()
	requestNewGame(nil)
end)

undoButton.Activated:Connect(requestUndo)

-- Veri sifirlama (ayarlar panelinde): cift onayli, geri alinamaz.
-- Baglanti burada cunku flushMoves/act/applyState bu noktadan sonra tanimli.
do
	local armed = false
	local function disarm()
		armed = false
		SET.reset.Text = "RESET ALL DATA"
		SET.reset.BackgroundColor3 = hex("5C3448")
		SET.reset.TextColor3 = hex("FFB3B3")
	end

	SET.reset.Activated:Connect(function()
		if not S.loaded then return end
		if not armed then
			armed = true
			SET.reset.Text = "TAP AGAIN TO CONFIRM"
			SET.reset.BackgroundColor3 = hex("D32F2F")
			SET.reset.TextColor3 = WHITE_TEXT
			task.delay(4, function()
				if armed then disarm() end
			end)
			return
		end
		disarm()
		flushMoves()
		local res = act({ a = "wipe" })
		if res and res.ok then
			applyTheme("Light")
			applyState(res.state)
			setSettingsOpen(false)
		end
	end)
end

-- Gunluk odul: yukleme bitince hak varsa gosterilir, Claim sunucuda dogrulanir
local function showDaily()
	if not S.dailyReady then return end
	-- Seri koptuysa sunucu 1'den baslatir; onizleme bunu yansitmali
	local nextStreak = S.dailyContinues and ((S.dailyStreak or 0) + 1) or 1
	dailySub.Text = "Day " .. nextStreak .. " streak"
	dailyButton.Text = "Claim"
	dailyButton.Active = true
	dailyLayer.Visible = true
end

dailyButton.Activated:Connect(function()
	if not S.loaded then return end
	if not S.dailyReady then
		dailyLayer.Visible = false   -- odul alinmis, buton "Play" gorevinde
		return
	end
	dailyButton.Active = false
	local res = act({ a = "daily" })
	if res and res.ok then
		S.coins = res.coins or S.coins
		S.dailyStreak = res.streak or S.dailyStreak
		S.dailyReady = false
		updateHUD()
		playSound("daily")
		burstConfetti(24)
		dailyTitle.Text = "+" .. (res.reward or 0) .. " COINS"
		dailySub.Text = "Come back tomorrow"
		dailyButton.Text = "Play"
		dailyButton.Active = true
		task.delay(1.2, function()
			dailyLayer.Visible = false
			dailyTitle.Text = "Daily Bonus"
		end)
	elseif res and res.err == "claimed" then
		-- Baska bir oturumda alinmis: kapat
		S.dailyReady = false
		dailyLayer.Visible = false
	else
		-- Gecici hata (sunucu hazir degil vb.): hak yanmasin, tekrar denenebilsin
		dailyButton.Active = true
		dailySub.Text = "Try again"
	end
end)

SyncEvent.OnClientEvent:Connect(function(p)
	if type(p) ~= "table" then return end
	if p.ev == "over" then
		S.coins = p.coins or S.coins
		S.best = math.max(S.best, p.best or 0)
		if overlay.Visible and not secondaryButton.Visible then
			overSub.Text = "+" .. (p.earned or 0) .. " COINS"
		end
		updateHUD()
	elseif p.ev == "win" then
		S.coins = p.coins or S.coins
		S.best = math.max(S.best, p.best or 0)
		if p.tile and p.tile > S.milestone then S.milestone = p.tile end
		updateHUD()
	elseif p.ev == "saved" then
		flashSaveIndicator()
	elseif p.ev == "vip" then
		S.vip = p.vip == true
		if S.shopOpen then rebuildShop() end
	elseif p.ev == "purchase" then
		-- Robux satin almasi sunucuda islendi
		S.coins = p.coins or S.coins
		S.up = p.up or S.up
		updateHUD()
		burstConfetti(18)
		if S.shopOpen then rebuildShop() end
	elseif p.ev == "resync" then
		applyState(p.state)
	end
end)

-- ========================================================================
-- 8. SHOP UI
-- ========================================================================
local shopTab = "shop"        -- "shop" | "top"
local topBoard = "score"      -- "score" | "tile" (TOP 10 alt sekmesi)
local shopBoard = "coin"      -- "coin" | "robux" (SHOP alt sekmesi)
local topRefreshToken = 0     -- otomatik yenileme iptali icin sayac
local TOP_REFRESH_SECONDS = 150

local function shopRow(height)
	local t = THEMES[currentTheme]
	local row = make("Frame", {
		Size = UDim2.new(1, -6, 0, height),
		BackgroundColor3 = t.empty,
		BorderSizePixel = 0,
		ZIndex = 21,
	}, shopList)
	corner(row, TILE_RADIUS)
	return row, textColorFor(t.empty)
end

-- Robux ile alinabilen urunler (ID 0 ise satirlari hic olusturulmaz).
-- robux alanlari yalnizca gosterim icindir; Roblox panelindeki fiyatla ayni tutulmali.
local COIN_BUNDLES = {
	{ id = PRODUCT_COINS_1K,  amount = 1000,  label = "+1,000 Coins",  robux = 49 },
	{ id = PRODUCT_COINS_5K,  amount = 5000,  label = "+5,000 Coins",  robux = 149 },
	{ id = PRODUCT_COINS_15K, amount = 15000, label = "+15,000 Coins", robux = 249 },
}
local ROBUX_VIP = 299

-- Tema urunleri: magaza kalemi -> tema adi, Robux urunu ve fiyati
local THEME_ITEMS = {
	themeNeon   = { theme = "Neon",   product = PRODUCT_THEME_NEON,   robux = 79 },
	themeSunset = { theme = "Sunset", product = PRODUCT_THEME_SUNSET, robux = 119 },
}

local function promptProduct(productId)
	pcall(function()
		MarketplaceService:PromptProductPurchase(player, productId)
	end)
end

local function promptGamePass(passId)
	pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, passId)
	end)
end

-- Robux fiyat butonu: satirin sagina yerlesir
local function robuxButton(parent, text, xOffset, width, onClick)
	local b = make("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, xOffset, 0.5, 0),
		Size = UDim2.fromOffset(width, 36),
		BackgroundColor3 = hex("00A24E"),
		Font = Enum.Font.GothamBold,
		Text = text,
		TextColor3 = WHITE_TEXT,
		TextSize = 13,
		AutoButtonColor = true,
		BorderSizePixel = 0,
		ZIndex = 22,
	}, parent)
	corner(b, 18)
	b.Activated:Connect(onClick)
	return b
end

local function sectionHeader(text)
	local t = THEMES[currentTheme]
	local head = make("Frame", {
		Size = UDim2.new(1, -6, 0, 18),
		BackgroundTransparency = 1,
		ZIndex = 21,
	}, shopList)
	make("TextLabel", {
		Position = UDim2.fromOffset(10, 0),
		Size = UDim2.new(1, -10, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = text,
		TextColor3 = t.statLabel,
		TextSize = 10,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 22,
	}, head)
end

-- ROBUX sekmesi: coin paketleri, VIP gamepass ve Robux ile acilan temalar
local function buildRobuxRows()
	local t = THEMES[currentTheme]
	local anyRow = false

	local bundles = {}
	for _, bundle in ipairs(COIN_BUNDLES) do
		if bundle.id ~= 0 then table.insert(bundles, bundle) end
	end

	if #bundles > 0 then
		sectionHeader("COIN PACKS")
		anyRow = true
		for _, bundle in ipairs(bundles) do
			local row, rowText = shopRow(52)
			coinIcon(row, 20, 22).Position = UDim2.new(0, 10, 0.5, 0)
			make("TextLabel", {
				Position = UDim2.fromOffset(38, 0),
				Size = UDim2.new(1, -150, 1, 0),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				Text = bundle.label,
				TextColor3 = rowText,
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 22,
			}, row)
			robuxButton(row, "R$ " .. bundle.robux, -10, 96, function()
				promptProduct(bundle.id)
			end)
		end
	end

	if GAMEPASS_2X_COINS ~= 0 then
		sectionHeader("PASSES")
		anyRow = true
		local row, rowText = shopRow(58)
		make("TextLabel", {
			Position = UDim2.fromOffset(10, 8),
			Size = UDim2.new(1, -120, 0, 18),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = "VIP 2x Coins",
			TextColor3 = rowText,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 22,
		}, row)
		make("TextLabel", {
			Position = UDim2.fromOffset(10, 28),
			Size = UDim2.new(1, -120, 0, 20),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			Text = "Permanent: double coins from every run",
			TextColor3 = rowText,
			TextTransparency = 0.25,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 22,
		}, row)
		if S.vip then
			make("TextLabel", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -10, 0.5, 0),
				Size = UDim2.fromOffset(96, 36),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				Text = "OWNED",
				TextColor3 = hex("00C853"),
				TextSize = 14,
				ZIndex = 22,
			}, row)
		else
			robuxButton(row, "R$ " .. ROBUX_VIP, -10, 96, function()
				promptGamePass(GAMEPASS_2X_COINS)
			end)
		end
	end

	-- Robux ile alinabilen temalar (coin ile de COIN sekmesinden alinabilir)
	local themeRows = {}
	for _, item in ipairs(SHOP) do
		local info = THEME_ITEMS[item.id]
		if info and info.product ~= 0 and S.up[item.id] < item.max then
			table.insert(themeRows, { item = item, info = info })
		end
	end
	if #themeRows > 0 then
		sectionHeader("THEMES")
		anyRow = true
		for _, entry in ipairs(themeRows) do
			local row, rowText = shopRow(52)
			make("TextLabel", {
				Position = UDim2.fromOffset(10, 0),
				Size = UDim2.new(1, -120, 1, 0),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				Text = entry.item.name,
				TextColor3 = rowText,
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				ZIndex = 22,
			}, row)
			robuxButton(row, "R$ " .. entry.info.robux, -10, 96, function()
				promptProduct(entry.info.product)
			end)
		end
	end

	if not anyRow then
		local row, rowText = shopRow(48)
		make("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = "No Robux items available yet",
			TextColor3 = rowText,
			TextSize = 13,
			ZIndex = 22,
		}, row)
	end
end

-- COIN sekmesi: coin ile alinan yukseltmeler + tahta boyutu + veri sifirlama
local function buildShopRows()
	local t = THEMES[currentTheme]

	for _, item in ipairs(SHOP) do
		local lv = S.up[item.id]
		-- Tahta kalemi kilit acikken buyur: aciklamanin altinda boyut secimi tasir
		local showSizes = (item.id == "grid5") and lv > 0
		local row, rowText = shopRow(showSizes and 112 or 64)
		make("TextLabel", {
			Position = UDim2.fromOffset(10, 8),
			Size = UDim2.new(1, -130, 0, 18),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = item.name .. "  (" .. lv .. "/" .. item.max .. ")",
			TextColor3 = rowText,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 22,
		}, row)
		make("TextLabel", {
			Position = UDim2.fromOffset(10, 30),
			Size = UDim2.new(1, -130, 0, 26),
			BackgroundTransparency = 1,
			Font = Enum.Font.Gotham,
			Text = item.desc,
			TextColor3 = rowText,
			TextTransparency = 0.25,
			TextSize = 11,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			ZIndex = 22,
		}, row)

		-- Boyut secimi: kilit acildiysa aciklamanin altinda
		if showSizes then
			make("TextLabel", {
				Position = UDim2.fromOffset(10, 58),
				Size = UDim2.new(1, -20, 0, 14),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				Text = "BOARD SIZE (STARTS A NEW RUN)",
				TextColor3 = rowText,
				TextTransparency = 0.4,
				TextSize = 10,
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 22,
			}, row)
			for i = 1, lv + 1 do
				local size = BASE_BOARD_SIZE + i - 1
				local active = (S.size == size)
				local sizeButton = make("TextButton", {
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.new(0, 10 + (i - 1) * 78, 1, -10),
					Size = UDim2.fromOffset(72, 28),
					BackgroundColor3 = active and ACCENT or t.button,
					Font = Enum.Font.GothamBold,
					Text = size .. "x" .. size,
					TextColor3 = active and WHITE_TEXT or t.buttonText,
					TextSize = 13,
					AutoButtonColor = not active,
					BorderSizePixel = 0,
					ZIndex = 22,
				}, row)
				corner(sizeButton, 14)
				if not active then
					sizeButton.Activated:Connect(function()
						S.shopOpen = false
						shopModal.Visible = false
						SET.button.Visible = true   -- modal kapandi, disli geri gelsin
						requestNewGame(size)
					end)
				end
			end
		end

		local buyButton = make("TextButton", {
			-- Uzun satirda ustte durur, boyut dugmelerinin uzerine binmesin
			AnchorPoint = Vector2.new(1, showSizes and 0 or 0.5),
			Position = showSizes and UDim2.new(1, -10, 0, 12) or UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(104, 36),
			Font = Enum.Font.GothamBold,
			TextSize = 14,
			AutoButtonColor = true,
			BorderSizePixel = 0,
			ZIndex = 22,
		}, row)
		corner(buyButton, 18)   -- tam yuvarlak pill
		local themeInfo = THEME_ITEMS[item.id]
		if lv >= item.max and themeInfo then
			-- Alinmis tema: kusanma/cikarma dugmesi. Cikarinca varsayilan Light'a doner.
			local active = (currentTheme == themeInfo.theme)
			buyButton.Text = active and "UNEQUIP" or "EQUIP"
			buyButton.BackgroundColor3 = active and hex("00C853") or ACCENT
			buyButton.TextColor3 = WHITE_TEXT
			buyButton.Activated:Connect(function()
				if not S.loaded then return end
				setTheme(active and "Light" or themeInfo.theme)
			end)
		elseif lv >= item.max then
			buyButton.Text = "MAX"
			buyButton.BackgroundColor3 = t.button
			buyButton.TextColor3 = t.statLabel
		else
			-- Fiyat pili: koyu zemin + coin ikonu + tutar; alinabilirse mavi
			local cost = item.costs[lv + 1]
			buyButton.Text = ""
			coinIcon(buyButton, 18, 23).Position = UDim2.new(0, 9, 0.5, 0)
			local priceLabel = make("TextLabel", {
				Position = UDim2.new(0, 33, 0, 0),
				Size = UDim2.new(1, -39, 1, 0),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				Text = tostring(cost),
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 23,
			}, buyButton)
			if S.coins >= cost then
				buyButton.BackgroundColor3 = ACCENT
				priceLabel.TextColor3 = WHITE_TEXT
			else
				buyButton.BackgroundColor3 = hex("3A3A40")
				priceLabel.TextColor3 = hex("9A968F")
			end
			buyButton.Activated:Connect(function()
				-- Bekleyen hamle satin almadan once islenmelidir: spawn seviyesi
				-- degisirse sunucu ve istemci farkli tile uretir
				flushMoves()
				local res = act({ a = "buy", id = item.id })
				if res and res.ok then
					S.coins = res.coins
					S.up = res.up
					if item.id == "undo" and not S.over then
						S.undoLeft += 1
					end
					playSound("buy")
					updateHUD()
					-- Tahta yukseltmesinde satir buyur ve boyut dugmeleri belirir;
					-- gecis oyuncunun secimine birakilir (tur ortasinda zorla bitmesin)
					rebuildShop()
				end
			end)
		end
	end

end

local function buildTopRows()
	local loadingRow, loadingRowText = shopRow(40)
	make("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "Loading...",
		TextColor3 = loadingRowText,
		TextSize = 14,
		ZIndex = 22,
	}, loadingRow)
	topRefreshToken += 1
	local token = topRefreshToken
	local boardKind = topBoard   -- dis kapsamdaki `board` Frame'ini golgelememek icin
	task.spawn(function()
		local res = act({ a = "top", board = boardKind })
		if not shopModal.Visible or shopTab ~= "top" or token ~= topRefreshToken then return end
		-- Hiz siniri: kisa sure sonra kendiliginden tekrar dene
		if res and res.err == "too_fast" then
			task.delay(0.35, function()
				if shopModal.Visible and shopTab == "top" and token == topRefreshToken then
					rebuildShop()
				end
			end)
			return
		end
		loadingRow:Destroy()
		local t = THEMES[currentTheme]
		local list = (res and res.ok and res.list) or {}

		-- Tek metrik: SCORE sekmesinde yalnizca skor, BLOCK sekmesinde yalnizca en yuksek blok
		local isTileBoard = (boardKind == "tile")
		local metricText = isTileBoard and "BLOCK" or "SCORE"

		local head = make("Frame", {
			Size = UDim2.new(1, -6, 0, 16),
			BackgroundTransparency = 1,
			ZIndex = 21,
		}, shopList)
		local function headLabel(text, pos, size, align)
			make("TextLabel", {
				Position = pos,
				Size = size,
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				Text = text,
				TextColor3 = t.statLabel,
				TextSize = 10,
				TextXAlignment = align,
				ZIndex = 22,
			}, head)
		end
		headLabel("PLAYER", UDim2.fromOffset(10, 0), UDim2.new(0.65, -10, 1, 0), Enum.TextXAlignment.Left)
		headLabel(metricText, UDim2.new(0.65, 0, 0, 0), UDim2.new(0.35, -10, 1, 0), Enum.TextXAlignment.Right)

		if #list == 0 then
			local row, rowText = shopRow(40)
			make("TextLabel", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				Text = isTileBoard and "No blocks yet" or "No scores yet",
				TextColor3 = rowText,
				TextSize = 14,
				ZIndex = 22,
			}, row)
		else
			for rank, entry in ipairs(list) do
				local row, rowText = shopRow(38)
				local metricVal = isTileBoard and entry.tile or entry.score
				make("TextLabel", {
					Position = UDim2.fromOffset(10, 0),
					Size = UDim2.new(0.65, -10, 1, 0),
					BackgroundTransparency = 1,
					Font = Enum.Font.GothamBold,
					Text = rank .. ". " .. entry.name,
					TextColor3 = rowText,
					TextSize = 13,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					ZIndex = 22,
				}, row)
				make("TextLabel", {
					Position = UDim2.new(0.65, 0, 0, 0),
					Size = UDim2.new(0.35, -10, 1, 0),
					BackgroundTransparency = 1,
					Font = Enum.Font.GothamBlack,
					Text = (metricVal and metricVal > 0) and tostring(metricVal) or "-",
					TextColor3 = rowText,
					TextSize = 13,
					TextXAlignment = Enum.TextXAlignment.Right,
					ZIndex = 22,
				}, row)
			end
		end

		-- Alt bar: aktif sekmedeki sirandaki yer + o sekmenin metrigi
		if res and res.ok and res.me then
			local me = res.me
			meBar.BackgroundColor3 = t.empty
			local mc = textColorFor(t.empty)
			for _, cap in ipairs(meCaps) do
				cap.TextColor3 = mc
				cap.TextTransparency = 0.4
			end
			for _, val in ipairs(meVals) do
				val.TextColor3 = mc
			end
			local myMetric = isTileBoard and (me.tile or 0) or (me.best or 0)
			if me.rank then
				meRankVal.Text = "#" .. me.rank
			elseif myMetric > 0 then
				meRankVal.Text = "100+"
			else
				meRankVal.Text = "-"
			end
			meMetricCap.Text = metricText
			meMetricVal.Text = (myMetric > 0) and tostring(myMetric) or "-"
			meBar.Visible = true
		end

		-- Otomatik yenileme: sekme acik kaldigi surece ~2.5 dk'da bir tazele
		task.delay(TOP_REFRESH_SECONDS, function()
			if token == topRefreshToken and S.shopOpen and shopTab == "top" and shopModal.Visible then
				rebuildShop()
			end
		end)
	end)
end

-- Aktif alt sekme mavi, digeri tema rengi
local function styleSubTabs(activeB, idleB)
	local t = THEMES[currentTheme]
	activeB.BackgroundColor3 = ACCENT
	activeB.TextColor3 = WHITE_TEXT
	idleB.BackgroundColor3 = t.button
	idleB.TextColor3 = t.buttonText
end

rebuildShop = function()
	for _, child in ipairs(shopList:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
	local isTop = (shopTab == "top")
	modalTitle.Text = isTop and "TOP 10" or "SHOP"
	meBar.Visible = false
	topSubBar.Visible = isTop
	shopSubBar.Visible = not isTop

	if isTop then
		styleSubTabs(
			(topBoard == "score") and scoreTabButton or blockTabButton,
			(topBoard == "score") and blockTabButton or scoreTabButton)
		-- Liste, ustte alt sekmelere ve altta kisisel bara yer birakir
		shopList.Position = UDim2.new(0, 0, 0, 78)
		shopList.Size = UDim2.new(1, 0, 1, -134)
		buildTopRows()
	else
		styleSubTabs(
			(shopBoard == "coin") and coinTabButton or robuxTabButton,
			(shopBoard == "coin") and robuxTabButton or coinTabButton)
		shopList.Position = UDim2.new(0, 0, 0, 78)
		shopList.Size = UDim2.new(1, 0, 1, -78)
		if shopBoard == "coin" then
			buildShopRows()
		else
			buildRobuxRows()
		end
	end
end

scoreTabButton.Activated:Connect(function()
	if topBoard ~= "score" then
		topBoard = "score"
		rebuildShop()
	end
end)

blockTabButton.Activated:Connect(function()
	if topBoard ~= "tile" then
		topBoard = "tile"
		rebuildShop()
	end
end)

coinTabButton.Activated:Connect(function()
	if shopBoard ~= "coin" then
		shopBoard = "coin"
		rebuildShop()
	end
end)

robuxTabButton.Activated:Connect(function()
	if shopBoard ~= "robux" then
		shopBoard = "robux"
		rebuildShop()
	end
end)

-- Header'daki SHOP / TOP 10 butonlari modali kendi sekmesinde acar;
-- ayni sekme acikken tekrar basmak kapatir
-- Disli butonu screenBg'nin cocugu, yani container'in (ve magaza modalinin)
-- uzerinde ciziliyor. Modal acikken gizlenir ki uzerine binmesin.
local function setShopOpen(open)
	S.shopOpen = open
	shopModal.Visible = open
	SET.button.Visible = not open
end

local function toggleModal(tab)
	if not S.loaded then return end
	if S.shopOpen and shopTab == tab then
		setShopOpen(false)
		return
	end
	shopTab = tab
	setShopOpen(true)
	rebuildShop()
end

shopButton.Activated:Connect(function()
	toggleModal("shop")
end)

topButton.Activated:Connect(function()
	toggleModal("top")
end)

closeButton.Activated:Connect(function()
	setShopOpen(false)
end)

-- ========================================================================
-- 9. INPUT (klavye + mobil swipe)
-- ========================================================================
local KEY_MAP = {
	[Enum.KeyCode.W] = "Up",    [Enum.KeyCode.Up] = "Up",
	[Enum.KeyCode.S] = "Down",  [Enum.KeyCode.Down] = "Down",
	[Enum.KeyCode.A] = "Left",  [Enum.KeyCode.Left] = "Left",
	[Enum.KeyCode.D] = "Right", [Enum.KeyCode.Right] = "Right",
}

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	local direction = KEY_MAP[input.KeyCode]
	if direction then doMove(direction) end
end)

local SWIPE_MAP = {
	[Enum.SwipeDirection.Up] = "Up",
	[Enum.SwipeDirection.Down] = "Down",
	[Enum.SwipeDirection.Left] = "Left",
	[Enum.SwipeDirection.Right] = "Right",
}

UserInputService.TouchSwipe:Connect(function(swipeDir, _, gameProcessed)
	if gameProcessed then return end
	local direction = SWIPE_MAP[swipeDir]
	if direction then doMove(direction) end
end)

-- ========================================================================
-- BASLAT
-- ========================================================================
applyTheme("Light")
updateHUD()

task.spawn(function()
	-- Sunucu kaydi yukleyene kadar dene; notReady geldikce tekrarla.
	-- Bekleme suresince oyuncu bos tahtaya degil, durum mesajina bakar.
	local startedAt = os.clock()
	while not S.loaded do
		local ok, state = pcall(function()
			return GetData:InvokeServer()
		end)
		if ok and type(state) == "table" and not state.notReady then
			applyState(state)
			S.loaded = true
			hideLoading()
			initSounds(gui)
			-- Ilk kez oynayan (hic skoru ve coini yok): ipucu gosterilir.
			-- Gunluk odul katmani aciksa once onun kapanmasi beklenir.
			local firstTime = (S.best == 0 and S.coins == 0)
			showDaily()
			if firstTime then
				if dailyLayer.Visible then
					local conn
					conn = dailyLayer:GetPropertyChangedSignal("Visible"):Connect(function()
						if dailyLayer.Visible then return end
						conn:Disconnect()
						if S.best == 0 then showTutorial() end
					end)
				else
					showTutorial()
				end
			end
		else
			if os.clock() - startedAt >= 4 then
				setLoading("Save server unavailable\nRetrying...")
			end
			task.wait(0.5)
		end
	end
end)
