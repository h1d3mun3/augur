# zsh completion for augur and augur-vm. Installed to ~/.augur/completions/augur.zsh and sourced from
# ~/.zshrc by `bash install`.

_augur() {
    local -a cmds names macos
    local out
    cmds=(
        'up:Start the container / VM'
        'claude:Launch Claude Code'
        'shell:Open a shell (bash in a container, zsh in a macOS VM)'
        'setup-token:Get a Claude token in the guest'
        'install-cert:Trust a custom CA in the guest'
        'down:Stop the container / VM (kept)'
        'destroy:Stop and remove the container / VM'
        'status:Check status and toolchain'
        'init-conf:Scaffold the project config'
        'list:List all containers / VMs'
        'update:Update the image / base VM'
        'version:Show the augur version'
        'build:Build the image / base VM'
        'help:Show help'
    )

    if (( CURRENT == 2 )); then
        _describe -t commands 'augur command' cmds
        return
    fi

    case $words[CURRENT-1] in
        --swift|--platforms) return ;;                         # free-form values
        --ipsw|--xcode-xip) _files; return ;;
    esac

    if [[ $words[CURRENT] == -* ]]; then
        compadd -- --macos --gui --egress --no-egress --swift --ipsw --xcode-xip --platforms --manual-setup
        return
    fi

    case $words[2] in
        install-cert) _files ;;
        destroy)
            (( ${words[(I)--macos]} )) && macos=(--macos)
            # `augur __names` is the hidden, quiet, read-only list of this mode's container/VM names.
            out=$($words[1] __names $macos 2>/dev/null)
            # Exit 3 = the container service is stopped. Completion never starts it (a TAB press
            # must not have side effects), so say why there is nothing to offer.
            if (( $? == 3 )); then
                _message 'Apple Container service is not running (run: augur list)'
                return
            fi
            names=( ${(f)out} )
            compadd -a names
            ;;
    esac
}

# compdef exists only once the user's compinit has run; load it if they have not yet.
(( $+functions[compdef] )) || { autoload -Uz compinit && compinit; }
compdef _augur augur

# augur-vm: the macOS VM backend binary installed next to augur.
_augur_vm() {
    local -a cmds opts names
    local i nargs=0
    # Options that take a value as the next word.
    local -a valopts=(--from-ipsw --disk-size --cpu --memory --dir --net-vfkit --provision-username --provision-full-name)
    cmds=(
        'version:Print the augur-vm version'
        'list:List VMs'
        'smoke:Verify VZ links and the virtualization entitlement'
        'create:Create a VM from an IPSW restore image'
        'set:Set CPU count and/or memory on a VM'
        'run:Boot a VM and keep it running'
        'ip:Print the IP address of a VM'
        'provisioning-support:Report whether a VM can provision its account automatically'
        'stop:Stop a running VM'
        'delete:Delete a VM bundle'
        'clone:Copy-on-write clone a VM'
        'help:Show help'
    )

    if (( CURRENT == 2 )); then
        if [[ $words[CURRENT] == -* ]]; then
            compadd -- --help --version
        else
            _describe -t commands 'augur-vm command' cmds
        fi
        return
    fi

    case $words[CURRENT-1] in
        --from-ipsw|--net-vfkit) _files; return ;;
        --disk-size|--cpu|--memory|--dir|--provision-username|--provision-full-name) return ;;  # free-form values
    esac
    # zsh keeps `--opt=value` as one word: complete only the part after the `=`.
    case $words[CURRENT] in
        --from-ipsw=*|--net-vfkit=*) compset -P '*='; _files; return ;;
        --disk-size=*|--cpu=*|--memory=*|--dir=*|--provision-username=*|--provision-full-name=*) return ;;  # free-form values
    esac

    case $words[2] in
        create) opts=(--from-ipsw --disk-size) ;;
        set)    opts=(--cpu --memory) ;;
        run)    opts=(--no-graphics --dir --net-vfkit --net-nat --provision-username --provision-password-stdin --provision-full-name) ;;
    esac
    if [[ $words[CURRENT] == -* ]]; then
        compadd -- $opts --help
        return
    fi

    # Count the positional arguments before the cursor, skipping options and their values.
    for (( i = 3; i < CURRENT; i++ )); do
        if (( ${valopts[(Ie)$words[i]]} )); then
            i=$(( i + 1 ))
        elif [[ $words[i] != -* ]]; then
            nargs=$(( nargs + 1 ))
        fi
    done
    # Only the first positional is an existing VM; later ones (clone's destination) are new names.
    (( nargs == 0 )) || return

    case $words[2] in
        # `create` is deliberately absent: it takes a new name, not an existing one.
        set|run|ip|provisioning-support|stop|delete|clone)
            # `augur-vm list` is read-only: a header row, then `local <name> 0 0 <state>` per VM.
            names=( ${(f)"$($words[1] list 2>/dev/null | awk 'NR>1 {print $2}')"} )
            compadd -a names
            ;;
        help) _describe -t commands 'augur-vm command' cmds ;;
    esac
}

compdef _augur_vm augur-vm
