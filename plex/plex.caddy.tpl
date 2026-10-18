# Plex Media Server — strip_prefix + Location rewrite (same pattern as Emby).
# {{UPSTREAM}} is ns_ip:port when a VPN app route is enabled, else 127.0.0.1:{{PORT}}.
@app_route_{{ROUTE_TAG}}_slash {
	path {{BASE}}
}
redir @app_route_{{ROUTE_TAG}}_slash {{BASE_SLASH}} 302
@app_route_{{ROUTE_TAG}} {
	path {{BASE}} {{BASE_SLASH}} {{BASE_SLASH}}*
}
route @app_route_{{ROUTE_TAG}} {
	uri strip_prefix {{BASE}}
	reverse_proxy {{UPSTREAM}} {
		flush_interval -1
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up Accept-Encoding identity
		header_down -x-webkit-csp
		header_down -content-security-policy
		header_down Location ^/(.*)$ "{{BASE_SLASH}}$1"
	}
}
