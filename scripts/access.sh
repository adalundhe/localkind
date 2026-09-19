#!/usr/bin/env bash
# Shows how to reach the Concourse and Argo CD UIs: URLs, usernames and (generated) passwords.
#
#   scripts/access.sh                  print URLs + credentials
#   scripts/access.sh --no-passwords   print URLs + usernames only (safe to paste / screen-share)
#   scripts/access.sh --copy concourse copy that UI's password to the clipboard, print nothing secret
#   scripts/access.sh --copy argocd
#   scripts/access.sh --open           also open both UIs in the browser
#
# Passwords are generated at install time and live only in Kubernetes Secrets:
#   concourse/concourse-admin              (username, password)
#   argocd/argocd-initial-admin-secret     (password; username is "admin")
. "$(dirname "$0")/lib.sh"
need kubectl

show_passwords=1; copy=""; open_ui=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-passwords) show_passwords=0 ;;
    --copy) copy="${2:-}"; shift ;;
    --open) open_ui=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

concourse_pw() { secret_value "$CONCOURSE_NAMESPACE" concourse-admin password; }
argocd_pw()    { secret_value "$ARGOCD_NAMESPACE" argocd-initial-admin-secret password; }

if [ -n "$copy" ]; then
  need pbcopy
  case "$copy" in
    concourse) concourse_pw | pbcopy; ok "Concourse password for '$CONCOURSE_ADMIN_USER' copied to the clipboard" ;;
    argocd)    argocd_pw    | pbcopy; ok "Argo CD password for 'admin' copied to the clipboard" ;;
    *) die "--copy expects 'concourse' or 'argocd'" ;;
  esac
  exit 0
fi

status() { # <url> -> "up" | "DOWN"
  if curl -fsS -m 4 -o /dev/null "$1" 2>/dev/null; then printf 'up'; else printf 'DOWN'; fi
}

field() { printf '  %-10s %s\n' "$1" "$2"; }
pw() { if [ "$show_passwords" = 1 ]; then "$1" 2>/dev/null || printf '<secret not found>'; else printf '<hidden: re-run without --no-passwords, or use --copy>'; fi; }

printf '\n\033[1mConcourse CI\033[0m  (%s)\n' "$(status "$CONCOURSE_URL/api/v1/info")"
field URL      "$CONCOURSE_URL"
field username "$CONCOURSE_ADMIN_USER"
field password "$(pw concourse_pw)"
field CLI      "$FLY_BIN -t $FLY_TARGET pipelines"

printf '\n\033[1mArgo CD\033[0m  (%s)\n' "$(status "$ARGOCD_URL/healthz")"
field URL      "$ARGOCD_URL"
field username "admin"
field password "$(pw argocd_pw)"

cat <<EOF

Notes
  - Use the URLs exactly as shown. Concourse's login flow redirects to its configured external
    URL, so mixing "localhost" and "127.0.0.1" breaks the login cookie.
  - Docker Desktop publishes these ports on IPv4 loopback only. If a browser hangs on
    "localhost", it is trying IPv6 (::1) first; curl -4 $CONCOURSE_URL/api/v1/info proves the
    service itself is fine.
  - Nothing is published beyond this machine.

EOF

if [ "$open_ui" = 1 ]; then
  need open
  open "$CONCOURSE_URL"; open "$ARGOCD_URL"
fi
