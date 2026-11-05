# Transmission: portal auth + reverse_proxy (WebUI ships in the daemon package).
@app_route_{{ROUTE_TAG}}_slash {
	path {{BASE}}
}
redir @app_route_{{ROUTE_TAG}}_slash {{BASE_SLASH}} 302
@app_route_{{ROUTE_TAG}} {
	path {{BASE}} {{BASE_SLASH}} {{BASE_SLASH}}*
}
route @app_route_{{ROUTE_TAG}} {
	authorize with torrent_apps_policy
	reverse_proxy {{UPSTREAM}} {
		flush_interval -1
		header_up Host {host}
		header_up X-Forwarded-Prefix {{BASE}}
		header_up X-Forwarded-PathBase {{BASE}}
		header_up Accept-Encoding identity
		header_down -x-webkit-csp
		header_down -content-security-policy
	}
}
