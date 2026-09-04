# Seerr (Next.js): no runtime base URL — strip_prefix + Location rewrite + referer-bound root assets.
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
@app_route_{{ROUTE_TAG}}_root {
	path /_next /_next/* /api/v1 /api/v1/* /images /images/* /login /login/* /favicon.ico /site.webmanifest
	header_regexp Referer .*{{BASE}}.*
}
route @app_route_{{ROUTE_TAG}}_root {
	reverse_proxy 127.0.0.1:{{PORT}} {
		flush_interval -1
		header_up Host {host}
		header_up Accept-Encoding identity
		header_down -x-webkit-csp
		header_down -content-security-policy
		header_down Location ^/(.*)$ "{{BASE_SLASH}}$1"
	}
}
@app_route_{{ROUTE_TAG}}_root_pref {
	path_regexp logo ^/logo_
	header_regexp Referer .*{{BASE}}.*
}
route @app_route_{{ROUTE_TAG}}_root_pref {
	reverse_proxy 127.0.0.1:{{PORT}} {
		flush_interval -1
		header_up Host {host}
		header_up Accept-Encoding identity
		header_down -x-webkit-csp
		header_down -content-security-policy
		header_down Location ^/(.*)$ "{{BASE_SLASH}}$1"
	}
}
@app_route_{{ROUTE_TAG}}_root_mobile {
	path_regexp mobile ^/(android|apple)-
	header_regexp Referer .*{{BASE}}.*
}
route @app_route_{{ROUTE_TAG}}_root_mobile {
	reverse_proxy 127.0.0.1:{{PORT}} {
		flush_interval -1
		header_up Host {host}
		header_up Accept-Encoding identity
		header_down -x-webkit-csp
		header_down -content-security-policy
		header_down Location ^/(.*)$ "{{BASE_SLASH}}$1"
	}
}
