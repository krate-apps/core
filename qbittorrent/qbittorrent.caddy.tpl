# qBittorrent: strip_prefix + portal auth; Host/X-Real-IP forced to loopback;
# /api/v2 at root via Referer; Krate theme static + HTML inject.
# Theme assets stay unauthenticated (like Deluge/Flood) so CSS/JS load on login.
#
# Use route (not handle) with authorize — caddy-security rejects authorize
# inside handle (Symfony-looking error page). Exclude /krate-theme from the
# auth+proxy matcher so theme GETs never hit reverse_proxy (403).
#
# CRITICAL: theme inject must live on a path-disjoint SHELL route only.
# Nested `route { replace }` still left replace-response on the parent chain,
# buffering Mocha XHR panels (views/rss.html, views/log.html, …). MooTools
# Browser.exec then SyntaxError'd on template literals → Execution Log dead.
@app_route_{{ROUTE_TAG}}_slash {
	path {{BASE}}
}
redir @app_route_{{ROUTE_TAG}}_slash {{BASE_SLASH}} 302
@app_route_{{ROUTE_TAG}}_krate {
	# Prefix match (krate-theme*) so nested assets stay on file_server.
	# Do not use block comments with a "js/*" path — it closes early.
	path {{BASE_SLASH}}krate-theme*
}
route @app_route_{{ROUTE_TAG}}_krate {
	uri strip_prefix {{BASE_SLASH}}krate-theme
	root * /opt/{{USERNAME}}/qbittorrent/krate-theme
	# init.js is injected without a stable ?kr= — never let browsers keep a stale copy.
	header Cache-Control "no-cache, must-revalidate"
	file_server
}
# Shell document only — mutually exclusive with _rest by path.
@app_route_{{ROUTE_TAG}}_shell {
	path {{BASE_SLASH}} {{BASE_SLASH}}index.html
}
route @app_route_{{ROUTE_TAG}}_shell {
	authorize with torrent_apps_policy
	uri strip_prefix {{BASE}}
	replace {
		match {
			header Content-Type text/html*
		}
		# Only init.js — it pins style.css?kr=VERSION. Bust init itself too.
		`</head>` `<script defer src="{{BASE_SLASH}}krate-theme/init.js?kr=1.0.0"></script></head>`
	}
	reverse_proxy {{UPSTREAM}} {
		flush_interval -1
		header_up Host 127.0.0.1:{{PORT}}
		header_up -Origin
		header_up X-Real-IP 127.0.0.1
		header_up Accept-Encoding identity
		header_down -x-webkit-csp
		header_down -content-security-policy
	}
}
# All other app paths (Mocha views/*, scripts, API under base) — NO replace.
@app_route_{{ROUTE_TAG}}_rest {
	path {{BASE_SLASH}}*
	not path {{BASE_SLASH}}krate-theme*
	not path {{BASE_SLASH}}index.html
}
route @app_route_{{ROUTE_TAG}}_rest {
	authorize with torrent_apps_policy
	uri strip_prefix {{BASE}}
	reverse_proxy {{UPSTREAM}} {
		flush_interval -1
		header_up Host 127.0.0.1:{{PORT}}
		header_up -Origin
		header_up X-Real-IP 127.0.0.1
		header_up Accept-Encoding identity
		header_down -x-webkit-csp
		header_down -content-security-policy
	}
}
@app_route_{{ROUTE_TAG}}_api_ref {
	path /api/v2 /api/v2/*
	header_regexp Referer .*{{BASE}}.*
}
route @app_route_{{ROUTE_TAG}}_api_ref {
	authorize with torrent_apps_policy
	reverse_proxy {{UPSTREAM}} {
		flush_interval -1
		header_up Host 127.0.0.1:{{PORT}}
		header_up -Origin
		header_up X-Real-IP 127.0.0.1
		header_up Accept-Encoding identity
		header_down -x-webkit-csp
		header_down -content-security-policy
	}
}
