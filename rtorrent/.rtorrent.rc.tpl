#
# rTorrent configuration (KRATE template)
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
# 2. Session, working directory, encoding
# =============================================================================
session.path.set = (cat, (cfg.session))
session.use_lock.set = yes
directory.default.set = (cat, (cfg.download))
system.cwd.set = (directory.default)
system.umask.set = 0007
system.daemon.set = false
encoding.add = utf8

# =============================================================================
# 3. File logging for executed commands
# =============================================================================
log.execute = (cat, (cfg.logs), "execute.log")

# =============================================================================
# 4. BitTorrent networking — ports, DHT/PEX, encryption
# =============================================================================
network.port_range.set = {{PORT_RANGE}}
network.port_random.set = yes
network.tos.set = throughput

dht.mode.set = disable
protocol.pex.set = no
trackers.use_udp.set = yes

protocol.encryption.set = allow_incoming,prefer_plaintext,enable_retry

# =============================================================================
# 5. Socket / file / buffer limits (tune to ulimit and workload)
# =============================================================================
network.http.max_open.set = 250
network.max_open_files.set = 8192
network.max_open_sockets.set = 2048
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
pieces.memory.max.set = 512M
pieces.preload.type.set = 2
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
schedule2 = monitor_diskspace, 15, 60, ((close_low_diskspace, 1000M))

# Auto-add from watch/load/*.torrent
schedule2 = watch_load, 11, 10, ((load.verbose, (cat, (cfg.watch), "/load/*.torrent")))
# Auto-add and start from watch/start/*.torrent
schedule2 = watch_start, 10, 10, ((load.start_verbose, (cat, (cfg.watch), "/start/*.torrent")))

# =============================================================================
# 10. SCGI — /run/krate/user/<user>.rtorrent.sock (setgid dir + systemd Group=krate, see krate-run.conf)
# =============================================================================
network.scgi.open_local = (cat, (cfg.socket))

# =============================================================================
# 11. rTorrent logging to file (verbose — debug SCGI / crash issues)
# =============================================================================
print = (cat, "Logging to ", (cfg.logfile))
log.open_file = "log", (cfg.logfile)
log.add_output = "info", "log"
log.add_output = "debug", "log"
log.add_output = "warn", "log"
log.add_output = "error", "log"
log.add_output = "critical", "log"
log.add_output = "connection", "log"

# =============================================================================
# 12. ruTorrent plugin init (run by rutorrent handler on install/update)
# =============================================================================
#schedule2 = init_plugins, 10, 0, "execute2={sh,-c,/usr/bin/php /srv/rutorrent/app/php/initplugins.php {{USERNAME}} &}"

# =============================================================================
# 13. Commented options (reference)
# =============================================================================
#config.path.set = (cat, (cfg.config))
#pieces.hash.on_completion.set = no
#view.sort_current = seeding, greater=d.ratio=
#keys.layout.set = qwerty
