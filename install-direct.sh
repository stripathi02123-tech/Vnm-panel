
    "${CLOUDFLARED_BIN}" version
    ok 'cloudflared installed.'
}

configure_cloudflare(){
    [[ "${DOMAIN_MODE}" == 'cloudflare' ]] || return 0

    [[ -x "${CLOUDFLARED_BIN}" ]] ||
        die 'cloudflared binary is missing.'

    # Store the secret separately instead of putting the token directly
    # in the service command line.
    printf '%s\n' "${CLOUDFLARE_TOKEN}" > "${CLOUDFLARED_TOKEN_FILE}"
    chmod 600 "${CLOUDFLARED_TOKEN_FILE}"

    if [[ "${HAS_SYSTEMD}" == 'true' ]]; then
        info 'Creating VNM Cloudflare Tunnel systemd service...'

        cat > "${CLOUDFLARED_SERVICE}" <<EOF
[Unit]
Description=VNM/HKVM Cloudflare Tunnel
After=network-online.target hkvm.service
Wants=network-online.target
Requires=hkvm.service

[Service]
Type=simple
ExecStart=${CLOUDFLARED_BIN} tunnel --loglevel info --logfile ${CLOUDFLARED_LOG_DIR}/vnm-cloudflared.log run --token-file ${CLOUDFLARED_TOKEN_FILE}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=${CLOUDFLARED_TOKEN_FILE}
ReadWritePaths=${CLOUDFLARED_LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF

        chmod 600 "${CLOUDFLARED_SERVICE}"
        systemd-analyze verify "${CLOUDFLARED_SERVICE}" ||
            die 'Cloudflare systemd service validation failed.'

        systemctl daemon-reload
        systemctl enable vnm-cloudflared.service >/dev/null
        systemctl restart vnm-cloudflared.service

        local active='false'
        for _ in {1..20}; do
            if systemctl is-active --quiet vnm-cloudflared.service; then
                active='true'
                break
            fi
            sleep 1
        done

        [[ "${active}" == 'true' ]] ||
            die 'Cloudflare Tunnel service did not remain running.'

        ok 'Cloudflare Tunnel service is running.'
    else
        warn 'systemd is unavailable; starting cloudflared in background mode.'

        pkill -f "${CLOUDFLARED_BIN}" >/dev/null 2>&1 || true

        nohup "${CLOUDFLARED_BIN}" \
            tunnel \
            --loglevel info \
            --logfile "${CLOUDFLARED_LOG_DIR}/vnm-cloudflared.log" \
            run \
            --token-file "${CLOUDFLARED_TOKEN_FILE}" \
            >/dev/null 2>&1 &

        echo "$!" > "${CLOUDFLARED_PID_FILE}"
        chmod 600 "${CLOUDFLARED_PID_FILE}"

        sleep 3

        if kill -0 "$(cat "${CLOUDFLARED_PID_FILE}")" >/dev/null 2>&1; then
            ok 'Cloudflare Tunnel started in background mode.'
        else
            die 'Cloudflare Tunnel failed to start.'
        fi
    fi

    CLOUDFLARE_TOKEN=''
}

verify_cloudflare(){
    [[ "${DOMAIN_MODE}" == 'cloudflare' ]] || return 0

    info "Checking configured domain: ${DOMAIN}"

    local code='000'
    code="$(curl -ksS \
        -o /dev/null \
        -w '%{http_code}' \
        --max-time 15 \
        "https://${DOMAIN}/" 2>/dev/null || true)"

    case "${code}" in
        2*|3*)
            ok "Cloudflare domain responded (HTTP ${code})."
            ;;
        4*|5*)
            warn "Domain responded with HTTP ${code}. The tunnel is installed, but the Cloudflare hostname/origin may still need checking."
            ;;
        *)
            warn "Could not verify ${DOMAIN} from this server yet."
            warn "Check Cloudflare Tunnel status and make sure the hostname routes to http://127.0.0.1:${PORT}."
            ;;
    esac
}

build_panel_url(){
    if [[ "${DOMAIN_MODE}" == 'cloudflare' ]]; then
        PANEL_URL="https://${DOMAIN}"
        return
    fi

    if [[ -n "${CODESPACE_NAME:-}" &&
          -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
        PANEL_URL="https://${CODESPACE_NAME}-${PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
    else
        SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
        PANEL_URL="http://${SERVER_IP:-YOUR_SERVER_IP}:${PORT}"
    fi
}

final_screen(){
    build_panel_url

    printf '\n%b\n' "${GREEN}"
    cat <<EOF
╔════════════════════════════════════════════════════════════╗
║                 VNM/HKVM INSTALL COMPLETE                 ║
╚════════════════════════════════════════════════════════════╝

  ACCESS MODE : ${DOMAIN_MODE^^}

  PANEL URL   : ${PANEL_URL}

  LOCAL ORIGIN:
    http://127.0.0.1:${PORT}

  ADMIN:
    Username  : admin
    Password  : ${ADMIN_PASSWORD}
    File      : /opt/hkvm/admin-credentials.txt

  VERIFY:
    ✓ Panel is listening on ${PORT}
    ✓ Fresh admin password written
    ✓ bcrypt password verification passed
    ✓ Old admin sessions invalidated
EOF

    if [[ "${DOMAIN_MODE}" == 'cloudflare' ]]; then
        cat <<EOF

  CLOUDFLARE:
    Domain    : ${DOMAIN}
    Status    : CONFIGURED
    Service   : vnm-cloudflared.service
    Log       : ${CLOUDFLARED_LOG_DIR}/vnm-cloudflared.log
    Token     : stored in ${CLOUDFLARED_TOKEN_FILE}

    IMPORTANT:
      Cloudflare Tunnel hostname must route to:
        http://127.0.0.1:${PORT}
EOF
    else
        cat <<EOF

  DIRECT MODE:
    No Cloudflare domain configured.
    Use:
      ${PANEL_URL}
EOF
    fi

    cat <<EOF

  SERVICES:
    Panel:
      systemctl status hkvm

    Cloudflare:
      systemctl status vnm-cloudflared

  Logs:
    Panel:
      tail -f /opt/hkvm/logs/hkvm.log
EOF

    if [[ "${DOMAIN_MODE}" == 'cloudflare' ]]; then
        cat <<EOF
    Cloudflare:
      tail -f ${CLOUDFLARED_LOG_DIR}/vnm-cloudflared.log
EOF
    fi

    cat <<'EOF'

╚════════════════════════════════════════════════════════════╝
EOF
    printf '%b\n' "${NC}"

    ok 'Installation and configuration completed.'
}

main(){
    detect_systemd
    prompt_domain_mode
    download_core
    install_core "$@"
    verify_core
    locate_database
    refresh_admin_credentials

    if [[ "${DOMAIN_MODE}" == 'cloudflare' ]]; then
        install_cloudflared
        configure_cloudflare
        verify_cloudflare
    fi

    final_screen
}

main "$@"
