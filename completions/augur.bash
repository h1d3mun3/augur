# bash completion for augur. Installed to ~/.augur/completions/augur.bash and sourced from
# ~/.bashrc by `bash install`.

_augur() {
    local cur prev cmd names macos=""
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    cmd="${COMP_WORDS[1]:-}"
    COMPREPLY=()

    # The subcommand is always the first word; options and arguments follow it.
    if (( COMP_CWORD == 1 )); then
        COMPREPLY=( $(compgen -W "up claude shell setup-token install-cert down destroy status init-conf list update version build help" -- "$cur") )
        return 0
    fi

    case "$prev" in
        --swift|--platforms) return 0 ;;                      # free-form values
        --ipsw|--xcode-xip) COMPREPLY=( $(compgen -f -- "$cur") ); return 0 ;;
    esac

    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "--macos --gui --egress --no-egress --swift --ipsw --xcode-xip --platforms" -- "$cur") )
        return 0
    fi

    case "$cmd" in
        install-cert) COMPREPLY=( $(compgen -f -- "$cur") ) ;;
        destroy)
            [[ " ${COMP_WORDS[*]} " == *" --macos "* ]] && macos="--macos"
            # `augur __names` is the hidden, quiet, read-only list of this mode's container/VM names.
            names="$("${COMP_WORDS[0]}" __names $macos 2>/dev/null)"
            COMPREPLY=( $(compgen -W "$names" -- "$cur") )
            ;;
    esac
    return 0
}

complete -o default -F _augur augur
