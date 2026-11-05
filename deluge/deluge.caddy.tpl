# Deluge: strip_prefix + portal auth + Krate theme static.
# Theme assets stay unauthenticated (Flood pattern) so CSS/JS load on the login page.
# init.js is injected in vendor index.html (${base}krate-theme/init.js) — no HTML replace.
# xtheme-krate.css is copied into Deluge vendor themes/css at deploy.
@app_route_{{ROUTE_TAG}}_slash {
	path {{BASE}}
}
redir @app_route_{{ROUTE_TAG}}_slash {{BASE_SLASH}} 302
@app_route_{{ROUTE_TAG}}_krate {
	path {{BASE_SLASH}}krate-theme {{BASE_SLASH}}krate-theme/*
}
handle @app_route_{{ROUTE_TAG}}_krate {
	uri strip_prefix {{BASE_SLASH}}krate-theme
	root * /opt/{{USERNAME}}/deluge/krate-theme
	header Cache-Control "no-cache, must-revalidate"
	file_server
}
@app_route_{{ROUTE_TAG}} {
	path {{BASE}} {{BASE_SLASH}} {{BASE_SLASH}}*
}
handle @app_route_{{ROUTE_TAG}} {
	authorize with torrent_apps_policy
	uri strip_prefix {{BASE}}
	reverse_proxy {{UPSTREAM}} {
		flush_interval -1
		header_up Host {host}
		header_up X-Deluge-Base {{BASE_SLASH}}
		header_up X-Forwarded-For 127.0.0.1
		header_up X-Real-IP 127.0.0.1
		header_up Accept-Encoding identity
		header_down -x-webkit-csp
		header_down -content-security-policy
	}
}
