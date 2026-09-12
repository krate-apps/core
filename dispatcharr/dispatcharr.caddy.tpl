# Dispatcharr: strip_prefix HTTP on PORT; Daphne WebSocket on PORT+1 at {{BASE}}/ws.
@app_route_{{ROUTE_TAG}}_ws {
	path {{BASE}}/ws {{BASE}}/ws/ {{BASE}}/ws/*
}
handle @app_route_{{ROUTE_TAG}}_ws {
	uri strip_prefix {{BASE}}
	reverse_proxy 127.0.0.1:{{DAPHNE_PORT}} {
		flush_interval -1
		transport http {
			versions 1.1
			read_timeout 0
			write_timeout 0
		}
		header_up Host {host}
		header_up X-Real-IP {remote_host}
	}
}
@app_route_{{ROUTE_TAG}}_slash {
	path {{BASE}}
}
redir @app_route_{{ROUTE_TAG}}_slash {{BASE_SLASH}} 302
@app_route_{{ROUTE_TAG}} {
	path {{BASE}} {{BASE_SLASH}} {{BASE_SLASH}}*
	not path {{BASE}}/ws {{BASE}}/ws/ {{BASE}}/ws/*
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
