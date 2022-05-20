#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

usage() {
  cat <<EOF # remove the space between << and EOF, this is due to web plugin issue
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-i] [--dbengine mysql] [--dbport 3306] [-p project_name] [--vncport 5900] --code_path /path/to/moodle/code webport

Start a suite of Docker containers to support local development. Requires docker installed and running.

Arguments:

webport         Host port number to bind to the web server.
                For accessing the web server via a browser on the host (e.g. https://localhost:8000)
                Required, commonly used value of 8000

Available options:

-h, --help      Print this help and exit
-v, --verbose   Print script debug info
-i, --install   Run the CLI install script
--code_path     Path to the directory with the Moodle PHP code.
                Required, typical value of '/var/work/moodle'
--dbengine      Which DB engine to spin up.
                Optional, default value of 'mysql'
                Currently supported:
                    pgsql
                    mariadb
                    mssql
                    mysql
                    oracle
--dbport        Port number on the host bind to the database.
                Useful for connecting database tools on the host to the database container.
                NOTE: No port is mapped by default.
                Optional, typical value of '3306'
-p, --project   Docker container prefix, useful when spinning up multiple sets of containers.
                Optional, default value of 'docker_moodle'
--vncport       Port number on the host bind to for VNC.
                Useful for viewing Behat tests from the host as the test run in the selenium container.
                NOTE: No port is mapped by default.
                Optional, typical value of '5900'
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

parse_params() {
  # default values of variables set from params
  install=0
  code_path=''
  dbengine='mysql'
  dbport=''
  vncport=''
  project='docker-moodle'
  docker_path='/var/work/docker-moodle/'

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -i | --install) install=1 ;;
    --code_path) # long parameter only
      code_path="${2-}"
      shift
      ;;
    --dbengine) # long parameter only
      dbengine="${2-}"
      shift
      ;;
    --dbport) # long parameter only
      dbport="${2-}"
      shift
      ;;
    -p | --project)
      project="${2-}"
      shift
      ;;
    --vncport) # long parameter only
      vncport="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [[ -z "${code_path-}" ]] && die "Missing required parameter: code_path"
  # webport argument required for this script
  [[ ${#args[@]} -eq 0 ]] && die "Missing script arguments"

  return 0
}

validate_options() {
  # parse and validate required arguments
  # - arg1 (webport)
  #   - a number
  #   - greater than 1000
  webport=8000

  # validate optional arguments (already parsed)
  # - dbengine
  #   - one of: pgsql, mariadb, mssql, mysql, oracle
  # - dbport
  #   - a number
  #   - greater than 1000
  dbport=13306
  # - project
  #   - non-empty
  #   - no internal whitespace
}

# XDebug 3 options
# We store the config data here and inject it with a function call
# as per this Stack Overflow answer: https://stackoverflow.com/a/35049057/6510524
xdebug_config() {
  cat <<'EOF'
; Settings for Xdebug Docker configuration
xdebug.mode=debug
xdebug.start_with_request=yes
xdebug.client_port=9003
; xdebug.remote_handler=dbgp
xdebug.idekey=VSCODE
xdebug.discover_client_host=false
xdebug.client_host=host.docker.internal
xdebug.log=/var/log/xdebug.log
EOF
}


parse_params "$@"
validate_options
setup_colors

# Check for running Docker daemon
docker ps > /dev/null
if [ 0 -ne "$?" ]
then
  die "Docker does not appear to be running; aborting startup"
fi

CODE_DIR=/var/work/moodle
DOCKER_DIR=/var/work/docker-moodle/

export COMPOSE_PROJECT_NAME="$project"
export MOODLE_DOCKER_WEB_PORT="$webport"
export MOODLE_DOCKER_SELENIUM_VNC_PORT="$vncport"
export MOODLE_DOCKER_WWWROOT="$CODE_DIR"
export MOODLE_DOCKER_DB=mysql
export MOODLE_DOCKER_DB_PORT="$dbport"

cd "$DOCKER_DIR"
cp config.docker-template.php "$MOODLE_DOCKER_WWWROOT"/config.php
msg "Starting containers..."
bin/moodle-docker-compose up -d

msg "Waiting for database to start..."
bin/moodle-docker-wait-for-db

# Check for installed PHP modules
xdebug=$(bin/moodle-docker-compose exec webserver bash -c 'php -m' | grep xdebug||true)
# The double brackets and '*' are needed as grep may return a '\r' after the needle
#   so we use regex matching instead of literal matching
if [[ "$xdebug" =~ "xdebug".* ]]
then
  msg "XDebug already installed; skipping..."
else
  msg "Installing XDebug from PECL..."
  # If pecl fails to install xdebug that's OK
  bin/moodle-docker-compose exec webserver pecl install xdebug ||true

  msg "Generating and injecting XDebug config..."
  # Yes, we are blindly overwriting any existent XDebug config
  bin/moodle-docker-compose exec webserver bash -c "echo '$(xdebug_config)' > /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini"
fi

# Even if the XDebug extension was installed, it might not have been enabled
msg "Enabling XDebug and restarting webserver..."
# If XDebug is already loaded, the following call will emit a warning (that we will suppress)
bin/moodle-docker-compose exec webserver docker-php-ext-enable xdebug > /dev/null
bin/moodle-docker-compose restart webserver


if [ "1" -eq "$install" ]
then
  #   The CLI script appears to detect existing installation, so always running this is not the worst thing ever
  # Initialize Moodle database for manual testing
  msg "Running init scripts..."
  bin/moodle-docker-compose exec webserver php admin/cli/install_database.php \
    --agree-license \
    --fullname="Docker moodle" \
    --shortname="docker_moodle" \
    --summary="Docker moodle site" \
    --adminpass="test" \
    --adminemail="admin@example.com" \
    ||true
fi

msg "${GREEN}Local environment started${NOFORMAT}. Changes made in ${BLUE}${MOODLE_DOCKER_WWWROOT}${NOFORMAT} will be reflected live at ${BLUE}http://localhost:${webport}${NOFORMAT}"

msg "${RED}Parsed/used parameter values:${NOFORMAT}"
msg "- install: ${install}"
msg "- code_path: ${code_path}"
msg "- dbengine: ${dbengine}"
msg "- dbport: ${dbport}"
msg "- project: ${project}"
msg "- vncport: ${vncport}"
msg "- arguments: ${args[*]-}"
