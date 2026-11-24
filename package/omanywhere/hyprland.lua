-- Omanywhere: Hyprland's config in the container. HYPRLAND_CONFIG points here
-- (set by omanywhere-session.service), so `hyprctl reload` reads this file
-- again too.
--
-- It loads the owner's ~/.config/hypr/hyprland.lua, the file Hyprland would
-- load without HYPRLAND_CONFIG, so Omarchy's defaults and the owner's own
-- settings apply as on any Omarchy machine. Then it loads the container's
-- monitor rules, which /usr/lib/omanywhere/session writes for the boot's DRM
-- card: on a GPU, the host's connectors off (and any that appear later), a
-- headless output on. Neither Omarchy's files nor the owner's are changed.
--
-- The container's rules load even when the owner's config raises an error,
-- which is then raised again, so Hyprland reports it as usual.

local config_home = os.getenv("XDG_CONFIG_HOME")
if config_home == nil or config_home == "" then
  config_home = os.getenv("HOME") .. "/.config"
end

local ok, err = pcall(dofile, config_home .. "/hypr/hyprland.lua")
dofile("/run/omanywhere/hypr/container.lua")
if not ok then
  error(err, 0)
end
