# Legacy path/host fragment template — unused for UI.
# Plex Web has no BaseUrl; zenfw::proxy::generate writes a dedicated site block
# (plex_site.caddy.tpl → /etc/caddy/users/plex-{user}.caddy) at https://plex-{user}.{apex}/
# or skips UI proxy so clients use the WAN port (customConnections).
#
# Kept so resolve_app_caddy_template still finds a file; generate short-circuits for plex.
