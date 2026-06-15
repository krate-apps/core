route {
    @downloads {
        path /{{USERNAME}}.rtorrent.downloads*
    }
    root @downloads {{DOWNLOADS_DIR}}
    file_server @downloads browse
    basic_auth /{{USERNAME}}.rtorrent.downloads* {
        {{USERNAME}} {{HASHED_PASSWORD}}
    }
    @phpDownloads {
        path /{{USERNAME}}.rtorrent.downloads/*.php
    }
    php_fastcgi @phpDownloads unix//{{PHP_FPM_SOCKET}}
}
