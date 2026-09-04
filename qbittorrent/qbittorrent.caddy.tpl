# qBittorrent: strip_prefix + portal auth; Host/XFF forced to loopback; /api/v2 at root via Referer.
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
		header_up X-Forwarded-For 127.0.0.1
		header_up X-Real-IP 127.0.0.1
		header_up -Accept-Encoding
		header_down -x-webkit-csp
		header_down -content-security-policy
	}
}
@app_route_{{ROUTE_TAG}}_api_ref {
	path /api/v2 /api/v2/*
	header_regexp Referer .*{{BASE}}.*
}
route @app_route_{{ROUTE_TAG}}_api_ref {
	authorize with torrent_apps_policy
	reverse_proxy 127.0.0.1:{{PORT}} {
		flush_interval -1
		header_up Host 127.0.0.1:{{PORT}}
		header_up -Origin
		header_up X-Forwarded-For 127.0.0.1
		header_up X-Real-IP 127.0.0.1
		header_up -Accept-Encoding
		header_down -x-webkit-csp
		header_down -content-security-policy
	}
}
