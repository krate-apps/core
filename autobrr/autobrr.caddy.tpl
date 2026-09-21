# Autobrr Vite UI emits /assets, fonts and icons at the site root.
# Official subfolder setup: strip_prefix + baseUrl + baseUrlModeLegacy.
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
	path /assets /assets/* /Inter-Variable.woff2 /favicon.ico /manifest.webmanifest /robots.txt /logo192.png
	header_regexp Referer ^https?://[^/]+{{BASE}}(?:/|$)
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

@app_route_{{ROUTE_TAG}}_icons {
	path_regexp icons ^/apple-touch-icon
	header_regexp Referer ^https?://[^/]+{{BASE}}(?:/|$)
}
route @app_route_{{ROUTE_TAG}}_icons {
	reverse_proxy 127.0.0.1:{{PORT}} {
		flush_interval -1
		header_up Host {host}
		header_up Accept-Encoding identity
		header_down -x-webkit-csp
		header_down -content-security-policy
		header_down Location ^/(.*)$ "{{BASE_SLASH}}$1"
	}
}
