-- LÖVE (love2d) для Forge: основная часть love.graphics / mouse / keyboard / timer поверх встроенной графики (gfx).
-- Программа задаёт love.load / love.update / love.draw / love.mousepressed / love.keypressed…,
-- Forge сам запускает цикл. Касание — левая кнопка мыши, экранный пульт — стрелки, space, return, escape.
local gfx = gfx
love = love or {}

local W, H = 800, 600
local color = {1, 1, 1, 1}
local bg = {0, 0, 0, 1}
local fontSize = 14
local keys = {[1] = "left", [2] = "right", [3] = "up", [4] = "down", [5] = "space", [6] = "return", [7] = "escape"}
local down = {}
local mx, my, mdown = 0, 0, false
local dt, fps, quitting = 0, 0, false

local function apply()
	gfx.color(color[1] * 255, color[2] * 255, color[3] * 255, (color[4] or 1) * 255)
end

-- love.graphics
local g = {}
love.graphics = g

function g.setColor(r, gg, b, a)
	if type(r) == "table" then r, gg, b, a = r[1], r[2], r[3], r[4] end
	color = {r or 1, gg or 1, b or 1, a or 1}
	apply()
end
function g.getColor() return color[1], color[2], color[3], color[4] end
function g.setBackgroundColor(r, gg, b, a)
	if type(r) == "table" then r, gg, b, a = r[1], r[2], r[3], r[4] end
	bg = {r or 0, gg or 0, b or 0, a or 1}
end
function g.getBackgroundColor() return bg[1], bg[2], bg[3], bg[4] end
function g.clear(r, gg, b, a)
	local c = r and {r, gg, b, a or 1} or bg
	gfx.color(c[1] * 255, c[2] * 255, c[3] * 255, 255)
	gfx.clear()
	apply()
end
function g.rectangle(mode, x, y, w, h)
	gfx.rect(x, y, w, h, mode == "line" and 1 or 0)
end
function g.circle(mode, x, y, r)
	gfx.ellipse(x - r, y - r, r * 2, r * 2, mode == "line" and 1 or 0)
end
function g.ellipse(mode, x, y, rx, ry)
	gfx.ellipse(x - rx, y - (ry or rx), rx * 2, (ry or rx) * 2, mode == "line" and 1 or 0)
end
function g.line(...)
	local p = {...}
	if type(p[1]) == "table" then p = p[1] end
	for i = 1, #p - 3, 2 do gfx.line(p[i], p[i + 1], p[i + 2], p[i + 3], 1) end
end
function g.polygon(mode, ...)
	local p = {...}
	if type(p[1]) == "table" then p = p[1] end
	gfx.poly(p, mode == "line" and 1 or 0)
end
function g.points(...)
	local p = {...}
	if type(p[1]) == "table" then p = p[1] end
	for i = 1, #p - 1, 2 do gfx.rect(p[i], p[i + 1], 1, 1, 0) end
end
function g.newFont(a, b)
	local size = type(a) == "number" and a or (b or 12)
	return {size = size, getHeight = function() return size * 1.2 end,
	        getWidth = function(self, t) return gfx.measure(tostring(t), size) end}
end
local currentFont = g.newFont(fontSize)
function g.setFont(f) currentFont = f end
function g.getFont() return currentFont end
function g.setNewFont(...) currentFont = g.newFont(...) return currentFont end
function g.print(text, x, y, r, sx)
	gfx.text(tostring(text), x or 0, y or 0, currentFont.size * (sx or 1))
end
function g.printf(text, x, y, limit, align)
	local w = gfx.measure(tostring(text), currentFont.size)
	if align == "center" then x = x + (limit - w) / 2 elseif align == "right" then x = x + limit - w end
	gfx.text(tostring(text), x, y, currentFont.size)
end
function g.newImage(path)
	local h = gfx.image_load(path)
	if h < 0 then error("cannot load image: " .. tostring(path), 2) end
	return {handle = h, getWidth = function() return gfx.image_w(h) end, getHeight = function() return gfx.image_h(h) end,
	        getDimensions = function() return gfx.image_w(h), gfx.image_h(h) end}
end
function g.draw(img, x, y, r, sx, sy, ox, oy)
	if type(img) ~= "table" or not img.handle then return end
	sx = sx or 1
	sy = sy or sx
	local w, h = gfx.image_w(img.handle) * sx, gfx.image_h(img.handle) * sy
	gfx.image_draw(img.handle, (x or 0) - (ox or 0) * sx, (y or 0) - (oy or 0) * sy, w, h)
end
function g.getWidth() return W end
function g.getHeight() return H end
function g.getDimensions() return W, H end
function g.setLineWidth() end
function g.push() end
function g.pop() end
function g.translate() end
function g.origin() end
function g.setDefaultFilter() end

-- окно, мышь, клавиатура, время
love.window = {
	setMode = function(w, h) W, H = w or W, h or H; gfx.open(W, H) return true end,
	setTitle = function() end,
	getMode = function() return W, H, {} end,
	getDimensions = function() return W, H end,
}
love.mouse = {
	getPosition = function() return mx, my end,
	getX = function() return mx end,
	getY = function() return my end,
	isDown = function(b) return (b == nil or b == 1) and mdown end,
	setVisible = function() end,
}
love.keyboard = {
	isDown = function(...)
		for _, k in ipairs({...}) do if down[k] then return true end end
		return false
	end,
	setKeyRepeat = function() end,
}
love.timer = {
	getTime = function() return gfx.ticks() / 1000 end,
	getDelta = function() return dt end,
	getFPS = function() return math.floor(fps + 0.5) end,
	sleep = function(s) gfx.sleep(s * 1000) end,
}
love.event = {quit = function() quitting = true end}
love.audio = {newSource = function() return {play = function() end, stop = function() end, setVolume = function() end,
                                             setLooping = function() end, pause = function() end} end,
              play = function() end, stop = function() end}
love.math = {random = math.random, setRandomSeed = math.randomseed}

local function call(name, ...)
	local f = love[name]
	if type(f) == "function" then f(...) end
end

-- цикл программы: события → update(dt) → draw → кадр, ~60 кадров в секунду
function love.__run()
	if love.conf then
		local t = {window = {width = W, height = H}, modules = {}}
		love.conf(t)
		W, H = t.window.width or W, t.window.height or H
	end
	gfx.open(W, H)
	call("load")
	local last = gfx.ticks()
	while not quitting do
		while true do
			local t, x, y, k = gfx.poll()
			if not t then break end
			if t == 6 then call("quit") return end
			if t == 1 then mx, my, mdown = x, y, true; call("mousepressed", x, y, 1, true)
			elseif t == 2 then mx, my, mdown = x, y, false; call("mousereleased", x, y, 1, true)
			elseif t == 3 then local dx, dy = x - mx, y - my; mx, my = x, y; call("mousemoved", x, y, dx, dy, true)
			elseif t == 4 then local key = keys[k]; if key then down[key] = true; call("keypressed", key, key, false) end
			elseif t == 5 then local key = keys[k]; if key then down[key] = nil; call("keyreleased", key, key) end
			end
		end
		local now = gfx.ticks()
		dt = (now - last) / 1000
		if dt > 0 then fps = 1 / dt end
		last = now
		call("update", dt)
		gfx.color(bg[1] * 255, bg[2] * 255, bg[3] * 255, 255)
		gfx.clear()
		color = {1, 1, 1, 1}
		apply()
		call("draw")
		gfx.present()
		local spent = gfx.ticks() - now
		if spent < 16 then gfx.sleep(16 - spent) end
	end
	call("quit")
end
