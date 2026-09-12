# Duplicati has no native URL base setting; strip the Krate prefix at the proxy.
@app_route_{{ROUTE_TAG}}_slash {
	path {{BASE}}
}
redir @app_route_{{ROUTE_TAG}}_slash {{BASE_SLASH}} 302

@app_route_{{ROUTE_TAG}} {
	path {{BASE_SLASH}}*
}
route @app_route_{{ROUTE_TAG}} {
	uri strip_prefix {{BASE}}
	reverse_proxy 127.0.0.1:{{PORT}} {
		flush_interval -1
		header_up Host {host}
		header_up X-Forwarded-Prefix {{BASE}}
		header_up Accept-Encoding identity
		header_down Location ^/(.*)$ "{{BASE_SLASH}}$1"
		header_down Set-Cookie "Path=/" "Path={{BASE_SLASH}}"
		header_down -x-webkit-csp
		header_down -content-security-policy
	}
}
