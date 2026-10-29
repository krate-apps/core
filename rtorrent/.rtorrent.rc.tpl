#
# rTorrent configuration (KRATE template — 0.16.23 canonical syntax)
# Canonical paths (do not change without updating manifest + ruTorrent/Flood):
#   Config:  /home/{{USERNAME}}/.config/rtorrent/.rtorrent.rc
#   SCGI:    /run/krate/user/{{USERNAME}}.rtorrent.sock
# ───────────────────────────────────────
#

# =============================================================================
# 1. Instance directory layout (paths derived from cfg.*)
# =============================================================================
method.insert = cfg.basedir,  private|const|string, (cat,"{{DATA_DIR}}")
method.insert = cfg.homedir,  private|const|string, (cat,"/home/{{USERNAME}}/")
method.insert = cfg.download, private|const|string, (cat,"{{DOWNLOADS_DIR}}")
method.insert = cfg.logs,     private|const|string, (cat,"{{LOGS_DIR}}")
method.insert = cfg.logfile,  private|const|string, (cat,(cfg.logs),"/rtorrent.log")
method.insert = cfg.session,  private|const|string, (cat,"{{SESSION_DIR}}")
method.insert = cfg.config,   private|const|string, (cat,(cfg.homedir),".config/")
method.insert = cfg.watch,    private|const|string, (cat,"{{WATCH_DIR}}")
method.insert = cfg.socket,   private|const|string, (cat,"/run/krate/user/{{USERNAME}}.rtorrent.sock")

# =============================================================================
# 2. Session, working directory
# =============================================================================
session.path.set = (cat, (cfg.session))
session.use_lock.set = yes
directory.default.set = (cat, (cfg.download))
system.cwd.set = (directory.default)
system.umask.set = 0007
system.daemon.set = false

# =============================================================================
# 3. File logging (before SCGI so startup failures are captured)
# =============================================================================
# Keep info/warn/error only. debug + connection flood the disk and stall the
# single-threaded event loop (SCGI / ruTorrent timeouts under load).
log.execute = (cat, (cfg.logs), "/execute.log")
print = (cat, "Logging to ", (cfg.logfile))
log.open_file = "log", (cfg.logfile)
log.add_output = "info", "log"
log.add_output = "warn", "log"
log.add_output = "error", "log"
log.add_output = "critical", "log"

# =============================================================================
# 4. BitTorrent networking — ports, DHT/PEX, encryption
# =============================================================================
network.listen.port.range.set = {{PORT_RANGE}}
network.listen.port.random.set = yes
network.tos.set = throughput

dht.mode.set = disable
protocol.pex.set = no

protocol.encryption.set = allow_incoming,prefer_plaintext,enable_retry

# =============================================================================
# 5. Socket / file / buffer limits (socket categories; match LimitNOFILE=16384)
# =============================================================================
# Default max_open is 1024. Do not call adjust_alloc: it keeps a large "generic"
# pool (often ~75% of max_size), so files.min_alloc=4096 can never fit.
system.sockets.max_size.set = 16384
system.sockets.http.min_alloc.set = 250
system.sockets.files.min_alloc.set = 2048

network.send_buffer.size.set = 16M
network.receive_buffer.size.set = 4M

network.http.dns_cache_timeout.set = 25
network.http.capath.set = "/etc/ssl/certs"
network.http.ssl_verify_peer.set = 1
network.http.ssl_verify_host.set = 1

# =============================================================================
# 6. Throttles, peers, disk sync safety
# =============================================================================
throttle.global_down.max_rate.set = 0
throttle.global_up.max_rate.set = 0

throttle.max_uploads.set = 100
throttle.max_uploads.global.set = 250
throttle.min_peers.normal.set = 1
throttle.max_peers.normal.set = 100
throttle.min_peers.seed.set = -1
throttle.max_peers.seed.set = -1
trackers.numwant.set = 30

pieces.sync.always_safe.set = no

# =============================================================================
# 7. Memory and XML-RPC request size limit
# =============================================================================
# preload 0 = off (default for end users). Type 2 (touched) reads piece data into
# RAM and blocks the event loop — SCGI stops answering (ruTorrent / panel timeouts).
# Type 1 (madvise) is an optional middle ground on fast local disks.
pieces.memory.max.set = 512M
pieces.preload.type.set = 0
network.xmlrpc.size_limit.set = 16M

# =============================================================================
# 8. Helper methods (torrent and session paths)
# =============================================================================
method.insert = system.startup_time, value|const, (system.time)
method.insert = d.data_path, simple,\
    "if=(d.is_multi_file),\
        (cat, (d.directory), /),\
        (cat, (d.directory), /, (d.name))"
method.insert = d.session_file, simple, "cat=(session.path), (d.hash), .torrent"

# =============================================================================
# 9. Schedules — free disk space, watch folders
# =============================================================================
schedule = monitor_diskspace, 15, 60, ((close_low_diskspace, 1000M))

# Auto-add from watch/load/*.torrent
schedule = watch_load, 11, 10, ((load.verbose, (cat, (cfg.watch), "/load/*.torrent")))
# Auto-add and start from watch/start/*.torrent
schedule = watch_start, 10, 10, ((load.start_verbose, (cat, (cfg.watch), "/start/*.torrent")))

# =============================================================================
# 10. SCGI — /run/krate/user/<user>.rtorrent.sock (setgid dir + systemd Group=krate, see krate-run.conf)
# =============================================================================
network.scgi.open_local = (cat, (cfg.socket))

# =============================================================================
# 11. ruTorrent plugin init (run by rutorrent handler on install/update)
# =============================================================================
#schedule = init_plugins, 10, 0, "execute={sh,-c,/usr/bin/php /srv/rutorrent/app/php/initplugins.php {{USERNAME}} &}"

# =============================================================================
# 12. Commented options (reference)
# =============================================================================
#config.path.set = (cat, (cfg.config))
#pieces.hash.on_completion.set = no
#view.sort_current = seeding, greater=d.ratio=
#keys.layout.set = qwerty
