# Syncthing GUI is at / on loopback and rejects a non-localhost Host (403 Host check error).
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
		header_up Host 127.0.0.1:{{PORT}}
		header_up -Origin
		header_up X-Real-IP 127.0.0.1
		header_up -Accept-Encoding
		header_down -x-webkit-csp
		header_down -content-security-policy
		header_down Location ^/(.*)$ "{{BASE_SLASH}}$1"
	}
}

@app_route_{{ROUTE_TAG}}_rest {
	path /rest /rest/* /qr /qr/* /meta.js
	header_regexp Referer ^https?://[^/]+{{BASE}}(?:/|$)
}
route @app_route_{{ROUTE_TAG}}_rest {
	authorize with torrent_apps_policy
	reverse_proxy 127.0.0.1:{{PORT}} {
		flush_interval -1
		header_up Host 127.0.0.1:{{PORT}}
		header_up -Origin
		header_up X-Real-IP 127.0.0.1
		header_up -Accept-Encoding
		header_down -x-webkit-csp
		header_down -content-security-policy
	}
}
