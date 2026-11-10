--!strict
return function(h)
 local Admin = h.require("src/server/AdminConfig.luau")
 local Commerce = h.require("src/shared/MonetizationConfig.luau")
 h.test("release defaults: admin and commerce disabled", function()
  h.eq(Admin.ADMIN_USER_ID, 0)
  for _, id in {0, -1, 90000001, "90000001", false} do h.eq(Admin.isAdmin(id), false) end
  h.eq(Admin.isAdmin(nil), false)
  h.eq(Commerce.Enabled, false)
  h.eq(Commerce.LAUNCH_HIDE, true)
  h.eq(Commerce.ReceiptRecoveryEnabled, false)
 end)
 h.test("synthetic configured admin is exclusive and Studio never grants live access", function()
  local policy = Admin.forUserId(90000001)
  h.eq(policy.isAdmin(90000001), true)
  h.eq(policy.isAdmin(90000002), false)
  h.eq(policy.isAdmin("90000001"), false)
  h.eq(Admin.isAdminPlayer(90000001, false, true, 90000001), false)
  h.eq(Admin.isAdminPlayer(90000001, true, true, 90000001), true)
  h.eq(Admin.ADMIN_USER_ID, 0)
 end)
 h.test("configured sales bind and mirror; recovery binds without advertising", function()
  local Binder = h.require("src/server/StoreBinder.luau")
  local product
  for _, p in Commerce.PRODUCTS do if p.kind == "DevProduct" then product = p; break end end
  h.ok(product ~= nil)
  local game = h.stubs.game
  local oldGet = game.GetService
  local rs = oldGet(game, "ReplicatedStorage")
  local mirrored = {}
  rs.SkyRallyStore = { SetAttribute = function(_, key, id) mirrored[key] = id end }
  local market = {
   GetDeveloperProductsAsync = function() return {
    IsFinished = true,
    GetCurrentPage = function() return {{ Name = product.storeName or product.label, ProductId = 90000002 }} end,
   } end,
   GetProductInfo = function() return { Name = product.storeName or product.label, PriceInRobux = 49 } end,
  }
  game.GetService = function(self, name) return if name == "MarketplaceService" then market else oldGet(self, name) end
  local run = Binder.run
  local captured
  Binder.run = function(options) captured = options end
  for _, enabled in {false, true} do
   local config = table.clone(Commerce)
   config.Enabled = enabled
   config.ReceiptRecoveryEnabled = true
   h.fake("src/shared/MonetizationConfig.luau", config)
   table.clear(mirrored)
   local bound = {}
   Binder.start(function(key, id) bound[key] = id; return true end, {product}, function() return true end)
   h.ok(captured ~= nil, "start scheduled binder")
   run(captured)
   h.eq(bound[product.key], 90000002)
   h.eq(mirrored[product.key], if enabled then 90000002 else nil)
  end
  Binder.run = run
  game.GetService = oldGet
  rs.SkyRallyStore = nil
  h.fake("src/shared/MonetizationConfig.luau", Commerce)
 end)
 h.test("disabled binder never touches Marketplace or publishes IDs", function()
  local Binder = h.require("src/server/StoreBinder.luau")
  Binder.start(function() error("must not bind") end, Commerce.PRODUCTS, function() return true end)
 end)
end
