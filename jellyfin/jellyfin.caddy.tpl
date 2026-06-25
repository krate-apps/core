# Jellyfin WebSocket — handle (not route) so matcher wins before generic reverse_proxy.
@app_route_{{ROUTE_TAG}}_ws {
	path {{BASE}}/socket {{BASE}}/socket/*
}
handle @app_route_{{ROUTE_TAG}}_ws {
	reverse_proxy 127.0.0.1:{{PORT}} {
		flush_interval -1
		transport http {
			versions 1.1
			read_timeout 0
			write_timeout 0
		}
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-For {remote_host}
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-Host {host}
	}
}
# Jellyfin subpath: match base, base/, and base/* (reverse_proxy /base/* alone misses /base/).
@app_route_{{ROUTE_TAG}}_slash {
	path {{BASE}}
}
redir @app_route_{{ROUTE_TAG}}_slash {{BASE}}/ 302
@app_route_{{ROUTE_TAG}} {
	path {{BASE}} {{BASE}}/ {{BASE}}/*
	not path {{BASE}}/socket {{BASE}}/socket/*
}
route @app_route_{{ROUTE_TAG}} {
	reverse_proxy 127.0.0.1:{{PORT}} {
		flush_interval -1
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-For {remote_host}
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-Host {host}
		header_up X-Forwarded-Prefix {{BASE}}
		header_up -Accept-Encoding
		header_down -x-webkit-csp
		header_down -content-security-policy
	}
}
