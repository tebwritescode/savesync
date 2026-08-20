-- Shared login across mods on one Gen1MMO/SaveSync server.
--
-- THE PROBLEM. Both mods talk to the same server with the same account, and a
-- player who has signed into one should not have to sign into the other. But
-- the engine's mod sandbox gives each mod PRIVATE storage (mod_compat/<id>/),
-- so they cannot share a file, and each mod runs in its own sandbox env, so a
-- plain global does not cross between them either.
--
-- THE CHANNEL. The one sanctioned cross-mod path is exports: a mod publishes
-- a table with `mod.exports`, and any other loaded mod reaches it with
-- `mod.find(id).exports` -- both run in the same Lua state. So each
-- server-using mod PUBLISHES its stored credential under a well-known export
-- name, and a mod with no credential of its own ADOPTS a sibling's.
--
-- THE CONTRACT (bump `V` only on a breaking change):
--   mod.exports.g1account = {
--     v = 1,
--     get = function() -> { name, verifier, deviceSeed, devicePub,
--                           deviceEnrolled } | nil end,
--   }
-- The credential is exactly what a login needs: the account name, the derived
-- verifier (never a password), and the optional passkey device key. Sharing
-- the verifier is safe -- it is scrypt/pbkdf2(password, accountSalt), the same
-- value whichever mod computed it, and useless off this one server.
--
-- FUTURE-PROOFING. A new mod that wants in adds its own id to SIBLINGS below
-- (this file is vendored identically into every participating mod) and
-- publishes the same export. Discovery needs an id per lookup -- the engine
-- exposes no "list every mod" call -- so the id list IS the registry.

local AuthShare = {}

-- Every mod that shares this account store. Vendored identically; a new
-- participant appends its id here. Order is the adoption preference.
AuthShare.SIBLINGS = { "gen1mmo", "savesync" }

AuthShare.CONTRACT = 1

--- Publish this mod's credential for siblings. `getCred` returns the stored
--- credential table (or nil when signed out); it is called live on each
--- lookup, so a later sign-in is visible without re-publishing.
function AuthShare.publish(mod, getCred)
  mod.exports = mod.exports or {}
  mod.exports.g1account = {
    v = AuthShare.CONTRACT,
    get = function()
      local ok, cred = pcall(getCred)
      if ok and type(cred) == "table" and cred.name and cred.verifier then
        return cred
      end
      return nil
    end,
  }
end

--- Look for a signed-in sibling and return its credential, or nil. Read-only:
--- adopting mods copy this into their own store; nothing here writes.
function AuthShare.adopt(mod, selfId)
  if type(mod.find) ~= "function" then return nil end
  for _, id in ipairs(AuthShare.SIBLINGS) do
    if id ~= selfId then
      local ok, handle = pcall(mod.find, mod, id)
      -- mod.find tolerates both mod.find(id) and mod:find(id); normalise.
      if not (ok and handle) then
        ok, handle = pcall(function() return mod.find(id) end)
      end
      local exp = ok and handle and handle.exports
      local account = exp and exp.g1account
      if type(account) == "table" and account.v == AuthShare.CONTRACT
        and type(account.get) == "function" then
        local ok2, cred = pcall(account.get)
        if ok2 and type(cred) == "table" and cred.name and cred.verifier then
          return cred, id
        end
      end
    end
  end
  return nil
end

return AuthShare
