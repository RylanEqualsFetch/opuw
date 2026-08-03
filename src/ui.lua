--[[ opus.cc — UI library

     Self-contained menu toolkit. No external library, no HTTP assets: every
     control is built from primitives so the client has exactly one download
     path and nothing to break when someone else's library changes.

     Controls bind directly to config paths, so a control and the feature that
     reads it never drift apart. ]]

local client = ...
local util = client.require("util")
local config = client.require("config")

local UserInputService = util.UserInputService
local TweenService = util.TweenService
local RunService = util.RunService

local ui = {}

--==========================================================================--
-- theme
--==========================================================================--

local theme = {
    background   = Color3.fromRGB(18, 18, 20),
    panel        = Color3.fromRGB(24, 24, 27),
    panelAlt     = Color3.fromRGB(30, 30, 34),
    raised       = Color3.fromRGB(38, 38, 43),
    border       = Color3.fromRGB(48, 48, 54),
    borderSoft   = Color3.fromRGB(38, 38, 43),
    text         = Color3.fromRGB(226, 226, 230),
    textDim      = Color3.fromRGB(140, 140, 148),
    textFaint    = Color3.fromRGB(96, 96, 104),
    accent       = Color3.fromRGB(214, 148, 60),
}
ui.theme = theme

local FONT = Enum.Font.Gotham
local FONT_BOLD = Enum.Font.GothamBold
local TEXT = 12

local maid = util.Maid.new()

local function accent()
    return config.get("menu.accent", theme.accent)
end

--==========================================================================--
-- primitives
--==========================================================================--

local function new(class, props, children)
    local instance = Instance.new(class)
    for key, value in pairs(props or {}) do
        if key ~= "Parent" then
            instance[key] = value
        end
    end
    for _, child in ipairs(children or {}) do
        child.Parent = instance
    end
    if props and props.Parent then
        instance.Parent = props.Parent
    end
    return instance
end

local function corner(radius, parent)
    return new("UICorner", { CornerRadius = UDim.new(0, radius or 4), Parent = parent })
end

local function stroke(color, thickness, parent)
    return new("UIStroke", {
        Color = color or theme.border,
        Thickness = thickness or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        Parent = parent,
    })
end

local function padding(all, parent)
    return new("UIPadding", {
        PaddingTop = UDim.new(0, all),
        PaddingBottom = UDim.new(0, all),
        PaddingLeft = UDim.new(0, all),
        PaddingRight = UDim.new(0, all),
        Parent = parent,
    })
end

local function label(text, size, color, parent)
    return new("TextLabel", {
        BackgroundTransparency = 1,
        Font = FONT,
        Text = text,
        TextSize = size or TEXT,
        TextColor3 = color or theme.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Parent = parent,
    })
end

--- Fire `fn` when the mouse is released inside `button`, with hover feedback.
local function bindButton(button, fn)
    maid:give(button.MouseButton1Click:Connect(function()
        local ok, err = pcall(fn)
        if not ok then
            warn("[opus.cc] ui callback: " .. tostring(err))
        end
    end))
end

--==========================================================================--
-- screen root
--==========================================================================--

local screen = new("ScreenGui", {
    Name = "opuscc_" .. tostring(math.random(1e6, 9e6)),
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 9999,
})
util.protect(screen)
screen.Parent = util.guiParent()
maid:give(screen)

ui.screen = screen

--==========================================================================--
-- notifications
--==========================================================================--

local notifyHolder = new("Frame", {
    Name = "Notifications",
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -16, 1, -16),
    Size = UDim2.fromOffset(280, 400),
    BackgroundTransparency = 1,
    Parent = screen,
}, {
    new("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        VerticalAlignment = Enum.VerticalAlignment.Bottom,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        Padding = UDim.new(0, 6),
    }),
})

function ui.notify(text, duration)
    if not config.get("menu.notifications", true) then return end
    duration = duration or 3

    local frame = new("Frame", {
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundColor3 = theme.panel,
        BackgroundTransparency = 1,
        Parent = notifyHolder,
    })
    corner(4, frame)
    local edge = stroke(theme.border, 1, frame)
    edge.Transparency = 1

    local bar = new("Frame", {
        Size = UDim2.new(0, 2, 1, -8),
        Position = UDim2.fromOffset(6, 4),
        BackgroundColor3 = accent(),
        BorderSizePixel = 0,
        Parent = frame,
    })
    corner(1, bar)

    local body = label(text, TEXT, theme.text, frame)
    body.Position = UDim2.fromOffset(16, 0)
    body.Size = UDim2.new(1, -22, 1, 0)
    body.TextTransparency = 1
    body.TextTruncate = Enum.TextTruncate.AtEnd

    local fadeIn = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(frame, fadeIn, { BackgroundTransparency = 0.08 }):Play()
    TweenService:Create(edge, fadeIn, { Transparency = 0 }):Play()
    TweenService:Create(body, fadeIn, { TextTransparency = 0 }):Play()

    task.delay(duration, function()
        if not frame.Parent then return end
        local fadeOut = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        TweenService:Create(frame, fadeOut, { BackgroundTransparency = 1 }):Play()
        TweenService:Create(edge, fadeOut, { Transparency = 1 }):Play()
        TweenService:Create(body, fadeOut, { TextTransparency = 1 }):Play()
        task.delay(0.22, function()
            if frame.Parent then frame:Destroy() end
        end)
    end)
end

--==========================================================================--
-- window
--==========================================================================--

local WINDOW_W, WINDOW_H = 620, 440

local window = new("Frame", {
    Name = "Window",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(WINDOW_W, WINDOW_H),
    BackgroundColor3 = theme.background,
    BorderSizePixel = 0,
    Visible = config.get("menu.open", true),
    Parent = screen,
})
corner(6, window)
local windowStroke = stroke(theme.border, 1, window)

ui.window = window

-- title bar -----------------------------------------------------------------

local titleBar = new("Frame", {
    Size = UDim2.new(1, 0, 0, 34),
    BackgroundColor3 = theme.panel,
    BorderSizePixel = 0,
    Parent = window,
})
corner(6, titleBar)
new("Frame", { -- square off the bottom corners of the rounded title bar
    Position = UDim2.new(0, 0, 1, -6),
    Size = UDim2.new(1, 0, 0, 6),
    BackgroundColor3 = theme.panel,
    BorderSizePixel = 0,
    Parent = titleBar,
})

local titleDot = new("Frame", {
    Position = UDim2.fromOffset(12, 14),
    Size = UDim2.fromOffset(6, 6),
    BackgroundColor3 = accent(),
    BorderSizePixel = 0,
    Parent = titleBar,
})
corner(3, titleDot)

local titleText = label("opus.cc", 13, theme.text, titleBar)
titleText.Font = FONT_BOLD
titleText.Position = UDim2.fromOffset(26, 0)
titleText.Size = UDim2.new(0, 100, 1, 0)

local subtitle = label(("v%s  ·  bloxstrike"):format(client.version), 11, theme.textFaint, titleBar)
subtitle.Position = UDim2.fromOffset(86, 0)
subtitle.Size = UDim2.new(0, 200, 1, 0)

-- dragging -------------------------------------------------------------------
do
    local dragging, dragStart, startPos = false, nil, nil

    maid:give(titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = window.Position
        end
    end))

    maid:give(UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end
        local delta = input.Position - dragStart
        window.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end))

    maid:give(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
end

-- tab rail --------------------------------------------------------------------

local rail = new("Frame", {
    Position = UDim2.fromOffset(0, 34),
    Size = UDim2.new(0, 120, 1, -34),
    BackgroundColor3 = theme.panel,
    BorderSizePixel = 0,
    Parent = window,
})
-- Sibling of the rail, not a child: the rail runs a UIListLayout, which lays
-- out *every* GuiObject child. A full-height divider parented inside it sorts
-- ahead of the tabs on default LayoutOrder 0 and shoves them all off the window.
new("Frame", {
    Position = UDim2.fromOffset(119, 34),
    Size = UDim2.new(0, 1, 1, -34),
    BackgroundColor3 = theme.border,
    BorderSizePixel = 0,
    ZIndex = 2,
    Parent = window,
})
new("UIListLayout", {
    SortOrder = Enum.SortOrder.LayoutOrder,
    Padding = UDim.new(0, 2),
    Parent = rail,
})
new("UIPadding", {
    PaddingTop = UDim.new(0, 8),
    PaddingLeft = UDim.new(0, 8),
    PaddingRight = UDim.new(0, 9),
    Parent = rail,
})

local pageHolder = new("Frame", {
    Position = UDim2.fromOffset(120, 34),
    Size = UDim2.new(1, -120, 1, -34),
    BackgroundTransparency = 1,
    Parent = window,
})

--==========================================================================--
-- tabs
--==========================================================================--

local tabs = {}
local activeTab = nil

local Tab = {}
Tab.__index = Tab

local function selectTab(tab)
    if activeTab == tab then return end
    for _, other in ipairs(tabs) do
        other.page.Visible = false
        other.button.BackgroundTransparency = 1
        other.label.TextColor3 = theme.textDim
        other.indicator.BackgroundTransparency = 1
    end
    tab.page.Visible = true
    tab.button.BackgroundTransparency = 0
    tab.label.TextColor3 = theme.text
    tab.indicator.BackgroundColor3 = accent()
    tab.indicator.BackgroundTransparency = 0
    activeTab = tab
end

function ui.tab(name)
    local button = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 28),
        BackgroundColor3 = theme.raised,
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        LayoutOrder = #tabs + 1,
        Parent = rail,
    })
    corner(4, button)

    local indicator = new("Frame", {
        Position = UDim2.fromOffset(0, 7),
        Size = UDim2.fromOffset(2, 14),
        BackgroundColor3 = accent(),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Parent = button,
    })
    corner(1, indicator)

    local text = label(name, TEXT, theme.textDim, button)
    text.Position = UDim2.fromOffset(12, 0)
    text.Size = UDim2.new(1, -12, 1, 0)

    local page = new("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Visible = false,
        Parent = pageHolder,
    })

    -- two independently scrolling columns keeps long feature lists readable
    local columns = {}
    for i = 1, 2 do
        local column = new("ScrollingFrame", {
            Position = UDim2.new(0.5 * (i - 1), i == 1 and 10 or 5, 0, 10),
            Size = UDim2.new(0.5, i == 1 and -15 or -15, 1, -20),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ScrollBarThickness = 2,
            ScrollBarImageColor3 = theme.border,
            CanvasSize = UDim2.new(),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            Parent = page,
        })
        new("UIListLayout", {
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, 8),
            Parent = column,
        })
        columns[i] = column
    end

    local tab = setmetatable({
        name = name,
        button = button,
        label = text,
        indicator = indicator,
        page = page,
        columns = columns,
        order = { 0, 0 },
    }, Tab)

    bindButton(button, function() selectTab(tab) end)

    maid:give(button.MouseEnter:Connect(function()
        if activeTab ~= tab then text.TextColor3 = theme.text end
    end))
    maid:give(button.MouseLeave:Connect(function()
        if activeTab ~= tab then text.TextColor3 = theme.textDim end
    end))

    table.insert(tabs, tab)
    if #tabs == 1 then selectTab(tab) end
    return tab
end

--==========================================================================--
-- sections
--==========================================================================--

local Section = {}
Section.__index = Section

function Tab:section(title, side)
    side = side == "right" and 2 or 1
    self.order[side] += 1

    local frame = new("Frame", {
        Size = UDim2.new(1, -4, 0, 30),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = theme.panel,
        BorderSizePixel = 0,
        LayoutOrder = self.order[side],
        Parent = self.columns[side],
    })
    corner(5, frame)
    stroke(theme.borderSoft, 1, frame)

    local header = label(title, TEXT, theme.textDim, frame)
    header.Font = FONT_BOLD
    header.Position = UDim2.fromOffset(10, 8)
    header.Size = UDim2.new(1, -20, 0, 14)

    local body = new("Frame", {
        Position = UDim2.fromOffset(0, 26),
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = frame,
    })
    new("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 4),
        Parent = body,
    })
    new("UIPadding", {
        PaddingLeft = UDim.new(0, 10),
        PaddingRight = UDim.new(0, 10),
        PaddingBottom = UDim.new(0, 10),
        Parent = body,
    })

    return setmetatable({ frame = frame, body = body, order = 0 }, Section)
end

function Section:_row(height)
    self.order += 1
    return new("Frame", {
        Size = UDim2.new(1, 0, 0, height),
        BackgroundTransparency = 1,
        LayoutOrder = self.order,
        Parent = self.body,
    })
end

--==========================================================================--
-- controls
--==========================================================================--

function Section:label(text)
    local row = self:_row(16)
    local body = label(text, 11, theme.textFaint, row)
    body.Size = UDim2.fromScale(1, 1)
    body.TextWrapped = true
    return {
        set = function(_, value) body.Text = value end,
    }
end

function Section:divider()
    local row = self:_row(7)
    new("Frame", {
        Position = UDim2.new(0, 0, 0, 3),
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = theme.borderSoft,
        BorderSizePixel = 0,
        Parent = row,
    })
end

function Section:button(text, callback)
    local row = self:_row(24)
    local button = new("TextButton", {
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = theme.raised,
        AutoButtonColor = false,
        Font = FONT,
        Text = text,
        TextSize = TEXT,
        TextColor3 = theme.text,
        Parent = row,
    })
    corner(4, button)
    stroke(theme.border, 1, button)

    maid:give(button.MouseEnter:Connect(function()
        button.BackgroundColor3 = theme.border
    end))
    maid:give(button.MouseLeave:Connect(function()
        button.BackgroundColor3 = theme.raised
    end))
    bindButton(button, callback)

    return { instance = button }
end

--- Boolean toggle bound to a config path.
function Section:toggle(text, path, callback)
    local row = self:_row(20)

    local hit = new("TextButton", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = "",
        Parent = row,
    })

    local box = new("Frame", {
        Position = UDim2.fromOffset(0, 3),
        Size = UDim2.fromOffset(14, 14),
        BackgroundColor3 = theme.raised,
        BorderSizePixel = 0,
        Parent = row,
    })
    corner(3, box)
    local boxStroke = stroke(theme.border, 1, box)

    local tick = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(6, 6),
        BackgroundColor3 = accent(),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Parent = box,
    })
    corner(2, tick)

    local body = label(text, TEXT, theme.textDim, row)
    body.Position = UDim2.fromOffset(22, 0)
    body.Size = UDim2.new(1, -22, 1, 0)

    local control = {}

    function control:render(value)
        local info = TweenInfo.new(0.12, Enum.EasingStyle.Quad)
        TweenService:Create(tick, info, {
            BackgroundTransparency = value and 0 or 1,
            Size = value and UDim2.fromOffset(8, 8) or UDim2.fromOffset(6, 6),
        }):Play()
        tick.BackgroundColor3 = accent()
        boxStroke.Color = value and accent() or theme.border
        body.TextColor3 = value and theme.text or theme.textDim
    end

    function control:set(value, silent)
        value = value and true or false
        config.set(path, value)
        control:render(value)
        if not silent and callback then
            local ok, err = pcall(callback, value)
            if not ok then warn("[opus.cc] toggle " .. path .. ": " .. tostring(err)) end
        end
    end

    function control:get()
        return config.get(path, false)
    end

    bindButton(hit, function()
        control:set(not config.get(path, false))
    end)

    maid:give(config.onChange(path, function(value)
        control:render(value and true or false)
    end))

    control:render(config.get(path, false))
    if callback then
        task.defer(function()
            local ok, err = pcall(callback, config.get(path, false))
            if not ok then warn("[opus.cc] toggle init " .. path .. ": " .. tostring(err)) end
        end)
    end
    return control
end

--- Numeric slider. `opts = { min, max, step, suffix }`.
function Section:slider(text, path, opts, callback)
    opts = opts or {}
    local minValue = opts.min or 0
    local maxValue = opts.max or 100
    local step = opts.step or 1
    local suffix = opts.suffix or ""

    local row = self:_row(32)

    local body = label(text, TEXT, theme.textDim, row)
    body.Size = UDim2.new(1, -50, 0, 14)

    local readout = label("", 11, theme.textFaint, row)
    readout.Size = UDim2.new(0, 50, 0, 14)
    readout.Position = UDim2.new(1, -50, 0, 0)
    readout.TextXAlignment = Enum.TextXAlignment.Right

    local track = new("Frame", {
        Position = UDim2.fromOffset(0, 20),
        Size = UDim2.new(1, 0, 0, 5),
        BackgroundColor3 = theme.raised,
        BorderSizePixel = 0,
        Parent = row,
    })
    corner(3, track)

    local fill = new("Frame", {
        Size = UDim2.fromScale(0, 1),
        BackgroundColor3 = accent(),
        BorderSizePixel = 0,
        Parent = track,
    })
    corner(3, fill)

    local knob = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(9, 9),
        BackgroundColor3 = theme.text,
        BorderSizePixel = 0,
        Parent = track,
    })
    corner(5, knob)

    local hit = new("TextButton", {
        Position = UDim2.fromOffset(0, 14),
        Size = UDim2.new(1, 0, 0, 18),
        BackgroundTransparency = 1,
        Text = "",
        Parent = row,
    })

    local control = {}

    local function quantise(value)
        value = math.clamp(value, minValue, maxValue)
        if step > 0 then
            value = math.floor((value - minValue) / step + 0.5) * step + minValue
        end
        -- Kill float dust from the division above so readouts stay clean.
        return util.round(math.clamp(value, minValue, maxValue), 4)
    end

    function control:render(value)
        local alpha = (maxValue - minValue) > 0 and (value - minValue) / (maxValue - minValue) or 0
        fill.Size = UDim2.fromScale(alpha, 1)
        fill.BackgroundColor3 = accent()
        knob.Position = UDim2.fromScale(alpha, 0.5)
        local display = (step < 1) and tostring(util.round(value, 2)) or tostring(math.floor(value + 0.5))
        readout.Text = display .. suffix
    end

    function control:set(value, silent)
        value = quantise(tonumber(value) or minValue)
        config.set(path, value)
        control:render(value)
        if not silent and callback then
            local ok, err = pcall(callback, value)
            if not ok then warn("[opus.cc] slider " .. path .. ": " .. tostring(err)) end
        end
    end

    function control:get()
        return config.get(path, minValue)
    end

    local dragging = false

    local function applyFromPointer(x)
        local alpha = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
        control:set(minValue + alpha * (maxValue - minValue))
    end

    maid:give(hit.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            applyFromPointer(input.Position.X)
        end
    end))

    maid:give(UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            applyFromPointer(input.Position.X)
        end
    end))

    maid:give(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    maid:give(config.onChange(path, function(value)
        if not dragging then control:render(value) end
    end))

    control:render(config.get(path, minValue))
    if callback then
        task.defer(function()
            pcall(callback, config.get(path, minValue))
        end)
    end
    return control
end

--- Single-select dropdown over a fixed option list.
function Section:dropdown(text, path, options, callback)
    local row = self:_row(38)

    local body = label(text, TEXT, theme.textDim, row)
    body.Size = UDim2.new(1, 0, 0, 14)

    local button = new("TextButton", {
        Position = UDim2.fromOffset(0, 16),
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundColor3 = theme.raised,
        AutoButtonColor = false,
        Font = FONT,
        Text = "",
        Parent = row,
    })
    corner(4, button)
    stroke(theme.border, 1, button)

    local current = label("", TEXT, theme.text, button)
    current.Position = UDim2.fromOffset(8, 0)
    current.Size = UDim2.new(1, -26, 1, 0)

    local chevron = label("▾", 11, theme.textFaint, button)
    chevron.Position = UDim2.new(1, -18, 0, 0)
    chevron.Size = UDim2.fromOffset(14, 22)
    chevron.TextXAlignment = Enum.TextXAlignment.Center

    -- The list is parented to the window (not the row) so it draws above every
    -- sibling control instead of being clipped by the scrolling column.
    local list = new("Frame", {
        Size = UDim2.fromOffset(0, 0),
        BackgroundColor3 = theme.panelAlt,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 50,
        Parent = window,
    })
    corner(4, list)
    stroke(theme.border, 1, list)
    new("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = list,
    })

    local open = false
    local entries = {}

    local control = {}

    function control:render(value)
        current.Text = tostring(value)
        for optionValue, entry in pairs(entries) do
            local selected = optionValue == value
            entry.TextColor3 = selected and accent() or theme.textDim
        end
    end

    function control:set(value, silent)
        config.set(path, value)
        control:render(value)
        if not silent and callback then
            local ok, err = pcall(callback, value)
            if not ok then warn("[opus.cc] dropdown " .. path .. ": " .. tostring(err)) end
        end
    end

    function control:get()
        return config.get(path)
    end

    local function close()
        open = false
        list.Visible = false
        chevron.Text = "▾"
    end

    for index, option in ipairs(options) do
        local entry = new("TextButton", {
            Size = UDim2.new(1, 0, 0, 22),
            BackgroundTransparency = 1,
            AutoButtonColor = false,
            Font = FONT,
            Text = "  " .. tostring(option),
            TextSize = TEXT,
            TextColor3 = theme.textDim,
            TextXAlignment = Enum.TextXAlignment.Left,
            LayoutOrder = index,
            ZIndex = 51,
            Parent = list,
        })
        entries[option] = entry

        maid:give(entry.MouseEnter:Connect(function()
            entry.BackgroundTransparency = 0.85
            entry.BackgroundColor3 = theme.text
        end))
        maid:give(entry.MouseLeave:Connect(function()
            entry.BackgroundTransparency = 1
        end))

        bindButton(entry, function()
            control:set(option)
            close()
        end)
    end

    local openedAt = 0

    bindButton(button, function()
        if open then
            close()
            return
        end
        open = true
        openedAt = os.clock()

        local pos = button.AbsolutePosition - window.AbsolutePosition
        local height = #options * 22
        local below = pos.Y + button.AbsoluteSize.Y + 2

        -- Drop upward when the list would run past the bottom of the window.
        local y = below
        if below + height > window.AbsoluteSize.Y - 4 then
            y = math.max(4, pos.Y - height - 2)
        end

        list.Position = UDim2.fromOffset(pos.X, y)
        list.Size = UDim2.fromOffset(button.AbsoluteSize.X, height)
        list.Visible = true
        chevron.Text = "▴"
    end)

    -- Any click landing outside the open list closes it. The 100ms guard skips
    -- the same click that opened it — InputBegan and MouseButton1Click both
    -- fire for one press and their order is not guaranteed.
    maid:give(UserInputService.InputBegan:Connect(function(input)
        if not open then return end
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        if os.clock() - openedAt < 0.1 then return end

        local mouse = UserInputService:GetMouseLocation()
        local origin = list.AbsolutePosition
        local size = list.AbsoluteSize
        local inside = mouse.X >= origin.X and mouse.X <= origin.X + size.X
            and mouse.Y >= origin.Y and mouse.Y <= origin.Y + size.Y
        if not inside then close() end
    end))

    maid:give(window:GetPropertyChangedSignal("Visible"):Connect(function()
        if not window.Visible then close() end
    end))

    maid:give(config.onChange(path, function(value) control:render(value) end))

    control:render(config.get(path, options[1]))
    if callback then
        task.defer(function()
            pcall(callback, config.get(path, options[1]))
        end)
    end
    return control
end

--==========================================================================--
-- keybind capture
--==========================================================================--

local capturing = nil   -- control currently listening for a key

function Section:keybind(text, path, callback)
    local row = self:_row(20)

    local body = label(text, TEXT, theme.textDim, row)
    body.Size = UDim2.new(1, -70, 1, 0)

    local button = new("TextButton", {
        Position = UDim2.new(1, -66, 0, 1),
        Size = UDim2.fromOffset(66, 18),
        BackgroundColor3 = theme.raised,
        AutoButtonColor = false,
        Font = FONT,
        Text = "",
        TextSize = 11,
        TextColor3 = theme.textDim,
        Parent = row,
    })
    corner(3, button)
    stroke(theme.border, 1, button)

    local control = {}

    function control:render(value)
        button.Text = util.keyName(value)
        button.TextColor3 = (value and value ~= "None") and theme.text or theme.textFaint
    end

    function control:set(value, silent)
        config.set(path, value)
        control:render(value)
        if not silent and callback then
            pcall(callback, value)
        end
    end

    bindButton(button, function()
        if capturing then
            capturing.button.Text = util.keyName(config.get(capturing.path))
        end
        capturing = { control = control, button = button, path = path }
        button.Text = "..."
        button.TextColor3 = accent()
    end)

    maid:give(config.onChange(path, function(value) control:render(value) end))
    control:render(config.get(path, "None"))
    return control
end

maid:give(UserInputService.InputBegan:Connect(function(input, processed)
    if not capturing then return end

    if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.Backspace then
        capturing.control:set("None")
        capturing = nil
        return
    end

    local encoded = util.encodeKey(input)
    if not encoded then return end

    -- Ignore the click that opened the capture prompt.
    if encoded == "MB1" and not processed then
        return
    end

    capturing.control:set(encoded)
    capturing = nil
end))

--==========================================================================--
-- colour picker
--==========================================================================--

local pickerOpen = nil
local pickerOpenedAt = 0

local picker = new("Frame", {
    Size = UDim2.fromOffset(180, 168),
    BackgroundColor3 = theme.panelAlt,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 60,
    Parent = window,
})
corner(5, picker)
stroke(theme.border, 1, picker)

-- SV square built from two gradients rather than an uploaded texture, so the
-- client has no asset dependency and renders identically if Roblox ever culls
-- the asset: hue base, white-to-transparent across X, black-to-transparent
-- down Y.
local satVal = new("Frame", {
    Position = UDim2.fromOffset(10, 10),
    Size = UDim2.fromOffset(160, 100),
    BackgroundColor3 = Color3.fromRGB(255, 0, 0),
    BorderSizePixel = 0,
    ZIndex = 61,
    Parent = picker,
})
corner(3, satVal)

local saturationShade = new("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
    ZIndex = 61,
    Parent = satVal,
})
corner(3, saturationShade)
new("UIGradient", {
    Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(1, 1, 1)),
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0),
        NumberSequenceKeypoint.new(1, 1),
    }),
    Parent = saturationShade,
})

local valueShade = new("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BorderSizePixel = 0,
    ZIndex = 62,
    Parent = satVal,
})
corner(3, valueShade)
new("UIGradient", {
    Rotation = 90,
    Color = ColorSequence.new(Color3.new(0, 0, 0), Color3.new(0, 0, 0)),
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(1, 0),
    }),
    Parent = valueShade,
})

local svCursor = new("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Size = UDim2.fromOffset(7, 7),
    BackgroundTransparency = 1,
    ZIndex = 64,
    Parent = satVal,
})
stroke(Color3.new(1, 1, 1), 2, svCursor)
corner(4, svCursor)

local hueBar = new("Frame", {
    Position = UDim2.fromOffset(10, 118),
    Size = UDim2.fromOffset(160, 12),
    BorderSizePixel = 0,
    ZIndex = 61,
    Parent = picker,
})
corner(3, hueBar)
new("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 0, 0)),
        ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 255, 0)),
        ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
        ColorSequenceKeypoint.new(0.50, Color3.fromRGB(0, 255, 255)),
        ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 0, 255)),
        ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
        ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 0, 0)),
    }),
    Parent = hueBar,
})

local hueCursor = new("Frame", {
    AnchorPoint = Vector2.new(0.5, 0),
    Size = UDim2.fromOffset(3, 12),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
    ZIndex = 63,
    Parent = hueBar,
})

local hexBox = new("TextBox", {
    Position = UDim2.fromOffset(10, 138),
    Size = UDim2.fromOffset(160, 20),
    BackgroundColor3 = theme.raised,
    Font = FONT,
    Text = "#FFFFFF",
    TextSize = 11,
    TextColor3 = theme.text,
    ClearTextOnFocus = false,
    ZIndex = 61,
    Parent = picker,
})
corner(3, hexBox)
stroke(theme.border, 1, hexBox)

local pickerH, pickerS, pickerV = 0, 0, 1

local function pushPickerColor(silent)
    if not pickerOpen then return end
    local color = Color3.fromHSV(pickerH, pickerS, pickerV)
    pickerOpen.control:set(color, silent)
end

local function renderPicker()
    satVal.BackgroundColor3 = Color3.fromHSV(pickerH, 1, 1)
    svCursor.Position = UDim2.fromScale(pickerS, 1 - pickerV)
    hueCursor.Position = UDim2.fromScale(pickerH, 0)
    hexBox.Text = util.toHex(Color3.fromHSV(pickerH, pickerS, pickerV))
end

do
    local draggingSV, draggingHue = false, false

    maid:give(satVal.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then draggingSV = true end
    end))
    maid:give(hueBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then draggingHue = true end
    end))
    maid:give(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            draggingSV, draggingHue = false, false
        end
    end))

    maid:give(RunService.RenderStepped:Connect(function()
        if not (draggingSV or draggingHue) then return end
        local mouse = UserInputService:GetMouseLocation()
        if draggingSV then
            pickerS = math.clamp((mouse.X - satVal.AbsolutePosition.X) / math.max(satVal.AbsoluteSize.X, 1), 0, 1)
            pickerV = 1 - math.clamp((mouse.Y - satVal.AbsolutePosition.Y) / math.max(satVal.AbsoluteSize.Y, 1), 0, 1)
        end
        if draggingHue then
            pickerH = math.clamp((mouse.X - hueBar.AbsolutePosition.X) / math.max(hueBar.AbsoluteSize.X, 1), 0, 1)
        end
        renderPicker()
        pushPickerColor()
    end))

    maid:give(hexBox.FocusLost:Connect(function(enter)
        if not enter then return end
        local text = hexBox.Text:gsub("#", "")
        if #text == 6 and text:match("^%x+$") then
            local color = util.hex(text)
            pickerH, pickerS, pickerV = Color3.toHSV(color)
            renderPicker()
            pushPickerColor()
        else
            renderPicker()
        end
    end))
end

local function closePicker()
    pickerOpen = nil
    picker.Visible = false
end

function Section:colorpicker(text, path, callback)
    local row = self:_row(20)

    local body = label(text, TEXT, theme.textDim, row)
    body.Size = UDim2.new(1, -36, 1, 0)

    local swatchButton = new("TextButton", {
        Position = UDim2.new(1, -30, 0, 3),
        Size = UDim2.fromOffset(30, 14),
        BackgroundColor3 = config.get(path, Color3.new(1, 1, 1)),
        AutoButtonColor = false,
        Text = "",
        Parent = row,
    })
    corner(3, swatchButton)
    stroke(theme.border, 1, swatchButton)

    local control = {}

    function control:render(value)
        swatchButton.BackgroundColor3 = value
    end

    function control:set(value, silent)
        config.set(path, value)
        control:render(value)
        if not silent and callback then
            pcall(callback, value)
        end
    end

    bindButton(swatchButton, function()
        if pickerOpen and pickerOpen.control == control then
            closePicker()
            return
        end
        pickerOpen = { control = control, path = path }
        pickerOpenedAt = os.clock()
        pickerH, pickerS, pickerV = Color3.toHSV(config.get(path, Color3.new(1, 1, 1)))
        renderPicker()

        local pos = swatchButton.AbsolutePosition - window.AbsolutePosition
        local x = math.clamp(pos.X - 150, 6, window.AbsoluteSize.X - 186)
        local y = math.clamp(pos.Y + 20, 6, window.AbsoluteSize.Y - 174)
        picker.Position = UDim2.fromOffset(x, y)
        picker.Visible = true
    end)

    maid:give(config.onChange(path, function(value) control:render(value) end))
    control:render(config.get(path, Color3.new(1, 1, 1)))
    return control
end

maid:give(UserInputService.InputBegan:Connect(function(input)
    if not pickerOpen then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    if os.clock() - pickerOpenedAt < 0.1 then return end

    local mouse = UserInputService:GetMouseLocation()
    local origin = picker.AbsolutePosition
    local size = picker.AbsoluteSize
    local inside = mouse.X >= origin.X - 2 and mouse.X <= origin.X + size.X + 2
        and mouse.Y >= origin.Y - 2 and mouse.Y <= origin.Y + size.Y + 2
    if not inside then closePicker() end
end))

maid:give(window:GetPropertyChangedSignal("Visible"):Connect(function()
    if not window.Visible then closePicker() end
end))

--- Text entry bound to a config path. `onSubmit` receives the final string.
function Section:textbox(text, placeholder, onSubmit)
    local row = self:_row(38)

    local body = label(text, TEXT, theme.textDim, row)
    body.Size = UDim2.new(1, 0, 0, 14)

    local box = new("TextBox", {
        Position = UDim2.fromOffset(0, 16),
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundColor3 = theme.raised,
        Font = FONT,
        Text = "",
        PlaceholderText = placeholder or "",
        PlaceholderColor3 = theme.textFaint,
        TextSize = TEXT,
        TextColor3 = theme.text,
        ClearTextOnFocus = false,
        Parent = row,
    })
    corner(4, box)
    stroke(theme.border, 1, box)
    new("UIPadding", { PaddingLeft = UDim.new(0, 8), Parent = box })

    maid:give(box.FocusLost:Connect(function(enter)
        if enter and onSubmit then pcall(onSubmit, box.Text) end
    end))

    return {
        instance = box,
        get = function() return box.Text end,
        set = function(_, value) box.Text = tostring(value) end,
    }
end

--==========================================================================--
-- watermark
--==========================================================================--

local watermark = new("Frame", {
    Position = UDim2.fromOffset(16, 16),
    Size = UDim2.fromOffset(200, 22),
    AutomaticSize = Enum.AutomaticSize.X,
    BackgroundColor3 = theme.panel,
    BackgroundTransparency = 0.08,
    BorderSizePixel = 0,
    Visible = false,
    Parent = screen,
})
corner(4, watermark)
stroke(theme.border, 1, watermark)

local watermarkAccent = new("Frame", {
    Size = UDim2.new(0, 2, 1, 0),
    BackgroundColor3 = accent(),
    BorderSizePixel = 0,
    Parent = watermark,
})

local watermarkText = label("opus.cc", 12, theme.text, watermark)
watermarkText.Font = FONT_BOLD
watermarkText.Position = UDim2.fromOffset(10, 0)
watermarkText.Size = UDim2.new(0, 0, 1, 0)
watermarkText.AutomaticSize = Enum.AutomaticSize.X
new("UIPadding", { PaddingRight = UDim.new(0, 12), Parent = watermark })

do
    local frames, accumulated, fps = 0, 0, 0

    maid:give(RunService.RenderStepped:Connect(function(dt)
        frames += 1
        accumulated += dt
        if accumulated >= 0.5 then
            fps = math.floor(frames / accumulated + 0.5)
            frames, accumulated = 0, 0
        end

        local enabled = config.get("menu.watermark", true)
        watermark.Visible = enabled
        if not enabled then return end

        local parts = { "opus.cc" }
        if config.get("menu.watermarkFps", true) then
            table.insert(parts, fps .. " fps")
        end
        if config.get("menu.watermarkPing", true) then
            table.insert(parts, math.floor(util.ping() + 0.5) .. " ms")
        end
        watermarkText.Text = table.concat(parts, "  │  ")
        watermarkAccent.BackgroundColor3 = accent()
    end))
end

--==========================================================================--
-- active keybind list
--==========================================================================--

local keyList = new("Frame", {
    AnchorPoint = Vector2.new(0, 1),
    Position = UDim2.new(0, 16, 1, -16),
    Size = UDim2.fromOffset(150, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundColor3 = theme.panel,
    BackgroundTransparency = 0.1,
    BorderSizePixel = 0,
    Visible = false,
    Parent = screen,
})
corner(4, keyList)
stroke(theme.border, 1, keyList)
new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = keyList })
new("UIPadding", {
    PaddingTop = UDim.new(0, 6),
    PaddingBottom = UDim.new(0, 6),
    PaddingLeft = UDim.new(0, 8),
    PaddingRight = UDim.new(0, 8),
    Parent = keyList,
})

local keyHeader = label("KEYBINDS", 10, theme.textFaint, keyList)
keyHeader.Font = FONT_BOLD
keyHeader.Size = UDim2.new(1, 0, 0, 14)
keyHeader.LayoutOrder = 0

local keyRows = {}
local keyEntries = {}

--- Register a keybind for display in the on-screen list.
--- `isActive` is polled each frame to colour the row.
function ui.trackKeybind(name, path, isActive)
    table.insert(keyEntries, { name = name, path = path, isActive = isActive })
end

maid:give(RunService.RenderStepped:Connect(function()
    local enabled = config.get("menu.keybindList", true)
    keyList.Visible = enabled
    if not enabled then return end

    local order = 0
    local shown = {}

    for _, entry in ipairs(keyEntries) do
        local bind = config.get(entry.path, "None")
        if bind and bind ~= "None" and bind ~= "" then
            order += 1
            local row = keyRows[entry.path]
            if not row then
                row = label("", 11, theme.textDim, keyList)
                row.Size = UDim2.new(1, 0, 0, 14)
                keyRows[entry.path] = row
            end
            row.LayoutOrder = order
            row.Visible = true
            row.Text = ("%s  [%s]"):format(entry.name, util.keyName(bind))
            local active = entry.isActive and entry.isActive() or false
            row.TextColor3 = active and accent() or theme.textDim
            shown[entry.path] = true
        end
    end

    for path, row in pairs(keyRows) do
        if not shown[path] then row.Visible = false end
    end

    keyHeader.Visible = order > 0
    keyList.Visible = order > 0
end))

--==========================================================================--
-- visibility
--==========================================================================--

function ui.setOpen(open)
    window.Visible = open
    config.set("menu.open", open)
    if not open then
        closePicker()
    end
end

function ui.toggle()
    ui.setOpen(not window.Visible)
end

maid:give(UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if capturing then return end
    local bind = config.get("menu.key", "Insert")
    if util.matchesKey(bind, input) then
        ui.toggle()
    end
end))

-- Re-tint accent-coloured chrome whenever the accent changes.
maid:give(config.onChange("menu.accent", function(color)
    titleDot.BackgroundColor3 = color
    watermarkAccent.BackgroundColor3 = color
    windowStroke.Color = theme.border
    if activeTab then
        activeTab.indicator.BackgroundColor3 = color
    end
end))

client.onUnload(function()
    maid:clean()
end)

return ui
