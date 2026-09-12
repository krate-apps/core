# Audiobookshelf is built per installation with ROUTER_BASE_PATH={{BASE}}.
@app_route_{{ROUTE_TAG}}_slash {
	path {{BASE}}
}
redir @app_route_{{ROUTE_TAG}}_slash {{BASE_SLASH}} 302
@app_route_{{ROUTE_TAG}} {
	path {{BASE}} {{BASE_SLASH}} {{BASE_SLASH}}*
}
route @app_route_{{ROUTE_TAG}} {
	reverse_proxy 127.0.0.1:{{PORT}} {
		flush_interval -1
		header_up Host {host}
		header_up Accept-Encoding identity
		header_down -x-webkit-csp
		header_down -content-security-policy
	}
}
