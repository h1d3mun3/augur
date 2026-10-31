# zsh completion for augur. Installed to ~/.augur/completions/augur.zsh and sourced from
# ~/.zshrc by `bash install`.

_augur() {
    local -a cmds names macos
    cmds=(
        'up:Start the container / VM'
        'claude:Launch Claude Code'
        'shell:Open a bash shell'
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
        compadd -- --macos --gui --egress --no-egress --swift --ipsw --xcode-xip --platforms
        return
    fi

    case $words[2] in
        install-cert) _files ;;
        destroy)
            (( ${words[(I)--macos]} )) && macos=(--macos)
            # `augur __names` is the hidden, quiet, read-only list of this mode's container/VM names.
            names=( ${(f)"$($words[1] __names $macos 2>/dev/null)"} )
            compadd -a names
            ;;
    esac
}

# compdef exists only once the user's compinit has run; load it if they have not yet.
(( $+functions[compdef] )) || { autoload -Uz compinit && compinit; }
compdef _augur augur
