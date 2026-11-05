# Flood: default (no strip) proxy + Krate theme static + HTML inject.
@app_route_{{ROUTE_TAG}}_slash {
	path {{BASE}}
}
redir @app_route_{{ROUTE_TAG}}_slash {{BASE_SLASH}} 302
@app_route_{{ROUTE_TAG}}_krate {
	path {{BASE_SLASH}}krate-theme {{BASE_SLASH}}krate-theme/*
}
route @app_route_{{ROUTE_TAG}}_krate {
	uri strip_prefix {{BASE_SLASH}}krate-theme
	root * /opt/{{USERNAME}}/flood/krate-theme
	file_server
}
# Theme inject on document navigations only. Skip /api/* so SSE activity-stream
# is not buffered by replace-response (that hang left /overview on the spinner).
@app_route_{{ROUTE_TAG}}_doc {
	path {{BASE}} {{BASE_SLASH}} {{BASE_SLASH}}*
	not path {{BASE_SLASH}}api {{BASE_SLASH}}api/*
}
route @app_route_{{ROUTE_TAG}}_doc {
	replace {
		`</head>` `<link rel="stylesheet" type="text/css" href="{{BASE_SLASH}}krate-theme/style.css"><script defer src="{{BASE_SLASH}}krate-theme/init.js"></script></head>`
	}
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
@app_route_{{ROUTE_TAG}}_api {
	path {{BASE_SLASH}}api {{BASE_SLASH}}api/*
}
route @app_route_{{ROUTE_TAG}}_api {
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
