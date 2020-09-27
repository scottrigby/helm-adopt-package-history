#!/bin/bash

set -eu
if [ "${DEBUG:-}" = 1 ]; then
    export PS4='+ ($LINENO) '
    set -x
fi

usage() {
    cat <<EOF
This comand helps a distributed chart repo adopt another repo's pacakge history

The goal is to make it easy for distributed Chart repo maintainers who have
already adopted helm charts to also store chart version pacakges prior to
adoption.

Scope: because distributed chart repo index and packages may be hosted
in various ways (object storage, GitHub pages, or any other HTTP server), this
command only helps find and download the package history of charts you have
already adopted, and updates your local repo directory for manual review. It
does not perform any commits or attempt to upload to your chart repository.

Context for stable/incubator: If adopting from stable or incubator repos, as of
13 November 2020, these will be deprecated and the Google sponsored GCP storage
buckets will be garbage collected. Due to global download usage, the cost of
these buckets is too high to move package history all together to new single
storage location. Instead, the Helm team is promoting the strategy for adopting
distributed chart repos to also host package history for the their adopted
charts, spreading the load in a more maintainable way. For updates on stable
chart adoption progress, see https://github.com/helm/charts/issues/21103.

Requires:
    helm >= 3.3.4
    yq

Usage:
    helm-adopt-package-history [flags]

Flags:
    -o, --old-repo
        Old chart repo (example: stable=https://kubernetes-charts.storage.googleapis.com)
    -n, --new-repo
        New chart repo (example: foo=http://charts.foo.bar)
    -l, --local-dir
        Local directory containing chart repo index file and packages
    -i, --include-charts
        Optional. Comma-separated list of charts to include (default: all charts listed in new repo index)
    -e, --exclude-charts
        Optional. Comma-separated list of charts to exclude (defult: none)
    -s, --skip-repo-commands
        Optional. Skips 'helm repo add' and 'helm repo update' commands
    -f, --force-update
        Optional. Passes '--force-update' option to 'helm repo add'
    -h, --help
        help message
EOF
}

requirements() {
    for c in helm yq; do
        if ! command -v helm &> /dev/null; then
            echo "$c could not be found"
            exit 1
        fi
    done
}

# 📢 Looking for volunteers to help fix this script for Windows
#
# Ref: https://github.com/helm/helm/blob/master/cmd/helm/root.go#L44
helm_cache_home() {
    if [ -z "${HELM_CACHE_HOME:-}" ]; then
        case $(uname | tr '[:upper:]' '[:lower:]') in
            linux*)     export HELM_CACHE_HOME=$HOME/.cache/helm;;
            darwin*)    export HELM_CACHE_HOME=$HOME/Library/Caches/helm;;
            # I'm 99% sure this won't work as-is on Windows. Looking for help with this
            msys*)      export HELM_CACHE_HOME='%TEMP%\helm';;
            # Ref: https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
            *)  export HELM_CACHE_HOME=${XDG_CACHE_HOME:$HOME/.cache/helm};;
        esac
    fi
}

# Ensures current metadata for old and new repos are cached locally
repo_add_update() {
    if [ -z "${skip_repo_commands:-}" ]; then
        [ "${force_update:-}" == "true" ] && local force_option='--force-update'
        helm repo add $old_repo_name $old_repo_url ${force_option:-}
        helm repo add $new_repo_name $new_repo_url ${force_option:-}
        helm repo update
    fi
}

check_cache_files() {
    local files="$old_repo_name-index.yaml $old_repo_name-charts.txt $new_repo_name-index.yaml $new_repo_name-charts.txt"
    for file in $files
    do
        local path="$HELM_CACHE_HOME/repository/$file"
        [ -f "$path" ] || (echo "Something went wrong. $path does not exist" && exit 1)
    done
}

extract_repo_option_values() {
    old_repo_name=$(echo $old_repo | cut -d'=' -f1)
    old_repo_url=$(echo $old_repo | cut -d'=' -f2)
    new_repo_name=$(echo $new_repo | cut -d'=' -f1)
    new_repo_url=$(echo $new_repo | cut -d'=' -f2)
    # Also validate values format
    # To-do: this could be done better, but for now catches easy incorrect value
    # mistakes
    if [ -z "${old_repo_name:-}" ] || [ -z "${old_repo_url:-}" ] || [ -z "${new_repo_name:-}" ] || [ -z "${new_repo_url:-}" ]; then
        echo 'Repo values must be in the format of NAME=URL. See --help for examples' >&2
        kill -10 $PROC
    fi
}

temp_dir() {
    export temp_dir=$(mktemp -d)
}

get_download_list() {
    if [ -n "${include_charts:-}" ]; then
        # Allow the specified include list
        download_list=$(echo $include_charts | tr , '\n')
    else
        # Default to all charts listed in new repo cache
        download_list=$(cat $HELM_CACHE_HOME/repository/$new_repo_name-charts.txt)
    fi

    # Remove any specified exclusions
    if [ -n "${exclude_charts:-}" ]; then
        for e in $exclude_charts; do
            download_list=$(echo "${download_list:-}" | sed "/^$e\$/d")
        done
    fi

    if [ -z "${download_list:-}" ]; then
        echo 'Something went wrong. No charts are configured for download'
        echo "Run 'helm-adopt-package-history --help' for usage" >&2
        kill -10 $PROC
    fi

    # Verify each chart in the list exists in the old repo cache
    #
    # Error if anything is not right. Users can always exclude or include
    # lists for edge cases. The most common use case is all or most of the new
    # charts repo list are the same names as the old repo. If users followed
    # best practices adopting charts, they would have deprecated a chart before
    # any renaming.
    for check in $download_list; do
        if ! grep -Fxq $check $HELM_CACHE_HOME/repository/$old_repo_name-charts.txt; then
            echo "Something went wrong. $check does not exist in $old_repo_name local cache" >&2
            kill -10 $PROC
        fi
    done
}

get_old_repo_chart_urls() {
    local chart=$1
    # Use sed to strip out annoying yq hyphens. If converted to Go we won't need yq or this
    yq r $HELM_CACHE_HOME/repository/$old_repo_name-index.yaml entries.$chart.*.urls | sed 's/^- //'
}

download_package_history() {
    get_download_list

    echo "Attempting package history download from $old_repo_name, for charts:"
    echo "$download_list" | nl
    echo "To temp directory: $temp_dir"

    # For charts progress
    local cn=$(echo "$download_list" | wc -l | tr -d ' ')
    local ci=0

    for chart in $download_list
    do
        # Increment chart index
        ci=$(($ci+1))
        local cm="⏳ downloading packages for $old_repo_name/$chart ($ci of $cn)"
        # For per-chart package progress
        local urls=$(get_old_repo_chart_urls $chart)
        local pn=$(echo "$urls" | wc -l | tr -d ' ')
        local pi=0

        # Empty newline for progress to overwrite
        echo
        for url in $urls
        do
            # Increment versions total
            local pi=$(($pi+1))
            local f=$(basename $url)
            local v=$(basename $f .tgz | cut -d'-' -f2)
            tput cuu 1 && tput el
            echo "$cm. package $v ($pi of $pn)"
            curl -SsLo $temp_dir/$f $url
        done
        tput cuu 1 && tput el
        echo "✅ downloaded $pi packages for $old_repo_name/$chart"
    done
}

# See https://github.com/helm/charts/blob/master/test/repo-sync.sh#L57
update_index() {
    echo "⏳ updating local index"
    if helm repo index --url "$new_repo_url" --merge $local_dir/index.yaml "$temp_dir"; then
        mv -f "$temp_dir/index.yaml" $local_dir/index.yaml
        tput cuu 1 && tput el
        echo "✅ updated local index"
    else
        tput cuu 1 && tput el
        echo "❌ unable to update local index" >&2
        kill -10 $PROC
    fi
}

move_packages() {
    echo "⏳ moving package history to local dir"
    mv $temp_dir/*.tgz $local_dir
    tput cuu 1 && tput el
    echo "✅ moved package history to local dir"
}

manual_review_message() {
    echo "Reminder to manually review your local repo directory before pushing to your repo"
    echo "See 'helm-adopt-package-history --help' for goal, scope and context"
    echo "Thanks for contributing 🙂"
}

# Quick getops with long options.
# To-do: convert to Go if this helper tool proves useful but buggy
die() { echo "$*" >&2; exit 2; }  # complain to STDERR and exit with error
needs_arg() { if [ -z "$OPTARG" ]; then die "No arg for --$OPT option"; fi; }
while getopts hfso:n:l:i:e:-: OPT; do
  # support long options: https://stackoverflow.com/a/28466267/519360
  if [ "$OPT" = "-" ]; then   # long option: reformulate OPT and OPTARG
    OPT="${OPTARG%%=*}"       # extract long option name
    OPTARG="${OPTARG#$OPT}"   # extract long option argument (may be empty)
    OPTARG="${OPTARG#=}"      # if long option argument, remove assigning `=`
  fi
  case "$OPT" in
    o | old-repo )              needs_arg; old_repo="$OPTARG" ;;
    n | new-repo )              needs_arg; new_repo="$OPTARG" ;;
    l | local-dir )             needs_arg; local_dir="$OPTARG" ;;
    i | include-charts )        needs_arg; include_charts="$OPTARG" ;;
    e | exclude-charts )        needs_arg; exclude_charts="$OPTARG" ;;
    h | help )                  usage && exit 0 ;;
    s | skip-repo-commands )    skip_repo_commands=true ;;
    f | force-update )          force_update=true ;;
    ??* )          die "Illegal option --$OPT" ;;  # bad long option
    \? )           exit 2 ;;  # bad short option (error reported via getopts)
  esac
done
shift $((OPTIND-1)) # remove parsed options and args from $@ list

# Validate required options
if [ -z "${old_repo:-}" ] || [ -z "${new_repo:-}" ] || [ -z "${local_dir:-}" ]; then
    [ -z "${old_repo:-}" ] && echo 'Required: [-o, --old-repo]'
    [ -z "${new_repo:-}" ] && echo 'Required: [-n, --new-repo]'
    [ -z "${local_dir:-}" ] && echo 'Required: [-l, --local-dir]'
    echo "Run 'helm-adopt-package-history --help' for usage"
    exit 1
elif [ ! -f "$local_dir/index.yaml" ]; then
    echo '[-l, --local-dir] must include a helm repo index.yaml file'
    echo "See The Chart Repsitory Guide: https://helm.sh/docs/topics/chart_repository for more info"
    exit 1
fi

trap "exit 1" 10
PROC="$$"

requirements
helm_cache_home
extract_repo_option_values
repo_add_update
check_cache_files
temp_dir
download_package_history
update_index
move_packages
manual_review_message
