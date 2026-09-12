# Tdarr WebUI is at /; path .../tdarr/ lets the UI rewrite API/socket.io. Strip the Krate prefix.
@app_route_{{ROUTE_TAG}}_slash {
	path {{BASE}}
}
redir @app_route_{{ROUTE_TAG}}_slash {{BASE_SLASH}} 302

@app_route_{{ROUTE_TAG}} {
	path {{BASE}} {{BASE_SLASH}} {{BASE_SLASH}}*
}
route @app_route_{{ROUTE_TAG}} {
	authorize with torrent_apps_policy
	uri strip_prefix {{BASE}}
	reverse_proxy 127.0.0.1:{{PORT}} {
		flush_interval -1
		header_up Host {host}
		header_up X-Forwarded-Prefix {{BASE}}
		header_up -Accept-Encoding
		header_down -x-webkit-csp
		header_down -content-security-policy
		header_down Location ^/(.*)$ "{{BASE_SLASH}}$1"
	}
}

@app_route_{{ROUTE_TAG}}_sio {
	path /socket.io /socket.io/*
	header_regexp Referer ^https?://[^/]+{{BASE}}(?:/|$)
}
route @app_route_{{ROUTE_TAG}}_sio {
	authorize with torrent_apps_policy
	reverse_proxy 127.0.0.1:{{PORT}} {
		flush_interval -1
		header_up Host {host}
		header_up -Accept-Encoding
		header_down -content-security-policy
	}
}
