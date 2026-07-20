--[[
	CHROMA 2048 — istemci (StarterPlayer > StarterPlayerScripts > LocalScript)

	Mimari:
	1. CONFIG      : tema tablolari, canli tile paleti, sabitler
	2. REMOTES     : sunucu kayit protokolu (CH_GetData / CH_Save)
	3. UI BUILD    : ScreenGui + header + 4x4 board, tamamen programatik (UICorner her yerde)
	4. THEME       : state-tabanli tema yoneticisi, TweenService ile yumusak gecis
	5. CORE        : 4x4 matris, slide/merge/spawn, skor, game-over tespiti
	6. PERSISTENCE : giriste sunucudan yukle, her hamlede sunucuya gonder
	7. INPUT       : UserInputService (WASD + ok tuslari), debounce
	8. ANIM        : UIScale pop-in (0.8 -> 1.05 -> 1.0), 2048+ icin neon hue dongusu

	NOT: Server.server.lua olmadan kayit calismaz; iki dosyayi birlikte guncelle.
]]

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ========================================================================
-- 1. CONFIG
-- ========================================================================
local GRID          = 4
local BOARD_RADIUS  = 16
local TILE_RADIUS   = 12
local MOVE_DEBOUNCE = 0.14
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

local DARK_TEXT  = Color3.fromRGB(55, 55, 55)
local WHITE_TEXT = Color3.new(1, 1, 1)

-- Parlaklik uzerinden kontrast metin rengi (rainbow dongusunde de kullanilir)
local function textColorFor(bg)
	local lum = 0.299 * bg.R + 0.587 * bg.G + 0.114 * bg.B
	return (lum > 0.62) and DARK_TEXT or WHITE_TEXT
end

-- ========================================================================
-- 2. REMOTES (Server.server.lua olusturur)
-- ========================================================================
local GetData   = ReplicatedStorage:WaitForChild("CH_GetData")   -- RemoteFunction
local SaveEvent = ReplicatedStorage:WaitForChild("CH_Save")      -- RemoteEvent

-- ========================================================================
-- 3. UI BUILD
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

local gui = make("ScreenGui", {
	Name = "Chroma2048",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, playerGui)

local screenBg = make("Frame", {
	Name = "ScreenBackground",
	Size = UDim2.fromScale(1, 1),
	BorderSizePixel = 0,
}, gui)

-- Ana konteyner: ortali, board icin 1:1 oran, max 450px genislik
local container = make("Frame", {
	Name = "Container",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromScale(0.92, 0.92),
	BackgroundTransparency = 1,
}, screenBg)
make("UISizeConstraint", { MaxSize = Vector2.new(450, 530) }, container)

local header = make("Frame", {
	Name = "Header",
	Size = UDim2.new(1, 0, 0, 60),
	BackgroundTransparency = 1,
}, container)

local title = make("TextLabel", {
	Name = "Title",
	Size = UDim2.new(0.38, 0, 1, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	Text = "Chroma\n2048",
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Left,
}, header)
make("UITextSizeConstraint", { MaxTextSize = 22 }, title)

-- SCORE / BEST kutulari
local function makeStat(name, caption, rightOffset)
	local frame = make("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, rightOffset, 0.5, 0),
		Size = UDim2.fromOffset(82, 48),
		BorderSizePixel = 0,
	}, header)
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
		Position = UDim2.new(0, 0, 0, 17),
		Size = UDim2.new(1, 0, 1, -21),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		Text = "0",
		TextScaled = true,
	}, frame)
	make("UITextSizeConstraint", { MaxTextSize = 20 }, value)
	return frame, cap, value
end

local scoreFrame, scoreCap, scoreValue = makeStat("Score", "SCORE", -142)
local bestFrame,  bestCap,  bestValue  = makeStat("Best",  "BEST",  -54)

local themeButton = make("TextButton", {
	Name = "ThemeToggle",
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, 0, 0.5, 0),
	Size = UDim2.fromOffset(46, 48),
	Font = Enum.Font.GothamBold,
	Text = "🌙",
	TextSize = 22,
	AutoButtonColor = true,
	BorderSizePixel = 0,
}, header)
corner(themeButton, TILE_RADIUS)

local board = make("Frame", {
	Name = "Board",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 70),
	Size = UDim2.new(1, 0, 1, -70),
	BorderSizePixel = 0,
}, container)
corner(board, BOARD_RADIUS)
make("UIAspectRatioConstraint", {
	AspectRatio = 1,
	AspectType = Enum.AspectType.FitWithinMaxSize,
}, board)
make("UIPadding", {
	PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12),
	PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
}, board)
make("UIGridLayout", {
	CellSize = UDim2.new(0.25, -8, 0.25, -8),
	CellPadding = UDim2.fromOffset(10, 10),
	FillDirection = Enum.FillDirection.Horizontal,
	FillDirectionMaxCells = GRID,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	SortOrder = Enum.SortOrder.LayoutOrder,
}, board)

-- 16 hucre (bos zemin) + her birinde gizli tile etiketi
local cells = {}   -- cells[r][c] = { frame, tile, scale }
for r = 1, GRID do
	cells[r] = {}
	for c = 1, GRID do
		local cell = make("Frame", {
			Name = ("Cell_%d_%d"):format(r, c),
			LayoutOrder = (r - 1) * GRID + c,
			BorderSizePixel = 0,
		}, board)
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

-- Game-over katmani
local overlay = make("Frame", {
	Name = "GameOver",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.fromRGB(15, 15, 15),
	BackgroundTransparency = 0.35,
	Visible = false,
	ZIndex = 10,
}, board)
corner(overlay, BOARD_RADIUS)

local overText = make("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.4),
	Size = UDim2.fromScale(0.8, 0.2),
	BackgroundTransparency = 1,
	Font = Enum.Font.GothamBlack,
	Text = "Game Over",
	TextColor3 = WHITE_TEXT,
	TextScaled = true,
	ZIndex = 11,
}, overlay)
make("UITextSizeConstraint", { MaxTextSize = 44 }, overText)

local restartButton = make("TextButton", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.62),
	Size = UDim2.new(0.45, 0, 0, 44),
	BackgroundColor3 = hex("2979FF"),
	Font = Enum.Font.GothamBold,
	Text = "Restart",
	TextColor3 = WHITE_TEXT,
	TextSize = 20,
	AutoButtonColor = true,
	BorderSizePixel = 0,
	ZIndex = 11,
}, overlay)
corner(restartButton, TILE_RADIUS)

-- ========================================================================
-- 4. THEME MANAGER
-- ========================================================================
local currentTheme = "Light"
local loaded = false          -- ilk yukleme bitmeden kayit gonderilmez
local sendSave                -- ileri bildirim (persistence bolumunde tanimli)

local function tween(inst, props)
	TweenService:Create(inst, THEME_TWEEN, props):Play()
end

local function applyTheme(name)
	currentTheme = name
	local t = THEMES[name]
	tween(screenBg, { BackgroundColor3 = t.screen })
	tween(board, { BackgroundColor3 = t.board })
	tween(title, { TextColor3 = t.text })
	tween(themeButton, { BackgroundColor3 = t.button, TextColor3 = t.buttonText })
	for _, statFrame in ipairs({ scoreFrame, bestFrame }) do
		tween(statFrame, { BackgroundColor3 = t.button })
	end
	for _, capLabel in ipairs({ scoreCap, bestCap }) do
		tween(capLabel, { TextColor3 = t.statLabel })
	end
	for _, valLabel in ipairs({ scoreValue, bestValue }) do
		tween(valLabel, { TextColor3 = t.statValue })
	end
	for r = 1, GRID do
		for c = 1, GRID do
			tween(cells[r][c].frame, { BackgroundColor3 = t.empty })
		end
	end
	themeButton.Text = (name == "Light") and "🌙" or "☀️"
end

themeButton.Activated:Connect(function()
	applyTheme(currentTheme == "Light" and "Dark" or "Light")
	sendSave()
end)

-- ========================================================================
-- 5. GAME CORE
-- ========================================================================
local grid = {}     -- grid[r][c] = 0 veya tile degeri
local score = 0
local best = 0
local gameOver = false

-- 8. ANIM: pop-in (0.8 -> 1.05 -> 1.0)
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

-- popSet: { ["r_c"] = true } -> bu hucrelerde pop animasyonu oynat
local function render(popSet)
	for r = 1, GRID do
		for c = 1, GRID do
			local v = grid[r][c]
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
	if score > best then best = score end
	scoreValue.Text = tostring(score)
	bestValue.Text = tostring(best)
end

local function spawnTile(popSet)
	local empties = {}
	for r = 1, GRID do
		for c = 1, GRID do
			if grid[r][c] == 0 then table.insert(empties, { r, c }) end
		end
	end
	if #empties == 0 then return end
	local pick = empties[math.random(#empties)]
	grid[pick[1]][pick[2]] = (math.random() < 0.9) and 2 or 4
	if popSet then popSet[pick[1] .. "_" .. pick[2]] = true end
end

-- Tek satir/sutunu hareket yonune dogru sikistir + birlestir
local function processLine(line)
	local vals = {}
	for _, v in ipairs(line) do
		if v ~= 0 then table.insert(vals, v) end
	end
	local out, mergedAt, gained = {}, {}, 0
	local i = 1
	while i <= #vals do
		if vals[i + 1] and vals[i] == vals[i + 1] then
			local m = vals[i] * 2
			table.insert(out, m)
			mergedAt[#out] = true
			gained += m
			i += 2
		else
			table.insert(out, vals[i])
			i += 1
		end
	end
	while #out < GRID do table.insert(out, 0) end
	return out, mergedAt, gained
end

-- Yon basina hucre koordinat siralari (hareket yonundeki uctan baslar)
local DIRECTIONS = {
	Left  = function(i) local t = {} for j = 1, GRID do t[j] = { i, j } end return t end,
	Right = function(i) local t = {} for j = 1, GRID do t[j] = { i, GRID - j + 1 } end return t end,
	Up    = function(i) local t = {} for j = 1, GRID do t[j] = { j, i } end return t end,
	Down  = function(i) local t = {} for j = 1, GRID do t[j] = { GRID - j + 1, i } end return t end,
}

local function isGameOver()
	for r = 1, GRID do
		for c = 1, GRID do
			local v = grid[r][c]
			if v == 0 then return false end
			if c < GRID and grid[r][c + 1] == v then return false end
			if r < GRID and grid[r + 1][c] == v then return false end
		end
	end
	return true
end

local function checkGameOver()
	if isGameOver() then
		gameOver = true
		overlay.Visible = true
	end
end

local function move(direction)
	local coordFn = DIRECTIONS[direction]
	local changed = false
	local popSet = {}

	for i = 1, GRID do
		local coords = coordFn(i)
		local line = {}
		for j, rc in ipairs(coords) do
			line[j] = grid[rc[1]][rc[2]]
		end
		local newLine, mergedAt, gained = processLine(line)
		score += gained
		for j, rc in ipairs(coords) do
			if grid[rc[1]][rc[2]] ~= newLine[j] then changed = true end
			grid[rc[1]][rc[2]] = newLine[j]
			if mergedAt[j] then popSet[rc[1] .. "_" .. rc[2]] = true end
		end
	end

	if not changed then return false end
	spawnTile(popSet)
	render(popSet)
	checkGameOver()
	sendSave()
	return true
end

local function newGame()
	score = 0
	gameOver = false
	overlay.Visible = false
	for r = 1, GRID do
		grid[r] = {}
		for c = 1, GRID do grid[r][c] = 0 end
	end
	local popSet = {}
	spawnTile(popSet)
	spawnTile(popSet)
	render(popSet)
	sendSave()
end

restartButton.Activated:Connect(newGame)

-- ========================================================================
-- 6. PERSISTENCE (sunucu kaydi: skor, best, tahta, tema)
-- ========================================================================
local VALID_TILE = { [0] = true }
do
	local v = 2
	while v <= 131072 do VALID_TILE[v] = true v *= 2 end
end

local function validBoard(b)
	if type(b) ~= "table" then return false end
	local tileCount = 0
	for r = 1, GRID do
		if type(b[r]) ~= "table" then return false end
		for c = 1, GRID do
			local v = b[r][c]
			if type(v) ~= "number" or not VALID_TILE[v] then return false end
			if v > 0 then tileCount += 1 end
		end
	end
	return tileCount > 0
end

sendSave = function()
	if not loaded then return end
	SaveEvent:FireServer({
		board = grid,
		score = score,
		theme = currentTheme,
	})
end

local function loadSavedState()
	local ok, data = pcall(function()
		return GetData:InvokeServer()
	end)

	if ok and type(data) == "table" then
		best = (type(data.best) == "number") and math.max(0, data.best) or 0
		if data.theme == "Dark" then applyTheme("Dark") end

		if validBoard(data.board) and type(data.score) == "number" and data.score >= 0 then
			-- Yarim kalan oyunu aynen surdur
			for r = 1, GRID do
				grid[r] = {}
				for c = 1, GRID do grid[r][c] = data.board[r][c] end
			end
			score = math.floor(data.score)
			render(nil)
			checkGameOver()
			loaded = true
			return
		end
	end

	-- Kayit yok veya bozuk: temiz baslangic (best korunur)
	loaded = true
	newGame()
end

-- ========================================================================
-- 7. INPUT (WASD + ok tuslari, debounce)
-- ========================================================================
local KEY_MAP = {
	[Enum.KeyCode.W] = "Up",    [Enum.KeyCode.Up] = "Up",
	[Enum.KeyCode.S] = "Down",  [Enum.KeyCode.Down] = "Down",
	[Enum.KeyCode.A] = "Left",  [Enum.KeyCode.Left] = "Left",
	[Enum.KeyCode.D] = "Right", [Enum.KeyCode.Right] = "Right",
}

local busy = false
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or busy or gameOver or not loaded then return end
	local direction = KEY_MAP[input.KeyCode]
	if not direction then return end
	busy = true
	move(direction)
	task.delay(MOVE_DEBOUNCE, function() busy = false end)
end)

-- ========================================================================
-- 8. ANIM: 2048+ tile'lari icin dinamik neon hue dongusu
-- ========================================================================
RunService.Heartbeat:Connect(function()
	local hue = (os.clock() * 0.35) % 1
	local rainbow = Color3.fromHSV(hue, 0.8, 1)
	local txt = textColorFor(rainbow)
	for r = 1, GRID do
		for c = 1, GRID do
			if grid[r] and grid[r][c] and grid[r][c] >= 2048 then
				local tile = cells[r][c].tile
				tile.BackgroundColor3 = rainbow
				tile.TextColor3 = txt
			end
		end
	end
end)

-- ========================================================================
-- BASLAT
-- ========================================================================
math.randomseed(os.clock() * 1e6)
for r = 1, GRID do
	grid[r] = {}
	for c = 1, GRID do grid[r][c] = 0 end
end
applyTheme("Light")
loadSavedState()   -- yields: sunucudan kayit gelene kadar bekler, sonra oyun baslar
