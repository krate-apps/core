# cross-seed v6 exposes an HTTP API without a web interface.
@app_route_{{ROUTE_TAG}}_root {
	path {{BASE}} {{BASE_SLASH}}
}
route @app_route_{{ROUTE_TAG}}_root {
	rewrite * /api/ping
	reverse_proxy 127.0.0.1:{{PORT}}
}

@app_route_{{ROUTE_TAG}} {
	path {{BASE_SLASH}}*
}
route @app_route_{{ROUTE_TAG}} {
	uri strip_prefix {{BASE}}
	reverse_proxy 127.0.0.1:{{PORT}} {
		flush_interval -1
		header_up Host {host}
	}
}
