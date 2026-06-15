<?php
// Per-user ruTorrent reference (KRATE). Runtime config is in /srv/rutorrent/app/conf/config.local.php
// (forbidUserSettings — Novik does not load conf/users/{user}/config.php).

$topDirectory = '/home/{{USERNAME}}/download-clients/rtorrent/';

$scgi_port = 0;
$scgi_host = 'unix:///run/krate/user/{{USERNAME}}.rtorrent.sock';

$XMLRPCMountPoint = '/RPC2';

$log_file = '/home/{{USERNAME}}/download-clients/rtorrent/logs/rutorrent.log';

$profilePath = '/var/lib/krate/rutorrent/{{USERNAME}}';
$profileMask = 0770;
$tempDirectory = '/home/{{USERNAME}}/tmp/rtorrent/';

$pathToExternals = array_merge(
	is_array($pathToExternals ?? null) ? $pathToExternals : array(),
	array(
		'python' => '/usr/bin/python3',
		'dumptorrent' => '/home/{{USERNAME}}/.local/bin/dumptorrent',
		'scrapec' => '/home/{{USERNAME}}/.local/bin/scrapec',
		'mktorrent' => '/home/{{USERNAME}}/.local/bin/mktorrent',
		'rblcheck' => '/home/{{USERNAME}}/.local/bin/rblcheck',
		'dnsget' => '/home/{{USERNAME}}/.local/bin/dnsget',
	)
);
