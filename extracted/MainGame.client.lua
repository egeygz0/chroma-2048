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

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

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
	},
}

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
	{ id = "grid5", max = 1, costs = { 5000 },
	  name = "5x5 Board", desc = "Unlock the big board (switch in shop)" },
}

local function tileBonus(maxTile)
	if maxTile >= 4096 then return 400
	elseif maxTile >= 2048 then return 150
	elseif maxTile >= 1024 then return 60
	elseif maxTile >= 512 then return 25
	elseif maxTile >= 256 then return 10 end
	return 0
end

local function coinsForRun(score, maxTile, coinLv)
	local base = math.floor(score / 200) + tileBonus(maxTile)
	return math.floor(base * (1 + 0.25 * coinLv))
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
	up = { spawn = 0, start = 0, undo = 0, coin = 0, grid5 = 0 },
}
local currentTheme = "Light"

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
	Size = UDim2.new(1, -292, 1, 0),
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

local themeButton = headerButton("ThemeToggle", "🌙", 48, 0)
local shopButton  = headerButton("Shop", "SHOP", 72, -54)
local newButton   = headerButton("NewGame", "NEW", 64, -132)
local undoButton  = headerButton("Undo", "UNDO 0", 80, -202)
undoButton.Visible = false
undoButton.TextSize = 14

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
stroke(board)
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

local cells = {}   -- cells[r][c] = { frame, tile, scale }

local function buildGrid(n)
	for _, child in ipairs(gridFrame:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
	local pad = (n == 4) and 10 or 8
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
			corner(cell, TILE_RADIUS)

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
			corner(tile, TILE_RADIUS)
			make("UITextSizeConstraint", { MaxTextSize = 40 }, tile)
			local scale = make("UIScale", { Scale = 1 }, tile)

			cells[r][c] = { frame = cell, tile = tile, scale = scale }
		end
	end
end

buildGrid(4)

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

-- Magaza / leaderboard modali
local shopModal = make("Frame", {
	Name = "ShopModal",
	Size = UDim2.fromScale(1, 1),
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 20,
}, container)
corner(shopModal, BOARD_RADIUS)
stroke(shopModal)
make("UIPadding", {
	PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10),
	PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
}, shopModal)

local shopTabButton = make("TextButton", {
	Name = "TabShop",
	Size = UDim2.fromOffset(80, 34),
	Font = Enum.Font.GothamBold,
	Text = "SHOP",
	TextSize = 15,
	AutoButtonColor = true,
	BorderSizePixel = 0,
	ZIndex = 21,
}, shopModal)
corner(shopTabButton, TILE_RADIUS)

local topTabButton = make("TextButton", {
	Name = "TabTop",
	Position = UDim2.fromOffset(86, 0),
	Size = UDim2.fromOffset(80, 34),
	Font = Enum.Font.GothamBold,
	Text = "TOP 10",
	TextSize = 15,
	AutoButtonColor = true,
	BorderSizePixel = 0,
	ZIndex = 21,
}, shopModal)
corner(topTabButton, TILE_RADIUS)

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

-- ========================================================================
-- 5. THEME MANAGER
-- ========================================================================
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
	for _, b in ipairs({ themeButton, shopButton, newButton, undoButton, shopTabButton, topTabButton, closeButton }) do
		tween(b, { BackgroundColor3 = t.button, TextColor3 = t.buttonText })
	end
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
			tween(cells[r][c].frame, { BackgroundColor3 = t.empty })
		end
	end
	themeButton.Text = (name == "Light") and "🌙" or "☀️"
end

themeButton.Activated:Connect(function()
	applyTheme(currentTheme == "Light" and "Dark" or "Light")
	task.spawn(act, { a = "theme", t = currentTheme })
end)

-- ========================================================================
-- 6. RENDER + ANIMASYON
-- ========================================================================
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
end

local function render(popSet)
	for r = 1, S.size do
		for c = 1, S.size do
			local v = S.board[r][c]
			local cell = cells[r][c]
			if v == 0 then
				cell.tile.Visible = false
			else
				local color = TILE_COLORS[math.min(v, 2048)] or TILE_COLORS[2048]
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
	for _, a in ipairs(anims) do
		local fromCell = cells[a.fr][a.fc].frame
		local toCell = cells[a.tr][a.tc].frame
		local color = TILE_COLORS[math.min(a.v, 2048)] or TILE_COLORS[2048]
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
		corner(ghost, TILE_RADIUS)
		make("UITextSizeConstraint", { MaxTextSize = 40 }, ghost)
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
local function showOver(earned)
	overTitle.Text = "Game Over"
	-- earned nil ise (resync yolu) odul metni gosterilmez; kesin degeri NM_Sync yazar
	overSub.Text = earned and ("+" .. earned .. " COINS") or ""
	primaryButton.Text = "New Game"
	secondaryButton.Visible = false
	overlay.Visible = true
end

local function showWin()
	overTitle.Text = "2048!"
	overSub.Text = "You reached 2048, keep going!"
	primaryButton.Text = "New Game"
	secondaryButton.Visible = true
	overlay.Visible = true
end

-- Sunucudan gelen tam durumu uygula
local function applyState(state, earned)
	if type(state) ~= "table" then return end
	S.coins = state.coins or S.coins
	S.best = state.best or S.best
	S.up = state.up or S.up
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
	local res = act({ a = "undo" })
	if res and res.ok then
		applyState(res.state)
	end
	S.busy = false
end

local function doMove(dir)
	-- overlay.Visible: win ekrani acikken de hamle kilitli (Continue/New Game beklenir)
	if not S.loaded or S.busy or S.over or S.shopOpen or overlay.Visible then return end
	local changed, gained, anims, popSet = simMove(S.board, S.size, dir)
	if not changed then return end
	S.busy = true
	S.score = S.score + gained
	local sr, sc = spawnTile(S.board, S.size, S.seed, S.spawns, S.up.spawn)
	S.spawns += 1
	if sr then popSet[sr .. "_" .. sc] = true end
	MoveEvent:FireServer(dir)
	if S.undoLeft > 0 then
		-- sunucuda snapshot olustu; buton aktif kalir
	end
	local justWon = false
	if not S.won and boardMax(S.board, S.size) >= 2048 then
		S.won = true
		justWon = true
	end
	playSlide(anims, function()
		render(popSet)
		if justWon then
			showWin()
		end
		if not hasMoves(S.board, S.size) then
			S.over = true
			-- Odul metni lokal formulle aninda gosterilir; coin bakiyesini
			-- YALNIZCA sunucu gunceller (NM_Sync "over"), cift sayim olmaz
			local earned = coinsForRun(S.score, boardMax(S.board, S.size), S.up.coin)
			updateHUD()
			showOver(earned)
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
		updateHUD()
	elseif p.ev == "resync" then
		applyState(p.state)
	end
end)

-- ========================================================================
-- 8. SHOP UI
-- ========================================================================
local shopTab = "shop"   -- "shop" | "top"

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

local rebuildShop   -- ileri bildirim (buy butonu icinden cagrilir)

local function buildShopRows()
	local t = THEMES[currentTheme]
	for _, item in ipairs(SHOP) do
		local lv = S.up[item.id]
		local row, rowText = shopRow(64)
		make("TextLabel", {
			Position = UDim2.fromOffset(10, 8),
			Size = UDim2.new(1, -130, 0, 18),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = item.name .. "  (" .. lv .. "/" .. item.max .. ")",
			TextColor3 = rowText,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
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
		local buyButton = make("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(104, 34),
			Font = Enum.Font.GothamBold,
			TextSize = 13,
			AutoButtonColor = true,
			BorderSizePixel = 0,
			ZIndex = 22,
		}, row)
		corner(buyButton, TILE_RADIUS)
		if lv >= item.max then
			buyButton.Text = "MAX"
			buyButton.BackgroundColor3 = t.button
			buyButton.TextColor3 = t.statLabel
		else
			-- Fiyat: coin ikonu + tutar (duz emoji yerine ikonlu buton)
			local cost = item.costs[lv + 1]
			buyButton.Text = ""
			coinIcon(buyButton, 16, 23).Position = UDim2.new(0, 10, 0.5, 0)
			local priceLabel = make("TextLabel", {
				Position = UDim2.new(0, 32, 0, 0),
				Size = UDim2.new(1, -38, 1, 0),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				Text = tostring(cost),
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 23,
			}, buyButton)
			if S.coins >= cost then
				buyButton.BackgroundColor3 = ACCENT
				priceLabel.TextColor3 = WHITE_TEXT
			else
				buyButton.BackgroundColor3 = t.button
				priceLabel.TextColor3 = t.statLabel
			end
			buyButton.Activated:Connect(function()
				local res = act({ a = "buy", id = item.id })
				if res and res.ok then
					S.coins = res.coins
					S.up = res.up
					if item.id == "undo" and not S.over then
						S.undoLeft += 1
					end
					updateHUD()
					rebuildShop()
				end
			end)
		end
	end

	-- 5x5 kilidi acildiysa tahta boyutu satiri
	if S.up.grid5 > 0 then
		local row, rowText = shopRow(56)
		make("TextLabel", {
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.new(1, -130, 1, 0),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = "Board Size (new run starts)",
			TextColor3 = rowText,
			TextSize = 13,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 22,
		}, row)
		local toggle = make("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(104, 34),
			BackgroundColor3 = ACCENT,
			Font = Enum.Font.GothamBold,
			Text = (S.size == 4) and "Play 5x5" or "Play 4x4",
			TextColor3 = WHITE_TEXT,
			TextSize = 13,
			AutoButtonColor = true,
			BorderSizePixel = 0,
			ZIndex = 22,
		}, row)
		corner(toggle, TILE_RADIUS)
		toggle.Activated:Connect(function()
			local target = (S.size == 4) and 5 or 4
			S.shopOpen = false
			shopModal.Visible = false
			requestNewGame(target)
		end)
	end
end

local function buildTopRows()
	local loadingRow, loadingText = shopRow(40)
	local label = make("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "Loading...",
		TextColor3 = loadingText,
		TextSize = 14,
		ZIndex = 22,
	}, loadingRow)
	task.spawn(function()
		local res = act({ a = "top" })
		if not shopModal.Visible or shopTab ~= "top" then return end
		loadingRow:Destroy()
		local list = (res and res.ok and res.list) or {}
		if #list == 0 then
			local row, rowText = shopRow(40)
			make("TextLabel", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				Text = "No scores yet",
				TextColor3 = rowText,
				TextSize = 14,
				ZIndex = 22,
			}, row)
			return
		end
		for rank, entry in ipairs(list) do
			local row, rowText = shopRow(38)
			make("TextLabel", {
				Position = UDim2.fromOffset(10, 0),
				Size = UDim2.new(0.65, 0, 1, 0),
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
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -10, 0, 0),
				Size = UDim2.new(0.3, 0, 1, 0),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBlack,
				Text = tostring(entry.score),
				TextColor3 = rowText,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Right,
				ZIndex = 22,
			}, row)
		end
	end)
end

rebuildShop = function()
	for _, child in ipairs(shopList:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
	local t = THEMES[currentTheme]
	local activeTab = (shopTab == "shop") and shopTabButton or topTabButton
	local idleTab = (shopTab == "shop") and topTabButton or shopTabButton
	activeTab.BackgroundColor3 = ACCENT
	activeTab.TextColor3 = WHITE_TEXT
	idleTab.BackgroundColor3 = t.button
	idleTab.TextColor3 = t.buttonText
	if shopTab == "shop" then
		buildShopRows()
	else
		buildTopRows()
	end
end

shopButton.Activated:Connect(function()
	if not S.loaded then return end
	S.shopOpen = not S.shopOpen
	shopModal.Visible = S.shopOpen
	if S.shopOpen then
		shopTab = "shop"
		rebuildShop()
	end
end)

shopTabButton.Activated:Connect(function()
	shopTab = "shop"
	rebuildShop()
end)

topTabButton.Activated:Connect(function()
	shopTab = "top"
	rebuildShop()
end)

closeButton.Activated:Connect(function()
	S.shopOpen = false
	shopModal.Visible = false
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
	-- Sunucu kaydi yukleyene kadar dene; notReady geldikce bekle
	while not S.loaded do
		local ok, state = pcall(function()
			return GetData:InvokeServer()
		end)
		if ok and type(state) == "table" and not state.notReady then
			applyState(state)
			S.loaded = true
		else
			task.wait(2)
		end
	end
end)
