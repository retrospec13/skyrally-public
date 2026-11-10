--!strict
-- Notification kit rules (economy v3 phase 3b; pure, no Roblox globals; tools/tests/notify_spec.luau runs it under Lune).
-- src/client/NotifyKit.luau draws; this module decides.
--  * toast queue: one toast shows at a time. Higher priority goes first, then first come first served. The same key while it shows
--    only extends it, the same key while it waits only merges, and a key that just ended is dropped for DEDUPE_S. A higher priority
--    toast preempts the one on screen (a normal-or-better one waits for its turn again, a low one is lost).
--  * banners: persistent lines keyed by id (a lobby timer, "Storm race in progress"); the top one shows, highest priority first,
--    newest on a tie. They stay until cleared.
--  * modals: one card at a time; the rest wait in priority order and never preempt (a modal blocks the screen).
--  * layout: toast / banner / modal / arch label rectangles from HudLayoutRules rects and metrics.
local WorldLabelRules = require(script.Parent:WaitForChild("WorldLabelRules"))

local NotifyRules = {}

NotifyRules.PRIORITY = { low = 1, normal = 2, high = 3, critical = 4 } :: { [string]: number }
NotifyRules.MAX_QUEUE = 6 -- waiting toasts; past this the lowest, oldest goes
NotifyRules.MIN_SECONDS = 1.2
NotifyRules.MAX_SECONDS = 8
NotifyRules.DEFAULT_SECONDS = 2.6
NotifyRules.DEDUPE_S = 1.5 -- a key that just ended is not shown again within this
NotifyRules.MAX_WAIT_S = 10 -- a low priority toast that waited this long is stale and dropped
NotifyRules.EXTEND_CAP_S = 12 -- an extended toast never stays longer than this in total

export type Note = {
	key: string,
	text: string,
	priority: number,
	seconds: number,
	kind: string?,
	id: number,
	seq: number,
	at: number, -- enqueue time
	endsAt: number,
	startedAt: number,
	opts: any?, -- caller extras NotifyKit passes through (color, sound, rect)
}
export type Toasts = { queue: { Note }, active: Note?, seq: number, recent: { [string]: number }, gen: number }

function NotifyRules.priorityOf(p: any): number
	if type(p) == "number" then
		return math.clamp(math.floor(p), 1, 4)
	end
	return NotifyRules.PRIORITY[p :: any] or NotifyRules.PRIORITY.normal
end

local function clampSeconds(s: any): number
	if type(s) ~= "number" then
		return NotifyRules.DEFAULT_SECONDS
	end
	return math.clamp(s, NotifyRules.MIN_SECONDS, NotifyRules.MAX_SECONDS)
end

-- Better first: higher priority, then earlier sequence.
local function before(a: Note, b: Note): boolean
	if a.priority ~= b.priority then
		return a.priority > b.priority
	end
	return a.seq < b.seq
end

local function make(q: { seq: number }, n: any, now: number): Note
	q.seq += 1
	local text = tostring(n.text or "")
	return {
		key = if type(n.key) == "string" and n.key ~= "" then n.key else text,
		text = text,
		priority = NotifyRules.priorityOf(n.priority),
		seconds = clampSeconds(n.seconds),
		kind = n.kind,
		id = q.seq,
		seq = q.seq,
		at = now,
		endsAt = 0,
		startedAt = 0,
		opts = n.opts,
	}
end

function NotifyRules.newToasts(): Toasts
	return { queue = {}, active = nil, seq = 0, recent = {}, gen = 0 }
end

local function sortQueue(q: Toasts)
	table.sort(q.queue, before)
end

local function start(q: Toasts, note: Note, now: number)
	note.startedAt = now
	note.endsAt = now + note.seconds
	q.active = note
	q.gen += 1
end

-- The one on screen waits again with what it had left (at least MIN_SECONDS), unless it was only a low caption; `note` takes over.
local function preempt(q: Toasts, act: Note, note: Note, now: number)
	if act.priority >= NotifyRules.PRIORITY.normal then
		act.seconds = math.max(NotifyRules.MIN_SECONDS, act.endsAt - now)
		table.insert(q.queue, act)
	end
	start(q, note, now)
	sortQueue(q)
end

-- Returns "shown", "queued", "refreshed", "merged" or "dropped".
function NotifyRules.push(q: Toasts, n: any, now: number): string
	local note = make(q, n, now)
	local act = q.active
	if act and act.key == note.key then
		act.text = note.text
		act.endsAt = math.min(math.max(act.endsAt, now + note.seconds), act.startedAt + NotifyRules.EXTEND_CAP_S)
		act.priority = math.max(act.priority, note.priority)
		return "refreshed"
	end
	for _, w in q.queue do
		if w.key == note.key then
			w.text = note.text
			w.priority = math.max(w.priority, note.priority)
			w.seconds = math.max(w.seconds, note.seconds)
			sortQueue(q)
			if act and w.priority > act.priority then
				table.remove(q.queue, table.find(q.queue, w))
				preempt(q, act, w, now)
				return "shown"
			end
			return "merged"
		end
	end
	local last = q.recent[note.key]
	if last and now - last < NotifyRules.DEDUPE_S then
		return "dropped"
	end
	if not act then
		start(q, note, now)
		return "shown"
	end
	if note.priority > act.priority then
		preempt(q, act, note, now)
		return "shown"
	end
	table.insert(q.queue, note)
	sortQueue(q)
	while #q.queue > NotifyRules.MAX_QUEUE do
		-- Worst = last in order (lowest priority, newest). Losing the newcomer itself reports "dropped".
		local lost = table.remove(q.queue) :: Note
		if lost == note then
			return "dropped"
		end
	end
	return "queued"
end

-- Advance time. Returns the toast to show (nil: none) and whether it differs from the last call.
function NotifyRules.tick(q: Toasts, now: number): (Note?, boolean)
	local genBefore = q.gen
	local act = q.active
	if act and now >= act.endsAt then
		q.recent[act.key] = now
		q.active = nil
		q.gen += 1
	end
	if not q.active then
		while #q.queue > 0 do
			local nxt = table.remove(q.queue, 1) :: Note
			local stale = nxt.priority <= NotifyRules.PRIORITY.low and now - nxt.at > NotifyRules.MAX_WAIT_S
			if not stale then
				start(q, nxt, now)
				break
			end
		end
	end
	return q.active, q.gen ~= genBefore
end

function NotifyRules.clearToasts(q: Toasts)
	q.queue = {}
	if q.active then
		q.active = nil
		q.gen += 1
	end
end

-- Persistent banners ------------------------------------------------------------------------------------------------

export type Banner = { key: string, text: string, priority: number, kind: string?, seq: number, opts: any? }
export type Banners = { items: { [string]: Banner }, seq: number }

function NotifyRules.newBanners(): Banners
	return { items = {}, seq = 0 }
end

-- Upsert; an update keeps the banner's place in the order of arrival.
function NotifyRules.setBanner(b: Banners, key: string, text: string, priority: any?, kind: string?, opts: any?)
	local cur = b.items[key]
	if cur then
		cur.text = text
		cur.priority = NotifyRules.priorityOf(priority or cur.priority)
		cur.kind = kind or cur.kind
		cur.opts = opts or cur.opts
		return
	end
	b.seq += 1
	b.items[key] = { key = key, text = text, priority = NotifyRules.priorityOf(priority), kind = kind, seq = b.seq, opts = opts }
end

function NotifyRules.clearBanner(b: Banners, key: string): boolean
	local had = b.items[key] ~= nil
	b.items[key] = nil
	return had
end

function NotifyRules.topBanner(b: Banners): Banner?
	local best: Banner? = nil
	for _, it in b.items do
		if not best or it.priority > best.priority or (it.priority == best.priority and it.seq > best.seq) then
			best = it
		end
	end
	return best
end

-- Modals ------------------------------------------------------------------------------------------------------------

export type Modal = { key: string, priority: number, seq: number, spec: any }
export type Modals = { current: Modal?, queue: { Modal }, seq: number, gen: number }

function NotifyRules.newModals(): Modals
	return { current = nil, queue = {}, seq = 0, gen = 0 }
end

-- "shown", "queued" or "dropped" (the same key is already on screen or waiting).
function NotifyRules.pushModal(m: Modals, key: string, spec: any, priority: any?): string
	if m.current and m.current.key == key then
		return "dropped"
	end
	for _, w in m.queue do
		if w.key == key then
			return "dropped"
		end
	end
	m.seq += 1
	local item: Modal = { key = key, priority = NotifyRules.priorityOf(priority), seq = m.seq, spec = spec }
	if not m.current then
		m.current = item
		m.gen += 1
		return "shown"
	end
	table.insert(m.queue, item)
	table.sort(m.queue, function(a, b)
		if a.priority ~= b.priority then
			return a.priority > b.priority
		end
		return a.seq < b.seq
	end)
	return "queued"
end

-- Close the card on screen; returns the next one (nil: none left).
function NotifyRules.closeModal(m: Modals): Modal?
	m.current = nil
	m.gen += 1
	if #m.queue > 0 then
		m.current = table.remove(m.queue, 1)
	end
	return m.current
end

-- Layout ------------------------------------------------------------------------------------------------------------

export type Rect = { x: number, y: number, w: number, h: number }

-- A toast sits in lane B (hub variant while the ADVENTURE bar is up); an explicit rect (the Garage plank) wins.
function NotifyRules.toastRect(rects: { [string]: Rect }, hubBarUp: boolean, override: Rect?): Rect
	if override then
		return override
	end
	return if hubBarUp and rects.hubLaneB then rects.hubLaneB else rects.laneB
end

-- Banners use the notice stack row under the toast lane, stopped 8 px short of the hub bar when it is up.
function NotifyRules.bannerRect(rects: { [string]: Rect }, hubBarUp: boolean): Rect
	local r = rects.noticeStack
	if hubBarUp and rects.hubBar then
		local right = math.min(r.x + r.w, rects.hubBar.x - 8)
		return { x = r.x, y = r.y, w = math.max(0, right - r.x), h = r.h }
	end
	return r
end

export type ModalLayout = {
	card: Rect,
	pad: number,
	iconSize: number,
	titleH: number,
	bodyH: number,
	buttonH: number,
	buttons: { primary: Rect, close: Rect? },
	titleSize: number,
	bodySize: number,
	buttonSize: number,
}

-- Centre card in the safe area: up to 520 px wide and 320 tall at S = 1, never wider or taller than the safe rect (a 740x360
-- phone leaves 652x~330), buttons never under MIN_BUTTON tall, text never under MIN_TEXT. m = HudLayoutRules.metrics().
-- bodyNeed (optional, px): the height the body text needs at bodySize; the card then shrinks to its content (never taller than
-- the default card, never shorter than FIT_MIN_H) with the same padding, so there is no empty gap above the buttons.
-- bodySizeFor(S) is the body text size the layout will use.
NotifyRules.FIT_MIN_H = 120
function NotifyRules.bodySizeFor(S: number): number
	return math.max(12, math.floor(20 * S + 0.5))
end
function NotifyRules.modalLayout(vpX: number, vpY: number, m: { S: number, x0: number, xr: number, yTop: number, yBot: number }, hasClose: boolean, bodyNeed: number?): ModalLayout
	local S = m.S
	local floorBtn, floorText = 44, 12
	local safeW, safeH = m.xr - m.x0, m.yBot - m.yTop
	local w = math.min(safeW, math.max(280, math.floor(520 * S + 0.5)))
	local h = math.min(safeH, math.max(floorBtn + 100, math.floor(320 * S + 0.5)))
	local pad = math.max(10, math.floor(16 * S + 0.5))
	if bodyNeed then
		local titleH0 = math.max(floorText, math.floor(26 * S + 0.5)) + 6
		local iconSize0 = math.max(28, math.floor(40 * S + 0.5))
		local bodyY0 = pad + math.max(titleH0, iconSize0) + 4
		local buttonH0 = math.max(floorBtn, math.floor(48 * S + 0.5))
		local fit = bodyY0 + math.ceil(bodyNeed) + 2 + pad // 2 + pad + buttonH0
		h = math.min(h, math.max(NotifyRules.FIT_MIN_H, fit))
	end
	local card = {
		x = math.floor((vpX - w) / 2),
		y = math.floor(math.max(m.yTop, math.min(m.yBot - h, (vpY - h) / 2))),
		w = w,
		h = h,
	}
	local buttonH = math.max(floorBtn, math.floor(48 * S + 0.5))
	local titleSize = math.max(floorText, math.floor(26 * S + 0.5))
	local bodySize = math.max(floorText, math.floor(20 * S + 0.5))
	local titleH = titleSize + 6
	local by = card.y + h - pad - buttonH
	local bw = w - 2 * pad
	local buttons: { primary: Rect, close: Rect? }
	if hasClose then
		local gap = math.max(8, pad // 2)
		local cw = math.max(floorBtn, math.floor((bw - gap) * 0.4))
		buttons = {
			primary = { x = card.x + pad, y = by, w = bw - gap - cw, h = buttonH },
			close = { x = card.x + pad + bw - cw, y = by, w = cw, h = buttonH },
		}
	else
		buttons = { primary = { x = card.x + pad, y = by, w = bw, h = buttonH }, close = nil }
	end
	local iconSize = math.max(28, math.floor(40 * S + 0.5))
	return {
		card = card,
		pad = pad,
		iconSize = iconSize,
		titleH = titleH,
		bodyH = math.max(0, by - pad - (card.y + pad + titleH)),
		buttonH = buttonH,
		buttons = buttons,
		titleSize = titleSize,
		bodySize = bodySize,
		buttonSize = math.max(floorText, math.floor(20 * S + 0.5)),
	}
end

-- World arch label: the battle label's distance scale, drawn ARCH_K times larger (an arch is read from the road, not from a nest).
NotifyRules.ARCH_K = 1.6
function NotifyRules.archLabelSize(dist: number, hudScale: number): (number, number)
	local w, h = WorldLabelRules.size(WorldLabelRules.scale(dist, hudScale))
	return math.floor(w * NotifyRules.ARCH_K + 0.5), math.floor(h * NotifyRules.ARCH_K + 0.5)
end

return NotifyRules
