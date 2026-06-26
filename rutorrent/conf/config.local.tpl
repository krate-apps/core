<?php
// Krate shared multi-user overrides (loaded from conf/config.php before util.php caches profilePath).
// forbidUserSettings: Novik must not append /users/{login}/ — profile is /var/lib/krate/rutorrent/{user}/.

$krateRuUser = $_SERVER['REMOTE_USER']
	?? $_ENV['REMOTE_USER']
	?? $_SERVER['REDIRECT_REMOTE_USER']
	?? $_SERVER['PHP_AUTH_USER']
	?? $_ENV['PHP_AUTH_USER']
	?? '';

// Caddy / php-fpm may pass SCGI target via $_SERVER before $_ENV is populated.
$krateScgiHost = $_SERVER['RU_SCGI_HOST'] ?? $_ENV['RU_SCGI_HOST'] ?? '';
if ($krateScgiHost !== '') {
	$scgi_port = (int) ($_SERVER['RU_SCGI_PORT'] ?? $_ENV['RU_SCGI_PORT'] ?? 0);
	$scgi_host = $krateScgiHost;
}

if ($krateRuUser !== '' && preg_match('/^[a-z_][a-z0-9_-]*$/i', $krateRuUser)) {
	$krateRuUser = strtolower($krateRuUser);
	$forbidUserSettings = true;
	$localHostedMode = true;

	$topDirectory = '/home/' . $krateRuUser . '/download-clients/rtorrent/';
	$profilePath = '/var/lib/krate/rutorrent/' . $krateRuUser;
	$profileMask = 0770;
	$tempDirectory = '/home/' . $krateRuUser . '/tmp/rtorrent/';
	$krateLogsDir = '/home/' . $krateRuUser . '/download-clients/rtorrent/logs';
	$log_file = $krateLogsDir . '/rutorrent.log';

	$rpcLogCalls = true;
	$rpcLogFaults = true;
	$rpcTimeOut = 10;
	$do_diagnostic = true;

	$scgi_port = 0;
	$scgi_host = 'unix:///run/krate/user/' . $krateRuUser . '.rtorrent.sock';
	$XMLRPCMountPoint = '/RPC2';

	// Copies in ~/.local/bin (see rtorrent/rutorrent handler); avoid symlinks into ~/.krate/active (www-data cannot traverse).
	$krateLocalBin = '/home/' . $krateRuUser . '/.local/bin';
	$krateVendorBin = '/home/' . $krateRuUser . '/.krate/active/rtorrent/usr/bin';
	$pathToExternals = array_merge(
		is_array($pathToExternals ?? null) ? $pathToExternals : [],
		array(
			'python' => '/usr/bin/python3',
			'dumptorrent' => $krateLocalBin . '/dumptorrent',
			'scrapec' => $krateLocalBin . '/scrapec',
			'mktorrent' => $krateLocalBin . '/mktorrent',
			'rblcheck' => $krateLocalBin . '/rblcheck',
			'dnsget' => $krateLocalBin . '/dnsget',
		)
	);
	// Fallback when copies are missing but vendor tree exists (rTorrent RPC runs as the app user).
	foreach (array('dumptorrent', 'scrapec', 'mktorrent', 'rblcheck', 'dnsget') as $krateTool) {
		if (!is_executable($pathToExternals[$krateTool] ?? '') && is_executable($krateVendorBin . '/' . $krateTool)) {
			$pathToExternals[$krateTool] = $krateVendorBin . '/' . $krateTool;
		}
	}
}

// Caddy php_fastcgi may inject these when basic-auth user is mapped per vhost.
if (!empty($_SERVER['RU_PROFILE_PATH'])) {
	$profilePath = $_SERVER['RU_PROFILE_PATH'];
} elseif (!empty($_ENV['RU_PROFILE_PATH'])) {
	$profilePath = $_ENV['RU_PROFILE_PATH'];
}
