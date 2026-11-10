# bash completion for augur and augur-vm. Installed to ~/.augur/completions/augur.bash and sourced from
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
        COMPREPLY=( $(compgen -W "--macos --gui --egress --no-egress --swift --ipsw --xcode-xip --platforms --manual-setup" -- "$cur") )
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

# augur-vm: the macOS VM backend binary installed next to augur.
_augur_vm() {
    local cur prev cmd opts="" names w i nargs=0
    # Options that take a value as the next word.
    local valopts="--from-ipsw --disk-size --cpu --memory --dir --net-vfkit --provision-username --provision-full-name"
    local cmds="version list smoke create set run ip provisioning-support stop delete clone help"
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    cmd="${COMP_WORDS[1]:-}"
    COMPREPLY=()
    # bash splits `--opt=value` into `--opt`, `=`, `value`; look past the `=` to the option.
    [[ "$prev" == "=" ]] && (( COMP_CWORD >= 2 )) && prev="${COMP_WORDS[COMP_CWORD-2]}"

    if (( COMP_CWORD == 1 )); then
        if [[ "$cur" == -* ]]; then
            COMPREPLY=( $(compgen -W "--help --version" -- "$cur") )
        else
            COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
        fi
        return 0
    fi

    case "$prev" in
        --from-ipsw|--net-vfkit)
            # Paths: have readline add a trailing slash to directories and quote special characters.
            compopt -o filenames 2>/dev/null
            COMPREPLY=( $(compgen -f -- "$cur") ); return 0 ;;
        --disk-size|--cpu|--memory|--dir|--provision-username|--provision-full-name) return 0 ;;  # free-form values
    esac

    case "$cmd" in
        create) opts="--from-ipsw --disk-size" ;;
        set)    opts="--cpu --memory" ;;
        run)    opts="--no-graphics --dir --net-vfkit --net-nat --provision-username --provision-password-stdin --provision-full-name" ;;
    esac
    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "$opts --help" -- "$cur") )
        return 0
    fi

    # Count the positional arguments before the cursor, skipping options and their values.
    for (( i = 2; i < COMP_CWORD; i++ )); do
        w="${COMP_WORDS[i]}"
        if [[ " $valopts " == *" $w "* ]]; then
            i=$(( i + 1 ))
            [[ "${COMP_WORDS[i]:-}" == "=" ]] && i=$(( i + 1 ))
        elif [[ "$w" != -* ]]; then
            nargs=$(( nargs + 1 ))
        fi
    done
    # Only the first positional is an existing VM; later ones (clone's destination) are new names.
    (( nargs == 0 )) || return 0

    case "$cmd" in
        # `create` is deliberately absent: it takes a new name, not an existing one.
        set|run|ip|provisioning-support|stop|delete|clone)
            # `augur-vm list` is read-only: a header row, then `local <name> 0 0 <state>` per VM.
            names="$("${COMP_WORDS[0]}" list 2>/dev/null | awk 'NR>1 {print $2}')"
            COMPREPLY=( $(compgen -W "$names" -- "$cur") )
            ;;
        help) COMPREPLY=( $(compgen -W "$cmds" -- "$cur") ) ;;
    esac
    return 0
}

# Deliberately no `-o default`: an empty reply (a new VM name, a free-form option value) must offer
# nothing rather than fall back to the files in the current directory.
complete -F _augur_vm augur-vm
