--!strict
-- Robux id binding as pure data (docs/STORE_PRODUCTS_TO_CREATE.md; TEST_LIST_LAUNCH L50-L51). No services: the server
-- binder (server/StoreBinder) feeds it what MarketplaceService:GetDeveloperProductsAsync() listed for the owner's own
-- universe, and the Lune spec feeds it fixtures.
-- * Developer products bind by exact name: a config row's storeName (default: its label) against each listed product's
--   Name, trimmed, inner whitespace collapsed, compared case-insensitively. Two listed products with that name are
--   ambiguous and bind neither. Listed products no row names are ignored.
-- * Every id returned was read from the input entry it matched: this module never makes one up, and a row whose entry
--   has no usable ProductId stays unbound.
-- * Game passes cannot be listed by any engine API, so their ids come only from StorePassIds (owner-pasted, all nil
--   until then); passIds() keeps the well-formed ones for Pass rows.

local StoreBinding = {}

-- What one GetDeveloperProductsAsync page entry carries that binding reads (other fields are ignored).
export type Listed = {
	Name: any,
	ProductId: any, -- the id PromptProductPurchase and ProcessReceipt use
	DeveloperProductId: any?, -- second candidate, tried only when ProductId fails GetProductInfo
	PriceInRobux: any?,
}

export type Match = {
	id: number,
	altId: number?,
	name: string,
	price: number?,
}

export type Result = {
	bound: { [string]: Match }, -- product key -> matched entry
	ambiguous: { string }, -- keys whose name two listed products share (sorted)
	unbound: { string }, -- keys with no listed product of that name (sorted)
}

local function isId(v: any): boolean
	return type(v) == "number" and v == v and v > 0 and v == math.floor(v) and v < 2 ^ 53
end

StoreBinding.isId = isId

-- "  500   gears " -> "500 gears". Non-strings normalize to "".
function StoreBinding.normalize(name: any): string
	if type(name) ~= "string" then
		return ""
	end
	local trimmed = string.match(name, "^%s*(.-)%s*$") or ""
	return string.lower((string.gsub(trimmed, "%s+", " ")))
end

-- The exact name to type in Creator Hub for a row.
function StoreBinding.storeName(p: any): string
	return if type(p.storeName) == "string" and p.storeName ~= "" then p.storeName else p.label
end

-- Matches config DevProduct rows against the listed entries. Pass rows are skipped (see passIds).
function StoreBinding.match(products: { any }, listed: { any }): Result
	local byName: { [string]: { any } } = {}
	for _, entry in ipairs(listed) do
		if type(entry) == "table" then
			local n = StoreBinding.normalize(entry.Name)
			if n ~= "" then
				local list = byName[n]
				if not list then
					list = {}
					byName[n] = list
				end
				table.insert(list, entry)
			end
		end
	end
	local result: Result = { bound = {}, ambiguous = {}, unbound = {} }
	for _, p in ipairs(products) do
		if p.kind == "DevProduct" then
			local hits = byName[StoreBinding.normalize(StoreBinding.storeName(p))]
			if hits and #hits > 1 then
				table.insert(result.ambiguous, p.key)
			elseif hits and isId(hits[1].ProductId) then
				local e = hits[1]
				local alt = if isId(e.DeveloperProductId) and e.DeveloperProductId ~= e.ProductId then e.DeveloperProductId else nil
				result.bound[p.key] = {
					id = e.ProductId,
					altId = alt,
					name = tostring(e.Name),
					price = if type(e.PriceInRobux) == "number" then e.PriceInRobux else nil,
				}
			else
				table.insert(result.unbound, p.key)
			end
		end
	end
	table.sort(result.ambiguous)
	table.sort(result.unbound)
	return result
end

-- Pass key -> id for every Pass row whose StorePassIds entry is a well-formed id; everything else stays unbound.
function StoreBinding.passIds(products: { any }, pasted: { [string]: any }): { [string]: number }
	local out: { [string]: number } = {}
	for _, p in ipairs(products) do
		local id = pasted[p.key]
		if p.kind == "Pass" and isId(id) then
			out[p.key] = id
		end
	end
	return out
end

return StoreBinding
