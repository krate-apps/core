# Emby: no BaseUrl — strip_prefix + Location rewrite; /embywebsocket at site root via Referer.
@app_route_{{ROUTE_TAG}}_slash {
	path {{BASE}}
}
redir @app_route_{{ROUTE_TAG}}_slash {{BASE_SLASH}} 302
@app_route_{{ROUTE_TAG}} {
	path {{BASE}} {{BASE_SLASH}} {{BASE_SLASH}}*
}
route @app_route_{{ROUTE_TAG}} {
	uri strip_prefix {{BASE}}
	reverse_proxy 127.0.0.1:{{PORT}} {
		flush_interval -1
		header_up Host {host}
		header_up Accept-Encoding identity
		header_down -x-webkit-csp
		header_down -content-security-policy
		header_down Location ^/(.*)$ "{{BASE_SLASH}}$1"
	}
}
@app_route_{{ROUTE_TAG}}_ws_ref {
	path /embywebsocket /embywebsocket/*
	header_regexp Referer .*{{BASE}}.*
}
route @app_route_{{ROUTE_TAG}}_ws_ref {
	reverse_proxy 127.0.0.1:{{PORT}} {
		flush_interval -1
		transport http {
			versions 1.1 2
		}
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up Connection {>Connection}
		header_up Upgrade {>Upgrade}
	}
}
